import Foundation
import Testing
@testable import MebokiCore

/// A model stand-in: applies fixed replacements to whatever it's sent, records each request.
final class FakeCorrector: Corrector, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    let fixes: [(String, String)]
    var delay: Duration = .zero
    /// Inputs containing this get a reply the similarity guard rejects.
    var garbageIfContains: String?
    var failFatally = false

    init(_ fixes: [(String, String)]) { self.fixes = fixes }

    var calls: [String] { lock.withLock { _calls } }

    func correct(_ text: String, system: String) async throws -> LLMClient.Reply {
        lock.withLock { _calls.append(text) }
        if failFatally { throw LLMClient.Failure(message: "bad key", fatal: true) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let g = garbageIfContains, text.contains(g) {
            return LLMClient.Reply(text: "Sure! Here is a completely different answer to your question.", truncated: false)
        }
        var out = text
        for (a, b) in fixes { out = out.replacingOccurrences(of: a, with: b) }
        return LLMClient.Reply(text: out, truncated: false)
    }
}

private let fixes = [("We was", "We were"), ("tomorow", "tomorrow"), ("dont", "don't"), ("teh", "the")]

@Suite struct CheckPipelineTests {
    let text = "Hi team. We was able to move most services. See you tomorow.\n\nI dont know teh answer yet. Ask me later."

    @Test func sentencesCoverParagraph() {
        let ns = text as NSString
        let paras = ProofreadEngine.chunks(of: text)
        let s = CheckPipeline.sentences(in: ns, range: paras[0]).map { ns.substring(with: $0) }
        #expect(s == ["Hi team.", "We was able to move most services.", "See you tomorow."])
    }

