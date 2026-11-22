import Foundation
import Testing
@testable import MebokiCore

/// Apply all in a LibreOffice-like document (2026-11-22 fixes): list labels the app can't select, groups skipped
/// when the paragraph is proven untouched, parking of paragraphs that scroll out, and small changes followed.
/// Replays the app's loop (`AppDelegate.applyAll` + `followDocument`) with the surface's traits as parameters.
@Suite struct ApplyAllLibreOfficeTests {
    struct Traits {
        var followsSmallChanges = false
        var skipsUntouched = false
        var parks = false
    }

    enum Stop: Equatable { case moved, failedWrite }

    struct Document {
        var paragraphs: [(id: Int, text: String)]
        var visible: Range<Int>
        /// A write whose range starts inside a paragraph's label fails with the paragraph untouched.
        var labelLength: (String) -> Int = ParagraphLabels.length(in:)
        var wrongParagraphWrites = 0

        var map: SegmentMap { SegmentMap(segments: paragraphs[visible].map(\.text)) }
        var ids: [Int] { paragraphs[visible].map(\.id) }

        enum Result { case ok, untouched, failed }

        mutating func write(_ range: NSRange, original: String, replacement: String, expected: String) -> Result {
            let m = map
            guard m.text == expected, (m.text as NSString).substring(with: range) == original,
                  let (i, local) = m.local(range) else { return .failed }
            let p = visible.lowerBound + i
            if local.location < labelLength(paragraphs[p].text) { return .untouched }
            paragraphs[p].text = (paragraphs[p].text as NSString).replacingCharacters(in: local, with: replacement)
            return .ok
        }
    }

    struct Outcome {
        var written = 0, followed = 0, skipped = 0
        var stop: Stop?
    }

    static func applyAll(_ list: inout FixList, in doc: inout Document, traits: Traits,
                         afterWrite: (Int, inout Document) -> Void = { _, _ in }) -> Outcome {
        list.parksDeparted = traits.parks
        var history: [(map: SegmentMap, ids: [Int])] = [(doc.map, doc.ids)]
        var groups = list.applyAllGroups { _ in true }
        var out = Outcome()
        var next = 0
        while true {
            if next >= groups.count {
                guard traits.parks, list.parkedCount > 0, doc.map.text != list.text, out.followed < 50 else { break }
            }
            if doc.map.text != list.text {
                guard let old = history.last(where: { $0.map.text == list.text }) else { out.stop = .moved; return out }
                if old.ids == doc.ids {
                    // `CompositeSurface.carry` answers nil: one small change describes it.
                    var small = list
                    guard traits.followsSmallChanges, let change = TextChange.between(list.text, doc.map.text),
                          small.textEdited(change) != nil else { out.stop = .moved; return out }
                    list = small
                } else {
                    guard list.followParagraphs(from: old.map, ids: old.ids, to: doc.map, ids: doc.ids) != nil else {
                        out.stop = .moved
                        return out
                    }
                }
                history.append((doc.map, doc.ids))
                out.followed += 1
                groups = list.applyAllGroups { _ in true }
                next = 0
                continue
            }
            if next >= groups.count { break }
            let g = groups[next]
            switch doc.write(g.range, original: g.original, replacement: g.replacement, expected: list.text) {
            case .ok:
                list.applyGroup(g)
                history.append((doc.map, doc.ids))
                out.written += 1
            case .untouched where traits.skipsUntouched:
                for i in g.indices { list.skip(at: i) }
                out.skipped += 1
            default:
                out.stop = .failedWrite
                return out
            }
            next += 1
            afterWrite(out.written, &doc)
        }
        return out
    }

    static func edit(_ text: String, _ original: String, _ replacement: String, after: String = "") -> Edit {
        let ns = text as NSString
        let start = after.isEmpty ? 0 : ns.range(of: after).location
        let r = ns.range(of: original, options: [], range: NSRange(location: start, length: ns.length - start))
        return Edit(range: r, original: original, replacement: replacement)
    }

    static func listDoc() -> Document {
        Document(paragraphs: [
            (1, "Me and him was late."),
            (2, "• First item have an error."),
            (3, "• Third item is fine, but there car is red."),
            (4, "The end dont come."),
        ], visible: 0..<4)
    }

    static func listEdits(_ text: String, labelInEdit: Bool) -> [Edit] {
        [
            edit(text, "was", "were"),
            edit(text, "have", "has"),
            labelInEdit ? edit(text, "• Third item is fine, but there", "• The third item is fine, but their")
                        : edit(text, "Third item is fine, but there", "The third item is fine, but their"),
            edit(text, "dont", "doesn't"),
        ]
    }

    @Test func labelFixWithoutTrimmingFailsAndStopsByDefault() {
        var doc = Self.listDoc()
        let text = doc.map.text
        var list = FixList(text: text, edits: Self.listEdits(text, labelInEdit: true))
        let r = Self.applyAll(&list, in: &doc, traits: Traits())
        #expect(r.stop == .failedWrite)
        // Writes go last to first: the last paragraph went in, then the list item stopped it.
        #expect(r.written == 1)
        #expect(doc.paragraphs[0].text == "Me and him was late.")
    }

    @Test func untouchedFailureIsSkippedAndTheRestGoesIn() {
        var doc = Self.listDoc()
        let text = doc.map.text
        var list = FixList(text: text, edits: Self.listEdits(text, labelInEdit: true))
        let r = Self.applyAll(&list, in: &doc, traits: Traits(skipsUntouched: true))
        #expect(r.stop == nil)
        #expect(r.written == 3)
        #expect(r.skipped == 1)
        #expect(doc.paragraphs[0].text == "Me and him were late.")
        #expect(doc.paragraphs[1].text == "• First item has an error.")
        #expect(doc.paragraphs[2].text == "• Third item is fine, but there car is red.")
        #expect(doc.paragraphs[3].text == "The end doesn't come.")
        #expect(list.skippedCount == 1)
        #expect(list.pendingCount == 0)
    }

