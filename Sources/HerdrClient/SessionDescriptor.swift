import Foundation

/// Validation shared by every boundary that passes a user-provided destination
/// to OpenSSH. `Process` avoids shell expansion, but a leading dash would still
/// be parsed as an ssh option.
public enum SSHTarget {
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// OpenSSH multiplexing options shared through one deterministic control path.
///
/// A tunnel may become the master, but must not use `ControlPersist`: OpenSSH
/// implicitly backgrounds a persistent master after authentication, which would
/// detach the real forward from `SSHTunnel`'s supervised `Process`. Discovery is
/// client-only so a short listing command can reuse a tunnel without ever leaving
/// its own background master behind.
public enum SSHMultiplexing {
    public static func controlPath(for target: String) -> String {
        let digest = SHA256Digest.hex(of: Data(target.utf8)).prefix(12)
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("notchagent-ssh-\(digest)")
    }

    public static func tunnelArguments(for target: String) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(for: target))",
        ]
    }

    public static func discoveryArguments(for target: String) -> [String] {
        [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath(for: target))",
        ]
    }
}

/// One herdr server NotchAgent can talk to.
///
/// herdr's socket API describes exactly one server: there is no session-listing
/// method and no remote addressing. `herdr --remote` is a *terminal UI* attach —
/// the server and its Unix socket stay on the remote host. So a session is
/// identified here by how we reach it: a local Unix socket, or a remote one that
/// an SSH tunnel forwards to a local path.
public struct SessionDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A herdr server on this machine.
        case local(name: String)
        /// A herdr server on `target` — any ssh destination (`workbox`,
        /// `you@server`, a `Host` alias from `~/.ssh/config`).
        case remote(target: String, name: String)

        public var name: String {
            switch self {
            case let .local(name): name
            case let .remote(_, name): name
            }
        }

        /// The ssh destination, or nil when the server is on this machine.
        public var sshTarget: String? {
            switch self {
            case .local: nil
            case let .remote(target, _): target
            }
        }
    }

    public let kind: Kind

    /// The socket path as herdr reported it, in the namespace of the host that
    /// runs the server.
    ///
    /// Directly connectable for `.local`. For `.remote` this is the *remote* end
    /// an `ssh -L` forward must point at — which is why we ask the remote CLI for
    /// it rather than guessing: `ssh -L` does not tilde-expand the remote path.
    public let serverSocketPath: String

    /// herdr reported this as the default session.
    public let isDefault: Bool
    /// herdr reported a server currently running for it.
    public let isRunning: Bool

    public init(
        kind: Kind,
        serverSocketPath: String,
        isDefault: Bool = false,
        isRunning: Bool = true
    ) {
        self.kind = kind
        self.serverSocketPath = serverSocketPath
        self.isDefault = isDefault
        self.isRunning = isRunning
    }

    /// Stable across restarts, and safe as a dictionary key or SwiftUI identity.
    ///
    /// Pane ids are only unique *within* one server — `w1:p1` exists on every host
    /// — so this is the prefix that makes an agent reference globally unique.
    public var id: String {
        switch kind {
        case let .local(name): "local:\(name)"
        case let .remote(target, name): "ssh:\(target)/\(name)"
        }
    }

    public var isRemote: Bool { kind.sshTarget != nil }

    /// Short label for the session badge in the attention list.
    public var label: String {
        switch kind {
        case let .local(name): name
        case let .remote(target, name):
            name == SessionDescriptor.defaultSessionName ? target : "\(target) · \(name)"
        }
    }

    /// The command that attaches a terminal to this session. Offered by the jump
    /// notice when no attached client is present to jump to.
    public var attachCommand: String {
        let isDefaultName = kind.name == SessionDescriptor.defaultSessionName
        switch kind {
        case let .local(name):
            return isDefaultName ? "herdr" : "herdr --session \(name)"
        case let .remote(target, name):
            let base = "herdr --remote \(target)"
            return isDefaultName ? base : "\(base) --session \(name)"
        }
    }

    /// herdr's name for the unnamed session. It is the one session whose socket is
    /// *not* under `sessions/`.
    public static let defaultSessionName = "default"

    /// The id of the local default session — the one everybody has, and the
    /// sensible identity for anything constructed before discovery has run.
    public static let localDefaultID = "local:\(defaultSessionName)"

    public static func localDefault(socketPath: String = SocketPath.defaultPath) -> Self {
        Self(kind: .local(name: defaultSessionName), serverSocketPath: socketPath,
             isDefault: true)
    }
}
