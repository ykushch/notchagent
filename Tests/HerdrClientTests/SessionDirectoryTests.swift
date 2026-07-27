import Foundation
import Testing
@testable import HerdrClient

/// Records what it was asked to run and replays a canned result.
private final class StubRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [(executable: String, arguments: [String])] = []
    private let result: Result<CommandOutput, any Error>

    init(_ result: Result<CommandOutput, any Error>) { self.result = result }

    convenience init(stdout: String, status: Int32 = 0, stderr: String = "") {
        self.init(.success(CommandOutput(
            status: status,
            standardOutput: Data(stdout.utf8),
            standardError: Data(stderr.utf8))))
    }

    var calls: [(executable: String, arguments: [String])] {
        lock.lock(); defer { lock.unlock() }
        return invocations
    }

    func run(executable: String, arguments: [String]) throws -> CommandOutput {
        lock.lock()
        invocations.append((executable, arguments))
        lock.unlock()
        return try result.get()
    }
}

private func directory(_ runner: StubRunner) -> SessionDirectory {
    SessionDirectory(runner: runner, herdrPath: "/fake/herdr", sshPath: "/fake/ssh")
}

@Suite("Session discovery")
struct SessionDirectoryTests {
    @Test("process runner drains large stdout and stderr without deadlocking")
    func drainsBothPipesConcurrently() throws {
        let output = try ProcessCommandRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2",
            ])

        #expect(output.status == 0)
        #expect(output.standardOutput.count == 262_144)
        #expect(output.standardError.count == 262_144)
    }

    @Test("decodes the live `herdr session list --json` capture")
    func decodesLiveCapture() throws {
        let runner = StubRunner(stdout: Fixtures.string("sessions/local-session-list.json"))
        let sessions = try directory(runner).localSessions()

        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.kind == .local(name: "default"))
        #expect(session.id == "local:default")
        #expect(session.isDefault)
        #expect(session.isRunning)
        // The whole point: the default session's socket is NOT under sessions/.
        #expect(session.serverSocketPath == "/Users/ykushch/.config/herdr/herdr.sock")
        #expect(!session.serverSocketPath.contains("/sessions/"))
        #expect(runner.calls.first?.arguments == ["session", "list", "--json"])
    }

    @Test("decodes named and stopped sessions")
    func decodesMultipleSessions() throws {
        let runner = StubRunner(stdout: Fixtures.string("sessions/multi-session-list.json"))
        let sessions = try directory(runner).localSessions()

        #expect(sessions.map(\.id) == ["local:default", "local:work", "local:side-project"])
        #expect(sessions.map(\.isRunning) == [true, true, false])
        #expect(sessions.filter(\.isDefault).map(\.id) == ["local:default"])
        #expect(sessions.allSatisfy { !$0.isRemote })
    }

    @Test("remote sessions carry the ssh target and the remote absolute socket path")
    func decodesRemoteSessions() throws {
        let runner = StubRunner(stdout: """
            {"sessions":[{"default":true,"name":"default","running":true,\
            "socket_path":"/home/you/.config/herdr/herdr.sock"},\
            {"default":false,"name":"agents","running":true,\
            "socket_path":"/home/you/.config/herdr/sessions/agents/herdr.sock"}]}
            """)
        let sessions = try directory(runner).remoteSessions(target: "workbox")

        #expect(sessions.map(\.id) == ["ssh:workbox/default", "ssh:workbox/agents"])
        #expect(sessions.allSatisfy { $0.isRemote })
        #expect(sessions.allSatisfy { $0.kind.sshTarget == "workbox" })
        // ssh -L needs the absolute remote path; we must use what the remote reported.
        #expect(sessions[1].serverSocketPath
            == "/home/you/.config/herdr/sessions/agents/herdr.sock")
        // Labels collapse "default" to just the host.
        #expect(sessions.map(\.label) == ["workbox", "workbox · agents"])
    }

    @Test("ssh invocation is non-interactive and probes the remote PATH")
    func sshArgumentsAreSafe() {
        let arguments = SessionDirectory.sshArguments(target: "workbox")
        // A missing key must fail fast, not block on a prompt with no terminal.
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ConnectTimeout=10"))
        // Discovery may reuse the tunnel's master but must never create a
        // background master of its own when no tunnel is available.
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("PermitLocalCommand=no"))
        #expect(!arguments.contains("ControlMaster=auto"))
        #expect(!arguments.contains { $0.hasPrefix("ControlPersist=") })
        #expect(arguments.contains {
            $0.hasPrefix("ControlPath=") && $0.contains("notchagent-ssh-")
        })
        #expect(arguments.contains("workbox"))
        // `ssh host cmd` is a non-login shell, so ~/.local/bin is usually absent.
        let command = arguments.last ?? ""
        #expect(command.contains("$HOME/.local/bin/herdr"))
        #expect(command.contains("session list --json"))
    }

    @Test("ssh-option-shaped destinations are rejected before launch")
    func rejectsOptionInjectionTarget() {
        let runner = StubRunner(stdout: #"{"sessions":[]}"#)
        #expect(throws: SessionDirectory.Failure.invalidSSHTarget(
            "-oProxyCommand=touch /tmp/notchagent-proof")) {
            try directory(runner).remoteSessions(
                target: "-oProxyCommand=touch /tmp/notchagent-proof")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("a remote entry with no socket path is skipped, not guessed")
    func remoteWithoutSocketPathIsSkipped() throws {
        let runner = StubRunner(stdout: """
            {"sessions":[{"name":"ghost","running":true},\
            {"name":"real","running":true,"socket_path":"/home/you/.config/herdr/herdr.sock"}]}
            """)
        // We cannot know a remote home directory, and ssh -L would not expand ~.
        let sessions = try directory(runner).remoteSessions(target: "workbox")
        #expect(sessions.map(\.kind.name) == ["real"])
    }

    @Test("a local entry with no socket path falls back to the name-derived path")
    func localWithoutSocketPathFallsBack() throws {
        let runner = StubRunner(stdout: """
            {"sessions":[{"name":"default","default":true},{"name":"work"}]}
            """)
        let sessions = try directory(runner).localSessions()

        #expect(sessions[0].serverSocketPath == SocketPath.defaultPath)
        #expect(sessions[1].serverSocketPath == SocketPath.forSession("work"))
        #expect(sessions[1].serverSocketPath.contains("/sessions/work/"))
    }

    @Test("an absent running field remains discoverable while explicit false stays stopped")
    func missingRunningDefaultsToAvailable() throws {
        let runner = StubRunner(stdout: """
            {"sessions":[
            {"name":"default","socket_path":"/tmp/default.sock"},
            {"name":"stopped","running":false,"socket_path":"/tmp/stopped.sock"}]}
            """)
        let sessions = try directory(runner).localSessions()

        #expect(sessions[0].isRunning)
        #expect(!sessions[1].isRunning)
    }

    @Test("unknown fields are ignored")
    func toleratesUnknownFields() throws {
        let runner = StubRunner(stdout: """
            {"sessions":[{"name":"default","default":true,"socket_path":"/tmp/a.sock",\
            "future_field":{"nested":1}}],"future_top_level":true}
            """)
        let sessions = try directory(runner).localSessions()
        #expect(sessions.map(\.serverSocketPath) == ["/tmp/a.sock"])
    }

    @Test("a failing command surfaces stderr")
    func failingCommandSurfacesStderr() {
        let runner = StubRunner(
            stdout: "", status: 255, stderr: "workbox: Permission denied (publickey).")
        #expect(throws: SessionDirectory.Failure.commandFailed(
            status: 255, message: "workbox: Permission denied (publickey).")) {
            try directory(runner).remoteSessions(target: "workbox")
        }
    }

    @Test("non-JSON output is reported as malformed, not decoded as empty")
    func malformedOutput() {
        let runner = StubRunner(stdout: "herdr: unknown subcommand 'session'\n")
        #expect(throws: SessionDirectory.Failure.self) {
            try directory(runner).localSessions()
        }
    }

    @Test("a missing binary is reported before anything runs")
    func missingExecutable() {
        let runner = StubRunner(stdout: "{}")
        let directory = SessionDirectory(runner: runner, herdrPath: nil, sshPath: nil)
        #expect(throws: SessionDirectory.Failure.executableNotFound("herdr")) {
            try directory.localSessions()
        }
        #expect(throws: SessionDirectory.Failure.executableNotFound("ssh")) {
            try directory.remoteSessions(target: "workbox")
        }
        #expect(runner.calls.isEmpty)
    }
}

