import Foundation

/// Forwards a remote herdr socket to a local path over SSH.
///
/// This is the whole of "remote support". herdr exposes no remote API — its socket
/// is a Unix socket on the host that runs the server — so rather than inventing a
/// transport we let OpenSSH forward the socket and point an ordinary
/// `HerdrClient` at the local end. `SocketConnection` never learns that a session
/// is remote.
public actor SSHTunnel {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case up
        /// Terminal-ish: retried with backoff, but the reason is surfaced so the
        /// user can fix it rather than watching a silent retry loop.
        case failed(reason: String)

        public var isUp: Bool { self == .up }
    }

    public struct Configuration: Sendable, Equatable {
        /// Any ssh destination: `workbox`, `you@host`, a `Host` alias.
        public let target: String
        /// Absolute path of the herdr socket **on the remote host**. `ssh -L` does
        /// not tilde-expand this, which is why we ask the remote CLI for it.
        public let remoteSocketPath: String
        /// Where the forward lands locally.
        public let localSocketPath: String

        public init(target: String, remoteSocketPath: String, localSocketPath: String) {
            self.target = target
            self.remoteSocketPath = remoteSocketPath
            self.localSocketPath = localSocketPath
        }
    }

    public private(set) var state: State = .idle

    private let configuration: Configuration
    private let sshPath: String?
    private let backoff: BackoffPolicy
    private let readinessTimeout: TimeInterval
    private let readinessProbe: @Sendable (String) async -> Bool
    private var process: Process?
    private var superviseTask: Task<Void, Never>?
    private var onStateChange: (@Sendable (State) -> Void)?

    public init(
        configuration: Configuration,
        sshPath: String? = ExecutableLocator.locate("ssh"),
        backoff: BackoffPolicy = BackoffPolicy(base: 1.0, max: 30.0),
        readinessTimeout: TimeInterval = 15,
        readinessProbe: (@Sendable (String) async -> Bool)? = nil
    ) {
        self.configuration = configuration
        self.sshPath = sshPath
        self.backoff = backoff
        self.readinessTimeout = readinessTimeout
        let probeTimeout = min(max(readinessTimeout, 0.1), 2.0)
        self.readinessProbe = readinessProbe ?? { socketPath in
            await HerdrClient(
                socketPath: socketPath, requestTimeout: probeTimeout).ping()
        }
    }

    // MARK: Arguments

    /// `-N` because we want the forward and nothing else — no remote command, no
    /// shell.
    ///
    /// `ExitOnForwardFailure` turns "the forward didn't happen" into a process
    /// exit we can see, instead of a live SSH session with a dead socket.
    /// `BatchMode` makes a missing key fail immediately rather than block forever
    /// on a password prompt that has no terminal to read from — a GUI app must
    /// never hang there. The keepalives detect a silently dropped link, which a
    /// laptop lid or a VPN change produces routinely.
    public static func arguments(for configuration: Configuration) -> [String] {
        [
            "-N",
        ] + SSHMultiplexing.tunnelArguments(for: configuration.target) + [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-L", "\(configuration.localSocketPath):\(configuration.remoteSocketPath)",
            configuration.target,
        ]
    }

    /// A short, deterministic local socket path for a session.
    ///
    /// macOS caps `sockaddr_un.sun_path` at 104 bytes *including* the terminator,
    /// and connecting fails outright past that — so the path is derived from a
    /// truncated digest of the session id rather than from the id itself, which
    /// can be arbitrarily long (`ssh:some-long-host.example.com/some-session`).
    public static func localSocketPath(
        forSessionID sessionID: String,
        directory: String = SSHTunnel.defaultSocketDirectory
    ) -> String {
        let digest = SHA256Digest.hex(of: Data(sessionID.utf8)).prefix(12)
        return (directory as NSString).appendingPathComponent("\(digest).sock")
    }

    /// Per-user on macOS (`/var/folders/.../T`), unlike the shared `/tmp`
    /// namespace where another account could pre-create a writable directory.
    public static let defaultSocketDirectory =
        (NSTemporaryDirectory() as NSString).appendingPathComponent("notchagent")

    /// The hard limit a local socket path must respect.
    public static let maxSocketPathLength = 103

    // MARK: Lifecycle

    /// Start supervising the forward. Safe to call twice.
    public func start(onStateChange: @escaping @Sendable (State) -> Void) {
        self.onStateChange = onStateChange
        guard superviseTask == nil else { return }
        superviseTask = Task { [weak self] in
            await self?.supervise()
        }
    }

    public func stop() {
        superviseTask?.cancel()
        superviseTask = nil
        terminateProcess()
        removeSocketFile()
        transition(to: .idle)
    }

    private func supervise() async {
        var attempt = 0
        while !Task.isCancelled {
            let outcome = await runOnce()
            if Task.isCancelled { break }
            // A connection that genuinely came up starts a new failure streak.
            if outcome.reachedUp { attempt = 0 }
            attempt += 1
            transition(to: .failed(reason: outcome.failure))
            let delay = backoff.delay(forAttempt: attempt)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Runs ssh until it exits, returning why it stopped.
    private func runOnce() async -> RunOutcome {
        guard SSHTarget.isValid(configuration.target) else {
            return .failed("Invalid SSH target: \(configuration.target)")
        }
        guard let sshPath else { return .failed("Couldn't find the ssh command.") }
        transition(to: .connecting)
        do {
            try Self.prepareSocketDirectory(configuration.localSocketPath)
        } catch {
            return .failed("Couldn't prepare \(configuration.localSocketPath): \(error)")
        }
        // ssh refuses to bind a local socket path that already exists, so a
        // previous crash would otherwise wedge the tunnel permanently.
        removeSocketFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = Self.arguments(for: configuration)
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failed("Couldn't start ssh: \(error)")
        }
        self.process = process
        let stderrDrain = BoundedPipeDrain(
            handle: errPipe.fileHandleForReading, maximumBytes: 64 * 1024)
        stderrDrain.start()

        // A bound local listener proves only that ssh accepted `-L`. The remote
        // stream-local channel is opened lazily on the first client connection,
        // where a proxy or sshd may still reject it. Publish `.up` only after a
        // real herdr request has crossed the complete forward.
        let becameReady = await waitUntilHerdrResponds(timeout: readinessTimeout)
        if becameReady, process.isRunning { transition(to: .up) }
        let readinessTimedOut = !becameReady && process.isRunning && !Task.isCancelled
        // Do not park in `.connecting` forever. A live ssh process without the
        // promised herdr response is not a usable tunnel; terminate it and let
        // supervision retry with backoff.
        if readinessTimedOut { process.terminate() }

        // ssh can exit before `terminationHandler` is even installed — an auth
        // failure returns in milliseconds — so both the handler and the liveness
        // check race to resume. The gate makes whichever arrives first the only
        // one that does; resuming twice traps.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeGate(continuation)
            process.terminationHandler = { _ in gate.resume() }
            if !process.isRunning { gate.resume() }
        }
        self.process = nil
        removeSocketFile()
        stderrDrain.wait()

        let stderr = String(
            decoding: stderrDrain.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = readinessTimedOut
            ? Self.readinessFailure(stderr: stderr, configuration: configuration)
            : Self.explain(stderr: stderr, status: process.terminationStatus,
                           target: configuration.target)
        return RunOutcome(failure: failure, reachedUp: becameReady)
    }

    /// Turns ssh's stderr into something the user can act on. Auth failures are
    /// the common case and are not fixable by retrying.
    public static func explain(stderr: String, status: Int32, target: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") || lower.contains("publickey") {
            return "SSH couldn't authenticate to \(target). Load your key with `ssh-add`, or check your ~/.ssh/config."
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return "SSH couldn't resolve \(target). Check the host name."
        }
        if lower.contains("connection refused") || lower.contains("connection timed out")
            || lower.contains("operation timed out") {
            return "Couldn't reach \(target) over SSH."
        }
        if lower.contains("forwarding") || lower.contains("bind") {
            return "SSH connected to \(target) but couldn't forward the herdr socket. Is herdr running there?"
        }
        if stderr.isEmpty {
            return "The SSH tunnel to \(target) exited (status \(status))."
        }
        return "SSH tunnel to \(target) failed: \(stderr)"
    }

    // MARK: Socket file plumbing

    private func waitUntilHerdrResponds(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if FileManager.default.fileExists(atPath: configuration.localSocketPath),
               await readinessProbe(configuration.localSocketPath) {
                return true
            }
            if process?.isRunning != true { return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    static func readinessFailure(
        stderr: String, configuration: Configuration
    ) -> String {
        let lower = stderr.lowercased()
        if lower.contains("administratively prohibited")
            || lower.contains("open failed") {
            return "SSH connected to \(configuration.target), but its server or proxy refused Unix-socket forwarding."
        }
        if lower.contains("no such file or directory") {
            return "SSH connected to \(configuration.target), but the remote herdr socket does not exist at \(configuration.remoteSocketPath)."
        }
        if lower.contains("permission denied") {
            return "SSH connected to \(configuration.target), but it cannot access the remote herdr socket at \(configuration.remoteSocketPath)."
        }
        let base = "SSH connected to \(configuration.target), but herdr did not answer through \(configuration.remoteSocketPath)."
        return stderr.isEmpty ? base : "\(base) SSH reported: \(stderr)"
    }

    private struct RunOutcome {
        let failure: String
        let reachedUp: Bool

        static func failed(_ failure: String) -> Self {
            Self(failure: failure, reachedUp: false)
        }
    }

    static func prepareSocketDirectory(_ socketPath: String) throws {
        guard socketPath.utf8.count <= maxSocketPathLength else {
            throw TunnelError.socketPathTooLong(socketPath)
        }
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: configuration.localSocketPath)
    }

    /// Deliberately leaves `terminationHandler` installed: clearing it would
    /// strand the continuation in `runOnce` waiting for an exit it never hears
    /// about.
    private func terminateProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    public enum TunnelError: Error, Sendable, Equatable {
        case socketPathTooLong(String)
    }
}

/// Continuously drains a long-lived helper's pipe while retaining only a bounded
/// stderr tail for diagnostics.
private final class BoundedPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()
    private var didStart = false

    init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = maximumBytes
    }

    func start() {
        lock.lock()
        guard !didStart else {
            lock.unlock()
            return
        }
        didStart = true
        lock.unlock()

        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                captured.append(chunk)
                if captured.count > maximumBytes {
                    captured.removeFirst(captured.count - maximumBytes)
                }
                lock.unlock()
            }
            completion.leave()
        }
    }

    func wait() {
        completion.wait()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

/// Lets several racing callbacks share one continuation safely.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

extension SSHTunnel.TunnelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path):
            "Socket path is too long for a Unix socket (\(path.utf8.count) > \(SSHTunnel.maxSocketPathLength) bytes): \(path)"
        }
    }
}
