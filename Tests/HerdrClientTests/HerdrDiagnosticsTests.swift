import Foundation
import Testing
@testable import HerdrClient

private final class DiagnosticRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var output: CommandOutput

    init(_ text: String, status: Int32 = 0) {
        output = CommandOutput(
            status: status,
            standardOutput: Data(text.utf8),
            standardError: status == 0 ? Data() : Data(text.utf8))
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(executable: String, arguments: [String]) throws -> CommandOutput {
        lock.lock(); recorded.append(arguments); lock.unlock()
        return output
    }
}

@Suite("herdr diagnostics")
struct HerdrDiagnosticsTests {
    @Test("status reports version and protocol compatibility")
    func status() throws {
        let runner = DiagnosticRunner(#"""
            {
              "client":{"version":"0.7.5","protocol":17},
              "server":{"running":true,"version":"0.7.5","protocol":17,"compatible":true},
              "update":{"restart_needed":false},"future_field":42
            }
            """#)
        let report = try HerdrDiagnostics(runner: runner, herdrPath: "/fake/herdr").status()

        #expect(report.versionSummary == "client 0.7.5 · server 0.7.5")
        #expect(report.protocolSummary == "protocol 17")
        #expect(report.compatible == true)
        #expect(report.restartNeeded == false)
        #expect(runner.calls == [["status", "--json"]])
    }

    @Test("named-session explanations stay scoped to their server")
    func explanation() throws {
        let runner = DiagnosticRunner(#"""
            {
              "agent":"codex","state":"unknown","fallback_reason":"no rule matched",
              "matched_rule":null,"manifest_source":"remote:/tmp/codex.toml",
              "manifest_version":"1","unknown_future_field":true
            }
            """#)
        let explanation = try HerdrDiagnostics(
            runner: runner, herdrPath: "/fake/herdr"
        ).explain(paneID: "w1:p2", sessionName: "work")

        #expect(explanation.agent == "codex")
        #expect(explanation.summary == "no rule matched")
        #expect(runner.calls == [[
            "--session", "work", "agent", "explain", "w1:p2", "--json",
        ]])
    }

    @Test("integration status creates fixes only for non-current agents")
    func integrations() throws {
        let runner = DiagnosticRunner("""
            claude: current (v7) (/tmp/claude)
            codex: outdated (v5, latest v6) (/tmp/codex)
            pi: not installed (/tmp/pi)
            """)
        let reports = try HerdrDiagnostics(
            runner: runner, herdrPath: "/fake/herdr").integrations()

        #expect(reports.map(\.agent) == ["claude", "codex", "pi"])
        #expect(reports[0].installCommand == nil)
        #expect(reports[1].installCommand == "herdr integration install codex")
        #expect(reports[2].state == .notInstalled)
    }

    @Test("failed commands preserve herdr's diagnostic message")
    func commandFailure() {
        let runner = DiagnosticRunner("server is not running", status: 2)
        #expect(throws: HerdrDiagnostics.Failure.commandFailed(
            status: 2, message: "server is not running")) {
            _ = try HerdrDiagnostics(runner: runner, herdrPath: "/fake/herdr").status()
        }
    }

    @Test("malformed JSON is an actionable diagnostics failure")
    func malformedOutput() {
        let runner = DiagnosticRunner("not json")
        #expect(throws: HerdrDiagnostics.Failure.malformedOutput("not json")) {
            _ = try HerdrDiagnostics(runner: runner, herdrPath: "/fake/herdr").status()
        }
    }
}
