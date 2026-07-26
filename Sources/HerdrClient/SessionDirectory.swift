import Foundation

/// Enumerates herdr sessions.
///
/// This has to shell out: the socket API has no session-listing method, so
/// `herdr session list --json` is the only authority on which sessions exist and
/// — crucially — where their sockets actually are. The default session's socket is
/// `~/.config/herdr/herdr.sock`, *not* under `sessions/`, so a path built from the
/// session name alone is wrong for the most common case (see
/// `SocketPath.forSession`, which is now a fallback only).
public struct SessionDirectory: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        /// The `herdr` (or `ssh`) binary could not be found.
        case executableNotFound(String)
        /// A user-provided destination would be interpreted as an ssh option.
        case invalidSSHTarget(String)
        /// The command ran but failed.
        case commandFailed(status: Int32, message: String)
        /// The command succeeded but did not produce a session list we understand.
        case malformedOutput(String)
    }

    private let runner: any CommandRunning
    private let herdrPath: String?
    private let sshPath: String?

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        herdrPath: String? = ExecutableLocator.locate("herdr"),
        sshPath: String? = ExecutableLocator.locate("ssh")
    ) {
        self.runner = runner
        self.herdrPath = herdrPath
        self.sshPath = sshPath
    }

    // MARK: Discovery

    /// Sessions served by a herdr on this machine.
    public func localSessions() throws -> [SessionDescriptor] {
        guard let herdrPath else { throw Failure.executableNotFound("herdr") }
        let output = try runner.run(
            executable: herdrPath, arguments: ["session", "list", "--json"])
        return try Self.decode(output, target: nil)
    }

    /// Sessions served by a herdr on `target`, reached over ssh.
    ///
    /// This is also how we learn each remote session's **absolute** socket path,
    /// which `ssh -L` needs — it does not expand `~` on the remote side.
    public func remoteSessions(target: String) throws -> [SessionDescriptor] {
        guard SSHTarget.isValid(target) else { throw Failure.invalidSSHTarget(target) }
        guard let sshPath else { throw Failure.executableNotFound("ssh") }
        let output = try runner.run(
            executable: sshPath, arguments: Self.sshArguments(target: target))
        return try Self.decode(output, target: target)
    }

    // MARK: Command construction

    /// `BatchMode` keeps a missing key from hanging on a password prompt with no
    /// terminal to type into; the failure surfaces as an error we can explain.
    static func sshArguments(target: String) -> [String] {
        SSHMultiplexing.discoveryArguments(for: target) + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            target,
            remoteListCommand,
        ]
    }

    /// A non-interactive `ssh host cmd` runs a non-login shell, so the remote
    /// `PATH` often misses `~/.local/bin` — herdr's own default install prefix.
    /// Probe the same well-known locations herdr's remote attach does.
    static let remoteListCommand = """
        for c in herdr "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr \
        /usr/local/bin/herdr "$HOME/.cargo/bin/herdr" "$HOME/.nix-profile/bin/herdr"; do \
        if command -v "$c" >/dev/null 2>&1; then exec "$c" session list --json; fi; done; \
        echo "herdr not found on remote PATH" >&2; exit 127
        """

    // MARK: Decoding

    /// Decode-tolerant per project convention: unknown fields are ignored, and an
    /// entry we cannot address (no name, and no socket path we can fall back to)
    /// is skipped rather than failing the whole list.
    static func decode(_ output: CommandOutput, target: String?) throws -> [SessionDescriptor] {
        guard output.isSuccess else {
            throw Failure.commandFailed(
                status: output.status,
                message: output.errorMessage.isEmpty
                    ? "exited with status \(output.status)" : output.errorMessage)
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: output.standardOutput)
        } catch {
            throw Failure.malformedOutput(
                String(decoding: output.standardOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let entries = payload.sessions else {
            throw Failure.malformedOutput("no \"sessions\" array in output")
        }
        return entries.compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            let isDefault = entry.isDefault ?? (name == SessionDescriptor.defaultSessionName)
            guard let socketPath = Self.socketPath(
                reported: entry.socketPath, name: name,
                isDefault: isDefault, isRemote: target != nil) else { return nil }
            return SessionDescriptor(
                kind: target.map { .remote(target: $0, name: name) } ?? .local(name: name),
                serverSocketPath: socketPath,
                isDefault: isDefault,
                // An absent future/older field should not make every otherwise
                // addressable session disappear. Explicit false still wins.
                isRunning: entry.running ?? true)
        }
    }

    /// Prefer what herdr reported. Falling back to a name-derived path is only
    /// safe locally — we cannot guess a remote home directory, and `ssh -L` would
    /// not expand it anyway.
    private static func socketPath(
        reported: String?, name: String, isDefault: Bool, isRemote: Bool
    ) -> String? {
        if let reported, !reported.isEmpty { return reported }
        guard !isRemote else { return nil }
        return isDefault ? SocketPath.defaultPath : SocketPath.forSession(name)
    }

    private struct Payload: Decodable {
        struct Entry: Decodable {
            var name: String?
            var running: Bool?
            var sessionDir: String?
            var socketPath: String?
            var isDefault: Bool?

            enum CodingKeys: String, CodingKey {
                case name, running
                case sessionDir = "session_dir"
                case socketPath = "socket_path"
                case isDefault = "default"
            }
        }

        var sessions: [Entry]?
    }
}

extension SessionDirectory.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            "Couldn't find the \(name) command. Check that it's installed."
        case let .invalidSSHTarget(target):
            "Invalid SSH target: \(target)"
        case let .commandFailed(_, message):
            message
        case let .malformedOutput(text):
            "Unexpected session list output: \(text)"
        }
    }
}
