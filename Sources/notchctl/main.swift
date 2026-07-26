import Foundation
import HerdrClient

@main @MainActor
enum CLI {
    static var jsonOutput = false
    static var explicitSocket: String?

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--json") { jsonOutput = true; args.remove(at: i) }
        if let i = args.firstIndex(where: { $0 == "--sock" || $0 == "--socket" }), args.indices.contains(i + 1) {
            explicitSocket = args[i + 1]; args.removeSubrange(i...i + 1)
        }
        // `--session <name>` resolves through herdr's own session list, so it
        // works for the default session too (whose socket is not under sessions/).
        if let i = args.firstIndex(of: "--session"), args.indices.contains(i + 1) {
            let name = args[i + 1]
            args.removeSubrange(i...i + 1)
            guard let session = try? SessionDirectory().localSessions()
                .first(where: { $0.kind.name == name }) else {
                fputs("notchctl: no local herdr session named '\(name)'\n", stderr)
                exit(1)
            }
            explicitSocket = session.serverSocketPath
        }
        guard let command = args.first else { usage(); return }
        let client = HerdrClient(socketPath: explicitSocket)
        do {
            switch command {
            case "resolve": guard args.count > 2 else { throw CLIError.usage("resolve requires a pane id and approve|deny|option number") }; try await resolve(client, pane: args[1], choice: args[2])
            case "dry-run": guard args.count > 2 else { throw CLIError.usage("dry-run requires a pane id and intent") }; try await dryRun(client, pane: args[1], args: Array(args.dropFirst(2)))
            case "inspect": guard args.count > 1 else { throw CLIError.usage("inspect requires a fixture directory or detection file") }; try inspect(path: args[1], args: Array(args.dropFirst(2)))
            case "list": try await list(client)
            case "sessions": try sessions(remote: optionalOption("--remote", in: args))
            case "read": guard args.count > 1 else { throw CLIError.usage("read requires a pane id") }; try await read(client, pane: args[1])
            case "capture": guard args.count > 1 else { throw CLIError.usage("capture requires a pane id and --output DIR") }; try await capture(client, pane: args[1], args: args)
            case "extract": guard args.count > 1 else { throw CLIError.usage("extract requires a capture directory, --annotations FILE, and --output DIR") }; try extract(capturePath: args[1], args: args)
            case "reply": guard args.count > 2 else { throw CLIError.usage("reply requires a pane id and text") }; report(try await Actions(client: client).reply(pane: args[1], text: args.dropFirst(2).joined(separator: " ")))
            case "jump": guard args.count > 1 else { throw CLIError.usage("jump requires a pane id") }; report(try await Actions(client: client).jump(pane: args[1]))
            case "watch": try await watch(client)
            default: throw CLIError.usage("unknown command: \(command)")
            }
        } catch { fputs("notchctl: \(error)\n", stderr); exit(1) }
    }

    static func list(_ client: HerdrClient) async throws {
        let result = try await client.request("session.snapshot")
        let snapshot = try (result["snapshot"] ?? result).decode(Snapshot.self)
        if jsonOutput { printJSON(result); return }
        for pane in snapshot.uniquePanes {
            print("\(pad(pane.paneID, 18)) \(pad(pane.agent ?? "—", 10)) \(pane.agentStatus.rawValue) \(pane.title ?? "")")
        }
    }

    /// Dogfoods session discovery. `--remote <target>` lists a remote host's
    /// sessions over ssh, which is also how we learn their absolute socket paths.
    static func sessions(remote target: String?) throws {
        let directory = SessionDirectory()
        let found = try target.map { try directory.remoteSessions(target: $0) }
            ?? directory.localSessions()
        for session in found {
            print("\(pad(session.id, 26)) \(pad(session.isRunning ? "running" : "stopped", 8)) \(session.serverSocketPath)")
        }
    }

    static func read(_ client: HerdrClient, pane: String) async throws {
        let context = try await classify(client, pane: pane)
        printDiagnostic(context.interaction)
    }

    static func inspect(path: String, args: [String]) throws {
        let url = fileURL(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.usage("fixture path does not exist: \(url.path)")
        }
        let interaction: PendingInteraction
        if isDirectory.boolValue {
            interaction = try InteractionFixtureInspector().inspect(directory: url)
        } else {
            guard let agent = optionalOption("--agent", in: args) else {
                throw CLIError.usage("inspecting a detection file requires --agent ID")
            }
            let detection = try String(contentsOf: url, encoding: .utf8)
            let visiblePath = optionalOption("--visible", in: args)
            let visible = try visiblePath.map {
                try String(contentsOf: fileURL($0), encoding: .utf8)
            }
            let revision = optionalOption("--revision", in: args).flatMap(UInt64.init)
            let paneID = optionalOption("--pane", in: args) ?? "fixture"
            interaction = PromptClassifier().classifyInteraction(
                paneID: paneID, agent: agent, text: detection,
                visibleANSIText: visible, paneRevision: revision,
                currentTabLabel: visible.flatMap(ScreenInteractionProvider.currentTabLabel))
        }
        printDiagnostic(interaction)
    }

    static func capture(_ client: HerdrClient, pane paneID: String,
                        args: [String]) async throws {
        guard let outputIndex = args.firstIndex(of: "--output"),
              args.indices.contains(outputIndex + 1) else {
            throw CLIError.usage("capture requires --output DIR")
        }
        let outputURL = URL(fileURLWithPath: NSString(
            string: args[outputIndex + 1]).expandingTildeInPath, isDirectory: true)
        let overwrite = args.contains("--force")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let bundle = try await PaneCapturer(client: client).capture(
            paneID: paneID, capturedAt: timestamp)
        let destination = try PaneCaptureWriter().write(bundle, to: outputURL,
                                                        overwrite: overwrite)
        print(destination.path)
        if !bundle.metadata.hasConsistentRevision {
            fputs("notchctl: warning: pane revision changed during capture\n", stderr)
        }
    }

    static func extract(capturePath: String, args: [String]) throws {
        let outputPath = try option("--output", in: args)
        let annotationsPath = try option("--annotations", in: args)
        let captureURL = fileURL(capturePath, isDirectory: true)
        let outputURL = fileURL(outputPath, isDirectory: true)
        let annotationsURL = fileURL(annotationsPath)
        let annotations = try JSONDecoder().decode(
            PaneFixtureAnnotations.self, from: Data(contentsOf: annotationsURL))
        let replacementDetection = try optionalFileData("--detection-file", in: args)
        let replacementVisible = try optionalFileData("--visible-file", in: args)
        let region = optionalOption("--from-marker", in: args).map {
            PaneFixtureRegion(startMarker: $0,
                              endMarker: optionalOption("--through-marker", in: args))
        }
        let destination = try PaneFixtureExtractor().extract(
            captureDirectory: captureURL, annotations: annotations,
            outputDirectory: outputURL, replacementDetection: replacementDetection,
            replacementVisibleANSI: replacementVisible, region: region)
        print(destination.path)
    }

    static func option(_ name: String, in args: [String]) throws -> String {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            throw CLIError.usage("missing required option \(name)")
        }
        return args[index + 1]
    }

    static func optionalFileData(_ name: String, in args: [String]) throws -> Data? {
        guard args.contains(name) else { return nil }
        return try Data(contentsOf: fileURL(try option(name, in: args)))
    }

    static func optionalOption(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    static func fileURL(_ path: String, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: isDirectory)
    }

    struct InteractionContext {
        let interaction: PendingInteraction
        let agentID: String?
        let revision: UInt64?
    }

    static func classify(_ client: HerdrClient, pane: String) async throws
        -> InteractionContext {
        let snapshotResult = try await client.request("session.snapshot")
        let snapshot = try (snapshotResult["snapshot"] ?? snapshotResult).decode(Snapshot.self)
        let paneInfo = snapshot.uniquePanes.first { $0.paneID == pane }
        let interaction = try await ScreenInteractionProvider(client: client).interaction(
            paneID: pane, agentID: paneInfo?.agent, paneRevision: paneInfo?.revision)
        return InteractionContext(
            interaction: interaction, agentID: paneInfo?.agent,
            revision: paneInfo?.revision)
    }

    static func resolve(_ client: HerdrClient, pane: String, choice: String) async throws {
        let context = try await classify(client, pane: pane)
        let interaction = context.interaction
        let actions = Actions(client: client)
        let intent: InteractionResponseIntent
        switch choice.lowercased() {
        case "approve", "yes", "y": intent = .approve
        case "deny", "no", "n":
            intent = interaction.kind == .approval ? .deny : .cancel
        default:
            guard let number = Int(choice), interaction.choices.indices.contains(number - 1) else {
                throw CLIError.usage("choice must be approve|deny|<option number 1...\(interaction.choices.count)>")
            }
            intent = .selectChoice(number - 1)
        }
        let provider = ScreenInteractionProvider(client: client)
        let responder = InteractionResponder(provider: provider, actions: actions)
        _ = try await responder.respond(InteractionResponseRequest(
            paneID: pane, agentID: context.agentID,
            paneRevision: context.revision,
            expectedFingerprint: interaction.fingerprint, intent: intent))
        report(.sent)
    }

    static func dryRun(_ client: HerdrClient, pane: String, args: [String]) async throws {
        let parsed = try parseIntent(args)
        let shown = try await classify(client, pane: pane)
        let expected = optionalOption("--expected-fingerprint", in: args)
            .map(InteractionFingerprint.init(rawValue:))
            ?? shown.interaction.fingerprint
        let provider = ScreenInteractionProvider(client: client)
        let result = try await InteractionDryRunner(provider: provider).run(
            InteractionDryRunRequest(
                paneID: pane, agentID: shown.agentID,
                paneRevision: shown.revision,
                expectedFingerprint: expected, intent: parsed.intent))
        printDryRun(result, intentName: parsed.name,
                    initial: shown.interaction)
    }

    static func watch(_ client: HerdrClient) async throws {
        let store = StateStore()
        let result = try await client.request("session.snapshot")
        let snapshot = try (result["snapshot"] ?? result).decode(Snapshot.self)
        store.hydrate(snapshot)
        let subscriptions = store.currentSubscriptions()
        for await raw in client.events(subscriptions: { subscriptions }) {
            if jsonOutput { printJSON(raw); continue }
            guard let event = EventEnvelope(raw) else { continue }
            _ = store.apply(event)
            print("\(timestamp()) \(event.event) \(event.paneID ?? "") \(event.agentStatus?.rawValue ?? "")")
        }
    }

    static func printDiagnostic(_ interaction: PendingInteraction) {
        let diagnostics = InteractionDiagnosticBuilder()
        if jsonOutput { printJSON(diagnostics.jsonValue(for: interaction)) }
        else { print(diagnostics.text(for: interaction)) }
    }

    static func printDryRun(_ result: InteractionDryRunResult,
                            intentName: String,
                            initial: PendingInteraction) {
        if jsonOutput {
            printJSON(.object([
                "schema_version": .number(1),
                "dry_run": .bool(true),
                "intent": .string(intentName),
                "status": .string(result.status.rawValue),
                "identity_matched": .bool(result.identityMatched),
                "initial_fingerprint": .string(initial.fingerprint.rawValue),
                "initial_revision": initial.evidence.paneRevision
                    .map { .number(Double($0)) } ?? .null,
                "expected_fingerprint": .string(result.expectedFingerprint.rawValue),
                "fresh_fingerprint": .string(result.freshInteraction.fingerprint.rawValue),
                "fresh_revision": result.freshInteraction.evidence.paneRevision
                    .map { .number(Double($0)) } ?? .null,
                "plan": result.plan.map(InteractionDiagnosticBuilder.planJSON) ?? .null,
                "refusal": result.refusal.map(JSONValue.string) ?? .null,
                "fresh_interaction": InteractionDiagnosticBuilder()
                    .jsonValue(for: result.freshInteraction),
            ]))
            return
        }
        print("DRY RUN — no input was sent")
        print("intent: \(intentName)")
        print("status: \(result.status.rawValue)")
        print("initial fingerprint: \(initial.fingerprint.rawValue)")
        print("initial revision: \(initial.evidence.paneRevision.map(String.init) ?? "—")")
        print("expected fingerprint: \(result.expectedFingerprint.rawValue)")
        print("fresh fingerprint: \(result.freshInteraction.fingerprint.rawValue)")
        print("identity matched: \(result.identityMatched)")
        if let plan = result.plan {
            print("plan: \(InteractionDiagnosticBuilder.describe(plan))")
        }
        if let refusal = result.refusal { print("refusal: \(refusal)") }
    }

    struct ParsedIntent {
        let name: String
        let intent: InteractionResponseIntent
    }

    static func parseIntent(_ args: [String]) throws -> ParsedIntent {
        guard let name = args.first else {
            throw CLIError.usage("missing dry-run intent")
        }
        func number(_ offset: Int = 1) throws -> Int {
            guard args.indices.contains(offset), let value = Int(args[offset]), value > 0 else {
                throw CLIError.usage("\(name) requires a 1-based number")
            }
            return value - 1
        }
        func text(after offset: Int) throws -> String {
            var values = Array(args.dropFirst(offset))
            if let option = values.firstIndex(of: "--expected-fingerprint") {
                let upper = min(option + 2, values.count)
                values.removeSubrange(option..<upper)
            }
            let value = values.joined(separator: " ")
            guard !value.isEmpty else {
                throw CLIError.usage("\(name) requires text")
            }
            return value
        }
        let intent: InteractionResponseIntent = switch name {
        case "option": .selectChoice(try number())
        case "check": .setChoice(try number(), checked: true)
        case "uncheck": .setChoice(try number(), checked: false)
        case "type": .enterText(try text(after: 1))
        case "text": .submitText(try text(after: 1))
        case "option-text": .submitChoiceText(
            try number(), try text(after: 2))
        case "add-notes": .beginTextEntry
        case "clear-notes": .clearTextEntry
        case "previous": .navigatePrevious
        case "next": .navigateNext
        case "step": .navigateToStep(try number())
        case "submit": .submit
        case "approve": .approve
        case "deny": .deny
        case "cancel": .cancel
        default:
            throw CLIError.usage(
                "unknown dry-run intent \(name); use option|check|uncheck|type|text|option-text|add-notes|clear-notes|previous|next|step|submit|approve|deny|cancel")
        }
        return ParsedIntent(name: name, intent: intent)
    }
    static func report(_ result: ActionResult) {
        switch result {
        case .sent: print(jsonOutput ? "{\"result\":\"sent\"}" : "sent")
        case .jumped(let terminal):
            switch terminal {
            case .presented(let appName):
                print(jsonOutput
                    ? "{\"result\":\"jumped\",\"terminal_presented\":true,\"terminal\":\"\(appName)\"}"
                    : "jumped (terminal presented: \(appName))")
            case .unavailable:
                print(jsonOutput
                    ? "{\"result\":\"jumped\",\"terminal_presented\":false}"
                    : "jumped (terminal could not be presented)")
            }
        case .needsAttach: print(jsonOutput ? "{\"result\":\"needs_attach\"}" : "pane is on a detached session — attach first")
        }
    }
    static func printJSON(_ value: JSONValue) {
        if let data = try? value.serialized(),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
    static func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func usage() {
        print("usage: notchctl [--sock PATH | --session NAME] [--json] <list|sessions|watch|read|inspect|dry-run|capture|extract|resolve|reply|jump> …")
        print("  sessions [--remote TARGET]   list herdr sessions and their socket paths")
        print("  inspect <fixture-dir|detection-file> [--agent ID --visible FILE --pane ID --revision N]")
        print("  dry-run <pane> <option N|check N|uncheck N|type TEXT|text TEXT|option-text N TEXT|add-notes|clear-notes|previous|next|step N|submit|approve|deny|cancel> [--expected-fingerprint HEX]")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let message): message } }
}