    @Test func coldCacheMatchesEngine() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        let r = try await pipe.check(text)
        let engine = try await ProofreadEngine(client: FakeCorrector(fixes)).check(text)
        #expect(r.edits == engine.edits)
        #expect(r.complete && r.requests == 2)
        // With an empty cache each paragraph goes as one request, as in the hotkey check.
        #expect(fake.calls == ProofreadEngine.chunks(of: text).map { (text as NSString).substring(with: $0) })
        #expect(Diff.apply(r.edits, to: text)
                == "Hi team. We were able to move most services. See you tomorrow.\n\nI don't know the answer yet. Ask me later.")
    }

    @Test func sameTextComesFromCache() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        let first = try await pipe.check(text)
        let again = try await pipe.check(text)
        #expect(again.requests == 0)
        #expect(again.edits == first.edits)
        #expect(fake.calls.count == 2)
    }

    @Test func editedSentenceIsTheOnlyRequest() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        _ = try await pipe.check(text)
        // The user adds an emoji line above and edits the middle sentence.
        let edited = "👋\n" + text.replacingOccurrences(of: "most services", with: "most of teh services")
        let r = try await pipe.check(edited)
        #expect(r.requests == 1)
        #expect(fake.calls.last == "We was able to move most of teh services.")
        #expect(Diff.apply(r.edits, to: edited)
                == "👋\nHi team. We were able to move most of the services. See you tomorrow.\n\nI don't know the answer yet. Ask me later.")
        // UTF-16 ranges: the emoji is two units.
        let e = try #require(r.edits.first { $0.original == "tomorow" })
        #expect((edited as NSString).substring(with: e.range) == "tomorow")
    }

    @Test func fixAcrossSentencesIsCachedAsOneUnit() async throws {
        let fake = FakeCorrector([("home. And then", "home, and then")])
        let pipe = CheckPipeline(client: fake)
        let t = "I went home. And then I slept. It was late."
        let r = try await pipe.check(t)
        #expect(Diff.apply(r.edits, to: t) == "I went home, and then I slept. It was late.")
        let again = try await pipe.check(t)
        #expect(again.requests == 0)
        #expect(again.edits == r.edits)
        // Editing the untouched last sentence sends only that one.
        let t2 = "I went home. And then I slept. It was very late."
        let r2 = try await pipe.check(t2)
        #expect(r2.requests == 1 && fake.calls.last == "It was very late.")
        #expect(Diff.apply(r2.edits, to: t2) == "I went home, and then I slept. It was very late.")
    }

    @Test func rejectedReplyIsRemembered() async throws {
        let fake = FakeCorrector(fixes)
        fake.garbageIfContains = "services"
        let pipe = CheckPipeline(client: fake)
        let t = "We was able to move most services. See you tomorow."
        let r = try await pipe.check(t)
        #expect(r.edits.isEmpty && r.rejectedChunks == 1)
        let again = try await pipe.check(t)
        #expect(again.requests == 0 && again.rejectedChunks == 1)
        // A changed sentence gets a new chance on its own.
        let t2 = "We was able to move most services. See you tomorow, ok."
        let r2 = try await pipe.check(t2)
        #expect(r2.requests == 1 && r2.rejectedChunks == 1)
        #expect(Diff.apply(r2.edits, to: t2) == "We was able to move most services. See you tomorrow, ok.")
    }

    @Test func cursorParagraphGoesFirst() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        let t = "First one here.\n\nSecond one here.\n\nThird one here."
        let cursor = (t as NSString).range(of: "Third").location + 3
        _ = try await pipe.check(t, scope: .init(cursor: cursor))
        #expect(fake.calls == ["Third one here.", "Second one here.", "First one here."])
    }

    @Test func cursorRunGoesFirstInsideParagraph() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        let t = "One is here. Two is here. Three is here."
        _ = try await pipe.check(t)
        let t2 = "One is now here. Two is here. Three is now here."
        let cursor = (t2 as NSString).length
        _ = try await pipe.check(t2, scope: .init(cursor: cursor))
        #expect(fake.calls.suffix(2) == ["Three is now here.", "One is now here."])
    }

    @Test func visibleRangeAndLengthCapDefer() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        let t = "First one here.\n\nSecond one here.\n\nThird one here."
        let r = try await pipe.check(t, scope: .init(visible: NSRange(location: 0, length: 5)))
        #expect(fake.calls == ["First one here."] && r.deferredChunks == 2)
        let capped = try await CheckPipeline(client: FakeCorrector(fixes)).check(t, scope: .init(maxLength: 20))
        #expect(capped.deferredChunks == 2)
        let all = try await CheckPipeline(client: FakeCorrector(fixes)).check(t, scope: .init(cursor: 3, maxLength: .max))
        #expect(all.deferredChunks == 0 && all.covered.count == 3)
    }

    @Test func settingsChangeUsesCacheVariantDoesNot() async throws {
        let fake = FakeCorrector([("dont", "don't"), ("color", "colour")])
        let pipe = CheckPipeline(client: fake)
        let t = "I dont like this color."
        let full = try await pipe.check(t)
        #expect(full.edits.count == 1)  // the US/UK respelling is dropped either way
        await pipe.setOptions(CheckOptions(level: .grammar, casual: true))
        let casual = try await pipe.check(t)
        #expect(casual.requests == 0)
        await pipe.setOptions(CheckOptions(variant: .uk))
        let uk = try await pipe.check(t)
        #expect(uk.requests == 1)  // a different prompt: new model answers
        await pipe.setClient(FakeCorrector(fixes))
        #expect(await pipe.cachedCount == 0)
    }

    @Test func fatalErrorStopsTheCheck() async {
        let fake = FakeCorrector(fixes)
        fake.failFatally = true
        await #expect(throws: LLMClient.Failure.self) { try await CheckPipeline(client: fake).check(text) }
    }

    @Test func cacheEvictsLeastRecentlyUsed() {
        var c = CheckPipeline.Cache()
        for i in 0..<10 { c.set(.init(variant: .us, text: "s\(i)"), .rejected, capacity: 8) }
        #expect(c.count <= 8)
        #expect(c.get(.init(variant: .us, text: "s9")) != nil)
        #expect(c.get(.init(variant: .us, text: "s0")) == nil)
    }
}

