import Foundation
import Testing
@testable import HerdrClient

/// Exercises the supervision state machine against a stand-in `ssh` binary.
///
/// A real round-trip needs a reachable sshd, which CI and most dev machines do
/// not have. The stand-in still drives the parts that are ours: the local socket
/// is bound before we report `.up`, a failure surfaces ssh's own stderr, and the
/// socket file is cleaned up on the way out.
@Suite("SSH tunnel supervision", .serialized)
struct SSHTunnelSupervisionTests {
    /// A script that binds the `-L` forward's local socket and then waits, the way
    /// a working `ssh -N -L` does.
    private static let bindingScript = """
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            */*.sock:*) spec="$arg";;
          esac
        done
        local_path="${spec%%:*}"
        python3 -c "
        import socket, sys, time
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sys.argv[1])
        s.listen(1)
        while True: time.sleep(0.2)
        " "$local_path"
        """

    private static let failingScript = """
        #!/bin/sh
        echo "workbox: Permission denied (publickey)." >&2
        exit 255
        """

    private static let noSocketScript = """
        #!/bin/sh
        while true; do sleep 1; done
        """

    private static let noisyBindingScript = """
        #!/bin/sh
        head -c 262144 /dev/zero >&2
        for arg in "$@"; do
          case "$arg" in
            */*.sock:*) spec="$arg";;
          esac
        done
        local_path="${spec%%:*}"
        python3 -c "
        import socket, sys, time
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sys.argv[1])
        s.listen(1)
        while True: time.sleep(0.2)
        " "$local_path"
        """

    private static let shortLivedBindingScript = """
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            */*.sock:*) spec="$arg";;
          esac
        done
        local_path="${spec%%:*}"
        python3 -c "
        import socket, sys, time
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sys.argv[1])
        s.listen(1)
        time.sleep(0.25)
        " "$local_path"
        """

    private func makeScript(_ body: String, name: String) throws -> String {
        let path = NSTemporaryDirectory() + "notchagent-fake-ssh-\(name)"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func configuration(local: String) -> SSHTunnel.Configuration {
        SSHTunnel.Configuration(
            target: "workbox",
            remoteSocketPath: "/home/you/.config/herdr/herdr.sock",
            localSocketPath: local)
    }

    @Test("reports .up only once the local socket is actually bound")
    func reachesUpWhenSocketIsBound() async throws {
        let script = try makeScript(Self.bindingScript, name: "bind")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let socketPath = SSHTunnel.localSocketPath(forSessionID: "ssh:test/bind")
        try? FileManager.default.removeItem(atPath: socketPath)

        let tunnel = SSHTunnel(
            configuration: configuration(local: socketPath), sshPath: script)
        let recorder = StateRecorder()
        await tunnel.start { recorder.record($0) }

        try await recorder.waitForUp(timeout: 20)
        #expect(await tunnel.state == .up)
        // `.up` must mean genuinely connectable, not merely "ssh is running".
        #expect(FileManager.default.fileExists(atPath: socketPath))
        #expect(recorder.states.firstIndex(of: .connecting)
            .map { index in recorder.states.firstIndex(of: .up).map { $0 > index } ?? false } ?? false)

        await tunnel.stop()
        // A leftover socket file makes the next ssh refuse to bind, wedging the
        // tunnel permanently — so teardown has to remove it.
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(await tunnel.state == .idle)
    }

