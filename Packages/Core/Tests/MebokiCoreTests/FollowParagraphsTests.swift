import Foundation
import Testing
@testable import MebokiCore

/// `FixList.followParagraphs`: a document of paragraph fields whose visible paragraphs change while scrolling
/// (LibreOffice). Fixes must stay with their paragraph, never follow repeated text into another one.
@Suite struct FollowParagraphsTests {
    static func edit(_ text: String, _ word: String, _ replacement: String, after: Int = 0) -> Edit {
        let ns = text as NSString
        let r = ns.range(of: word, options: [], range: NSRange(location: after, length: ns.length - after))
        return Edit(range: r, original: word, replacement: replacement)
    }

    /// The case seen on 2026-11-22: after a scroll, paragraph 3's text "…, and it dont end with a full stop" left
    /// the screen and paragraph 31 with the same ending came in. A whole-text diff carried the fix onto 31.
    @Test func fixLeavesWithItsParagraphNotWithRepeatedText() {
        let old = SegmentMap(segments: ["This is paragraph 3, and it dont end with a full stop",
                                        "Paragraph 4 say that less people came."])
        let new = SegmentMap(segments: ["Paragraph 4 say that less people came.",
                                        "This is paragraph 31, and it dont end with a full stop"])
        var list = FixList(text: old.text, edits: [
            Self.edit(old.text, "dont", "doesn't"),
            Self.edit(old.text, "say", "says"),
        ])
        let remap = list.followParagraphs(from: old, ids: [3, 4], to: new, ids: [4, 31])
        #expect(remap == [1: 0])
        #expect(list.text == new.text)
        #expect(list.fixes.count == 1)
        let f = list.fixes[0].edit
        #expect((list.text as NSString).substring(with: f.range) == "say")
        #expect(f.range.location == 12)
    }

    @Test func scrollDownKeepsFixesOfParagraphsStillOnScreen() {
        let old = SegmentMap(segments: ["A have one.", "B have two.", "C have three.", "D have four."])
        let new = SegmentMap(segments: ["C have three.", "D have four.", "E have five.", "F have six."])
        let edits = ["A", "B", "C", "D"].map { p in
            Self.edit(old.text, "have", "has", after: (old.text as NSString).range(of: p + " have").location)
        }
        var list = FixList(text: old.text, edits: edits)
        let remap = list.followParagraphs(from: old, ids: [1, 2, 3, 4], to: new, ids: [3, 4, 5, 6])
        #expect(remap == [2: 0, 3: 1])
        #expect(list.text == new.text)
        let ns = list.text as NSString
        #expect(list.fixes.map { ns.substring(with: $0.edit.range) } == ["have", "have"])
        #expect(list.fixes.map(\.edit.range.location) == [2, 16])
    }

    @Test func scrollUpMovesFixesDown() {
        let old = SegmentMap(segments: ["C have three.", "D have four."])
        let new = SegmentMap(segments: ["A.", "B.", "C have three.", "D have four."])
        var list = FixList(text: old.text, edits: [Self.edit(old.text, "have", "has", after: 14)])
        #expect(list.followParagraphs(from: old, ids: [3, 4], to: new, ids: [1, 2, 3, 4]) == [0: 0])
        let r = list.fixes[0].edit.range
        #expect(r.location == (new.text as NSString).range(of: "D have").location + 2)
    }

    @Test func editInsideAParagraphThatStayedWhileOthersCame() {
        let old = SegmentMap(segments: ["She have two cat.", "They is happy."])
        let new = SegmentMap(segments: ["She have two cats!", "They is happy.", "New one."])
        var list = FixList(text: old.text, edits: [
            Self.edit(old.text, "have", "has"),
            Self.edit(old.text, "is", "are", after: 18),
        ])
        list.followParagraphs(from: old, ids: [7, 8], to: new, ids: [7, 8, 9])
        #expect(list.text == new.text)
        // The edited sentence's fix leaves (its context changed); the other paragraph's fix moved by the edit.
        let ns = list.text as NSString
        #expect(list.fixes.map { ns.substring(with: $0.edit.range) } == ["is"])
        #expect(list.fixes[0].edit.range.location == (new.text as NSString).range(of: "They is").location + 5)
    }

    @Test func appliedFixesCountEvenWhenTheirParagraphLeaves() {
        let old = SegmentMap(segments: ["One have.", "Two have."])
        var list = FixList(text: old.text, edits: [Self.edit(old.text, "have", "has")])
        list.applyOne(at: 0)
        let afterWrite = SegmentMap(segments: ["One has.", "Two have."])
        #expect(list.text == afterWrite.text)
        let new = SegmentMap(segments: ["Two have.", "Three."])
        list.followParagraphs(from: afterWrite, ids: [1, 2], to: new, ids: [2, 3])
        #expect(list.fixes.isEmpty)
        #expect(list.appliedCount == 1)
    }

