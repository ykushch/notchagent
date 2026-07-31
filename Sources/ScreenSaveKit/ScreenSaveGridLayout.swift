import SwiftUI

public struct ScreenSaveGridLayout: Sendable, Equatable {
    public static let minimumCardWidth: CGFloat = 420
    public static let maximumCardWidth: CGFloat = 620
    public static let minimumCardHeight: CGFloat = 190

    public struct Page: Sendable, Equatable {
        public let index: Int
        public let count: Int
        public let itemRange: Range<Int>
    }

    public let columnCount: Int
    public let rowCount: Int
    public let itemCount: Int
    public let spacing: CGFloat = 18
    public let edgePadding: CGFloat
    public let minimumColumnWidth: CGFloat

    public init(size: CGSize, itemCount: Int) {
        self.itemCount = itemCount
        edgePadding = max(36, min(88, size.width * 0.055))
        let usableWidth = max(1, size.width - edgePadding * 2)
        let usableHeight = max(1, size.height - 210)
        minimumColumnWidth = min(Self.minimumCardWidth, usableWidth)
        columnCount = max(1, Int(
            (usableWidth + spacing) / (Self.minimumCardWidth + spacing)))
        rowCount = max(1, Int(
            (usableHeight + spacing) / (Self.minimumCardHeight + spacing)))
    }

    /// A partial page should stay centered instead of reserving invisible
    /// columns that leave one or two cards stranded at the leading edge.
    public func columns(displayedItemCount: Int) -> [GridItem] {
        let visibleColumnCount = min(columnCount, max(1, displayedItemCount))
        return Array(repeating: GridItem(
            .flexible(
                minimum: minimumColumnWidth,
                maximum: Self.maximumCardWidth),
            spacing: spacing), count: visibleColumnCount)
    }

    public var capacity: Int { max(1, columnCount * rowCount) }

    public func page(at date: Date) -> Page {
        let count = max(1, Int(ceil(Double(itemCount) / Double(capacity))))
        let index = itemCount == 0
            ? 0 : Int(date.timeIntervalSinceReferenceDate / 12) % count
        let lower = min(itemCount, index * capacity)
        let upper = min(itemCount, lower + capacity)
        return Page(index: index, count: count, itemRange: lower..<upper)
    }
}
