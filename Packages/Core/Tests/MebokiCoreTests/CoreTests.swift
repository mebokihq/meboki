import Foundation
import Testing
@testable import MebokiCore

@Suite struct PostFilterTests {
    @Test func cleanStripsWrappers() {
        #expect(PostFilter.clean("<text>He goes.</text>", input: "He go.") == "He goes.")
        #expect(PostFilter.clean("np, happy to help :)</text>", input: "np, happy to help :)") == "np, happy to help :)")
        #expect(PostFilter.clean("<think>hmm</think>\nHe goes.", input: "He go.") == "He goes.")
        #expect(PostFilter.clean("\"He goes.\"", input: "He go.") == "He goes.")
    }

    @Test func cleanKeepsUsersOwnQuotesAndTags() {
        #expect(PostFilter.clean("\"We were late.\"", input: "\"We were late.\"") == "\"We were late.\"")
        #expect(PostFilter.judge(input: "\"We were late.\"", rawOutput: "\"We were late.\"") == .unchanged)
        let html = "Wrap it in <text>hello</text>"
        #expect(PostFilter.judge(input: html, rawOutput: html) == .unchanged)
    }

    /// Reference values from Python: difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()
    @Test func similarityMatchesDifflib() {
        let cases: [(String, String, Double)] = [
            ("abxcd", "cdxab", 0.4),
            ("She dont like apples.", "She doesn't like apples.", 0.933333),
            ("Hi, how are you? I will be in the office tomorrow.", "Привет, как дела? Я завтра буду в офисе.", 0.222222),
            ("the quick brown fox", "quick the brown fox jumps", 0.681818),
        ]
        for (a, b, want) in cases {
            #expect(abs(PostFilter.similarity(a, b) - want) < 1e-5, "\(a) / \(b)")
        }
    }

    @Test func unchangedWhenSame() {
        #expect(PostFilter.judge(input: "What time is it?", rawOutput: "What time is it?") == .unchanged)
        #expect(PostFilter.judge(input: "It’s fine.", rawOutput: "It's fine.") == .unchanged)
    }

    @Test func styleOnlyIgnored() {
        #expect(PostFilter.judge(input: "lol ok see u there", rawOutput: "Lol ok see u there.") == .unchanged)
        #expect(PostFilter.judge(input: "lol ok see u there", rawOutput: "Lol ok see u there.", ignoreStyleOnly: false)
            == .corrected("Lol ok see u there."))
    }

    @Test func rejectsTranslationAndAnswers() {
        let r1 = PostFilter.judge(input: "Привет, как дела? Я завтра буду в офисе.", rawOutput: "Hi, how are you? I'll be in the office tomorrow.")
        #expect(r1 != .unchanged)
        if case .corrected = r1 { Issue.record("translation must be rejected") }
        let r2 = PostFilter.judge(input: "teh deploy failed again", rawOutput: "teh deploy failed again -> teo? Wait, instruction says only fix spelling so the answer is")
        if case .corrected = r2 { Issue.record("reasoning leak must be rejected") }
    }

    @Test func acceptsRealFix() {
        #expect(PostFilter.judge(input: "She dont like apples.", rawOutput: "She doesn't like apples.") == .corrected("She doesn't like apples."))
    }
}

@Suite struct DiffTests {
    @Test func singleWordFix() {
        let e = Diff.edits(from: "I has a car.", to: "I have a car.")
        #expect(e == [Edit(range: NSRange(location: 2, length: 3), original: "has", replacement: "have")])
    }

    @Test func adjacentWordsMerge() {
        let e = Diff.edits(from: "Their is still a few issues.", to: "There are still a few issues.")
        #expect(e.count == 1)
        #expect(e[0].original == "Their is")
        #expect(e[0].replacement == "There are")
    }

    @Test func insertionAndDeletion() {
        let a = "Lets discuss it on tomorrow's call."
        let b = "Let's discuss it on tomorrow's call."
        let e = Diff.edits(from: a, to: b)
        #expect(Diff.apply(e, to: a) == b)
        let c = "I think we should of tested this."
        let d = "I think we should have tested this."
        #expect(Diff.apply(Diff.edits(from: c, to: d), to: c) == d)
    }

    @Test func utf16RangesWithEmoji() {
        let a = "lol 👍 she dont care"
        let b = "lol 👍 she doesn't care"
        let e = Diff.edits(from: a, to: b)
        #expect(e.count == 1)
        #expect((a as NSString).substring(with: e[0].range) == "dont")
        #expect(Diff.apply(e, to: a) == b)
    }

