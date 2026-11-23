import Foundation
import Testing
@testable import MebokiCore

@Suite struct AnchoredEditTests {
    private func anchored(_ from: String, _ to: String) -> [Edit] {
        Diff.edits(from: from, to: to).map { $0.anchored(in: from) }
    }

    @Test func insertedWordTakesTheNextCharacter() {
        let text = "Dessi said doesn’t matter."
        let e = anchored(text, "Dessi said it doesn’t matter.")
        #expect(e.count == 1)
        #expect(e[0].original == "d")
        #expect(e[0].replacement == "it d")
        #expect(Diff.apply(e, to: text) == "Dessi said it doesn’t matter.")
    }

    @Test func trailingSpaceOfAReplacementTakesTheNextCharacter() {
        let text = "Second item is fine."
        let e = anchored(text, "The second item is fine.")
        #expect(e.allSatisfy { !($0.replacement.last?.isWhitespace ?? false) })
        #expect(Diff.apply(e, to: text) == "The second item is fine.")
    }

    @Test func leadingSpaceTakesThePreviousCharacter() {
        let text = "I like it"
        let e = Edit(range: NSRange(location: 9, length: 0), original: "", replacement: " a lot").anchored(in: text)
        #expect(e.original == "t")
        #expect(e.replacement == "t a lot")
        #expect(e.range == NSRange(location: 8, length: 1))
    }

    @Test func plainSwapIsUnchanged() {
        let text = "I has a car."
        let e = Diff.edits(from: text, to: "I have a car.")[0]
        #expect(e.anchored(in: text) == e)
    }

    @Test func neverTakesALineBreakObjectOrSpace() {
        let text = "Hi\n\u{FFFC}  x"
        // Leading space next to a line break, trailing space next to an object: unchanged.
        let a = Edit(range: NSRange(location: 3, length: 0), original: "", replacement: " a ")
        #expect(a.anchored(in: text) == a)
        let b = Edit(range: NSRange(location: 5, length: 0), original: "", replacement: " b ")
        #expect(b.anchored(in: text) == b)
    }

    @Test func emojiNeighbourIsTakenWhole() {
        let text = "ok 👍"
        let e = Edit(range: NSRange(location: 3, length: 0), original: "", replacement: "so ").anchored(in: text)
        #expect(e.original == "👍")
        #expect(e.replacement == "so 👍")
        #expect(Diff.apply([e], to: text) == "ok so 👍")
    }

    @Test func endOfTextAndMismatchStayAsTheyAre() {
        let text = "Done"
        let end = Edit(range: NSRange(location: 4, length: 0), original: "", replacement: " now ")
        let anchoredEnd = end.anchored(in: text)
        #expect(anchoredEnd.original == "e")
        #expect(anchoredEnd.replacement == "e now ")
        let stale = Edit(range: NSRange(location: 0, length: 2), original: "XX", replacement: "a ")
        #expect(stale.anchored(in: text) == stale)
    }
}
