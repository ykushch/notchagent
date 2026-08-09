import HerdrClient
import Testing
@testable import NotchApp

@Suite("Focused pane activity presentation")
struct PaneActivityPresentationTests {
    @Test("rollup status selects an explicit focused surface")
    func statusRouting() {
        #expect(FocusedPaneSurfaceKind(status: .blocked) == .blocked)
        #expect(FocusedPaneSurfaceKind(status: .working) == .working)
        #expect(FocusedPaneSurfaceKind(status: .idle) == .idle)
        #expect(FocusedPaneSurfaceKind(status: .done) == .done)
        #expect(FocusedPaneSurfaceKind(status: .unknown) == .unavailable)
        #expect(FocusedPaneSurfaceKind(status: nil) == .unavailable)
    }

    @Test("only blocked interactions and idle prompts own the action shelf")
    func shelfPolicy() {
        #expect(FocusedPaneSurfaceKind.blocked.hasActionShelf)
        #expect(FocusedPaneSurfaceKind.idle.hasActionShelf)
        #expect(!FocusedPaneSurfaceKind.working.hasActionShelf)
        #expect(!FocusedPaneSurfaceKind.done.hasActionShelf)
        #expect(!FocusedPaneSurfaceKind.unavailable.hasActionShelf)
    }
}
