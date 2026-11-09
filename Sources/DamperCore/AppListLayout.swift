import CoreGraphics

/// The height of the app list's viewport.
public enum AppListLayout {
    /// All the rows when they fit. Otherwise the viewport ends `peek` into a hidden row, because
    /// one that ends on a row boundary or clips a row only slightly looks like the whole list.
    /// When `limit` can't fit even one row and a peek, the viewport still shows them.
    public static func viewportHeight(rowHeights: [CGFloat], spacing: CGFloat, peek: CGFloat,
                                      maxVisibleRows: Int, limit: CGFloat) -> CGFloat {
        func end(peekingInto row: Int) -> CGFloat {
            rowHeights[..<row].reduce(peek) { $0 + $1 + spacing }
        }
        let wanted = rowHeights.count > maxVisibleRows ? end(peekingInto: maxVisibleRows)
            : end(peekingInto: rowHeights.count) - peek - spacing
        guard wanted > limit, rowHeights.count > 1 else { return wanted }
        return (1..<min(rowHeights.count, maxVisibleRows)).map(end(peekingInto:)).last { $0 <= limit } ?? end(peekingInto: 1)
    }
}
