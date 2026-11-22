import Foundation
import Testing
@testable import MebokiCore

/// Apply all in a document that lists only the paragraphs on screen (LibreOffice) and scrolls itself to the text a
/// write selects. Replays the app's loop (`AppDelegate.applyAll` with `followDocument`): before each write the list
/// follows the document by paragraph (`FixList.followParagraphs`), what's pending is grouped again, and a write
/// goes in only while the document holds exactly the list's text (`CompositeSurface.replace(expected:)`).
@Suite struct ApplyAllScrollTests {
    /// A document of paragraphs with stable ids, of which `visible` is on screen.
    struct Document {
        var paragraphs: [(id: Int, text: String)]
        var visible: Range<Int>

        var map: SegmentMap { SegmentMap(segments: paragraphs[visible].map(\.text)) }
        var ids: [Int] { paragraphs[visible].map(\.id) }

        /// `CompositeSurface.replace`: refuses unless the document holds `expected` and `original` is at `range`
        /// inside one paragraph; writes into that paragraph only.
        mutating func write(_ range: NSRange, original: String, replacement: String, expected: String) -> Bool {
            let m = map
            guard m.text == expected, (m.text as NSString).substring(with: range) == original,
                  let (i, local) = m.local(range) else { return false }
            let p = visible.lowerBound + i
            paragraphs[p].text = (paragraphs[p].text as NSString).replacingCharacters(in: local, with: replacement)
            return true
        }
    }

    static func edits(in text: String, _ pairs: [(String, String, after: String)]) -> [Edit] {
        let ns = text as NSString
        return pairs.map { word, replacement, after in
            let start = ns.range(of: after).location
            let r = ns.range(of: word, options: [], range: NSRange(location: start, length: ns.length - start))
            return Edit(range: r, original: word, replacement: replacement)
        }
    }

    /// The app's Apply all loop. `afterWrite` lets the document move (scroll) after a given write.
    static func applyAll(_ list: inout FixList, in doc: inout Document,
                         afterWrite: (Int, inout Document) -> Void) -> (written: Int, followed: Int, failed: Bool) {
        var history: [(map: SegmentMap, ids: [Int])] = [(doc.map, doc.ids)]
        var groups = list.applyAllGroups { _ in true }
        var written = 0, followed = 0, next = 0
        while next < groups.count {
            // followDocument: the document no longer holds the list's text → carry the list over by paragraph.
            if doc.map.text != list.text {
                guard let old = history.last(where: { $0.map.text == list.text }),
                      list.followParagraphs(from: old.map, ids: old.ids, to: doc.map, ids: doc.ids) != nil
                else { return (written, followed, true) }
                history.append((doc.map, doc.ids))
                followed += 1
                groups = list.applyAllGroups { _ in true }
                next = 0
                continue
            }
            let g = groups[next]
            guard doc.write(g.range, original: g.original, replacement: g.replacement, expected: list.text) else {
                return (written, followed, true)
            }
            list.applyGroup(g)
            history.append((doc.map, doc.ids))
            written += 1
            next += 1
            afterWrite(written, &doc)
        }
        return (written, followed, false)
    }

    /// The case from the 2026-11-22 run: the first write (last group: the end of a long paragraph at the bottom of
    /// the window) makes LibreOffice scroll down two paragraphs. Paragraphs 1 and 5 end the same way, so a text
    /// diff over the whole document would have carried paragraph 1's fix onto paragraph 5.
    @Test func selfScrollAfterTheFirstWriteKeepsEveryFixInItsParagraph() {
        var doc = Document(paragraphs: [
            (1, "First she have a cat, and it dont end with a full stop"),
            (2, "Second they is here."),
            (3, "Third we was late."),
            (4, "Fourth he go home."),
            (5, "Fifth the dog have a cat, and it dont end with a full stop"),
            (6, "Sixth is long and it have many sentences. The last one are wrong."),
            (7, "Seventh is below the window and have a mistake."),
        ], visible: 0..<6)
        let text = doc.map.text
        var list = FixList(text: text, edits: Self.edits(in: text, [
            ("have", "has", after: "First"), ("dont", "doesn't", after: "First"),
            ("is", "are", after: "Second"),
            ("was", "were", after: "Third"),
            ("go", "goes", after: "Fourth"),
            ("dont", "doesn't", after: "Fifth"),
            ("are", "is", after: "The last one"),
        ]))
        let result = Self.applyAll(&list, in: &doc) { written, doc in
            if written == 1 { doc.visible = 2..<7 }  // LibreOffice scrolled to the end of paragraph 6
        }
        #expect(!result.failed)
        #expect(result.followed == 1)
        let texts = Dictionary(uniqueKeysWithValues: doc.paragraphs.map { ($0.id, $0.text) })
        // Paragraphs 1 and 2 scrolled off before their fixes were written: untouched (the next check brings them back).
        #expect(texts[1] == "First she have a cat, and it dont end with a full stop")
        #expect(texts[2] == "Second they is here.")
        // Every other fix landed in its own paragraph.
        #expect(texts[3] == "Third we were late.")
        #expect(texts[4] == "Fourth he goes home.")
        #expect(texts[5] == "Fifth the dog have a cat, and it doesn't end with a full stop")
        #expect(texts[6] == "Sixth is long and it have many sentences. The last one is wrong.")
        // Paragraph 7 came into view with no fix for it: untouched.
        #expect(texts[7] == "Seventh is below the window and have a mistake.")
        #expect(list.text == doc.map.text)
        #expect(list.pendingCount == 0)
    }

    /// Scrolling after every write (LibreOffice following each selection up the page).
    @Test func scrollAfterEveryWrite() {
        var doc = Document(paragraphs: (1...8).map { ($0, "Paragraph \($0) have a mistake.") }, visible: 2..<8)
        let text = doc.map.text
        var list = FixList(text: text, edits: (3...8).flatMap { n in
            Self.edits(in: text, [("have", "has", after: "Paragraph \(n) ")])
        })
        let result = Self.applyAll(&list, in: &doc) { _, doc in
            if doc.visible.lowerBound > 0 { doc.visible = (doc.visible.lowerBound - 1)..<(doc.visible.upperBound - 1) }
        }
        #expect(!result.failed)
        for p in doc.paragraphs {
            // Paragraphs 3–8 had fixes; 8 and the ones still on screen when their turn came got them.
            let fixed = p.text.contains(" has ")
            if p.id <= 2 { #expect(!fixed) }  // never had a fix
            if fixed { #expect(p.text == "Paragraph \(p.id) has a mistake.") }
        }
        #expect(list.text == doc.map.text)
    }

    /// Without following (the old loop), the second write is refused: the document moved. With a stale list and
    /// no expected-text check, it would have gone into the wrong paragraph; the check refuses it.
    @Test func aWriteIntoAMovedDocumentIsRefused() {
        var doc = Document(paragraphs: [(1, "A have."), (2, "B have."), (3, "C have.")], visible: 0..<2)
        let before = doc.map.text
        doc.visible = 1..<3
        // The fix for paragraph 1's "have" at its old offset: paragraph 2 has "have" at the same offset.
        let r = (before as NSString).range(of: "have")
        let written = doc.write(r, original: "have", replacement: "has", expected: before)
        #expect(!written)
        #expect(doc.paragraphs.map(\.text) == ["A have.", "B have.", "C have."])
    }
}