    @Test func trimmedLabelFixIsWrittenWithoutAnySkip() {
        var doc = Self.listDoc()
        let text = doc.map.text
        let edits = ParagraphLabels.trim(Self.listEdits(text, labelInEdit: true), in: text)
        var list = FixList(text: text, edits: edits)
        let r = Self.applyAll(&list, in: &doc, traits: Traits(skipsUntouched: true))
        #expect(r.stop == nil && r.skipped == 0)
        #expect(r.written == 4)
        #expect(doc.paragraphs[2].text == "• The third item is fine, but their car is red.")
    }

    @Test func otherFailuresStillStopEvenWhenSkippingIsOn() {
        // The paragraph changed under the write: not an untouched failure.
        var doc = Self.listDoc()
        let text = doc.map.text
        var list = FixList(text: text, edits: Self.listEdits(text, labelInEdit: false))
        let r = Self.applyAll(&list, in: &doc, traits: Traits(skipsUntouched: true)) { written, doc in
            if written == 1 { doc.paragraphs[0].text = "Me and him was late!" }  // typed behind the review's back
        }
        #expect(r.stop == .moved || r.stop == .failedWrite)
        #expect(r.written < 4)
    }

    /// The paragraphs on screen change after a write (a window that scrolls), paragraphs come back as new
    /// elements: with parking on, the fixes of paragraphs that left are still written when they return.
    @Test func parkingKeepsFixesOfParagraphsThatScrolledOut() {
        var doc = Document(paragraphs: (1...6).map { ($0, "Paragraph \($0) have a mistake.") }, visible: 0..<4)
        let text = doc.map.text
        var list = FixList(text: text, edits: (1...4).map { Self.edit(text, "have", "has", after: "Paragraph \($0) ") })
        let r = Self.applyAll(&list, in: &doc, traits: Traits(parks: true)) { written, doc in
            if written == 1 {
                // Paragraphs 1 and 2 leave, 5 and 6 arrive (their elements are new when they come back).
                doc.paragraphs[0].id = 900
                doc.paragraphs[1].id = 901
                doc.visible = 2..<6
            }
            if written == 2 {
                doc.paragraphs[0].id = 902
                doc.paragraphs[1].id = 903
                doc.visible = 0..<4
            }
        }
        #expect(r.stop == nil)
        #expect(r.written == 4)
        #expect(doc.paragraphs.prefix(4).allSatisfy { $0.text.contains("has a mistake") })
    }

    // MARK: small changes

    /// The same paragraphs (same ids), but another paragraph's text changed (a window that trims or adds a line).
    static func smallChangeDoc() -> (Document, [Edit]) {
        let doc = Document(paragraphs: [
            (1, "Paragraph one have a mistake."),
            (2, "Paragraph two is fine."),
            (3, "Paragraph three have a mistake."),
        ], visible: 0..<3)
        let text = doc.map.text
        return (doc, [edit(text, "have", "has", after: "Paragraph one"), edit(text, "have", "has", after: "Paragraph three")])
    }

    @Test func smallChangeFollowedWhenTheSurfaceFollowsSmallChanges() {
        var (doc, edits) = Self.smallChangeDoc()
        var list = FixList(text: doc.map.text, edits: edits)
        let r = Self.applyAll(&list, in: &doc, traits: Traits(followsSmallChanges: true)) { written, doc in
            if written == 1 { doc.paragraphs[1].text = "Paragraph two is fine now." }
        }
        #expect(r.stop == nil)
        #expect(r.written == 2)
        #expect(r.followed == 1)
        #expect(doc.paragraphs[0].text == "Paragraph one has a mistake.")
        #expect(doc.paragraphs[2].text == "Paragraph three has a mistake.")
    }

    @Test func singleFieldTwinStillStopsOnTheSameSmallChange() {
        var (doc, edits) = Self.smallChangeDoc()
        var list = FixList(text: doc.map.text, edits: edits)
        let r = Self.applyAll(&list, in: &doc, traits: Traits()) { written, doc in
            if written == 1 { doc.paragraphs[1].text = "Paragraph two is fine now." }
        }
        #expect(r.stop == .moved)
        #expect(r.written == 1)
        #expect(doc.paragraphs[0].text == "Paragraph one have a mistake.")
    }

    @Test func smallChangeTouchingAPendingFixDropsThatFixOnly() {
        var (doc, edits) = Self.smallChangeDoc()
        var list = FixList(text: doc.map.text, edits: edits)
        let r = Self.applyAll(&list, in: &doc, traits: Traits(followsSmallChanges: true)) { written, doc in
            if written == 1 { doc.paragraphs[0].text = "Paragraph one have a bigger mistake." }
        }
        #expect(r.stop == nil)
        #expect(r.written == 1)
        // The edited paragraph's fix left the list; nothing was written over the user's change.
        #expect(doc.paragraphs[0].text == "Paragraph one have a bigger mistake.")
        #expect(doc.paragraphs[2].text == "Paragraph three has a mistake.")
    }

    @Test func defaultsAreOffForASurfaceThatDoesNotOptIn() {
        let t = Traits()
        #expect(!t.followsSmallChanges && !t.skipsUntouched && !t.parks)
    }
}
