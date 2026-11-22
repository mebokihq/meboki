import Foundation
import Testing
@testable import MebokiCore

@Suite struct SegmentMapTests {
    /// Three paragraph fields, as LibreOffice Writer gives them, one with an emoji (2 UTF-16 units).
    static let paragraphs = ["She have two cat.", "Emoji 😀 here an mistake.", "Last one."]

    @Test func joinsSegmentsWithTheSeparator() {
        let map = SegmentMap(segments: Self.paragraphs)
        #expect(map.text == "She have two cat.\nEmoji 😀 here an mistake.\nLast one.")
        #expect(map.length == (map.text as NSString).length)
        let ns = map.text as NSString
        for (i, r) in map.ranges.enumerated() {
            #expect(ns.substring(with: r) == Self.paragraphs[i])
        }
        #expect(map.ranges[1].location == 18)
        #expect(map.ranges[2].location == 18 + 25 + 1)
    }

    @Test func emptyAndSingleSegment() {
        let none = SegmentMap(segments: [])
        #expect(none.text.isEmpty)
        #expect(none.length == 0)
        #expect(none.locate(0) == nil)
        #expect(none.pieces(of: NSRange(location: 0, length: 3)).isEmpty)

        let one = SegmentMap(segments: ["Only this."])
        #expect(one.text == "Only this.")
        #expect(one.local(NSRange(location: 5, length: 4))! == (0, NSRange(location: 5, length: 4)))
        #expect(one.locate(10)! == (0, 10))
        #expect(one.locate(11) == nil)
    }

    @Test func splitsRangesIntoSegmentLocalPieces() {
        let map = SegmentMap(segments: Self.paragraphs)
        let ns = map.text as NSString
        // Inside one segment, after the emoji.
        let p = map.pieces(of: ns.range(of: "here"))
        #expect(p.count == 1)
        #expect(p[0].segment == 1)
        #expect(p[0].range == NSRange(location: 9, length: 4))
        // Across a separator: the newline is left out.
        let across = map.pieces(of: ns.range(of: "cat.\nEmoji"))
        #expect(across.map(\.segment) == [0, 1])
        #expect(across.map(\.range) == [NSRange(location: 13, length: 4), NSRange(location: 0, length: 5)])
        // Only the separator, or nothing.
        #expect(map.pieces(of: NSRange(location: 17, length: 1)).isEmpty)
        #expect(map.pieces(of: NSRange(location: 3, length: 0)).isEmpty)
    }

    @Test func localNeedsOneSegment() {
        let map = SegmentMap(segments: Self.paragraphs)
        let ns = map.text as NSString
        #expect(map.local(ns.range(of: "an mistake"))! == (1, NSRange(location: 14, length: 10)))
        #expect(map.local(ns.range(of: "Last"))! == (2, NSRange(location: 0, length: 4)))
        // Over a separator: no single segment can take the write.
        #expect(map.local(ns.range(of: "cat.\nEmoji")) == nil)
        #expect(map.local(NSRange(location: 17, length: 1)) == nil)
        // Past the end.
        #expect(map.local(NSRange(location: map.length, length: 1)) == nil)
        #expect(map.local(NSRange(location: -1, length: 1)) == nil)
    }

    @Test func locateCaretsAtEdges() {
        let map = SegmentMap(segments: Self.paragraphs)
        #expect(map.locate(0)! == (0, 0))
        // Right after "cat." (where the separator starts): the end of segment 0.
        #expect(map.locate(17)! == (0, 17))
        // The next segment's start.
        #expect(map.locate(18)! == (1, 0))
        #expect(map.locate(map.length)! == (2, 9))
        #expect(map.locate(map.length + 1) == nil)
        // Empty insertion at a segment's end belongs to it.
        #expect(map.local(NSRange(location: 17, length: 0))! == (0, NSRange(location: 17, length: 0)))
    }

    @Test func emptySegmentsKeepTheirPlace() {
        // An empty paragraph between two others (two newlines in a row in the document).
        let map = SegmentMap(segments: ["A.", "", "B."])
        #expect(map.text == "A.\n\nB.")
        #expect(map.ranges == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 0),
                               NSRange(location: 4, length: 2)])
        // A caret on the empty line is in the empty segment.
        #expect(map.locate(3)! == (1, 0))
        #expect(map.locate(2)! == (0, 2))
        #expect(map.local(NSRange(location: 4, length: 2))! == (2, NSRange(location: 0, length: 2)))
    }

    @Test func documentRangeRoundTrips() {
        let map = SegmentMap(segments: Self.paragraphs)
        for (i, s) in Self.paragraphs.enumerated() {
            let local = NSRange(location: 1, length: (s as NSString).length - 1)
            let doc = map.documentRange(segment: i, local)!
            #expect(map.local(doc)! == (i, local))
        }
        #expect(map.documentRange(segment: 0, NSRange(location: 10, length: 20)) == nil)
        #expect(map.documentRange(segment: 3, NSRange(location: 0, length: 0)) == nil)
    }

    @Test func replacingMovesLaterSegments() {
        let map = SegmentMap(segments: Self.paragraphs)
        let edited = map.replacing(segment: 0, with: "She has two cats.")
        #expect(edited.text == "She has two cats.\nEmoji 😀 here an mistake.\nLast one.")
        #expect(edited.ranges[1].location == map.ranges[1].location)
        let longer = map.replacing(segment: 1, with: "Emoji 😀 here a small mistake.")
        #expect(longer.ranges[2].location == map.ranges[2].location + 5)
        #expect(map.replacing(segment: 9, with: "x") == map)
    }

    @Test func otherSeparator() {
        let map = SegmentMap(segments: ["a", "b"], separator: "\n\n")
        #expect(map.text == "a\n\nb")
        #expect(map.ranges[1] == NSRange(location: 3, length: 1))
        #expect(map.pieces(of: NSRange(location: 0, length: 4)).map(\.segment) == [0, 1])
    }
}
