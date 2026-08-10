import HerdrClient
import SwiftUI

struct ExpandedNotchSurface: View {
    @Bindable var model: NotchViewModel
    @Bindable var surface: NotchSurfaceState
    let presentation: NotchPresentation
    let snapshot: NotchDisplaySnapshot
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ExpandedNotchHeader(
                model: model,
                isFocused: presentation.isFocused,
                sessionCount: snapshot.items.count)
            Divider().overlay(NotchPalette.hairline)
            ZStack {
                NotchOverviewSurface(model: model, snapshot: snapshot)
                    .opacity(presentation == .overview ? 1 : 0)
                    .allowsHitTesting(presentation == .overview)

                NotchFocusedSurface(model: model, snapshot: snapshot)
                    .opacity(presentation.isFocused ? 1 : 0)
                    .allowsHitTesting(presentation.isFocused)
            }
        }
        .padding(.top, topInset > 0 ? topInset + 5 : 8)
        .foregroundStyle(NotchPalette.primaryText)
        .onPreferenceChange(NotchHeightPreferenceKey.self, perform: applyMeasuredHeights)
    }

    private var chromeHeight: CGFloat {
        (topInset > 0 ? topInset + 5 : 8) + 39
    }

    private func applyMeasuredHeights(_ heights: [NotchMeasuredRegion: CGFloat]) {
        if presentation == .overview, let content = heights[.overviewContent] {
            surface.reportOverviewHeight(chromeHeight + content)
        } else if presentation.isFocused,
                  let identity = model.selectedFocusedSizingIdentity,
                  let content = heights[.focusedContent] {
            surface.reportFocusedHeight(
                chromeAndContentHeight: chromeHeight + content,
                shelfHeight: heights[.actionShelf] ?? 0,
                identity: identity)
        }
    }
}

private struct ExpandedNotchHeader: View {
    @Bindable var model: NotchViewModel
    let isFocused: Bool
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 10) {
            if isFocused {
                Button(action: model.showOverview) {
                    Label("All \(sessionCount)", systemImage: "chevron.left")
                }
                .help("Show all agents")
            } else {
                Label(AgentCountLabel.text(sessionCount), systemImage: "terminal")
            }
            Spacer()
            if isFocused {
                Button { model.selectAdjacentPane(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous agent")
                Button { model.selectAdjacentPane(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .help("Next agent")
            }
            Button(action: model.collapse) {
                Label("Hide", systemImage: "chevron.up")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchPalette.primaryText)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 76, minHeight: 30)
                    .background(Capsule().fill(NotchPalette.selected))
                    .overlay(Capsule().stroke(NotchPalette.hairline, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .accessibilityLabel("Hide notch")
            .help("Hide notch")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .buttonStyle(.plain)
        .foregroundStyle(NotchPalette.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

enum AgentCountLabel {
    static func text(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }

    static func attentionText(_ count: Int) -> String {
        count == 1 ? "1 needs input" : "\(count) need input"
    }
}

private struct NotchOverviewSurface: View {
    @Bindable var model: NotchViewModel
    let snapshot: NotchDisplaySnapshot

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                if model.connection == .unavailable {
                    StatusBanner(
                        text: "herdr isn't reachable. Is the server running?",
                        systemImage: "exclamationmark.triangle.fill",
                        color: NotchPalette.critical)
                }
                if let notice = model.jumpNotice {
                    JumpNoticeBanner(model: model, notice: notice)
                }
                AttentionListView(
                    items: snapshot.items,
                    select: model.selectPane,
                    jump: model.jump)
                if snapshot.items.isEmpty, model.connection != .unavailable {
                    ContentUnavailableView(
                        "No agents",
                        systemImage: "terminal",
                        description: Text("Start an agent under herdr and it will appear here."))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 140)
                }
                if model.accessibilityMissing {
                    StatusBanner(
                        text: "Global hotkeys need Accessibility permission.",
                        systemImage: "keyboard.badge.ellipsis",
                        color: NotchPalette.critical)
                }
                if let advice = model.updateAdvice {
                    UpdateNoticeBanner(model: model, advice: advice)
                }
            }
            .padding(14)
            .reportNotchHeight(.overviewContent)
        }
    }
}

private struct NotchFocusedSurface: View {
    @Bindable var model: NotchViewModel
    let snapshot: NotchDisplaySnapshot

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let item = snapshot.selectedItem {
                        if let notice = model.jumpNotice {
                            JumpNoticeBanner(model: model, notice: notice)
                        }
                        FocusedSessionHeader(model: model, item: item)
                        FocusedPaneContent(model: model, item: item)
                    } else {
                        ProgressView("Loading agent…")
                            .foregroundStyle(NotchPalette.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .padding(14)
                .reportNotchHeight(.focusedContent)
            }
            if model.selectedFocusedSurfaceKind.hasActionShelf {
                Divider().overlay(NotchPalette.hairline)
                switch model.selectedFocusedSurfaceKind {
                case .blocked:
                    if let state = model.selectedInteractionState,
                       let interaction = state.interaction {
                        InteractionActionShelf(
                            model: model,
                            interaction: interaction,
                            phase: state.phase)
                            .id(interaction.fingerprint.rawValue)
                            .reportNotchHeight(.actionShelf)
                    } else if model.selectedInteractionState?.phase != .reading {
                        TerminalFallbackShelf(
                            model: model,
                            warning: "No structured prompt was detected. Drive the selected terminal manually.")
                            .reportNotchHeight(.actionShelf)
                    }
                case .idle:
                    IdlePromptShelf(model: model)
                        .reportNotchHeight(.actionShelf)
                case .working:
                    if let item = snapshot.selectedItem {
                        WorkingAgentActionShelf(model: model, item: item)
                            .id(item.ref)
                            .reportNotchHeight(.actionShelf)
                    }
                case .done, .unavailable:
                    EmptyView()
                }
            }
        }
    }
}

private struct FocusedSessionHeader: View {
    @Bindable var model: NotchViewModel
    let item: InteractionAttentionDisplayModel

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(NotchPalette.status(item.status))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text([item.agentName, item.modelName, item.tabTitle]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchPalette.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            if let elapsed = item.elapsedText {
                Text(elapsed).monospacedDigit()
            }
            if let freshness = item.freshnessText {
                Text(freshness).foregroundStyle(NotchPalette.tertiaryText)
            }
            AgentModeControl(model: model)
            Button("Jump") { model.jump(item.ref) }
                .foregroundStyle(NotchPalette.action)
        }
        .font(.system(size: 9, weight: .medium))
        .buttonStyle(.plain)
    }
}

private struct AgentModeControl: View {
    @Bindable var model: NotchViewModel

    @ViewBuilder var body: some View {
        if model.selectedAgentSupportsModeCycling {
            Button(action: model.cycleSelectedAgentMode) {
                Label(
                    model.selectedAgentMode.map { "Mode: \($0.displayName)" } ?? "Mode",
                    systemImage: "arrow.triangle.2.circlepath")
            }
            .foregroundStyle(NotchPalette.secondaryText)
            .disabled(!model.canCycleSelectedAgentMode)
            .help("Cycle agent mode (Shift-Tab)")
            .accessibilityLabel("Cycle agent mode")
            .accessibilityValue(model.selectedAgentMode?.displayName ?? "Unknown")
            .accessibilityHint("Sends Shift-Tab to the selected agent")
        }
    }
}

private struct FocusedPaneContent: View {
    @Bindable var model: NotchViewModel
    let item: InteractionAttentionDisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch item.status {
            case .blocked:
                blockedContent
            case .working:
                WorkingOutputPreview(
                    state: model.selectedActivityState,
                    retry: model.retrySelectedWorkingOutput)
            case .idle:
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ready for a new task")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchPalette.primaryText)
                        Text("Send a prompt below without leaving the notch.")
                            .font(.system(size: 10))
                            .foregroundStyle(NotchPalette.secondaryText)
                    }
                } icon: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(NotchPalette.action)
                }
            case .done:
                Text(item.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondaryText)
            case .unknown:
                Text("No pending prompt was detected.")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondaryText)
            }
        }
    }

    @ViewBuilder private var blockedContent: some View {
        if let state = model.selectedInteractionState {
            if state.draft.state == .stale {
                StaleDraftBanner(model: model, state: state)
            }
            if let interaction = state.interaction {
                InteractionDetailView(
                    interaction: interaction,
                    draftText: $model.replyText,
                    phase: state.phase,
                    hotkeySymbols: model.hotkeySymbols,
                    respond: model.respondToSelectedInteraction)
            } else if state.phase == .reading {
                ProgressView("Reading live prompt…")
                    .foregroundStyle(NotchPalette.secondaryText)
            } else {
                Text("No structured prompt was detected. Manual controls remain available.")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.critical)
            }
            if let error = state.error {
                StatusBanner(
                    text: error,
                    systemImage: "exclamationmark.circle",
                    color: NotchPalette.critical)
            }
        } else {
            ProgressView("Reading live prompt…")
                .foregroundStyle(NotchPalette.secondaryText)
        }
    }
}