    @Test("a stale socket file from a previous crash does not wedge the tunnel")
    func clearsStaleSocketFile() async throws {
        let script = try makeScript(Self.bindingScript, name: "stale")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let socketPath = SSHTunnel.localSocketPath(forSessionID: "ssh:test/stale")
        try SSHTunnel.prepareSocketDirectory(socketPath)
        // Simulate the leftover from a hard kill.
        FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))
        #expect(FileManager.default.fileExists(atPath: socketPath))

        let tunnel = SSHTunnel(
            configuration: configuration(local: socketPath), sshPath: script)
        let recorder = StateRecorder()
        await tunnel.start { recorder.record($0) }
        try await recorder.waitForUp(timeout: 20)
        #expect(await tunnel.state == .up)
        await tunnel.stop()
    }

    @Test("ssh failing surfaces its own reason and retries rather than giving up")
    func surfacesFailureAndRetries() async throws {
        let script = try makeScript(Self.failingScript, name: "fail")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let socketPath = SSHTunnel.localSocketPath(forSessionID: "ssh:test/fail")

        let tunnel = SSHTunnel(
            configuration: configuration(local: socketPath),
            sshPath: script,
            backoff: BackoffPolicy(base: 0.2, max: 0.2))
        let recorder = StateRecorder()
        await tunnel.start { recorder.record($0) }

        try await recorder.waitForFailure(timeout: 20)
        let reason = try #require(recorder.reasons.first)
        // The actionable diagnosis, not "herdr isn't running".
        #expect(reason.contains("authenticate"))
        #expect(reason.contains("ssh-add"))

        // It keeps trying: a key can be added with ssh-add while the app runs.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(recorder.reasons.count >= 2)
        await tunnel.stop()
    }

    @Test("a live ssh process without a socket times out and retries")
    func readinessTimeoutDoesNotParkConnecting() async throws {
        let script = try makeScript(Self.noSocketScript, name: "no-socket")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let socketPath = SSHTunnel.localSocketPath(forSessionID: "ssh:test/no-socket")
        let tunnel = SSHTunnel(
            configuration: configuration(local: socketPath),
            sshPath: script,
            backoff: BackoffPolicy(base: 60, max: 60),
            readinessTimeout: 0.2)
        let recorder = StateRecorder()
        await tunnel.start { recorder.record($0) }

        try await recorder.waitForFailure(timeout: 3)
        #expect(recorder.reasons.contains { $0.contains("did not become ready") })
        await tunnel.stop()
    }

    @Test("stderr is drained while a long-lived tunnel is running")
    func drainsStderrBeforeExit() async throws {
        let script = try makeScript(Self.noisyBindingScript, name: "noisy")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let socketPath = SSHTunnel.localSocketPath(forSessionID: "ssh:test/noisy")
        let tunnel = SSHTunnel(
            configuration: configuration(local: socketPath),
            sshPath: script,
            readinessTimeout: 2)
        let recorder = StateRecorder()
        await tunnel.start { recorder.record($0) }

        try await recorder.waitForUp(timeout: 3)
        await tunnel.stop()
    }

    @Test("a healthy connection resets the reconnect backoff streak")
    func healthyConnectionResetsBackoff() async throws {
        let script = try makeScript(Self.shortLivedBindingScript, name: "short-lived")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let socketPath = SSHTunnel.localSocketPath(forSessionID: "ssh:test/short-lived")
        let tunnel = SSHTunnel(
            configuration: configuration(local: socketPath),
            sshPath: script,
            backoff: BackoffPolicy(base: 0.2, max: 2),
            readinessTimeout: 1)
        let recorder = StateRecorder()
        await tunnel.start { recorder.record($0) }

        // Five successful reconnects fit comfortably only if each `.up` resets
        // the exponential failure streak.
        try await recorder.waitForUpCount(5, timeout: 3)
        await tunnel.stop()
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SSHTunnel.State] = []

    func record(_ state: SSHTunnel.State) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(state)
    }

    var states: [SSHTunnel.State] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var reasons: [String] {
        states.compactMap { if case let .failed(reason) = $0 { return reason } else { return nil } }
    }

    func waitForUp(timeout: TimeInterval) async throws {
        try await wait(timeout: timeout) { $0.contains(.up) }
    }

    func waitForFailure(timeout: TimeInterval) async throws {
        try await wait(timeout: timeout) { states in
            states.contains { if case .failed = $0 { return true } else { return false } }
        }
    }

    func waitForUpCount(_ count: Int, timeout: TimeInterval) async throws {
        try await wait(timeout: timeout) { states in
            states.filter { $0 == .up }.count >= count
        }
    }

    private func wait(
        timeout: TimeInterval, until predicate: ([SSHTunnel.State]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(states) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("timed out waiting; saw \(states)")
    }
}
