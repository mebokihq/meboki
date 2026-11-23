import Foundation
import Testing
@testable import MebokiCore

@Suite struct ParagraphBreakMapTests {
    /// The start of the Proton Docs test document as Safari 27 reports it (2026-11-23): two `\n` between paragraphs,
    /// four around an empty paragraph.
    static let text = "Multi-paragraph test document\n\nThis document test how.\n\nShe have two cat.\n\n\n\nThe paragraph above is empty.\n\nEmoji 😀 here."

    @Test func shiftIsHalfTheBreaksBefore() {
        let map = ParagraphBreakMap(text: Self.text)
        let ns = Self.text as NSString
        for (needle, breaks) in [("This", 2), ("She", 4), ("The paragraph", 8), ("Emoji", 10)] {
            let i = ns.range(of: needle).location
            #expect(map.webKitIndex(i) == i - breaks / 2, "\(needle)")
            #expect(map.valueIndex(map.webKitIndex(i)) == i, "\(needle) round trip")
        }
        #expect(map.webKitIndex(0) == 0)
        #expect(map.webKitIndex(5) == 5)
    }

    @Test func matchesTheProbeOnSafari27() {
        // Probe rows (value offset, breaks before, measured shift) from the 3079-unit document.
        var text = "Multi-paragraph test document"
        var expected: [(Int, Int)] = []
        for p in 0..<40 {
            text += "\n\n"
            if p == 3 { text += "\n\n" } // the empty paragraph
            expected.append(((text as NSString).length, ((text.filter { $0 == "\n" }.count) / 2)))
            text += "Paragraph \(p) say that less people came then we expected."
        }
        let map = ParagraphBreakMap(text: text)
        for (i, shift) in expected {
            #expect(i - map.webKitIndex(i) == shift)
        }
    }

    @Test func rangesAndSelectionBackToValue() {
        let map = ParagraphBreakMap(text: Self.text)
        let ns = Self.text as NSString
        let word = ns.range(of: "empty")
        let w = map.webKitRange(word)
        #expect(w.length == word.length)
        #expect(map.valueRange(w) == word)
        // A range across a break keeps its ends.
        let across = NSRange(location: ns.range(of: "how.").location, length: ns.range(of: "She").location + 3 - ns.range(of: "how.").location)
        #expect(map.valueRange(map.webKitRange(across)) == across)
        // The end of the text.
        #expect(map.valueIndex(map.webKitIndex(ns.length)) == ns.length)
        #expect(map.valueIndex(10_000) == ns.length)
    }

    @Test func singleBreaksAndPlainTextAreUnchanged() {
        for t in ["One line only.", "Line one\nLine two\nLine three", ""] {
            let map = ParagraphBreakMap(text: t)
            #expect(map.isIdentity)
            for i in 0...(t as NSString).length {
                #expect(map.webKitIndex(i) == i)
                #expect(map.valueIndex(i) == i)
            }
        }
    }

    @Test func insideARunLandsOnAPair() {
        let map = ParagraphBreakMap(text: "a\n\n\n\nb")  // value: a=0, run 1..<5, b=5
        #expect(map.webKitIndex(5) == 3)              // a, \n, \n, b
        #expect(map.webKitIndex(3) == 2)
        #expect(map.valueIndex(2) == 3)
        #expect(map.valueIndex(3) == 5)
        let odd = ParagraphBreakMap(text: "a\n\n\nb")  // three: counted as two
        #expect(odd.webKitIndex(4) == 3)
        #expect(odd.valueIndex(3) == 4)
    }

    @Test func paragraphStartsSkipBulletsAndIndents() {
        let t = "Title\n\n    • First item\n\nSecond paragraph\n\n\n\nThird"
        let map = ParagraphBreakMap(text: t)
        let starts = map.paragraphStarts(in: t)
        let ns = t as NSString
        #expect(starts.map(\.index) == [ns.range(of: "Second").location, ns.range(of: "Third").location])
        #expect(starts.map(\.shift) == [2, 4])
    }
}
