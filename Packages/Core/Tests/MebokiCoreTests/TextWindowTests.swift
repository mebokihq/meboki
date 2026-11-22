import Foundation
import Testing
@testable import MebokiCore

/// Google Docs' hidden copy holds whole paragraphs around the caret and moves its window without an edit.
@Suite struct TextWindowTests {
    static func paras(_ r: ClosedRange<Int>) -> String {
        r.map { "Paragraph \($0) of the long test. We has written many sentence here so the document spill over." }
            .joined(separator: "\n")
    }

    @Test func windowShrinksAtTheEnd() {
        // Seen 2026-11-22: after a paste near the top, 4241 → 1054 characters, same start.
        let old = Self.paras(1...30), new = Self.paras(1...8)
        let a = TextWindow.alignment(old: old, new: new)
        #expect(a?.shift == 0)
        #expect(a?.overlap == NSRange(location: 0, length: (new as NSString).length))
        #expect(a?.edit == nil)
    }

    @Test func windowMovesForward() {
        let old = Self.paras(1...20), new = Self.paras(11...30)
        let start = (old as NSString).range(of: "Paragraph 11 ").location
        let a = TextWindow.alignment(old: old, new: new)
        #expect(a?.shift == start)
        #expect(a.map { NSMaxRange($0.overlap) } == (old as NSString).length)
    }

    @Test func windowMovesBack() {
        let old = Self.paras(11...30), new = Self.paras(1...20)
        let start = (new as NSString).range(of: "Paragraph 11 ").location
        let a = TextWindow.alignment(old: old, new: new)
        #expect(a?.shift == -start)
        #expect(a?.overlap.location == 0)
    }

    /// Seen 2026-11-22: Apply all wrote "paragraf" → "paragraph" near the end, and Docs moved the window at once;
    /// the review still held the text from before the write.
    @Test func windowMovedWithAWriteInside() {
        let old = Self.paras(1...20)
        var newer = Self.paras(15...26)
        let at = (newer as NSString).range(of: "Paragraph 18 of the long test. We has").location
        newer = (newer as NSString).replacingCharacters(in: NSRange(location: at + 34, length: 3), with: "have")
        let a = TextWindow.alignment(old: old, new: newer)
        let start = (old as NSString).range(of: "Paragraph 15 ").location
        #expect(a?.shift == start)
        #expect(a?.edit?.replacement == "ve")
        #expect(a.map { NSMaxRange($0.overlap) } == (old as NSString).length)
    }

    @Test func smallEditIsNotAMove() {
        let old = Self.paras(1...10)
        let new = old.replacingOccurrences(of: "Paragraph 3 of", with: "Paragraph 3 off")
        #expect(TextWindow.alignment(old: old, new: new) == nil)
    }

    /// Seen 2026-11-22: right after a paste Docs added one short paragraph at the top of its window (1069 → 1106);
    /// a small change describes it, yet it is a shift of whole paragraphs, and the write's check must see it so.
    @Test func shortParagraphAddedAtAnEdgeAlignsWhenAsked() {
        let old = Self.paras(2...10)
        let new = "Short one.\n" + old
        #expect(TextWindow.alignment(old: old, new: new) == nil)
        let a = TextWindow.alignment(old: old, new: new, evenWhenSmall: true)
        #expect(a?.shift == -("Short one.\n" as NSString).length)
        #expect(a?.edit == nil)
        #expect(a?.overlap == NSRange(location: 0, length: (old as NSString).length))
    }

    @Test func smallEditStaysAnEditWhenAsked() {
        let old = Self.paras(1...10)
        let new = old.replacingOccurrences(of: "Paragraph 3 of", with: "Paragraph 3 off")
        let a = TextWindow.alignment(old: old, new: new, evenWhenSmall: true)
        #expect(a?.shift == 0)
        #expect(a?.edit != nil)
    }

    @Test func unrelatedTextsDontAlign() {
        #expect(TextWindow.alignment(old: Self.paras(1...10), new: Self.paras(40...50)) == nil)
    }

    @Test func repeatedParagraphPicksTheLongestOverlap() {
        let same = "The same paragraph text, repeated in this document."
        func p(_ c: String) -> String { String(repeating: c + " paragraph with enough text to be long. ", count: 4) }
        let old = [same, p("A"), same, p("B"), p("C"), p("D")].joined(separator: "\n")
        let new = [same, p("B"), p("C"), p("D"), p("E")].joined(separator: "\n")
        let a = TextWindow.alignment(old: old, new: new)
        let second = (old as NSString).range(of: same + "\n" + p("B")).location
        #expect(a?.shift == second)
    }
}