@Suite("Session descriptors")
struct SessionDescriptorTests {
    @Test("ids stay distinct across hosts so colliding pane ids can be disambiguated")
    func idsAreDistinctAcrossHosts() {
        let local = SessionDescriptor(kind: .local(name: "default"), serverSocketPath: "/a")
        let remote = SessionDescriptor(
            kind: .remote(target: "workbox", name: "default"), serverSocketPath: "/b")
        let other = SessionDescriptor(
            kind: .remote(target: "buildbox", name: "default"), serverSocketPath: "/c")
        #expect(Set([local.id, remote.id, other.id]).count == 3)
    }

    @Test("attach command matches the session shape")
    func attachCommands() {
        #expect(SessionDescriptor(kind: .local(name: "default"), serverSocketPath: "/a")
            .attachCommand == "herdr")
        #expect(SessionDescriptor(kind: .local(name: "work"), serverSocketPath: "/a")
            .attachCommand == "herdr --session work")
        #expect(SessionDescriptor(kind: .remote(target: "workbox", name: "default"),
                                  serverSocketPath: "/a")
            .attachCommand == "herdr --remote workbox")
        #expect(SessionDescriptor(kind: .remote(target: "workbox", name: "agents"),
                                  serverSocketPath: "/a")
            .attachCommand == "herdr --remote workbox --session agents")
    }
}

@Suite("Executable location")
struct ExecutableLocatorTests {
    @Test("finds a binary in a well-known prefix that a GUI PATH would miss")
    func findsOutsidePath() {
        // A login-launched accessory app gets a minimal PATH; herdr installs to
        // ~/.local/bin by default.
        let found = ExecutableLocator.locate(
            "herdr",
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"],
            isExecutable: { $0 == "/Users/me/.local/bin/herdr" })
        #expect(found == "/Users/me/.local/bin/herdr")
    }

    @Test("PATH wins over the well-known prefixes")
    func pathWins() {
        let found = ExecutableLocator.locate(
            "herdr",
            environment: ["PATH": "/opt/custom/bin", "HOME": "/Users/me"],
            isExecutable: { $0 == "/opt/custom/bin/herdr" || $0 == "/Users/me/.local/bin/herdr" })
        #expect(found == "/opt/custom/bin/herdr")
    }

    @Test("the override env var beats everything")
    func overrideWins() {
        let found = ExecutableLocator.locate(
            "herdr",
            environment: [
                ExecutableLocator.overrideEnvironmentKey: "/tmp/build/herdr",
                "PATH": "/usr/bin", "HOME": "/Users/me",
            ],
            isExecutable: { _ in true })
        #expect(found == "/tmp/build/herdr")
    }

    @Test("returns nil when nothing is executable")
    func notFound() {
        let found = ExecutableLocator.locate(
            "herdr",
            environment: ["PATH": "/usr/bin", "HOME": "/Users/me"],
            isExecutable: { _ in false })
        #expect(found == nil)
    }
}
