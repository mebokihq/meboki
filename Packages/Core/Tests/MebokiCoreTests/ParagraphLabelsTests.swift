import Foundation
import Testing
@testable import MebokiCore

@Suite struct ParagraphLabelsTests {
    @Test func detectsBulletsAndNumbers() {
        #expect(ParagraphLabels.length(in: "• Third item") == 2)
        #expect(ParagraphLabels.length(in: "◦ Nested") == 2)
        #expect(ParagraphLabels.length(in: "– Dash item") == 2)
        #expect(ParagraphLabels.length(in: "12. Twelfth") == 4)
        #expect(ParagraphLabels.length(in: "3) Third") == 3)
        #expect(ParagraphLabels.length(in: "b) Letter") == 3)
        #expect(ParagraphLabels.length(in: "1.\tTabbed") == 3)
    }

    @Test func plainTextHasNoLabel() {
        #expect(ParagraphLabels.length(in: "Third item") == 0)
        #expect(ParagraphLabels.length(in: "3.14 is pi") == 0)
        #expect(ParagraphLabels.length(in: "1234. Too many digits") == 0)
        #expect(ParagraphLabels.length(in: "Word. Next") == 0)
        #expect(ParagraphLabels.length(in: "•") == 0)
        #expect(ParagraphLabels.length(in: "•no space") == 0)
        #expect(ParagraphLabels.length(in: "") == 0)
    }

    private func edit(_ text: String, _ original: String, _ replacement: String, after: String = "") -> Edit {
        let ns = text as NSString
        let start = after.isEmpty ? 0 : ns.range(of: after).location
        let r = ns.range(of: original, options: [], range: NSRange(location: start, length: ns.length - start))
        return Edit(range: r, original: original, replacement: replacement)
    }

    @Test func editStartingAtTheLabelIsCutAfterIt() {
        let text = "Intro line\n• Third item is fine, but there car is red.\nEnd"
        let e = edit(text, "• Third item is fine, but there", "• The third item is fine, but their")
        let out = ParagraphLabels.trim([e], in: text)
        #expect(out.count == 1)
        #expect(out[0].original == "Third item is fine, but there")
        #expect(out[0].replacement == "The third item is fine, but their")
        #expect(out[0].range.location == e.range.location + 2)
        #expect(out[0].range.length == e.range.length - 2)
        #expect((text as NSString).substring(with: out[0].range) == out[0].original)
    }

    @Test func editThatChangesTheLabelIsDropped() {
        let text = "• Third item"
        #expect(ParagraphLabels.trim([edit(text, "• Third", "Third")], in: text).isEmpty)
        #expect(ParagraphLabels.trim([edit(text, "• Third", "- Third")], in: text).isEmpty)
    }

    @Test func labelOnlyOrEndingInsideTheLabelIsDropped() {
        let text = "12. Twelfth item"
        #expect(ParagraphLabels.trim([edit(text, "12.", "13.")], in: text).isEmpty)
        #expect(ParagraphLabels.trim([edit(text, "12. ", "12. ")], in: text).isEmpty)
        // Nothing left of the edit once the label is cut off.
        let same = Edit(range: NSRange(location: 0, length: 4), original: "12. ", replacement: "12. ")
        #expect(ParagraphLabels.trim([same], in: text).isEmpty)
        // An insertion before the label.
        let ins = Edit(range: NSRange(location: 0, length: 0), original: "", replacement: "So ")
        #expect(ParagraphLabels.trim([ins], in: text).isEmpty)
    }

    @Test func insertionRightAfterTheLabelStays() {
        let text = "• item"
        let ins = Edit(range: NSRange(location: 2, length: 0), original: "", replacement: "The ")
        #expect(ParagraphLabels.trim([ins], in: text) == [ins])
    }

    @Test func editsNotTouchingLabelsAreUnchanged() {
        let text = "• First item have an error.\nPlain paragraph with an eror.\n2. Second dont stop"
        let edits = [edit(text, "have", "has"), edit(text, "eror", "error"), edit(text, "dont", "doesn't")]
        #expect(ParagraphLabels.trim(edits, in: text) == edits)
    }

    @Test func labelOnTheSecondParagraphOnlyAffectsThatParagraph() {
        let text = "• One\n• Two is here"
        let e = edit(text, "• Two is", "• Two are", after: "\n")
        let out = ParagraphLabels.trim([e], in: text)
        #expect(out.count == 1 && out[0].original == "Two is" && out[0].replacement == "Two are")
    }

    @Test func utf16OffsetsWithEmojiBeforeTheLabel() {
        let text = "Party 🎉🎉 time\n• Third item is fine, but there car"
        let e = edit(text, "• Third item is fine, but there", "• The third item is fine, but their")
        let out = ParagraphLabels.trim([e], in: text)
        #expect(out.count == 1)
        #expect((text as NSString).substring(with: out[0].range) == "Third item is fine, but there")
        // An emoji after the label is untouched by the cut.
        let t2 = "• 🎉 party have fun"
        let e2 = edit(t2, "• 🎉 party have", "• 🎉 party has")
        let o2 = ParagraphLabels.trim([e2], in: t2)
        #expect(o2.count == 1 && o2[0].original == "🎉 party have" && o2[0].replacement == "🎉 party has")
    }

    @Test func scopeInsideTheTextKeepsItsOffset() {
        let text = "Intro\n• Third there"
        let ns = text as NSString
        let scopeStart = ns.range(of: "• Third").location
        let e = Edit(range: NSRange(location: 0, length: 9), original: "• Third t", replacement: "• Third T")
        let out = ParagraphLabels.trim([e], in: text, scopeLocation: scopeStart)
        #expect(out.count == 1 && out[0].range.location == 2 && out[0].original == "Third t")
    }
}
