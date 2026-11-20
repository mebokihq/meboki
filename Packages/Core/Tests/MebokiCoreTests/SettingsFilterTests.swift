import Foundation
import Testing
@testable import MebokiCore

/// Stage 9: protected tokens, US/UK respelling, chat slang, casual mode, check level, per-variant prompt.
@Suite struct ProtectedTokenTests {
    func protected(_ text: String) -> [String] {
        ProtectedTokens.ranges(in: text).map { (text as NSString).substring(with: $0) }
    }

    @Test func findsLinksCodeMentionsAndIdentifiers() {
        #expect(protected("Check https://example.com/docs for details.") == ["https://example.com/docs"])
        #expect(protected("See https://example.com/docs.") == ["https://example.com/docs"])
        #expect(protected("Email jane.doe@example.com today") == ["jane.doe@example.com"])
        #expect(protected("@sarah can you look?") == ["@sarah"])
        #expect(protected("Can you take a look at PR #482?") == ["#482"])
        #expect(protected("Run `npm install` first") == ["`npm install`"])
        #expect(protected("Open ~/Library/Logs and /usr/bin") == ["~/Library/Logs", "/usr/bin"])
        #expect(protected("I pushed feature/login_v2 yesterday") == ["feature/login_v2"])
        #expect(protected("Set maxTokens in config.yaml") == ["maxTokens", "config.yaml"])
        #expect(protected("the iOS build on GitHub") == ["iOS", "GitHub"])
        #expect(protected("Can you send me the отчет by Friday?") == ["отчет"])
        #expect(protected("lol 👍 ok :)") == ["👍", ":)"])
        #expect(protected("She doesn't like apples.").isEmpty)
        #expect(protected("Nguyen and Siobhan will join the call at 3 pm.").isEmpty)
    }

    @Test func fencedCodeAcrossParagraphs() {
        let t = "Look:\n```\nlet x = their_value\nfoo bar baz\n```\nDone."
        let r = ProtectedTokens.ranges(in: t)
        let chunks = ProofreadEngine.chunks(of: t)
        // "foo bar baz" is inside the fence: the engine skips it.
        let inner = chunks.first { (t as NSString).substring(with: $0) == "foo bar baz" }!
        #expect(ProtectedTokens.covers(r, inner))
        #expect(!ProtectedTokens.covers(r, chunks.first!))
    }

    @Test func touchesOverlapAndInsertionsInside() {
        let p = [NSRange(location: 10, length: 5)]
        #expect(ProtectedTokens.touches(NSRange(location: 12, length: 1), p))
        #expect(ProtectedTokens.touches(NSRange(location: 8, length: 3), p))
        #expect(ProtectedTokens.touches(NSRange(location: 12, length: 0), p))
        #expect(!ProtectedTokens.touches(NSRange(location: 15, length: 0), p))  // right after: an added period
        #expect(!ProtectedTokens.touches(NSRange(location: 10, length: 0), p))
        #expect(!ProtectedTokens.touches(NSRange(location: 2, length: 4), p))
    }

    @Test func clipToChunk() {
        let p = [NSRange(location: 5, length: 10)]
        #expect(ProtectedTokens.clip(p, to: NSRange(location: 10, length: 20)) == [NSRange(location: 0, length: 5)])
        #expect(ProtectedTokens.clip(p, to: NSRange(location: 20, length: 5)).isEmpty)
    }

    @Test func dropsEditsOnProtectedTokensKeepsOtherFixes() {
        let on = CheckOptions(), off = CheckOptions(protectTokens: false)
        let input = "@sarah can you review it? Their is a bug in `parseUrl`."
        let output = "@Sarah, can you review it? There is a bug in `parseURL`."
        #expect(fixed(input, output, on) == "@sarah can you review it? There is a bug in `parseUrl`.")
        #expect(fixed(input, output, off) == output)
        // Translation of a non-English word.
        #expect(fixed("Can you send me the отчет by Friday?", "Can you send me the report by Friday?", on)
            == "Can you send me the отчет by Friday?")
        // A period after a URL is outside it.
        #expect(fixed("The docs is at https://example.com/start", "The docs are at https://example.com/start.", on)
            == "The docs are at https://example.com/start.")
        #expect(fixed("Check https://example.com/docs for details.", "Check https://example.com/doc for details.", on)
            == "Check https://example.com/docs for details.")
    }
}

