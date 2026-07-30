import Foundation
import Testing
@testable import HerdrClient

@Suite("Interaction response planner")
struct InteractionResponsePlannerTests {
    private let planner = InteractionResponsePlanner()

    @Test("captured Codex key plans match fixture metadata")
    func codexCorpusPlans() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }

        var matched = 0
        var refusedAmbiguous = 0
        for directory in directories {
            let metadata = try JSONDecoder().decode(
                PaneFixtureMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
            let text = try String(
                contentsOf: directory.appendingPathComponent("detection.txt"), encoding: .utf8)
            let interaction = PromptClassifier().classifyInteraction(
                paneID: metadata.sourceCapture.paneID,
                agent: metadata.sourceCapture.agent,
                text: text,
                paneRevision: metadata.sourceCapture.paneRevisionBefore)

            for (name, expectedKeys) in metadata.annotations.expectedResponsePlans {
                guard let intent = intent(named: name) else {
                    Issue.record("No M3 intent mapping for \(metadata.annotations.name).\(name)")
                    continue
                }
                if interaction.presentation.mechanism == .ambiguous, name != "deny" {
                    #expect(throws: InteractionPlanningError.ambiguousMechanism) {
                        try planner.plan(intent, for: interaction)
                    }
                    refusedAmbiguous += 1
                } else {
                    let plan = try planner.plan(intent, for: interaction)
                    #expect(plan.flattenedKeys == expectedKeys,
                            "plan mismatch for \(metadata.annotations.name).\(name)")
                    matched += 1
                }
            }
        }
        #expect(matched == 38)
        #expect(refusedAmbiguous == 0)
    }

    @Test("arrow movement is recomputed from each fresh cursor")
    func freshArrowCursor() throws {
        let first = question(mechanism: .arrowNavigate, cursor: 0)
        let last = question(mechanism: .arrowNavigate, cursor: 3)
        #expect(try planner.plan(.selectChoice(3), for: first).flattenedKeys
            == ["down", "down", "down", "enter"])
        #expect(try planner.plan(.selectChoice(0), for: last).flattenedKeys
            == ["up", "up", "up", "enter"])
    }

    @Test("preview navigation moves the cursor without submitting")
    func previewNavigation() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p2", kind: .question, title: "Compare",
            choices: (1...3).map { InteractionChoice(label: "Option \($0)") },
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .arrowNavigate,
                selectedChoicePreview: "Current preview"),
            capabilities: [.selectOne, .deny], evidence: evidence)

        #expect(try planner.plan(.previewChoice(2), for: interaction).flattenedKeys
            == ["down", "down"])
        #expect(try planner.plan(.previewChoice(0), for: interaction) == .noOp)
        #expect(try planner.plan(.selectChoice(2), for: interaction).flattenedKeys
            == ["down", "down", "enter"])
    }

    @Test("numbered shortcuts select by number then Enter")
    func numberedShortcut() throws {
        let interaction = question(mechanism: .numberedShortcut, cursor: nil)
        #expect(try planner.plan(.selectChoice(2), for: interaction).flattenedKeys
            == ["3", "enter"])
    }

    @Test("verified explicit shortcuts select directly and Enter confirms the cursor")
    func explicitShortcuts() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p2", kind: .approval, title: "Run command?",
            choices: [
                InteractionChoice(label: "Allow once", shortcutKeys: ["y"]),
                InteractionChoice(label: "Allow prefix", shortcutKeys: ["p"]),
                InteractionChoice(label: "Deny", shortcutKeys: ["esc"]),
            ],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .explicitShortcut),
            capabilities: [.approve, .deny, .selectOne], evidence: evidence)

        #expect(try planner.plan(.approve, for: interaction).flattenedKeys == ["y"])
        #expect(try planner.plan(.selectChoice(1), for: interaction).flattenedKeys == ["p"])
        #expect(try planner.plan(.selectChoice(2), for: interaction).flattenedKeys == ["esc"])
        #expect(try planner.plan(.submit, for: interaction).flattenedKeys == ["enter"])
    }

    @Test("checkbox planner uses fresh cursor and checked state")
    func checkboxToggle() throws {
        let unchecked = question(mechanism: .multiSelect, cursor: 0,
                                 checked: [], selectMany: true)
        let movedToggle = try planner.plan(
            .setChoice(2, checked: true), for: unchecked)
        #expect(movedToggle.flattenedKeys == ["down", "down", "enter"])
        #expect(movedToggle.operations == [
            .sendKeys(["down", "down", "enter"]),
        ])

        let freshlyChecked = question(mechanism: .multiSelect, cursor: 2,
                                      checked: [2], selectMany: true)
        #expect(try planner.plan(.setChoice(2, checked: true), for: freshlyChecked) == .noOp)
        #expect(try planner.plan(.setChoice(2, checked: false), for: freshlyChecked).flattenedKeys
            == ["enter"])
    }

    @Test("multi-select submit navigates to Claude's explicit confirmation")
    func multiSelectSubmit() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p1", kind: .question, title: "Choose rules",
            choices: (1...4).map { InteractionChoice(label: "Rule \($0)") },
            steps: [
                InteractionStep(label: "Depth", isAnswered: true, isSubmit: false),
                InteractionStep(label: "Placement", isAnswered: true, isSubmit: false),
                InteractionStep(label: "Rules", isAnswered: true, isSubmit: false),
                InteractionStep(label: "Submit", isAnswered: true, isSubmit: true),
            ],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, activeStepIndex: 2,
                mechanism: .multiSelect),
            capabilities: [.selectMany, .navigateSteps, .deny],
            evidence: evidence)

        #expect(try planner.plan(.submit, for: interaction).flattenedKeys
            == ["right", "enter"])
    }

    @Test("text entry plans text separately from submission")
    func textEntry() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p2", kind: .question, title: "Notes",
            presentation: InteractionPresentation(mechanism: .textEntry),
            capabilities: [.enterText, .deny], evidence: evidence)
        #expect(try planner.plan(.enterText("details"), for: interaction).operations
            == [.sendText("details")])
        #expect(try planner.plan(.submitText("details"), for: interaction).operations
            == [.sendText("details"), .sendKeys(["enter"])])
        #expect(try planner.plan(.submit, for: interaction).flattenedKeys == ["enter"])
        #expect(try planner.plan(.clearTextEntry, for: interaction).flattenedKeys == ["tab"])
    }

    @Test("Claude text choices navigate from the fresh cursor before typing")
    func choiceTextEntry() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p1", kind: .question, title: "Choose",
            choices: [
                InteractionChoice(label: "A"),
                InteractionChoice(kind: .textEntry, label: "Type something"),
            ],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .arrowNavigate),
            capabilities: [.selectOne, .enterText, .deny], evidence: evidence)
        #expect(try planner.plan(
            .submitChoiceText(1, "custom answer"), for: interaction).operations == [
                .sendKeys(["down"]), .sendText("custom answer"),
                .sendKeys(["enter"]),
            ])
    }

    @Test("step targeting uses the fresh active step")
    func targetStep() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p1", kind: .question, title: "Choose",
            steps: (1...4).map {
                InteractionStep(label: "Step \($0)", isAnswered: false,
                                isSubmit: $0 == 4)
            },
            presentation: InteractionPresentation(
                activeStepIndex: 2, mechanism: .arrowNavigate),
            capabilities: [.navigateSteps, .deny], evidence: evidence)
        #expect(try planner.plan(.navigateToStep(0), for: interaction).flattenedKeys
            == ["left", "left"])
    }

    @Test("ambiguous approvals expose denial but no structured submit")
    func ambiguousApproval() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p2", kind: .approval, title: "Run command?",
            choices: [InteractionChoice(label: "Yes"), InteractionChoice(label: "No")],
            presentation: InteractionPresentation(selectedChoiceIndex: 0,
                                                  mechanism: .ambiguous),
            capabilities: [.approve, .deny, .selectOne], evidence: evidence)
        #expect(try planner.plan(.deny, for: interaction).flattenedKeys == ["esc"])
        #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try planner.plan(.approve, for: interaction)
        }
        #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try planner.plan(.selectChoice(0), for: interaction)
        }
        #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try planner.plan(.submit, for: interaction)
        }
    }

    private var evidence: InteractionEvidence {
        InteractionEvidence(source: .screen, providerID: "test", confidence: .exact)
    }

    private func question(mechanism: InteractionMechanism, cursor: Int?,
                          checked: [Int] = [], selectMany: Bool = false) -> PendingInteraction {
        PendingInteraction(
            paneID: "w1:p2", kind: .question, title: "Choose",
            choices: (1...4).map { InteractionChoice(label: "Option \($0)") },
            presentation: InteractionPresentation(
                selectedChoiceIndex: cursor, checkedChoiceIndexes: checked,
                mechanism: mechanism),
            capabilities: [selectMany ? .selectMany : .selectOne, .deny],
            evidence: evidence)
    }

    private func intent(named name: String) -> InteractionResponseIntent? {
        if name.hasPrefix("option_"), let number = Int(name.dropFirst("option_".count)) {
            return .selectChoice(number - 1)
        }
        return switch name {
        case "add_notes": .beginTextEntry
        case "clear_notes": .clearTextEntry
        case "next_question": .navigateNext
        case "previous_question": .navigatePrevious
        case "submit_all", "proceed", "confirm_selected": .submit
        case "go_back": .selectChoice(1)
        case "approve_once": .approve
        case "approve_persist": .selectChoice(1)
        case "deny": .deny
        case "cancel", "cancel_notes", "interrupt": .cancel
        default: nil
        }
    }
}

