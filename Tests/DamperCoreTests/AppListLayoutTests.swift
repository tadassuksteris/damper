import CoreGraphics
import Testing
@testable import DamperCore

private func viewport(rows: Int, limit: CGFloat) -> CGFloat {
    AppListLayout.viewportHeight(rowHeights: Array(repeating: 50, count: rows), spacing: 8, peek: 12, maxVisibleRows: 6, limit: limit)
}

@Test func aListThatFitsShowsEveryRowAndNoPeek() {
    #expect(viewport(rows: 1, limit: .greatestFiniteMagnitude) == 50)
    #expect(viewport(rows: 6, limit: .greatestFiniteMagnitude) == 340)
    #expect(viewport(rows: 6, limit: 340) == 340)
}

@Test func aListPastTheVisibleRowsPeeksIntoTheNextRow() {
    #expect(viewport(rows: 7, limit: .greatestFiniteMagnitude) == 360)
    #expect(viewport(rows: 20, limit: 360) == 360)
}

@Test func aShortListEndsAPeekIntoAHiddenRowWhereverTheLimitFalls() {
    // A limit in the gap after the fifth row, near that row's end, at a peek into it, and short of a peek.
    #expect(viewport(rows: 7, limit: 286) == 244)
    #expect(viewport(rows: 7, limit: 281) == 244)
    #expect(viewport(rows: 7, limit: 240) == 186)
    #expect(viewport(rows: 7, limit: 244) == 244)
    // A list within the visible rows that doesn't quite fit also shows it continues.
    #expect(viewport(rows: 3, limit: 165) == 128)
    #expect(viewport(rows: 6, limit: 339) == 302)
}

@Test func theShortestListStillShowsARowAndAPeek() {
    #expect(viewport(rows: 7, limit: 69) == 70)
    #expect(viewport(rows: 7, limit: -20) == 70)
    #expect(viewport(rows: 2, limit: 60) == 70)
    #expect(viewport(rows: 1, limit: 20) == 50)
}

@Test func measuredRowHeightsPlaceThePeek() {
    let height = AppListLayout.viewportHeight(rowHeights: [50, 80, 50, 50], spacing: 8, peek: 12, maxVisibleRows: 6, limit: 200)
    #expect(height == 158)
}