    @Test func refusesAStaleOldTextOrAReorder() {
        let old = SegmentMap(segments: ["A have.", "B have."])
        var list = FixList(text: old.text, edits: [Self.edit(old.text, "have", "has")])
        let before = list
        #expect(list.followParagraphs(from: SegmentMap(segments: ["X"]), ids: [1], to: old, ids: [1]) == nil)
        #expect(list.followParagraphs(from: old, ids: [1, 2], to: SegmentMap(segments: ["B have.", "A have."]),
                                      ids: [2, 1]) == nil)
        #expect(list == before)
    }

    @Test func emptyParagraphsAndEmoji() {
        let old = SegmentMap(segments: ["Emoji 😀 here have.", "", "Last have."])
        let new = SegmentMap(segments: ["", "Last have.", "More."])
        var list = FixList(text: old.text, edits: [
            Self.edit(old.text, "have", "has"),
            Self.edit(old.text, "have", "has", after: 20),
        ])
        #expect(list.followParagraphs(from: old, ids: [1, 2, 3], to: new, ids: [2, 3, 4]) == [1: 0])
        #expect(list.fixes[0].edit.range.location == 6)
        #expect(list.text == new.text)
    }

    // MARK: - Parked fixes (parksDeparted)

    @Test func parkedFixesComeBackWithTheirParagraphByExactText() {
        let old = SegmentMap(segments: ["A have one.", "B have two.", "C have three."])
        var list = FixList(text: old.text, edits: [
            Self.edit(old.text, "have", "has"),
            Self.edit(old.text, "have", "has", after: 12),
            Self.edit(old.text, "have", "has", after: 24),
        ])
        list.parksDeparted = true
        // A leaves, D comes.
        let mid = SegmentMap(segments: ["B have two.", "C have three.", "D here."])
        #expect(list.followParagraphs(from: old, ids: [1, 2, 3], to: mid, ids: [2, 3, 4]) != nil)
        #expect(list.fixes.count == 2)
        #expect(list.parkedCount == 1)
        // A returns as a new element, B leaves.
        let back = SegmentMap(segments: ["A have one.", "C have three.", "D here."])
        let remap = list.followParagraphs(from: mid, ids: [2, 3, 4], to: back, ids: [9, 3, 4])
        #expect(remap == [1: 1])
        #expect(list.parkedCount == 1)  // B's fix now waits
        #expect(list.fixes.count == 2)
        #expect(list.text == back.text)
        for f in list.fixes {
            #expect((list.text as NSString).substring(with: f.edit.range) == "have")
        }
        #expect(list.fixes[0].edit.range.location == 2)  // A's "have"
        #expect(list.pendingCount == 2)
    }

    @Test func repeatedTextIsNotMatchedAndNothingIsParkedForIt() {
        let old = SegmentMap(segments: ["Same have text.", "X have y.", "Same have text."])
        var list = FixList(text: old.text, edits: [
            Self.edit(old.text, "have", "has"),
            Self.edit(old.text, "have", "has", after: 16),
        ])
        list.parksDeparted = true
        // Both "Same" paragraphs leave, then one comes back: it is not either one of them for certain.
        let mid = SegmentMap(segments: ["X have y."])
        _ = list.followParagraphs(from: old, ids: [1, 2, 3], to: mid, ids: [2])
        #expect(list.parkedCount == 0)
        #expect(list.fixes.count == 1)
        let back = SegmentMap(segments: ["X have y.", "Same have text."])
        _ = list.followParagraphs(from: mid, ids: [2], to: back, ids: [2, 7])
        #expect(list.fixes.count == 1)
    }

    @Test func parkedTextThatNowAppearsTwiceStaysParked() {
        let old = SegmentMap(segments: ["A have one.", "B have two."])
        var list = FixList(text: old.text, edits: [Self.edit(old.text, "have", "has")])
        list.parksDeparted = true
        let mid = SegmentMap(segments: ["B have two."])
        _ = list.followParagraphs(from: old, ids: [1, 2], to: mid, ids: [2])
        #expect(list.parkedCount == 1)
        let two = SegmentMap(segments: ["A have one.", "B have two.", "A have one."])
        _ = list.followParagraphs(from: mid, ids: [2], to: two, ids: [8, 2, 9])
        #expect(list.fixes.isEmpty)
        #expect(list.parkedCount == 1)
    }

    @Test func withoutParkingFixesOfDepartedParagraphsAreDropped() {
        let old = SegmentMap(segments: ["A have one.", "B have two."])
        var list = FixList(text: old.text, edits: [Self.edit(old.text, "have", "has")])
        let mid = SegmentMap(segments: ["B have two."])
        _ = list.followParagraphs(from: old, ids: [1, 2], to: mid, ids: [2])
        #expect(list.parkedCount == 0)
        #expect(list.fixes.isEmpty)
    }
}