/// Collects scheduler updates for tests.
actor UpdateLog {
    var updates: [CheckScheduler.Update] = []
    func add(_ u: CheckScheduler.Update) { updates.append(u) }
    func done() -> [CheckScheduler.Update] { updates.filter(\.done) }

    /// Waits until `count` passes finished (or ~2 s).
    func waitForDone(_ count: Int = 1) async -> [CheckScheduler.Update] {
        for _ in 0..<200 {
            if done().count >= count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }
}

@Suite struct CheckSchedulerTests {
    @Test func debounceChecksOnlyTheLastText() async {
        let fake = FakeCorrector(fixes)
        let log = UpdateLog()
        let s = CheckScheduler(pipeline: CheckPipeline(client: fake), delay: .milliseconds(80)) { u in
            Task { await log.add(u) }
        }
        await s.textChanged("We")
        await s.textChanged("We was")
        await s.textChanged("We was here.")
        let done = await log.waitForDone()
        #expect(done.count == 1)
        #expect(done.first?.text == "We was here.")
        #expect(fake.calls == ["We was here."])
        #expect(done.first.map { Diff.apply($0.result!.edits, to: $0.text) } == "We were here.")
    }

    @Test func editingTheSentenceInFlightCancelsIt() async throws {
        let fake = FakeCorrector(fixes)
        fake.delay = .milliseconds(400)
        let log = UpdateLog()
        let s = CheckScheduler(pipeline: CheckPipeline(client: fake), delay: .milliseconds(10)) { u in
            Task { await log.add(u) }
        }
        await s.textChanged("We was here.")
        try await Task.sleep(for: .milliseconds(100))  // the request is in flight
        await s.textChanged("We was there.")
        let done = await log.waitForDone()
        try await Task.sleep(for: .milliseconds(100))
        let all = await log.done()
        #expect(all.count == 1 && done.first?.text == "We was there.")
        #expect(fake.calls == ["We was here.", "We was there."])
    }

    @Test func requestForUnchangedTextFinishesAndIsCached() async throws {
        let fake = FakeCorrector(fixes)
        fake.delay = .milliseconds(200)
        let pipe = CheckPipeline(client: fake)
        let log = UpdateLog()
        let s = CheckScheduler(pipeline: pipe, delay: .milliseconds(10)) { u in Task { await log.add(u) } }
        await s.textChanged("We was here.\n\nSee you tomorow.")
        try await Task.sleep(for: .milliseconds(80))  // first paragraph in flight
        // A new paragraph after it: the first request is still useful.
        await s.textChanged("We was here.\n\nSee you tomorow.\n\nI dont know.")
        let done = await log.waitForDone()
        #expect(done.count == 1)
        #expect(fake.calls.filter { $0 == "We was here." }.count == 1)
        #expect(done.first.map { Diff.apply($0.result!.edits, to: $0.text) }
                == "We were here.\n\nSee you tomorrow.\n\nI don't know.")
    }

    @Test func cancelDropsResults() async throws {
        let fake = FakeCorrector(fixes)
        fake.delay = .milliseconds(200)
        let log = UpdateLog()
        let s = CheckScheduler(pipeline: CheckPipeline(client: fake), delay: .milliseconds(10)) { u in
            Task { await log.add(u) }
        }
        await s.textChanged("We was here.")
        try await Task.sleep(for: .milliseconds(60))
        await s.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await log.updates.isEmpty)
    }

    @Test func failureIsReported() async {
        let fake = FakeCorrector(fixes)
        fake.failFatally = true
        let log = UpdateLog()
        let s = CheckScheduler(pipeline: CheckPipeline(client: fake), delay: .milliseconds(10)) { u in
            Task { await log.add(u) }
        }
        await s.checkNow("We was here.")
        let done = await log.waitForDone()
        #expect(done.first?.error == "bad key")
    }
}