@Suite("Normalized interaction display model")
struct InteractionDisplayModelTests {
    @Test("M0C fixtures expose their annotated presentation content")
    func codexCorpusContent() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }
        for directory in directories {
            let metadata = try JSONDecoder().decode(
                PaneFixtureMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
            let text = try String(
                contentsOf: directory.appendingPathComponent("detection.txt"), encoding: .utf8)
            let interaction = PromptClassifier().classifyInteraction(
                paneID: metadata.sourceCapture.paneID, agent: "codex", text: text)
            let display = InteractionDisplayModel(interaction: interaction)
            #expect(display.showsManualControls)
            if metadata.annotations.interactionKind == "none" { continue }
            #expect(display.title == metadata.annotations.title)
            #expect(display.progressText == metadata.annotations.progress)
            #expect(display.choices.map(\.label) == metadata.annotations.optionLabels)
            #expect(display.choices.map { $0.description ?? "" }
                == metadata.annotations.optionDescriptions)
            #expect(display.choices.firstIndex(where: \.isSelected)
                == metadata.annotations.observedCursorIndex)
            if metadata.annotations.interactionKind == "question_text_entry" {
                #expect(display.showsTextEntry)
            }
            if metadata.annotations.responseMechanism == "explicit_shortcut" {
                #expect(display.exposesStructuredSubmit)
                #expect(display.choices.map(\.shortcutKeys) == [["y"], ["p"], ["esc"]])
            }
        }
    }

    @Test("Codex display exposes only response mechanisms M4 can execute safely")
    func actionableControls() throws {
        let classifier = PromptClassifier()
        func display(_ fixture: String) -> InteractionDisplayModel {
            let text = Fixtures.string("interactions/\(fixture)/detection.txt")
            return InteractionDisplayModel(interaction: classifier.classifyInteraction(
                paneID: "w1:p2", agent: "codex", text: text))
        }

        let question = display(
            "codex-plan-single-select-q1-df1ba0216047.fixture")
        #expect(question.choicesAreActionable)
        #expect(question.showsBeginTextEntry)
        #expect(!question.showsTextEntry)
        #expect(question.showsCancel)

        let multiSelect = InteractionDisplayModel(
            interaction: classifier.classifyInteraction(
                paneID: "w1:p4", agent: "claude",
                text: Fixtures.string("prompts/live-askquestion-multiselect-detection.txt"),
                currentTabLabel: "Topics"))
        #expect(multiSelect.showsExplicitSubmit)

        let review = InteractionDisplayModel(
            interaction: classifier.classifyInteraction(
                paneID: "w1:p4", agent: "claude",
                text: Fixtures.string("prompts/live-review-submit-detection.txt"),
                currentTabLabel: "Submit"))
        #expect(review.showsExplicitSubmit)

        let notes = display(
            "codex-plan-free-text-notes-q3-7cbd68a04fb3.fixture")
        #expect(notes.showsTextEntry)
        #expect(!notes.showsBeginTextEntry)

        let approval = display(
            "codex-command-approval-explicit-shortcuts-0e257cdd8f3b.fixture")
        #expect(approval.choicesAreActionable)
        #expect(approval.showsCancel)
        #expect(approval.exposesStructuredSubmit)
        #expect(approval.approvalOnceAvailable)
        #expect(approval.approvalPersistChoiceIndex == 1)
        #expect(approval.choices[1].description?.contains("printf") == false)
        #expect(approval.choices[1].description?.contains("touch /private/tmp/") == true)

        #expect(!question.approvalOnceAvailable)
        #expect(question.approvalPersistChoiceIndex == nil)

        let ambiguousApproval = PendingInteraction(
            paneID: "w1:p2", kind: .approval, title: "Run command?",
            choices: [InteractionChoice(label: "Allow")],
            presentation: InteractionPresentation(mechanism: .ambiguous),
            capabilities: [.approve, .deny, .selectOne],
            evidence: InteractionEvidence(
                source: .screen, providerID: "test", confidence: .fallback))
        #expect(!InteractionDisplayModel(
            interaction: ambiguousApproval).choicesAreActionable)
    }

    @Test("attention rows surface prompt, phases, stale drafts, errors, and accessibility")
    func attentionStates() {
        let interaction = PendingInteraction(
            paneID: "w1:p1", kind: .question, title: "Choose deployment target",
            progress: InteractionProgress(current: 2, total: 3, unanswered: 2),
            choices: [InteractionChoice(label: "Production")],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .arrowNavigate),
            capabilities: [.selectOne],
            evidence: InteractionEvidence(
                source: .screen, providerID: "test", agentID: "claude",
                confidence: .exact))
        let readyState = PaneInteractionState(
            paneID: "w1:p1", agentID: "claude", interaction: interaction)
        let ready = InteractionAttentionDisplayModel(
            paneID: "w1:p1", taskTitle: "Fix auth", agentName: "claude",
            workspaceLabel: "project", tabTitle: "Tab 2",
            status: .blocked, state: readyState, isSelected: true)
        #expect(ready.stateText == "needs input")
        #expect(ready.summary == "Question 2/3 (2 unanswered)")
        #expect(ready.title == "project")
        #expect(ready.taskTitle == "Fix auth")
        #expect(ready.tabTitle == "Tab 2")
        #expect(ready.modelName == nil)
        #expect(ready.accessibilityLabel.contains("claude, in project, Tab 2"))
        #expect(!ready.accessibilityLabel.contains("Fix auth"))
        #expect(ready.accessibilityLabel.contains("pane w1:p1"))
        let other = InteractionAttentionDisplayModel(
            paneID: "w1:p2", taskTitle: "Ship release", agentName: "codex",
            workspaceLabel: "release", status: .blocked, state: nil,
            isSelected: false)
        #expect(AttentionRollupDisplay.pillTaskTitle(
            items: [ready, other], selected: other.ref) == "release")
        #expect(AttentionRollupDisplay.pillTaskTitle(
            items: [ready, other], selected: nil) == "project")
        let working = InteractionAttentionDisplayModel(
            paneID: "w1:p3", taskTitle: "Background work", agentName: "claude",
            workspaceLabel: "project", status: .working, state: nil,
            isSelected: false)
        #expect(working.stateText == "working")
        #expect(working.summary == "Agent is working — no input needed.")
        #expect(AttentionRollupDisplay.pillTaskTitle(
            items: [working], selected: working.ref) == nil)
        let finished = InteractionAttentionDisplayModel(
            paneID: "w1:p4", taskTitle: "Auth fix", agentName: "codex",
            workspaceLabel: "project", status: .done, state: nil,
            completionSummary: "Implemented authentication and added tests.",
            isSelected: false)
        #expect(finished.stateText == "finished")
        #expect(finished.summary == "Implemented authentication and added tests.")

        for (phase, expected) in [
            (PaneInteractionPhase.reading, "Reading the live prompt…"),
            (.responding, "Revalidating and sending…"),
            (.settling, "Waiting for the terminal to settle…"),
        ] {
            let state = PaneInteractionState(
                paneID: "w1:p1", interaction: interaction, phase: phase)
            let row = InteractionAttentionDisplayModel(
                paneID: "w1:p1", taskTitle: "Fix auth", agentName: "claude",
                workspaceLabel: "project",
                status: .blocked, state: state, isSelected: false)
            #expect(row.stateText == phase.rawValue)
            #expect(row.summary == expected)
        }

        let stale = PaneInteractionState(
            paneID: "w1:p1", interaction: interaction,
            draft: PaneInteractionDraft(
                text: "old answer", fingerprint: interaction.fingerprint,
                state: .stale))
        #expect(InteractionAttentionDisplayModel(
            paneID: "w1:p1", taskTitle: "Fix auth", agentName: "claude",
            workspaceLabel: "project",
            status: .blocked, state: stale, isSelected: false).stateText
            == "draft needs review")

        let failed = PaneInteractionState(
            paneID: "w1:p1", interaction: interaction, error: "Input rejected")
        let errorRow = InteractionAttentionDisplayModel(
            paneID: "w1:p1", taskTitle: "Fix auth", agentName: "claude",
            workspaceLabel: "project",
            status: .blocked, state: failed, isSelected: false)
        #expect(errorRow.stateText == "error")
        #expect(errorRow.summary == "Input rejected")

        let modeled = InteractionAttentionDisplayModel(
            paneID: "w1:p5", taskTitle: "Native task", agentName: "opencode",
            modelName: "anthropic/claude-opus-4-1", workspaceLabel: "project",
            status: .working, state: nil, isSelected: false)
        #expect(modeled.accessibilityLabel.contains("anthropic/claude-opus-4-1"))
    }

    @Test("attention rows format elapsed time and prompt read freshness")
    func attentionTiming() {
        let now = Date(timeIntervalSince1970: 10_000)
        let state = PaneInteractionState(
            paneID: "w1:p1", lastReadAt: now.addingTimeInterval(-42))
        let recent = InteractionAttentionDisplayModel(
            paneID: "w1:p1", taskTitle: "Fix auth", agentName: "codex",
            workspaceLabel: "project", status: .blocked, state: state,
            activeSince: now.addingTimeInterval(-3_780), now: now,
            isSelected: true)
        #expect(recent.elapsedText == "1h 3m elapsed")
        #expect(recent.freshnessText == "fresh <1m")
        #expect(recent.accessibilityLabel.contains("1h 3m elapsed"))

        let olderState = PaneInteractionState(
            paneID: "w1:p1", lastReadAt: now.addingTimeInterval(-125))
        let older = InteractionAttentionDisplayModel(
            paneID: "w1:p1", taskTitle: "Fix auth", agentName: "codex",
            workspaceLabel: "project", status: .blocked, state: olderState,
            now: now, isSelected: false)
        #expect(older.elapsedText == nil)
        #expect(older.freshnessText == "read 2m ago")
    }

    @Test("display identity separates space, tab, and terminal fallbacks")
    func paneIdentityFallbacks() {
        func pane(title: String? = nil, label: String? = nil,
                  cwd: String? = nil, foregroundCwd: String? = nil) -> PaneInfo {
            PaneInfo(
                paneID: "w1:p1", terminalID: "term-1", workspaceID: "w1",
                tabID: "w1:t1", focused: false, agentStatus: .blocked,
                revision: 1, agent: "codex", label: label, title: title,
                cwd: cwd, foregroundCwd: foregroundCwd)
        }

        #expect(PaneDisplayIdentity.taskTitle(
            pane: pane(title: "  Fix auth  ", label: "fallback",
                       cwd: "/work/project")) == "Fix auth")
        #expect(PaneDisplayIdentity.taskTitle(
            pane: pane(label: "Release prep", cwd: "/work/project")) == "Release prep")
        #expect(PaneDisplayIdentity.taskTitle(
            pane: pane(cwd: "/work/project")) == "project")
        #expect(PaneDisplayIdentity.taskTitle(
            pane: pane(foregroundCwd: "/work/live-project")) == "live-project")
        #expect(PaneDisplayIdentity.taskTitle(
            pane: pane(), workspaceLabel: "Workspace") == "Workspace")
        #expect(PaneDisplayIdentity.taskTitle(pane: pane()) == "codex")

        #expect(PaneDisplayIdentity.spaceTitle(
            pane: pane(cwd: "/work/project"),
            workspaceLabel: "  Capacity Planning  ") == "Capacity Planning")
        #expect(PaneDisplayIdentity.spaceTitle(
            pane: pane(cwd: "/work/project")) == "project")
        #expect(PaneDisplayIdentity.spaceTitle(
            pane: pane(foregroundCwd: "/work/live-project")) == "live-project")
        #expect(PaneDisplayIdentity.spaceTitle(pane: pane()) == "w1")

        #expect(PaneDisplayIdentity.tabTitle(
            label: "Release prep", number: 2) == "Release prep")
        #expect(PaneDisplayIdentity.tabTitle(label: "4", number: nil) == "Tab 4")
        #expect(PaneDisplayIdentity.tabTitle(label: " 12 ", number: nil) == "Tab 12")
        #expect(PaneDisplayIdentity.tabTitle(label: "Tab1", number: nil) == "Tab 1")
        #expect(PaneDisplayIdentity.tabTitle(label: " tab 12 ", number: nil) == "Tab 12")
        #expect(PaneDisplayIdentity.tabTitle(label: nil, number: 3) == "Tab 3")
        #expect(PaneDisplayIdentity.tabTitle(label: "  ", number: nil) == "Tab")
    }

    @Test("Claude text-entry choices remain typed in shared display data")
    func choiceKinds() {
        let text = Fixtures.string("prompts/live-askquestion-multi-detection.txt")
        let interaction = PromptClassifier().classifyInteraction(
            paneID: "w1:p1", agent: "claude", text: text)
        let display = InteractionDisplayModel(interaction: interaction)
        #expect(display.choices.filter { $0.kind == .textEntry }.count == 2)
    }
}
