import Foundation
import Testing
@testable import HerdrClient

@Suite("SSH tunnel")
struct SSHTunnelTests {
    private func configuration(
        target: String = "workbox",
        remote: String = "/home/you/.config/herdr/herdr.sock",
        local: String = "/tmp/notchagent/abc123.sock"
    ) -> SSHTunnel.Configuration {
        SSHTunnel.Configuration(
            target: target, remoteSocketPath: remote, localSocketPath: local)
    }

    @Test("forwards the socket and nothing else")
    func argumentsForwardOnly() throws {
        let arguments = SSHTunnel.arguments(for: configuration())
        #expect(arguments.contains("-N"))
        #expect(arguments.last == "workbox")
        #expect(arguments.contains("ControlMaster=auto"))
        // A persistent mux master implicitly backgrounds itself, detaching the
        // real forward from the Process that SSHTunnel supervises.
        #expect(!arguments.contains { $0.hasPrefix("ControlPersist=") })
        let forwardIndex = try #require(arguments.firstIndex(of: "-L"))
        #expect(arguments[forwardIndex + 1]
            == "/tmp/notchagent/abc123.sock:/home/you/.config/herdr/herdr.sock")
    }

    @Test("fails fast instead of hanging a GUI app on a prompt")
    func argumentsAreNonInteractive() {
        let arguments = SSHTunnel.arguments(for: configuration())
        // No terminal exists to type a passphrase into.
        #expect(arguments.contains("BatchMode=yes"))
        // A live session with a dead forward would look "connected" but never work.
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
        // A closed laptop lid or VPN change drops the link silently otherwise.
        #expect(arguments.contains("ServerAliveInterval=15"))
        #expect(arguments.contains("ServerAliveCountMax=3"))
    }

    @Test("local socket paths stay inside the Unix sun_path limit")
    func socketPathsRespectSunPathLimit() {
        // macOS caps sockaddr_un.sun_path at 104 bytes including the terminator,
        // and a session id can be arbitrarily long.
        let absurd = "ssh:" + String(repeating: "very-long-host-name.example.com", count: 12)
            + "/" + String(repeating: "session", count: 20)
        for sessionID in ["local:default", "ssh:workbox/agents", absurd] {
            let path = SSHTunnel.localSocketPath(forSessionID: sessionID)
            #expect(path.utf8.count <= SSHTunnel.maxSocketPathLength)
            #expect(path.hasPrefix(SSHTunnel.defaultSocketDirectory))
            #expect(path.hasSuffix(".sock"))
        }
        #expect(SSHTunnel.defaultSocketDirectory.hasPrefix(NSTemporaryDirectory()))
        #expect(SSHTunnel.defaultSocketDirectory != "/tmp/notchagent")
    }

    @Test("socket paths are deterministic per session and distinct across sessions")
    func socketPathsAreStableAndUnique() {
        let a = SSHTunnel.localSocketPath(forSessionID: "ssh:workbox/default")
        let b = SSHTunnel.localSocketPath(forSessionID: "ssh:workbox/agents")
        let c = SSHTunnel.localSocketPath(forSessionID: "ssh:buildbox/default")
        // Stable: restarting must reuse the same path, not leak a new socket file.
        #expect(a == SSHTunnel.localSocketPath(forSessionID: "ssh:workbox/default"))
        // Unique: two tunnels must never fight over one path.
        #expect(Set([a, b, c]).count == 3)
    }

    @Test("an over-long socket path is rejected before ssh is launched")
    func rejectsOverLongPath() {
        let tooLong = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: SSHTunnel.TunnelError.socketPathTooLong(tooLong)) {
            try SSHTunnel.prepareSocketDirectory(tooLong)
        }
    }

    @Test("auth failure is explained as auth, not as a missing server")
    func explainsAuthFailure() {
        let message = SSHTunnel.explain(
            stderr: "workbox: Permission denied (publickey).", status: 255, target: "workbox")
        #expect(message.contains("authenticate"))
        #expect(message.contains("ssh-add"))
        #expect(message.contains("workbox"))
        // The failure the user must NOT be sent chasing.
        #expect(!message.lowercased().contains("herdr isn't running"))
    }

    @Test("a forwarding failure points at herdr on the remote, not at ssh")
    func explainsForwardingFailure() {
        let message = SSHTunnel.explain(
            stderr: "unix_listener: cannot bind to path: forwarding request failed",
            status: 255, target: "workbox")
        #expect(message.contains("herdr"))
        #expect(message.contains("workbox"))
    }

    @Test("unreachable and unresolvable hosts read differently")
    func explainsReachabilityFailures() {
        let unresolved = SSHTunnel.explain(
            stderr: "ssh: Could not resolve hostname workbox", status: 255, target: "workbox")
        #expect(unresolved.contains("resolve"))

        let refused = SSHTunnel.explain(
            stderr: "ssh: connect to host workbox port 22: Connection refused",
            status: 255, target: "workbox")
        #expect(refused.contains("reach"))
        #expect(unresolved != refused)
    }

    @Test("a silent exit still produces a message")
    func explainsSilentExit() {
        let message = SSHTunnel.explain(stderr: "", status: 1, target: "workbox")
        #expect(message.contains("workbox"))
        #expect(message.contains("1"))
    }

    @Test("a tunnel with no ssh binary fails instead of hanging")
    func missingSSHFails() async {
        let tunnel = SSHTunnel(
            configuration: configuration(local: "/tmp/notchagent/test-nossh.sock"),
            sshPath: nil,
            backoff: BackoffPolicy(base: 60, max: 60))
        let states = StateRecorder()
        await tunnel.start { state in states.record(state) }
        // One supervise pass is enough: it must reach .failed, not sit in
        // .connecting forever.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await tunnel.stop()
        #expect(states.reasons.contains { $0.contains("ssh") })
    }

    @Test("persisted option-shaped targets are rejected by the tunnel boundary")
    func invalidTargetFailsBeforeLaunch() async {
        let tunnel = SSHTunnel(
            configuration: configuration(target: "-oProxyCommand=bad"),
            sshPath: "/path/that/must/not/run",
            backoff: BackoffPolicy(base: 60, max: 60))
        let states = StateRecorder()
        await tunnel.start { states.record($0) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await tunnel.stop()
        #expect(states.reasons.contains { $0.contains("Invalid SSH target") })
    }

    @Test("stopping an idle tunnel is safe and leaves no socket behind")
    func stopIsIdempotent() async {
        let path = "/tmp/notchagent/test-idle.sock"
        let tunnel = SSHTunnel(configuration: configuration(local: path), sshPath: nil)
        await tunnel.stop()
        await tunnel.stop()
        #expect(await tunnel.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SSHTunnel.State] = []

    func record(_ state: SSHTunnel.State) {
        lock.lock(); defer { lock.unlock() }
        states.append(state)
    }

    var reasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return states.compactMap { if case let .failed(reason) = $0 { return reason } else { return nil } }
    }
}
