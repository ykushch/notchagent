import Foundation
import ScreenSaveKit
import Testing
@testable import NotchApp

@Suite("Screen-save grid layout")
struct ScreenSaveGridLayoutTests {
    @Test("large agent sets rotate through bounded pages")
    func paginates() {
        let layout = ScreenSaveGridLayout(
            size: CGSize(width: 900, height: 700), itemCount: 10)
        #expect(layout.capacity == 2)

        let first = layout.page(at: Date(timeIntervalSinceReferenceDate: 0))
        let second = layout.page(at: Date(timeIntervalSinceReferenceDate: 12))
        let third = layout.page(at: Date(timeIntervalSinceReferenceDate: 24))

        #expect(first.index == 0)
        #expect(first.count == 5)
        #expect(first.itemRange == 0..<2)
        #expect(second.itemRange == 2..<4)
        #expect(third.itemRange == 4..<6)
    }

    @Test("empty state always has a safe empty page")
    func emptyState() {
        let layout = ScreenSaveGridLayout(
            size: CGSize(width: 320, height: 240), itemCount: 0)
        let page = layout.page(at: Date(timeIntervalSinceReferenceDate: 120))

        #expect(layout.capacity >= 1)
        #expect(page.index == 0)
        #expect(page.count == 1)
        #expect(page.itemRange.isEmpty)
    }

    @Test("wide cards center partially filled pages")
    func centersPartialPages() {
        let layout = ScreenSaveGridLayout(
            size: CGSize(width: 1_920, height: 1_080), itemCount: 7)

        #expect(layout.columnCount == 4)
        #expect(layout.minimumColumnWidth == ScreenSaveGridLayout.minimumCardWidth)
        #expect(layout.columns(displayedItemCount: 4).count == 4)
        #expect(layout.columns(displayedItemCount: 1).count == 1)
    }
}
