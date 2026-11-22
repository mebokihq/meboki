import Foundation
import Testing
@testable import MebokiCore

@Suite struct BlockBreaksTests {
    /// Firefox on telegra.ph (2026-11-22): the title and author end in `\n`, the body paragraphs are joined with
    /// nothing. One paragraph has an emoji (2 UTF-16 units).
    static let blocks = ["Title", "Your name", "Paragraph 1 say 😀 hi.", "It dont end with a full stop", "Paragraph 3."]
    static let real = "Title\nYour name\nParagraph 1 say 😀 hi.It dont end with a full stopParagraph 3."

    static func ranges() -> [NSRange?] {
        let ns = real as NSString
        return blocks.map { ns.range(of: $0) }
    }

    @Test func breaksOnlyWhereBlocksTouch() {
        let breaks = BlockBreaks.breaks(between: Self.ranges(), in: Self.real)
        let ns = Self.real as NSString
        #expect(breaks == [ns.range(of: "It dont").location, ns.range(of: "Paragraph 3").location])
        let map = BlockBreaks(real: Self.real, breaks: breaks)
        #expect(map.text == "Title\nYour name\nParagraph 1 say 😀 hi.\nIt dont end with a full stop\nParagraph 3.")
    }

    @Test func noBreaksLeavesTheTextAlone() {
        let map = BlockBreaks(real: "One paragraph only.", breaks: [])
        #expect(map.text == map.real)
        #expect(map.realRange(NSRange(location: 4, length: 9)) == NSRange(location: 4, length: 9))
        #expect(BlockBreaks.breaks(between: [NSRange(location: 0, length: 5), nil], in: "Hello") == [])
        // Blocks with the app's own separator between them need none.
        #expect(BlockBreaks.breaks(between: [NSRange(location: 0, length: 5), NSRange(location: 6, length: 3)],
                                   in: "Hello\nabc") == [])
    }

    /// Firefox test page (2026-11-22): list bullets are in the value ("• ") but their elements report no text, so the
    /// list items' blocks start after the bullet. The break goes before the bullet, at the end of the block before.
    @Test func breakBeforeABulletNoBlockCovers() {
        let real = "Div two say bye.• Item para one.• Plain itemLast top paragraph."
        let ns = real as NSString
        let blocks: [NSRange?] = ["Div two say bye.", "Item para one.", "Plain item", "Last top paragraph."].map {
            ns.range(of: $0)
        }
        let map = BlockBreaks(real: real, breaks: BlockBreaks.breaks(between: blocks, in: real))
        #expect(map.text == "Div two say bye.\n• Item para one.\n• Plain item\nLast top paragraph.")
    }

    @Test func mapsRangesBothWays() {
        let map = BlockBreaks(real: Self.real, breaks: BlockBreaks.breaks(between: Self.ranges(), in: Self.real))
        let t = map.text as NSString, r = Self.real as NSString
        for word in ["dont", "stop", "Paragraph 3", "😀", "Title", "hi."] {
            let tr = t.range(of: word), rr = r.range(of: word)
            #expect(map.realRange(tr) == rr, "\(word)")
            #expect(map.textRange(rr) == tr, "\(word)")
        }
        // Over a break: not writable as one range, split into pieces without the added `\n`.
        let over = t.range(of: "stop\nParagraph")
        #expect(map.realRange(over) == nil)
        #expect(map.realPieces(over) == [r.range(of: "stop"), NSRange(location: r.range(of: "Paragraph 3").location, length: 9)])
        // Offsets on both sides of an added `\n` map to the break.
        let sep = t.range(of: "stop\n").location + 4
        #expect(map.realOffset(sep) == r.range(of: "Paragraph 3").location)
        #expect(map.realOffset(sep + 1) == r.range(of: "Paragraph 3").location)
        #expect(map.textOffset(r.range(of: "Paragraph 3").location) == sep)
    }

    @Test func insertionAtABlockEndTakesItsLastCharacter() {
        let map = BlockBreaks(real: Self.real, breaks: BlockBreaks.breaks(between: Self.ranges(), in: Self.real))
        let t = map.text as NSString, r = Self.real as NSString
        let end = t.range(of: "full stop").location + 9
        let w = map.writable(NSRange(location: end, length: 0), original: "", replacement: ".")
        #expect(w?.range == NSRange(location: r.range(of: "full stop").location + 8, length: 1))
        #expect(w?.original == "p")
        #expect(w?.replacement == "p.")
        // At a block's start: its first character comes along.
        let start = t.range(of: "Paragraph 3").location
        let s = map.writable(NSRange(location: start, length: 0), original: "", replacement: "A ")
        #expect(s?.range == NSRange(location: r.range(of: "Paragraph 3").location, length: 1))
        #expect(s?.original == "P")
        #expect(s?.replacement == "A P")
        // Inside a block: unchanged.
        let mid = t.range(of: "dont")
        let m = map.writable(mid, original: "dont", replacement: "doesn't")
        #expect(m?.range == r.range(of: "dont"))
        #expect(m?.replacement == "doesn't")
        // Reaching over a break: refused.
        #expect(map.writable(t.range(of: "stop\nPara"), original: "stop\nPara", replacement: "stop. Para") == nil)
    }
}
