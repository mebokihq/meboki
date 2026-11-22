import Foundation
import Testing
@testable import MebokiCore

@Suite struct TextLeafMapTests {
    /// The x.com-like probe page in Chrome (2026-11-16): three blocks, a bold word, an emoji, a `<br>`.
    static let value = "She have two cat and they is happy.\nThis sentence is very long, i think.\nEmoji 😀 here an mistake.\nSecond line."
    static let leaves = ["She have two cat and they is happy.", "This sentence is ", "very", " long, i think.",
                         "Emoji 😀 here an mistake.", "Second line."]

    @Test func linesUpBlocksAndInlineRuns() {
        let map = TextLeafMap(value: Self.value, leaves: Self.leaves)
        #expect(map.segments.map(\.leaf) == [0, 1, 2, 3, 4, 5])
        let ns = Self.value as NSString
        for s in map.segments {
            #expect(ns.substring(with: s.range) == Self.leaves[s.leaf])
        }
        #expect(map.coverage(of: Self.value) == 1)
    }

    @Test func splitsRangesIntoLeafLocalPieces() {
        let map = TextLeafMap(value: Self.value, leaves: Self.leaves)
        let ns = Self.value as NSString
        // Inside one leaf, after the emoji (UTF-16 offsets, the emoji is 2 units).
        let here = ns.range(of: "here")
        let p = map.pieces(of: here)
        #expect(p.count == 1)
        #expect(p.first?.leaf == 4)
        #expect(p.first?.range == NSRange(location: 9, length: 4))
        // Across the bold run: "is very long" → three leaves.
        let across = map.pieces(of: ns.range(of: "is very long"))
        #expect(across.map(\.leaf) == [1, 2, 3])
        #expect(across.map(\.range) == [NSRange(location: 14, length: 3), NSRange(location: 0, length: 4),
                                         NSRange(location: 0, length: 5)])
        // The \n between blocks belongs to no leaf.
        let nl = ns.range(of: "happy.\nThis")
        #expect(map.pieces(of: nl).map(\.leaf) == [0, 1])
        #expect(map.pieces(of: NSRange(location: NSMaxRange(ns.range(of: "happy.")), length: 1)).isEmpty)
        #expect(map.pieces(of: NSRange(location: 3, length: 0)).isEmpty)
    }

    @Test func locatesIndicesInLeaves() {
        let map = TextLeafMap(value: Self.value, leaves: Self.leaves)
        let ns = Self.value as NSString
        #expect(map.locate(0)! == (0, 0))
        #expect(map.locate(4)! == (0, 4))
        // The end of the first block (a caret after "happy.") is in leaf 0; the next index is the \n's end = leaf 1.
        let end0 = NSMaxRange(ns.range(of: "happy."))
        #expect(map.locate(end0)! == (0, 35))
        #expect(map.locate(end0 + 1)! == (1, 0))
        // Where two inline leaves meet, the later one wins: "very" starts where "This sentence is " ends.
        let very = ns.range(of: "very").location
        #expect(map.locate(very)! == (2, 0))
        #expect(map.locate(ns.length)! == (5, 12))
        #expect(map.locate(ns.length + 1) == nil)
        // Between leaves, after an unmatched gap.
        let m2 = TextLeafMap(value: "one\n\ntwo", leaves: ["one", "two"])
        #expect(m2.locate(4) == nil)
    }

    @Test func skipsLeavesThatDontMatchAndRecovers() {
        // A leaf whose text isn't in the value (a placeholder, a list bullet) is left out; the rest still match.
        let leaves = ["She have two cat and they is happy.", "• ", "This sentence is ", "very", " long, i think.",
                      "Emoji 😀 here an mistake.", "Second line."]
        let map = TextLeafMap(value: Self.value, leaves: leaves)
        #expect(map.segments.map(\.leaf) == [0, 2, 3, 4, 5, 6])
        // A leaf that differs from the value: the next leaf may jump over its text.
        let changed = ["She have two cat and they is happy.", "This sentence IS ", "very", " long, i think."]
        let m2 = TextLeafMap(value: Self.value, leaves: changed)
        #expect(m2.segments.map(\.leaf) == [0, 2, 3])
        #expect(m2.pieces(of: (Self.value as NSString).range(of: "is very")).map(\.leaf) == [2])
    }

    @Test func neverMatchesFarAhead() {
        // A short leaf that only appears much later isn't pulled forward over real text.
        let map = TextLeafMap(value: "alpha beta gamma delta", leaves: ["alpha", "delta"])
        #expect(map.segments.map(\.leaf) == [0])
        // Object replacement characters (images) and blank lines are skipped.
        let m2 = TextLeafMap(value: "one\n\u{FFFC}\n\ntwo", leaves: ["one", "two"])
        #expect(m2.segments.map(\.leaf) == [0, 1])
        // Empty leaves and an empty value.
        #expect(TextLeafMap(value: "", leaves: ["a"]).segments.isEmpty)
        #expect(TextLeafMap(value: "a b", leaves: ["", "a", "", "b"]).segments.map(\.leaf) == [1, 3])
    }

    @Test func editedShiftsLaterLeavesAndResizesTheEditedOne() {
        let map = TextLeafMap(value: Self.value, leaves: Self.leaves)
        let ns = Self.value as NSString
        let r = ns.range(of: "have")
        let change = TextChange(range: r, replacement: "has")
        let new = ns.replacingCharacters(in: r, with: "has")
        guard let (edited, leaf) = map.edited(change) else { Issue.record("no in-place map"); return }
        #expect(leaf == 0)
        var leaves = Self.leaves
        leaves[0] = "She has two cat and they is happy."
        #expect(edited == TextLeafMap(value: new, leaves: leaves))
    }

    @Test func editedRefusesChangesOutsideOneLeaf() {
        let map = TextLeafMap(value: Self.value, leaves: Self.leaves)
        let ns = Self.value as NSString
        // Across the line break between two blocks.
        let across = NSRange(location: ns.range(of: "happy.").location, length: 8)
        #expect(map.edited(TextChange(range: across, replacement: "x")) == nil)
        // An insertion at a leaf's edge.
        let edge = ns.range(of: "very").location
        #expect(map.edited(TextChange(range: NSRange(location: edge, length: 0), replacement: "x")) == nil)
        // Emptying a leaf.
        #expect(map.edited(TextChange(range: ns.range(of: "very"), replacement: "")) == nil)
        // Inside a leaf right before another one: fine.
        let inside = ns.range(of: "is ", options: .backwards, range: NSRange(location: 0, length: edge))
        #expect(map.edited(TextChange(range: inside, replacement: "was ")) != nil)
    }

    /// x.com list items (Chrome, 2026-11-22): each item is one leaf "    • item", while the value puts the indent
    /// before the line break. The leaf matches without its indent, and leaf-local ranges count the indent.
    @Test func linesUpIndentedListItemLeaves() {
        let value = "Late again.    \n• First item have an error.    \n• Second item\nAfter."
        let leaves = ["Late again.", "    • First item have an error.", "    • Second item", "After."]
        let map = TextLeafMap(value: value, leaves: leaves)
        let ns = value as NSString
        #expect(map.segments.map(\.leaf) == [0, 1, 2, 3])
        #expect(map.segments.map(\.offset) == [0, 4, 4, 0])
        #expect(map.coverage(of: value) == 1)
        let have = ns.range(of: "have")
        #expect(map.pieces(of: have).map(\.range) == [NSRange(location: 17, length: 4)])
        #expect(map.locate(have.location)! == (1, 17))
        #expect(map.locate(ns.range(of: "• Second").location)! == (2, 4))
        // Marker counts include every leaf's whole text: "Late again." (11) + 4 spaces + "• First" → value "First".
        #expect(map.valueIndex(leafCount: 11 + 6, atStart: true) == ns.range(of: "First").location)
        // Inside the left-out indent: the start of the item's matched text.
        #expect(map.valueIndex(leafCount: 11 + 2, atStart: true) == ns.range(of: "• First").location)
        #expect(map.valueIndex(leafCount: 0, atStart: true) == 0)
        #expect(map.valueIndex(leafCount: 11, atStart: false) == 11)
        // An edit inside the item keeps its offset and grows its leaf.
        let (edited, leaf) = map.edited(TextChange(range: have, replacement: "has"))!
        #expect(leaf == 1)
        #expect(edited.segments[1].offset == 4)
        #expect(edited.segments[1].leafLength == leaves[1].utf16.count - 1)
    }
}