/// Final text after `ProofreadEngine.process` (judge → diff → filters).
func fixed(_ input: String, _ output: String, _ options: CheckOptions) -> String {
    switch ProofreadEngine.process(chunk: input, rawOutput: output, options: options) {
    case .unchanged, .rejected: return input
    case .edits(let e): return Diff.apply(e, to: input)
    }
}

@Suite struct SpellingVariantTests {
    @Test func respellingPairs() {
        let pairs = [("colour", "color"), ("behaviour", "behavior"), ("favourite", "favorite"), ("organise", "organize"),
                     ("organisation", "organization"), ("analysed", "analyzed"), ("centre", "center"),
                     ("theatres", "theaters"), ("travelled", "traveled"), ("cancelling", "canceling"),
                     ("catalogue", "catalog"), ("grey", "gray"), ("programmes", "programs"), ("licence", "license"),
                     ("maths", "math"), ("apologise", "apologize"), ("paediatric", "pediatric"), ("Colour", "color")]
        for (uk, us) in pairs {
            #expect(SpellingVariant.isRespelling(uk, us), "\(uk) → \(us)")
            #expect(SpellingVariant.isRespelling(us, uk), "\(us) → \(uk)")
        }
    }

    @Test func realTyposAreNotRespellings() {
        let fixes = [("tollerate", "tolerate"), ("intence", "intense"), ("thae", "the"), ("four", "for"),
                     ("recieve", "receive"), ("there", "their"), ("whether", "weather"), ("colur", "colour")]
        for (a, b) in fixes { #expect(!SpellingVariant.isRespelling(a, b), "\(a) → \(b)") }
    }

    @Test func restorePutsBackOnlyTheRespelledWord() {
        let e = Edit(range: NSRange(location: 4, length: 9), original: "colour is", replacement: "color are")
        #expect(SpellingVariant.restore(e)?.replacement == "colour are")
        let only = Edit(range: NSRange(location: 4, length: 6), original: "colour", replacement: "color")
        #expect(SpellingVariant.restore(only) == nil)
    }

    @Test func keepsTheWritersVariantEitherWay() {
        let o = CheckOptions()
        #expect(fixed("The colour of the logo is off.", "The color of the logo is off.", o) == "The colour of the logo is off.")
        #expect(fixed("If I was you, I would apologize.", "If I were you, I would apologise.", CheckOptions(variant: .uk))
            == "If I were you, I would apologize.")
    }

    /// The English switcher picks the prompt; a correct word is never respelled into the other variant,
    /// whichever variant is selected and in either direction.
    @Test func respellingDroppedWithBothSwitcherSettings() {
        for v in EnglishVariant.allCases {
            let o = CheckOptions(variant: v)
            #expect(fixed("Our colour is grey.", "Our color is gray.", o) == "Our colour is grey.", "\(v)")
            #expect(fixed("Our color is gray.", "Our colour is grey.", o) == "Our color is gray.", "\(v)")
            #expect(fixed("We organise teh centre.", "We organize the center.", o) == "We organise the centre.", "\(v)")
            // A real typo next to it is still fixed.
            #expect(fixed("The colur is nice.", "The colour is nice.", o) == "The colour is nice.", "\(v)")
        }
    }
}

@Suite struct NoiseFilterTests {
    let o = CheckOptions()

    @Test func numbersAreNeverChanged() {
        #expect(fixed("I got 500,000+ impressions.", "I got 500 000+ impressions.", o) == "I got 500,000+ impressions.")
        #expect(fixed("I got 500,000+ impressions.", "I got 500,000 impressions.", o) == "I got 500,000+ impressions.")
        #expect(fixed("I have 2 cats.", "I have two cats.", o) == "I have 2 cats.")
        #expect(fixed("On the 1st day.", "On the first day.", o) == "On the 1st day.")
        #expect(fixed("Pages 5-6 are done.", "Pages 5–6 are done.", o) == "Pages 5-6 are done.")
        #expect(fixed("It costs $5.", "It costs 5$.", o) == "It costs $5.")
        #expect(fixed("Meet at 10:30.", "Meet at 10.30.", o) == "Meet at 10:30.")
        // Fixes around numbers stay.
        #expect(fixed("I has 3 cat.", "I have 3 cats.", o) == "I have 3 cats.")
        #expect(fixed("In 2024 we met them.", "In 2024, we met them.", o) == "In 2024, we met them.")
    }

