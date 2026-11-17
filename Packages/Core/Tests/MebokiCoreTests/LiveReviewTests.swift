import Foundation
import Testing
@testable import MebokiCore

@Suite struct TextChangeTests {
    @Test func typingDeletingAndPasting() {
        #expect(TextChange.between("abc", "abc") == nil)
        #expect(TextChange.between("hello world", "hello, world") == TextChange(range: NSRange(location: 5, length: 0), replacement: ","))
        #expect(TextChange.between("hello world", "hello") == TextChange(range: NSRange(location: 5, length: 6), replacement: ""))
        #expect(TextChange.between("see you", "see them") == TextChange(range: NSRange(location: 4, length: 3), replacement: "them"))
        #expect(TextChange.between("", "x") == TextChange(range: NSRange(location: 0, length: 0), replacement: "x"))
        // Several edits apart collapse into one change.
        #expect(TextChange.between("a b c", "x b y") == TextChange(range: NSRange(location: 0, length: 5), replacement: "x b y"))
    }

    @Test func neverSplitsSurrogatePairs() {
        // 😀 and 😃 share their lead surrogate.
        let c = TextChange.between("a😀b", "a😃b")
        #expect(c == TextChange(range: NSRange(location: 1, length: 2), replacement: "😃"))
        let d = TextChange.between("😀", "😀😀")
        #expect(d.map { ("😀" as NSString).replacingCharacters(in: $0.range, with: $0.replacement) } == "😀😀")
        #expect(d?.replacement == "😀")
    }
}

@Suite struct LiveFixListTests {
    /// "Hi teh team. We was late.\n\nSee you tomorow." with three fixes.
    static let text = "Hi teh team. We was late.\n\nSee you tomorow."
    static func edit(_ text: String, _ original: String, _ replacement: String) -> Edit {
        Edit(range: (text as NSString).range(of: original), original: original, replacement: replacement)
    }
    static func list() -> FixList {
        FixList(text: text, edits: [edit(text, "teh", "the"), edit(text, "was", "were"), edit(text, "tomorow", "tomorrow")])
    }
    /// The user changes the field from `old` to `new`.
    static func type(_ l: inout FixList, _ old: String, _ new: String) throws {
        let c = try #require(TextChange.between(old, new))
        let ok = l.textEdited(c)
        #expect(ok)
        #expect(l.text == new)
    }
    static func originals(_ l: FixList) -> [String] { l.fixes.map(\.edit.original) }
    /// Every fix's range still holds its original (pending, skipped) or replacement (applied).
    static func consistent(_ l: FixList) -> Bool {
        let ns = l.text as NSString
        return l.fixes.allSatisfy { f in
            ns.substring(with: f.currentRange) == (f.status == .applied ? f.edit.replacement : f.edit.original)
        }
    }

    @Test func typingInAnotherSentenceShiftsLaterFixes() throws {
        var l = Self.list()
        let new = Self.text.replacingOccurrences(of: "Hi teh team.", with: "Hi teh team. 👋 Quick note.")
        // The change is appended after the first sentence's space: that sentence isn't touched.
        try Self.type(&l, Self.text, new)
        #expect(l.text == new)
        #expect(Self.originals(l) == ["teh", "was", "tomorow"])
        #expect(Self.consistent(l))
    }

    @Test func typingInASentenceDropsItsPendingFixes() throws {
        var l = Self.list()
        let new = Self.text.replacingOccurrences(of: "We was late.", with: "We was very late.")
        try Self.type(&l, Self.text, new)
        #expect(Self.originals(l) == ["teh", "tomorow"])
        #expect(Self.consistent(l))
    }

    @Test func skippedFixSurvivesASpaceButNotALetter() throws {
        var l = Self.list()
        l.skip(at: 2)  // tomorow
        var t = Self.text + " "
        try Self.type(&l, Self.text, t)
        #expect(l.fixes.last?.status == .skipped)
        // Typing right after the word: the word grew.
        let u = (Self.text as NSString).replacingOccurrences(of: "tomorow", with: "tomorows")
        l = Self.list()
        l.skip(at: 2)
        t = Self.text
        try Self.type(&l, t, u)
        #expect(!l.fixes.contains { $0.edit.original == "tomorow" })
        #expect(l.skippedCount == 1)  // still counted for the done line
    }

    @Test func insertionFixIsTouchedByAnythingAtItsPoint() throws {
        let t = "Well I think so. Fine."
        var l = FixList(text: t, edits: [Edit(range: NSRange(location: 4, length: 0), original: "", replacement: ",")])
        l.skip(at: 0)
        let u = "Well. I think so. Fine."
        try Self.type(&l, t, u)
        #expect(l.fixes.isEmpty)
    }

    @Test func appliedFixTouchedStaysCounted() throws {
        var l = Self.list()
        let after = l.applyOne(at: 0)!  // "teh" → "the"
        let new = after.replacingOccurrences(of: "the team", with: "thee team")
        try Self.type(&l, after, new)
        #expect(l.appliedCount == 1)
        #expect(Self.originals(l) == ["was", "tomorow"])
    }

