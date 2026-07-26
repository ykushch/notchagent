import Foundation

/// Resolves the herdr Unix-socket path per the documented order:
/// explicit arg → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → default.
public enum SocketPath {
    public static let defaultPath = NSString(string: "~/.config/herdr/herdr.sock")
        .expandingTildeInPath

    /// - Parameters:
    ///   - explicit: a `--session <name>`-style explicit socket *path* (already resolved by a caller), if any.
    ///   - environment: the environment to read (`HERDR_SOCKET_PATH`, `HERDR_SESSION`). Injectable for tests.
    public static func resolve(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let explicit, !explicit.isEmpty {
            return NSString(string: explicit).expandingTildeInPath
        }
        if let fromEnv = environment["HERDR_SOCKET_PATH"], !fromEnv.isEmpty {
            return NSString(string: fromEnv).expandingTildeInPath
        }
        if let session = environment["HERDR_SESSION"], !session.isEmpty {
            return forSession(session)
        }
        return defaultPath
    }

    /// Best-effort socket path for a named session.
    ///
    /// **Fallback only.** herdr's `session list --json` reports the authoritative
    /// `socket_path`; use `SessionDirectory.localSessions()` whenever the CLI is
    /// reachable. This exists for when it isn't.
    ///
    /// Note the special case: herdr does *not* put the default session under
    /// `sessions/` — its socket is `~/.config/herdr/herdr.sock`. Deriving a path
    /// from the name alone was wrong for the most common session of all.
    public static func forSession(_ name: String) -> String {
        guard !name.isEmpty, name != SessionDescriptor.defaultSessionName else {
            return defaultPath
        }
        return NSString(string: "~/.config/herdr/sessions/\(name)/herdr.sock")
            .expandingTildeInPath
    }
}
