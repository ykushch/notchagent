import Foundation

/// A decode-tolerant projection of `herdr status --json` for support UI.
public struct HerdrStatusReport: Sendable, Equatable {
    public let clientVersion: String?
    public let clientProtocol: Int?
    public let serverVersion: String?
    public let serverProtocol: Int?
    public let serverRunning: Bool?
    public let compatible: Bool?
    public let restartNeeded: Bool?

    public var versionSummary: String {
        switch (clientVersion, serverVersion) {
        case let (client?, server?): "client \(client) · server \(server)"
        case let (client?, nil): "client \(client)"
        case let (nil, server?): "server \(server)"
        case (nil, nil): "version unavailable"
        }
    }

    public var protocolSummary: String {
        switch (clientProtocol, serverProtocol) {
        case let (client?, server?) where client == server: "protocol \(client)"
        case let (client?, server?): "protocol \(client) / \(server)"
        case let (client?, nil): "client protocol \(client)"
        case let (nil, server?): "server protocol \(server)"
        case (nil, nil): "protocol unavailable"
        }
    }

    static func decode(_ output: CommandOutput) throws -> Self {
        let value = try JSONValue.parse(output.standardOutput)
        return Self(
            clientVersion: value["client"]?["version"]?.stringValue,
            clientProtocol: value["client"]?["protocol"]?.intValue,
            serverVersion: value["server"]?["version"]?.stringValue,
            serverProtocol: value["server"]?["protocol"]?.intValue,
            serverRunning: value["server"]?["running"]?.boolValue,
            compatible: value["server"]?["compatible"]?.boolValue,
            restartNeeded: value["update"]?["restart_needed"]?.boolValue
                ?? value["server"]?["restart_needed"]?.boolValue)
    }
}

public struct HerdrIntegrationReport: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case current, outdated, notInstalled, unknown }

    public let agent: String
    public let state: State
    public let detail: String
    public var id: String { agent }

    public var installCommand: String? {
        state == .current ? nil : "herdr integration install \(agent)"
    }
}

public struct HerdrAgentExplanation: Sendable, Equatable {
    public let agent: String?
    public let state: String?
    public let matchedRule: String?
    public let fallbackReason: String?
    public let warning: String?
    public let manifestSource: String?
    public let manifestVersion: String?
    public let remoteUpdateStatus: String?
    public let remoteUpdateError: String?

    public var summary: String {
        if let warning, !warning.isEmpty { return warning }
        if let fallbackReason, !fallbackReason.isEmpty { return fallbackReason }
        if let matchedRule { return "Matched rule \(matchedRule)." }
        if agent == nil { return "herdr did not identify an agent in this pane." }
        return "No detection reason was reported."
    }

    static func decode(_ output: CommandOutput) throws -> Self {
        let value = try JSONValue.parse(output.standardOutput)
        return Self(
            agent: value["agent"]?.stringValue,
            state: value["state"]?.stringValue,
            matchedRule: value["matched_rule"]?["id"]?.stringValue,
            fallbackReason: value["fallback_reason"]?.stringValue,
            warning: value["warning"]?.stringValue,
            manifestSource: value["manifest_source"]?.stringValue,
            manifestVersion: value["manifest_version"]?.stringValue,
            remoteUpdateStatus: value["remote_update_status"]?.stringValue,
            remoteUpdateError: value["remote_update_error"]?.stringValue)
    }
}

/// Short-lived CLI diagnostics. This deliberately does not become another state
/// authority: herdr produces the evidence and NotchAgent only presents it.
public struct HerdrDiagnostics: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case executableNotFound
        case commandFailed(status: Int32, message: String)
        case malformedOutput(String)
    }

    private let runner: any CommandRunning
    private let herdrPath: String?

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        herdrPath: String? = ExecutableLocator.locate("herdr")
    ) {
        self.runner = runner
        self.herdrPath = herdrPath
    }

    public func status(sessionName: String? = nil) throws -> HerdrStatusReport {
        let output = try run(arguments: sessionArguments(sessionName) + ["status", "--json"])
        do { return try HerdrStatusReport.decode(output) }
        catch { throw malformed(output) }
    }

    public func integrations() throws -> [HerdrIntegrationReport] {
        let output = try run(arguments: ["integration", "status"])
        return String(decoding: output.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap(Self.decodeIntegrationLine)
            .sorted { $0.agent < $1.agent }
    }

    public func explain(
        paneID: String, sessionName: String? = nil
    ) throws -> HerdrAgentExplanation {
        let output = try run(
            arguments: sessionArguments(sessionName) + ["agent", "explain", paneID, "--json"])
        do { return try HerdrAgentExplanation.decode(output) }
        catch { throw malformed(output) }
    }

    private func sessionArguments(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != SessionDescriptor.defaultSessionName else { return [] }
        return ["--session", name]
    }

    private func run(arguments: [String]) throws -> CommandOutput {
        guard let herdrPath else { throw Failure.executableNotFound }
        let output = try runner.run(executable: herdrPath, arguments: arguments)
        guard output.isSuccess else {
            throw Failure.commandFailed(
                status: output.status,
                message: output.errorMessage.isEmpty
                    ? "herdr exited with status \(output.status)" : output.errorMessage)
        }
        return output
    }

    private func malformed(_ output: CommandOutput) -> Failure {
        .malformedOutput(String(decoding: output.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func decodeIntegrationLine(_ line: Substring) -> HerdrIntegrationReport? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let agent = line[..<colon].trimmingCharacters(in: .whitespaces)
        let detail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !agent.isEmpty else { return nil }
        let state: HerdrIntegrationReport.State
        if detail.hasPrefix("current") { state = .current }
        else if detail.hasPrefix("outdated") { state = .outdated }
        else if detail.hasPrefix("not installed") { state = .notInstalled }
        else { state = .unknown }
        return HerdrIntegrationReport(agent: agent, state: state, detail: detail)
    }
}

extension HerdrDiagnostics.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Couldn't find the herdr command. Check that it is installed."
        case let .commandFailed(_, message):
            message
        case let .malformedOutput(text):
            "Unexpected herdr diagnostics output: \(text)"
        }
    }
}