/// Counts how many requests are in flight at once.
final class ConcurrencyProbe: Corrector, @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    let inner: FakeCorrector

    init(_ inner: FakeCorrector) { self.inner = inner }

    func correct(_ text: String, system: String) async throws -> LLMClient.Reply {
        lock.withLock { now += 1; peak = max(peak, now) }
        defer { lock.withLock { now -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        return try await inner.correct(text, system: system)
    }
}

@Suite struct ParallelRequestTests {
    /// 12 paragraphs, each with errors, some with a sentence that fails. No sentence is in two paragraphs: with one
    /// lane the second would come from the cache, with more it may already be on its way as part of its paragraph.
    static let text = (0..<12).map { "Paragraph \($0): we was late. See you tomorow at \($0)." + ($0 % 5 == 0 ? " Bad one here \($0)." : "") }
        .joined(separator: "\n")

    @Test func sameEditsAndPartialsWithMoreLanes() async throws {
        var results: [CheckPipeline.Result] = []
        var partialCovers: [[[NSRange]]] = []
        var peaks: [Int] = []
        for lanes in [1, 4] {
            let fake = FakeCorrector([("we was", "we were"), ("tomorow", "tomorrow")])
            fake.garbageIfContains = "Bad one"
            let probe = ConcurrencyProbe(fake)
            let pipe = CheckPipeline(client: probe)
            await pipe.setMaxConcurrentRequests(lanes)
            let log = PartialLog()
            let cursor = (Self.text as NSString).range(of: "Paragraph 7").location
            let r = try await pipe.check(Self.text, scope: .init(cursor: cursor)) { log.add($0.covered) }
            results.append(r)
            partialCovers.append(log.all)
            peaks.append(probe.peak)
            // Each paragraph went to the model once.
            #expect(fake.calls.count == 12, "\(lanes): \(fake.calls)")
        }
        #expect(results[0] == results[1])
        #expect(partialCovers[0] == partialCovers[1])
        #expect(results[0].rejectedChunks == 3)
        #expect(peaks == [1, 4])
    }

    @Test func longParagraphsStayInsideTheTokenBudget() async throws {
        // Four 3000-character paragraphs: at most two fit an 8192-token pool by the worst-case cost (2n + 300 each
        // is 6300, so only one); short ones go four at a time.
        let long = (0..<4).map { i in String(repeating: "We was here \(i). ", count: 200).prefix(3000) }.joined(separator: "\n")
        let probe = ConcurrencyProbe(FakeCorrector([]))
        let pipe = CheckPipeline(client: probe)
        await pipe.setMaxConcurrentRequests(4)
        _ = try await pipe.check(long)
        #expect(probe.peak == 1)
        let wide = ConcurrencyProbe(FakeCorrector([]))
        let pipe2 = CheckPipeline(client: wide)
        await pipe2.setMaxConcurrentRequests(4, tokenBudget: 4 * 6400)
        _ = try await pipe2.check(long)
        #expect(wide.peak == 4)
    }

    @Test func aRejectedReplyKeepsAGoodCachedSentence() async throws {
        // Paragraph 2 is started ahead as a whole while paragraph 1 caches the sentence they share; paragraph
        // 2's reply is rejected (its other sentence), and must not wipe that sentence's correction.
        let text = "See you tomorow. Line one.\nSee you tomorow. Bad one here."
        let fake = FakeCorrector([("tomorow", "tomorrow")])
        fake.garbageIfContains = "Bad one"
        let pipe = CheckPipeline(client: fake)
        await pipe.setMaxConcurrentRequests(4)
        _ = try await pipe.check(text)
        let again = try await pipe.check("See you tomorow.")
        #expect(again.requests == 0)
        #expect(again.edits.count == 1)
    }

    @Test func stopCancelsRequestsStartedAhead() async throws {
        let fake = FakeCorrector([])
        fake.delay = .milliseconds(50)
        let pipe = CheckPipeline(client: fake)
        await pipe.setMaxConcurrentRequests(4)
        let control = PassControl()
        let task = Task { try await pipe.check(Self.text, control: control) { _ in control.stop() } }
        await #expect(throws: CancellationError.self) { try await task.value }
        // The first paragraph and up to three started ahead; nothing after the stop.
        #expect(fake.calls.count <= 4)
    }
}

final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[NSRange]] = []
    func add(_ r: [NSRange]) { lock.withLock { items.append(r) } }
    var all: [[NSRange]] { lock.withLock { items } }
}
