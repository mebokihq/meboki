import Foundation
import Testing
@testable import MebokiCore

/// Replies recorded from Gemma 4 E4B Q4_0 (eval/results_rewrite_e4b.json).
@Suite struct RewriteDetectorTests {
    static let cinema = ("Yesterday me and friend go cinema but film was very boring so we leaved after half hour and go eat pizza.",
                         "Yesterday my friend and I went to the cinema, but the film was very boring so we left after half an hour and went to eat pizza.")
    static let typos = ("Thanks for you're help yesterday, it was realy usefull and i appreciate it alot.",
                        "Thanks for your help yesterday, it was really useful and I appreciate it a lot.")
    static let explain = ("Could you please explain me the problem?", "Could you please explain to me the problem?")

    func edits(_ p: (String, String), group: Bool = true) -> [Edit] {
        ProofreadEngine.edits(chunk: p.0, corrected: p.1, options: CheckOptions(groupRewrites: group))
    }

    @Test func clauseRebuildBecomesOneRewrite() {
        #expect(edits(Self.cinema, group: false).count == 7)
        let e = edits(Self.cinema)
        #expect(e.count == 1)
        #expect(Diff.apply(e, to: Self.cinema.0) == Self.cinema.1)
        #expect(FixClassifier.classify(e[0], in: Self.cinema.0) == .rewrite)
    }

    @Test func independentTyposStaySeparate() {
        #expect(edits(Self.typos).count == 4)
    }

    @Test func fewEditsStaySeparateWhateverTheirSize() {
        #expect(edits(Self.explain).count == edits(Self.explain, group: false).count)
    }

    @Test func settingOffKeepsEveryFix() {
        #expect(edits(Self.cinema, group: false).count == 7)
    }

    @Test func onlyTheRewrittenSentenceIsMerged() {
        let text = Self.cinema.0 + " She dont like apples."
        let fixed = Self.cinema.1 + " She doesn't like apples."
        let e = ProofreadEngine.edits(chunk: text, corrected: fixed, options: CheckOptions())
        #expect(e.count == 2)
        #expect(Diff.apply(e, to: text) == fixed)
        #expect(e[0].range.length < (Self.cinema.0 as NSString).length)
        #expect(e[1].original == "dont")
    }

    @Test func rewriteAppliesThroughFixList() {
        let list = FixList(text: Self.cinema.0, edits: edits(Self.cinema))
        #expect(list.fixes.count == 1)
        #expect(list.fixes[0].category == .rewrite)
        #expect(FixCategory.rewrite.title == "Rewrite")
    }

    @Test func levelFiltersRunBeforeGrouping() {
        // Spelling level keeps almost nothing of this reply, so there is nothing to merge.
        let e = ProofreadEngine.edits(chunk: Self.cinema.0, corrected: Self.cinema.1, options: CheckOptions(level: .spelling))
        #expect(e.count < 4)
    }
}