    /// The parts of one edit aren't always independent: dropping one must not leave text that writes twice.
    @Test func unitSpacingIsDroppedWhole() {
        #expect(fixed("We need 10kg of flour.", "We need 10 kg of flour.", o) == "We need 10kg of flour.")
        #expect(fixed("It has 5GB free.", "It has 5 GB free.", o) == "It has 5GB free.")
        #expect(fixed("I paid 5pm yesterday, we was late.", "I paid 5 pm yesterday, we were late.", o)
            == "I paid 5pm yesterday, we were late.")
    }

    @Test func fixesThatCarryTheNumberOverStay() {
        #expect(fixed("The 1990's were great.", "The 1990s were great.", o) == "The 1990s were great.")
        #expect(fixed("A 5 year old boy.", "A 5-year-old boy.", o) == "A 5-year-old boy.")
        #expect(fixed("Covid 19 hit us.", "COVID-19 hit us.", o) == "COVID-19 hit us.")
    }

    @Test func chatDigitsUsedAsWords() {
        #expect(fixed("I want 2 go home.", "I want to go home.", o) == "I want to go home.")
        #expect(fixed("Thanks 4 the help.", "Thanks for the help.", o) == "Thanks for the help.")
        #expect(fixed("Me 2 want it.", "Me too want it.", o) == "Me too want it.")
        // A real count is never a word.
        #expect(fixed("I have 2 cats.", "I have two cats.", o) == "I have 2 cats.")
        #expect(fixed("Page 4.", "Page for.", o) == "Page 4.")
    }

    @Test func keepPartsDropsAOneSidedNeighbourOfADroppedPart() {
        let chunk = "We need 10kg of flour."
        let e = Edit(range: NSRange(location: 8, length: 5), original: "10kg ", replacement: "10 kg ")
        // Keep everything but the "10kg" → "10" part: the inserted "kg " goes with it.
        let kept = EditFilter.keepParts(of: e, in: chunk) { $0.original != "10kg" }
        #expect(kept.isEmpty)
        // Independent parts one space apart: the other one stays.
        let chunk2 = "I don't knw."
        let e2 = Edit(range: NSRange(location: 2, length: 9), original: "don't knw", replacement: "don’t know")
        let kept2 = EditFilter.keepParts(of: e2, in: chunk2) { $0.original != "don't" }
        #expect(kept2.map(\.replacement) == ["know"])
    }

    @Test func keepingStyleTakesTheWritersTypography() {
        #expect(EditFilter.keepingStyle(original: "I dont know \"it\" .", corrected: "I don’t know “it”.")
            == "I don’t know \"it\".")
        #expect(EditFilter.keepingStyle(original: "I came - and left.", corrected: "I came — and left.") == "I came - and left.")
        #expect(EditFilter.keepingStyle(original: "We was here.", corrected: "We were here.") == "We were here.")
    }

    @Test func secondReviewCases() {
        #expect(fixed("i has 10kg flour.", "I have 10 kg flour.", o) == "I have 10kg flour.")
        #expect(fixed("its 2 late for us.", "it's too late for us.", o) == "it's too late for us.")
        #expect(fixed("2 much salt here.", "Too much salt here.", o) == "Too much salt here.")
        #expect(fixed("Score: 5 🎉3 points", "Score: 5 🎉 3 points", o) == "Score: 5 🎉3 points")
        #expect(fixed("Wait… we was here.", "Wait we were here.", o) == "Wait… we were here.")
        #expect(fixed("Wait... we were here.", "Wait… we were here.", o) == "Wait... we were here.")
        #expect(fixed("It was 5 - the best day.", "It was 5 – the best day.", o) == "It was 5 - the best day.")
        #expect(fixed("We left. Then we eat.", "We left. then we ate.", o) == "We left. Then we ate.")
        // Joins and abbreviations keep their lowercase start.
        #expect(fixed("I went home. And then I slep.", "I went home, and then I slept.", o) == "I went home, and then I slept.")
        #expect(fixed("Bring fruit, e.g. Apples and pear.", "Bring fruit, e.g. apples and pears.", o)
            == "Bring fruit, e.g. apples and pears.")
    }

    @Test func quoteStyleOnlyIsDropped() {
        #expect(fixed("I don't know.", "I don’t know.", o) == "I don't know.")
        #expect(fixed("He said \"hi\" to me.", "He said “hi” to me.", o) == "He said \"hi\" to me.")
        // A missing apostrophe is still a fix, in either style.
        #expect(fixed("I dont know.", "I don’t know.", o) == "I don’t know.")
        // Mixed: the quote change goes, the real fix stays.
        #expect(fixed("I don't knw.", "I don’t know.", o) == "I don't know.")
    }

    @Test func spacingOnlyIsDropped() {
        #expect(fixed("Hello  world, we was here.", "Hello world, we were here.", o) == "Hello  world, we were here.")
        #expect(fixed("One line\nsecond line.", "One line second line.", o) == "One line\nsecond line.")
        // Spacing that changes the words or punctuation is a real fix.
        #expect(fixed("I like it alot.", "I like it a lot.", o) == "I like it a lot.")
        #expect(fixed("It ends.Then more.", "It ends. Then more.", o) == "It ends. Then more.")
        #expect(fixed("Wait , what?", "Wait, what?", o) == "Wait, what?")
    }
}

