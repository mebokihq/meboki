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
        /// The index (in `paragraphs`) of the paragraph the last write went into.
        var lastWritten: Int?
        var nextID = 1000

        /// An app that renders only the paragraphs near the screen: a paragraph that leaves is a different element
        /// (new id) when it comes back.
        mutating func show(_ range: Range<Int>) {
            for i in visible where !range.contains(i) {
                paragraphs[i].id = nextID
                nextID += 1
            }
            visible = range
        }

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
            lastWritten = p
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
                         parks: Bool = false,
                         afterWrite: (Int, inout Document) -> Void) -> (written: Int, followed: Int, failed: Bool) {
        list.parksDeparted = parks
        var history: [(map: SegmentMap, ids: [Int])] = [(doc.map, doc.ids)]
        var groups = list.applyAllGroups { _ in true }
        var written = 0, followed = 0, next = 0
        while true {
            if next >= groups.count {
                // What waits for its paragraph: has it come back?
                guard parks, list.parkedCount > 0, doc.map.text != list.text, followed < 50 else { break }
            }
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
            if next >= groups.count { break }
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

    // MARK: - An app that renders only the paragraphs near the screen (Notion)

    /// Every paragraph has a mistake; the app renders five paragraphs around the one written last, and a paragraph
    /// that leaves comes back as a new element. Without parking, the writes at the bottom push the top paragraphs
    /// out and their fixes are lost; with it, they return as the writes move up.
    @Test func renderedWindowFollowsTheWritesAndKeepsEveryFix() {
        var doc = Document(paragraphs: (1...12).map { ($0, "Paragraph \($0) have a mistake.") }, visible: 3..<10)
        let text = doc.map.text
        var list = FixList(text: text, edits: (4...10).flatMap { n in
            Self.edits(in: text, [("have", "has", after: "Paragraph \(n) ")])
        })
        let result = Self.applyAll(&list, in: &doc, parks: true) { _, doc in
            guard let p = doc.lastWritten else { return }
            doc.show(max(0, p - 2)..<min(12, p + 3))
        }
        #expect(!result.failed)
        for (i, p) in doc.paragraphs.enumerated() {
            let shouldBeFixed = (3..<10).contains(i)
            #expect(p.text == (shouldBeFixed ? "Paragraph \(i + 1) has a mistake."
                                             : "Paragraph \(i + 1) have a mistake."))
        }
        #expect(list.pendingCount == 0)
        #expect(list.parkedCount == 0)
    }

    /// The same window without parking loses the fixes of the paragraphs that scrolled out (the old behaviour):
    /// nothing is written in the wrong place, but not everything is applied.
    @Test func withoutParkingTheFixesOfDepartedParagraphsAreLost() {
        var doc = Document(paragraphs: (1...12).map { ($0, "Paragraph \($0) have a mistake.") }, visible: 3..<10)
        let text = doc.map.text
        var list = FixList(text: text, edits: (4...10).flatMap { n in
            Self.edits(in: text, [("have", "has", after: "Paragraph \(n) ")])
        })
        let result = Self.applyAll(&list, in: &doc) { _, doc in
            guard let p = doc.lastWritten else { return }
            doc.show(max(0, p - 2)..<min(12, p + 3))
        }
        #expect(!result.failed)
        #expect(doc.paragraphs.filter { $0.text.contains(" has ") }.count < 7)
        for (i, p) in doc.paragraphs.enumerated() where p.text.contains(" has ") {
            #expect(p.text == "Paragraph \(i + 1) has a mistake.")
        }
    }

    /// Two paragraphs with the same text in the window are told apart by nothing: neither is parked, and a write
    /// only ever lands in a paragraph that has the fix's words (the document is checked, not guessed).
    @Test func repeatedTextInTheWindowIsNotParked() {
        var doc = Document(paragraphs: [
            (1, "Same have text."), (2, "Two have text."), (3, "Three have text."), (4, "Four have text."),
            (5, "Five have text."), (6, "Same have text."), (7, "Seven have text."),
        ], visible: 0..<7)
        let text = doc.map.text
        // The two "Same" paragraphs both have a fix.
        let r = (text as NSString).range(of: "Same have text.", options: .backwards)
        var list = FixList(text: text, edits: Self.edits(in: text, [("have", "has", after: "Same")])
            + [Edit(range: NSRange(location: r.location + 5, length: 4), original: "have", replacement: "has")]
            + Self.edits(in: text, [("have", "has", after: "Seven")]))
        let result = Self.applyAll(&list, in: &doc, parks: true) { _, doc in
            guard let p = doc.lastWritten else { return }
            doc.show(max(0, p - 1)..<min(7, p + 2))
        }
        #expect(!result.failed)
        // Whatever was written went into a paragraph that had the fix, and the text of every paragraph is its own.
        for (i, p) in doc.paragraphs.enumerated() {
            let original = ["Same have text.", "Two have text.", "Three have text.", "Four have text.",
                            "Five have text.", "Same have text.", "Seven have text."][i]
            #expect(p.text == original || p.text == original.replacingOccurrences(of: "have", with: "has"))
        }
        #expect(doc.paragraphs[1].text == "Two have text.")
        #expect(doc.paragraphs[4].text == "Five have text.")
    }
}