private struct StaleDraftBanner: View {
    @Bindable var model: NotchViewModel
    let state: PaneInteractionState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved draft belongs to an earlier prompt")
                .font(.system(size: 10, weight: .semibold))
            Text(state.draft.text)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(3)
            HStack {
                Button("Reuse draft", action: model.confirmSelectedDraftReuse)
                Button("Discard", action: model.discardSelectedDraft)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchPalette.action)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(NotchPalette.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(NotchPalette.blocked.opacity(0.42), lineWidth: 1))
        .foregroundStyle(NotchPalette.blocked)
    }
}

/// The landing place for the compact notch's update dot: the badge is only a
/// signal, so expanding has to lead somewhere that says what to actually do.
/// Dismissing means "skip this version", not "hide until relaunch".
private struct UpdateNoticeBanner: View {
    @Bindable var model: NotchViewModel
    let advice: UpdateAdvice.Guidance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(advice.headline)
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.updateCommandCopied ? "Copied. Run it in a terminal." : advice.detail)
                        .foregroundStyle(NotchPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: model.skipPendingUpdate) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Skip this version")
            }
            HStack(spacing: 10) {
                if let title = advice.commandActionTitle {
                    Button(title, action: model.copyUpdateCommand)
                }
                Button(advice.primaryLinkActionTitle, action: model.openUpdateLink)
                Spacer()
            }
            .foregroundStyle(NotchPalette.updateAccent)
            Text(advice.accessibilityReminder)
                .font(.system(size: 9))
                .foregroundStyle(NotchPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(NotchPalette.elevated))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(NotchPalette.hairline, lineWidth: 1))
    }
}

private struct StatusBanner: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(NotchPalette.elevated))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(color.opacity(0.42), lineWidth: 1))
    }
}

private struct JumpNoticeBanner: View {
    @Bindable var model: NotchViewModel
    let notice: JumpNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(notice.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if notice.attachCommand != nil {
                Button("Copy attach command", action: model.copyJumpAttachCommand)
                    .foregroundStyle(NotchPalette.action)
            }
            Button(action: model.dismissJumpNotice) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss jump message")
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(NotchPalette.blocked)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(NotchPalette.elevated))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(NotchPalette.blocked.opacity(0.42), lineWidth: 1))
    }
}