@Suite struct CasualAndSlangTests {
    @Test func slangIsKeptInAnyApp() {
        let o = CheckOptions()
        #expect(fixed("just pushed it, lmk if it breaks", "just pushed it, let me know if it breaks", o)
            == "just pushed it, lmk if it breaks")
        #expect(fixed("Thx, will do.", "Thanks, will do.", o) == "Thx, will do.")
        #expect(fixed("can u send me the the link", "can you send me the link", o) == "can u send me the link")
    }

    @Test func casualTextKeepsCaseAndPunctuation() {
        #expect(EditFilter.casualText(original: "lol their late again", corrected: "Lol, they're late again.")
            == "lol they're late again")
        #expect(EditFilter.casualText(original: "ok cool thanks see you", corrected: "Ok cool, thanks. See you.")
            == "ok cool thanks see you")
        #expect(EditFilter.casualText(original: "i has the tickets", corrected: "I have the tickets.") == "i have the tickets")
    }

    @Test func casualModeFixesErrorsNotStyle() {
        let casual = CheckOptions(casual: true), normal = CheckOptions()
        #expect(fixed("teh build is green now", "The build is green now.", casual) == "the build is green now")
        #expect(fixed("teh build is green now", "The build is green now.", normal) == "The build is green now.")
        #expect(fixed("we was just talking about that lol", "We were just talking about that, lol.", casual)
            == "we were just talking about that lol")
        #expect(fixed("yep that's the one", "Yep, that's the one.", casual) == "yep that's the one")
        #expect(fixed("thx, i will send it tomorow", "Thanks, I will send it tomorrow.", casual)
            == "thx, i will send it tomorrow")
        // Apostrophes are word fixes, kept in casual mode.
        #expect(fixed("im here, dont wait", "I'm here, don't wait.", casual) == "i'm here, don't wait")
    }
}

@Suite struct CheckLevelTests {
    func run(_ input: String, _ output: String, _ level: CheckLevel) -> String {
        fixed(input, output, CheckOptions(level: level))
    }

    @Test func levelsKeepTheirCategories() {
        let i = "I definately has the report.", o = "I definitely have the report."
        #expect(run(i, o, .spelling) == "I definitely has the report.")
        #expect(run(i, o, .grammar) == o)
        #expect(run(i, o, .full) == o)

        let i2 = "However we was late.", o2 = "However, we were late."
        #expect(run(i2, o2, .spelling) == i2)
        #expect(run(i2, o2, .grammar) == "However we were late.")
        #expect(run(i2, o2, .full) == o2)

        let i3 = "Its been a long week, hasnt it?", o3 = "It's been a long week, hasn't it?"
        #expect(run(i3, o3, .spelling) == "Its been a long week, hasn't it?")
        #expect(run(i3, o3, .grammar) == o3)

        let i4 = "Lets meet tommorow at the the office.", o4 = "Let's meet tomorrow at the office."
        for level in CheckLevel.allCases { #expect(run(i4, o4, level) == o4, "\(level)") }
    }

    @Test func unmergedDiffKeepsPartsSeparate() {
        let merged = Diff.edits(from: "We was late", to: "We were late")
        #expect(merged.count == 1)
        let parts = Diff.edits(from: "definately has", to: "definitely have", merge: false)
        #expect(parts.map(\.replacement) == ["definitely", "have"])
    }
}

@Suite struct PromptVariantTests {
    @Test func usPromptIsTheBenchmarkedOne() {
        #expect(Prompt.system(for: .us) == Prompt.system)
        #expect(Prompt.system(for: .us) == Prompt.system(for: .us))
    }

