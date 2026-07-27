import Foundation
import Testing
@testable import HerdrClient

@Suite("SSH tunnel")
struct SSHTunnelTests {
    private func configuration(
        target: String = "workbox",
        remote: String = "/home/you/.config/herdr/herdr.sock",
        localPort: UInt16 = 47_891
    ) -> SSHTunnel.Configuration {
        SSHTunnel.Configuration(
            target: target, remoteSocketPath: remote, localPort: localPort)
    }

    @Test("forwards the socket and nothing else")
    func argumentsForwardOnly() throws {
        let arguments = SSHTunnel.arguments(for: configuration())
        #expect(arguments.contains("-N"))
        #expect(arguments.last == "workbox")
        // A tunnel must remain the foreground process SSHTunnel owns. It cannot
        // join another master or background itself, including when the user's
        // ssh config enables connection sharing globally.
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("ControlPersist=no"))
        #expect(arguments.contains("ControlPath=none"))
        #expect(!arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("PermitLocalCommand=no"))
        let forwardIndex = try #require(arguments.firstIndex(of: "-L"))
        #expect(arguments[forwardIndex + 1]
            == "127.0.0.1:47891:/home/you/.config/herdr/herdr.sock")
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

    @Test("allocates a private loopback port")
    func allocatesLoopbackPort() throws {
        let port = try SSHTunnel.availableLoopbackPort()
        #expect(port > 0)
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

    @Test("readiness failures distinguish forwarding policy from a missing socket")
    func explainsReadinessFailures() {
        let configuration = configuration()
        let prohibited = SSHTunnel.readinessFailure(
            stderr: "channel 2: open failed: administratively prohibited: open failed",
            configuration: configuration)
        #expect(prohibited.contains("refused Unix-socket forwarding"))

        let missing = SSHTunnel.readinessFailure(
            stderr: "connect to /home/you/.config/herdr/herdr.sock: No such file or directory",
            configuration: configuration)
        #expect(missing.contains(configuration.remoteSocketPath))
        #expect(missing.contains("does not exist"))
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
            configuration: configuration(),
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

    @Test("stopping an idle tunnel is safe")
    func stopIsIdempotent() async {
        let tunnel = SSHTunnel(configuration: configuration(), sshPath: nil)
        await tunnel.stop()
        await tunnel.stop()
        #expect(await tunnel.state == .idle)
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