    @Test func paragraphRoundTrip() {
        let a = "Hi team, i wanted to give a quick update. We was able to move most of the services last week, but their is still a few issues."
        let b = "Hi team, I wanted to give a quick update. We were able to move most of the services last week, but there are still a few issues."
        let e = Diff.edits(from: a, to: b)
        #expect(Diff.apply(e, to: a) == b)
        #expect(e.count == 3)
    }

    @Test func segmentsShowChanges() {
        let a = "I has a car."
        let s = Diff.segments(original: a, edits: Diff.edits(from: a, to: "I have a car."))
        #expect(s == [.same("I "), .removed("has"), .added("have"), .same(" a car.")])
    }
}

@Suite struct ClientTests {
    @Test func outputCapCoversDenseScripts() {
        #expect(LLMClient.maxTokens(for: "短い文です") >= 5 + 64)
    }
}

@Suite struct ChunkTests {
    @Test func splitsParagraphsAndTrims() {
        let t = "  Hello there.\n\nSecond line here.\n123\n"
        let r = ProofreadEngine.chunks(of: t).map { (t as NSString).substring(with: $0) }
        #expect(r == ["Hello there.", "Second line here."])
    }
}

/// Integration test against a running llama-server. Skipped unless MEBOKI_SERVER is set,
/// e.g. MEBOKI_SERVER=http://127.0.0.1:8080 swift test
@Suite struct LiveModelTests {
    static let server = ProcessInfo.processInfo.environment["MEBOKI_SERVER"].flatMap(URL.init(string:))

    @Test(.enabled(if: server != nil)) func fixesParagraph() async throws {
        let engine = ProofreadEngine(client: LLMClient(baseURL: Self.server!))
        let text = "Hi team, i wanted to give a quick update. We was able to move most of the services.\n\nlol ok see u there"
        let result = try await engine.check(text)
        let fixed = Diff.apply(result.edits, to: text)
        #expect(fixed.contains("We were able"))
        #expect(fixed.hasSuffix("lol ok see u there"))
    }

    /// Milestone B: the pipeline's first check equals the hotkey check; a re-check needs no request, and an
    /// edit in one sentence sends only that sentence.
    @Test(.enabled(if: server != nil)) func pipelineCachesSentences() async throws {
        let text = "Hi team, i wanted to give a quick update. We was able to move most of the services. See you tomorow."
        let pipe = CheckPipeline(client: LLMClient(baseURL: Self.server!))
        let first = try await pipe.check(text)
        let engine = try await ProofreadEngine(client: LLMClient(baseURL: Self.server!)).check(text)
        #expect(first.edits == engine.edits)
        #expect(try await pipe.check(text).requests == 0)
        let edited = text.replacingOccurrences(of: "See you tomorow.", with: "See you on monday tomorow.")
        let r = try await pipe.check(edited)
        #expect(r.requests == 1)
        let fixed = Diff.apply(r.edits, to: edited)
        #expect(fixed.contains("We were able"))
        #expect(fixed.contains("tomorrow"))
    }

    /// Stage 9 "done when": a UK-spelling sentence is left alone with UK selected.
    @Test(.enabled(if: server != nil)) func ukSpellingLeftAloneWithUK() async throws {
        let engine = ProofreadEngine(client: LLMClient(baseURL: Self.server!), options: CheckOptions(variant: .uk))
        for text in ["Our favourite colour is grey.", "The team are reviewing the programme this week.",
                     "We organised the workshop and analysed the feedback."] {
            let result = try await engine.check(text)
            #expect(result.edits.isEmpty, "\(text) → \(Diff.apply(result.edits, to: text))")
        }
    }

    /// Stage 9 "done when": a casual chat line is left alone with Casual on; a real error in one is still fixed.
    @Test(.enabled(if: server != nil)) func casualLineLeftAloneWithCasual() async throws {
        let engine = ProofreadEngine(client: LLMClient(baseURL: Self.server!), options: CheckOptions(casual: true))
        for text in ["yep that's the one", "just pushed it, lmk if it breaks", "gm! shipping the fix now"] {
            let result = try await engine.check(text)
            #expect(result.edits.isEmpty, "\(text) → \(Diff.apply(result.edits, to: text))")
        }
        let text = "we was just talking about that lol"
        let result = try await engine.check(text)
        #expect(Diff.apply(result.edits, to: text) == "we were just talking about that lol")
    }
}