    @Test func ukPromptAddsOneSentenceAndKeepsExamples() {
        let uk = Prompt.system(for: .uk)
        #expect(uk != Prompt.system)
        #expect(uk.contains("The writer uses British English"))
        #expect(uk.hasPrefix("You are a proofreader."))
        #expect(uk.hasSuffix("<text>The colour is nice.</text> -> The colour is nice."))
        #expect(uk == Prompt.system(for: .uk))  // byte-identical within a session
        #expect(uk.replacingOccurrences(of: " The writer uses British English: never change any British spelling or usage to American. "
            + "This covers every British form, not only these examples: colour, organise, centre, travelled, "
            + "cancelled, grey, \"the team are\".", with: "") == Prompt.system)
    }
}

/// `ProofreadEngine.check` against a fake server: the session prompt per variant, skipped code blocks, options applied.
@Suite(.serialized) struct EngineOptionsTests {
    @Test func sendsTheVariantPromptAndAppliesFilters() async throws {
        MockServer.install(replies: [
            "The colour of they're car is lovely.": "The color of their car is lovely.",
            "teh build is green now": "The build is green now.",
        ])
        let client = LLMClient(baseURL: URL(string: "http://\(MockServer.host)")!)
        let text = "The colour of they're car is lovely.\n```\nlet x = 1\n```\nteh build is green now"
        let engine = ProofreadEngine(client: client, options: CheckOptions(variant: .uk, casual: true))
        let result = try await engine.check(text)
        #expect(Diff.apply(result.edits, to: text)
            == "The colour of their car is lovely.\n```\nlet x = 1\n```\nthe build is green now")
        let seen = MockServer.requests()
        #expect(seen.map(\.user) == ["<text>The colour of they're car is lovely.</text>", "<text>teh build is green now</text>"])
        #expect(Set(seen.map(\.system)) == [Prompt.systemUK])
    }
}

/// Answers `/v1/chat/completions` on a fake host with canned replies (input → output; unknown input echoes).
final class MockServer: URLProtocol, @unchecked Sendable {
    static let host = "proofreader.mock"
    nonisolated(unsafe) private static var replies: [String: String] = [:]
    nonisolated(unsafe) private static var seen: [(system: String, user: String)] = []
    private static let lock = NSLock()

    static func install(replies r: [String: String]) {
        lock.lock(); replies = r; seen = []; lock.unlock()
        URLProtocol.registerClass(MockServer.self)
    }

    static func requests() -> [(system: String, user: String)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let messages = json?["messages"] as? [[String: String]] ?? []
        let system = messages.first { $0["role"] == "system" }?["content"] ?? ""
        let user = messages.first { $0["role"] == "user" }?["content"] ?? ""
        let text = user.replacingOccurrences(of: "<text>", with: "").replacingOccurrences(of: "</text>", with: "")
        Self.lock.lock()
        Self.seen.append((system, user))
        let reply = Self.replies[text] ?? text
        Self.lock.unlock()
        let out: [String: Any] = ["choices": [["message": ["content": reply], "finish_reason": "stop"]]]
        let data = try! JSONSerialization.data(withJSONObject: out)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct CollectiveNounTests {
    @Test func ukKeepsPluralVerbAfterCollectiveNoun() {
        let uk = CheckOptions(variant: .uk), us = CheckOptions()
        let i = "The team are meeting in the main hall.", o = "The team is meeting in the main hall."
        #expect(fixed(i, o, uk) == i)
        #expect(fixed(i, o, us) == o)
        // Not a collective noun: the fix stays.
        #expect(fixed("Our neighbours was very kind.", "Our neighbours were very kind.", uk) == "Our neighbours were very kind.")
        #expect(fixed("The centre have been closed.", "The centre has been closed.", uk) == "The centre has been closed.")
    }
}
