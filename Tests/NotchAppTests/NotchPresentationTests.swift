import Testing
@testable import NotchApp

@Suite("Notch presentation")
struct NotchPresentationTests {
    @Test("Untouched automatic focus returns to compact")
    func automaticUntouchedResolution() {
        let presentation = NotchPresentation.focused(.init(
            origin: .automatic,
            hasUserEngaged: false))

        #expect(!presentation.preservesResolvedSelection)
        #expect(presentation.fallbackAfterFocusedPaneEnds == .compact)
    }

    @Test("Engaging with automatic focus returns to overview")
    func automaticEngagedResolution() {
        var presentation = NotchPresentation.focused(.init(
            origin: .automatic,
            hasUserEngaged: false))

        presentation.markUserEngaged()

        #expect(presentation.preservesResolvedSelection)
        #expect(presentation.fallbackAfterFocusedPaneEnds == .overview)
    }

    @Test("Manual focus preserves completion until the user leaves detail")
    func manualResolution() {
        let presentation = NotchPresentation.focused(.init(
            origin: .manual,
            hasUserEngaged: false))

        #expect(presentation.preservesResolvedSelection)
        #expect(presentation.fallbackAfterFocusedPaneEnds == .overview)
    }

    @Test("Overview is expanded without implying a selected pane")
    func overviewState() {
        #expect(NotchPresentation.overview.isExpanded)
        #expect(!NotchPresentation.overview.isFocused)
        #expect(!NotchPresentation.compact.isExpanded)
    }

    @Test("automatic attention never replaces overview or user-owned detail")
    func automaticAttentionRespectsUserContext() {
        #expect(NotchPresentation.compact.allowsAutomaticFocus)
        #expect(!NotchPresentation.overview.allowsAutomaticFocus)
        #expect(!NotchPresentation.focused(.init(
            origin: .automatic, hasUserEngaged: false)).allowsAutomaticFocus)
        #expect(!NotchPresentation.focused(.init(
            origin: .manual, hasUserEngaged: true)).allowsAutomaticOverview)
    }
}