    @Test func currentMovesToNearestPendingWhenItsFixGoes() throws {
        var l = Self.list()
        _ = l.select(1)
        let new = Self.text.replacingOccurrences(of: "We was late.", with: "We was so late.")
        try Self.type(&l, Self.text, new)
        #expect(l.currentFix?.edit.original == "tomorow")
    }

    @Test func reconcileOnlyInsideCoveredParagraphs() {
        var l = Self.list()
        _ = l.select(2)
        let t = Self.text
        let paras = ProofreadEngine.chunks(of: t)
        // A partial result for the second paragraph only, with the same fix: nothing changes.
        l.reconcile(edits: [Self.edit(t, "tomorow", "tomorrow")], covered: [paras[1]])
        #expect(Self.originals(l) == ["teh", "was", "tomorow"])
        #expect(l.currentFix?.edit.original == "tomorow")
        // The first paragraph again, now without "teh" and with a new fix: "teh" goes, "late" comes.
        l.reconcile(edits: [Self.edit(t, "was", "were"), Self.edit(t, "late", "later")], covered: [paras[0]])
        #expect(Self.originals(l) == ["was", "late", "tomorow"])
        #expect(l.currentFix?.edit.original == "tomorow")
        #expect(Self.consistent(l))
    }

    @Test func reconcileKeepsSkippedAndRetiresApplied() throws {
        var l = Self.list()
        l.skip(at: 0)                       // teh
        let after = l.applyOne(at: 1)!  // was → were
        let paras = ProofreadEngine.chunks(of: after)
        // The model still suggests "teh" → "the" and now "teh team" → "the team": both overlap the skipped fix.
        l.reconcile(edits: [Self.edit(after, "teh", "the"), Self.edit(after, "teh team", "the team"),
                            Self.edit(after, "tomorow", "tomorrow")], covered: paras)
        #expect(l.fixes.map(\.status) == [.skipped, .pending])
        #expect(l.appliedCount == 1 && l.skippedCount == 1)
        #expect(l.currentFix?.edit.original == "tomorow")
    }
}

@Suite struct IgnoredFixesTests {
    static func edit(_ text: String, _ original: String, _ replacement: String) -> Edit {
        Edit(range: (text as NSString).range(of: original), original: original, replacement: replacement)
    }

    @Test func ignoredFixStaysIgnoredWhereverItsSentenceMoves() {
        let text = "Hi teh team. We was late."
        var ignored = IgnoredFixes()
        ignored.add(Self.edit(text, "was", "were"), in: text)
        #expect(ignored.contains(Self.edit(text, "was", "were"), in: text))
        #expect(!ignored.contains(Self.edit(text, "teh", "the"), in: text))
        // The sentence moved: text added before it, and in a new paragraph.
        let moved = "Hello.\n\nHi teh team, again. We was late."
        #expect(ignored.contains(Self.edit(moved, "was", "were"), in: moved))
        #expect(ignored.filter([Self.edit(moved, "teh", "the"), Self.edit(moved, "was", "were")], in: moved)
            == [Self.edit(moved, "teh", "the")])
    }

    @Test func comesBackWhenTheSentenceChangesOrTheFixDiffers() {
        let text = "We was late."
        var ignored = IgnoredFixes()
        ignored.add(Self.edit(text, "was", "were"), in: text)
        let changed = "We was very late."
        #expect(!ignored.contains(Self.edit(changed, "was", "were"), in: changed))
        #expect(!ignored.contains(Self.edit(text, "was", "are"), in: text))
    }

    @Test func insertionsAndSentenceJoins() {
        let text = "I came home. and then slept."
        var ignored = IgnoredFixes()
        // An insertion (empty range) and a fix across the sentence boundary.
        let comma = Edit(range: NSRange(location: 1, length: 0), original: "", replacement: ",")
        let join = Self.edit(text, ". and", ", and")
        ignored.add(comma, in: text)
        ignored.add(join, in: text)
        #expect(ignored.contains(comma, in: text))
        #expect(ignored.contains(join, in: "Note.\n" + text) == false)  // the range is relative to the text
        let shifted = "Note.\n" + text
        #expect(ignored.contains(Self.edit(shifted, ". and", ", and"), in: shifted))
        #expect(!ignored.contains(Edit(range: NSRange(location: 99, length: 0), original: "", replacement: ","), in: text))
    }

    @Test func capacityDropsTheOldest() {
        var ignored = IgnoredFixes(capacity: 2)
        let texts = ["A teh.", "B teh.", "C teh."]
        for t in texts { ignored.add(Self.edit(t, "teh", "the"), in: t) }
        #expect(ignored.count == 2)
        #expect(!ignored.contains(Self.edit(texts[0], "teh", "the"), in: texts[0]))
        #expect(ignored.contains(Self.edit(texts[2], "teh", "the"), in: texts[2]))
    }
}
