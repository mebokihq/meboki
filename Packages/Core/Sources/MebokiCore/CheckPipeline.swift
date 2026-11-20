import Foundation

/// Checking as you type (Milestone B, PLAN.md §2 "Check Pipeline"): the same check as `ProofreadEngine`,
/// but with a sentence cache, so after a typing pause only the sentences that changed go to the model.
///
/// - The request unit is a run of sentences next to each other that aren't in the cache. With an empty
///   cache that's the whole paragraph, so the first check sends exactly what `ProofreadEngine.check` sends
///   and returns the same edits. After an edit inside one sentence, only that sentence is sent.
/// - The cache maps sentence text (plus the English variant, which picks the prompt) to the model's
///   corrected text after `PostFilter.judge`. The settings' edit filters (`EditFilter`: level, casual,
///   protect) run on every check, so changing them needs no new request.
/// - A fix that crosses a sentence boundary ("home. and" → "home, and") is cached for the sentences it
///   joins, as one unit.
/// - The cursor's paragraph goes first, then the others by distance from the cursor; `Scope.visible`
///   and `Scope.maxLength` limit what one pass looks at.
/// - Text that isn't English (`LanguageGate`) is never sent: a foreign paragraph is skipped, and a foreign
///   sentence inside an English paragraph splits the request around it, as in `ProofreadEngine`.
///
/// One pipeline per model: `setClient(_:)` clears the cache. The cache holds the user's text in memory
/// only; it is never written anywhere.
public actor CheckPipeline {
    public private(set) var client: any Corrector
    public private(set) var options: CheckOptions
    /// Paragraphs longer than this (UTF-16 units) are skipped, as in `ProofreadEngine`.
    public var maxChunkLength = 3000
    /// Most sentence results kept; the least recently used quarter goes when it's full.
    public var cacheCapacity = 4000
    /// Longest run of sentences looked up as one cached unit (a fix that joined sentences).
    static let maxUnitSentences = 8
    /// Most model requests in flight at once (Optimization A3). With more than one, the requests of the next
    /// paragraphs in check order start while the current one is awaited; results are still used in check order,
    /// so the edits and partial updates are the same as one at a time. Match the server's slots
    /// (`llama-server -np`); 1 for cloud models.
    public private(set) var maxConcurrentRequests = 1
    /// Tokens the server holds for all requests in flight together (`llama-server -c` with `--kv-unified`). A
    /// request is started ahead only while the worst case of everything in flight fits (`tokenCost`): four dense
    /// 3000-character paragraphs at once overflow an 8192-token pool and all four fail ("Context size has been
    /// exceeded", measured 2026-11-16). A request alone always goes, as with one slot.
    public private(set) var tokenBudget = 8192

    /// Worst-case tokens of one request: the ~200-token prompt and wrapper, the text, and a reply as long as
    /// `LLMClient.maxTokens` allows, counting one token per UTF-16 unit (dense scripts come close: 1.08 per
    /// character measured for Chinese).
    static func tokenCost(_ span: String) -> Int { 2 * span.utf16.count + 300 }

    private var cache = Cache()
    /// Blanked sentence or paragraph text → not English (`LanguageGate`). The recognizer costs about 0.5 ms a
    /// call, too much for every sentence of a long field on every typing pause.
    private var languageCache: [String: Bool] = [:]

    public init(client: any Corrector, options: CheckOptions = CheckOptions()) {
        self.client = client
        self.options = options
    }

    /// New settings for the next check. Only the English variant changes the prompt (and the cache key).
    public func setOptions(_ options: CheckOptions) { self.options = options }

    public func setMaxConcurrentRequests(_ n: Int, tokenBudget: Int = 8192) {
        maxConcurrentRequests = max(1, n)
        self.tokenBudget = tokenBudget
    }

    /// A different model (or provider): its answers differ, so the cache starts empty. `sameModel`: the same
    /// model through a new client (a new API key, a restarted server): the cache stays.
    public func setClient(_ client: any Corrector, sameModel: Bool = false) {
        self.client = client
        if !sameModel { cache.removeAll() }
    }

    public func clearCache() {
        cache.removeAll()
        languageCache.removeAll()
    }

    /// Tests: puts a correction for `text` (one sentence or a unit) straight into the cache.
    func seed(_ text: String, _ corrected: String, variant: EnglishVariant = .us) {
        cache.set(Cache.Key(variant: variant, text: text), .corrected(corrected), capacity: cacheCapacity)
    }

    private func isForeign(_ blanked: String) -> Bool {
        if let known = languageCache[blanked] { return known }
        let foreign = LanguageGate.foreignLanguage(blanked) != nil
        if languageCache.count >= cacheCapacity { languageCache.removeAll() }
        languageCache[blanked] = foreign
        return foreign
    }

    /// Sentence results in the cache (for tests and the debug menu).
    public var cachedCount: Int { cache.count }

    public struct Scope: Sendable, Equatable {
        /// The caret (UTF-16). Its paragraph is checked first, and within it the run of changed sentences
        /// around the caret.
        public var cursor: Int?
        /// Only paragraphs touching this range (plus the cursor's) are checked; nil checks all of them.
        public var visible: NSRange?
        /// Most text (UTF-16) one pass looks at, counted by whole paragraphs in check order. The cursor's
        /// paragraph is always included.
        public var maxLength: Int
        /// The check follows typing: a word the caret sits right after may still be half typed ("Li" on the
        /// way to "Like"), so no fix touches it (`wordBeingTyped`). Off for ⌃⌥G and focus checks.
        public var typing: Bool

        public init(cursor: Int? = nil, visible: NSRange? = nil, maxLength: Int = 20_000, typing: Bool = false) {
            self.cursor = cursor
            self.visible = visible
            self.maxLength = maxLength
            self.typing = typing
        }
    }

    public struct Result: Sendable, Equatable {
        /// Edits relative to the checked text, in text order.
        public var edits: [Edit]
        /// Paragraphs with a part whose model reply was unusable: too different, cut off, or a server error.
        /// Includes rejections remembered from earlier passes. That part gets no fixes; the rest still does.
        public var rejectedChunks: Int
        /// Paragraphs too long to check.
        public var skippedChunks: Int
        /// Paragraphs not sent because they aren't in English (`LanguageGate`). A foreign sentence inside an
        /// English paragraph isn't counted.
        public var foreignChunks: Int = 0
        /// Paragraphs left out by `Scope.visible` or `Scope.maxLength`.
        public var deferredChunks: Int
        /// Model requests made in this pass (0 when everything came from the cache).
        public var requests: Int
        /// False for the partial results passed to `partial` while the pass is still running.
        public var complete: Bool
        /// The paragraphs (trimmed, as `ProofreadEngine.chunks`) this result speaks for, so far: inside them
        /// `edits` is the whole answer; outside them the result says nothing (`FixList.reconcile`).
        public var covered: [NSRange]
        /// Paragraphs the pass will check in all (for "Checking paragraph n of N").
        public var totalChunks: Int
    }

    /// Checks `text`. `control` lets a `CheckScheduler` stop the pass between requests (it throws
    /// `CancellationError` then). `partial` gets the edits found so far after each paragraph.
    public func check(_ text: String, scope: Scope = Scope(), control: PassControl? = nil,
                      partial: (@Sendable (Result) -> Void)? = nil) async throws -> Result {
        // Settings for the whole pass, even if they change while it waits on the model.
        let options = self.options, client = self.client
        let system = Prompt.system(for: options.variant)
        let ns = text as NSString
        let paragraphs = ProofreadEngine.chunks(of: text)
        let protected = options.protectTokens ? ProtectedTokens.ranges(in: text) : []
        let blanked = options.englishOnly ? LanguageGate.blanked(text) : ns
        let selected = Self.order(paragraphs, scope: scope)

        var found: [Int: [Edit]] = [:]  // paragraph index → edits (absolute)
        var rejected = 0, skipped = 0, foreignChunks = 0, requests = 0
        var covered: [NSRange] = []
        func result(complete: Bool) -> Result {
            let edits = found.keys.sorted().flatMap { found[$0]! }
            return Result(edits: edits, rejectedChunks: rejected, skippedChunks: skipped, foreignChunks: foreignChunks,
                          deferredChunks: paragraphs.count - selected.count, requests: requests, complete: complete,
                          covered: covered.sorted { $0.location < $1.location }, totalChunks: selected.count)
        }

        /// What paragraph `p` sends to the model now (nil when it sends nothing: too long, code, not English).
        struct Plan {
            var sentences: [NSRange]
            var foreign: Set<Int>
        }
        func plan(_ p: Int) -> Plan? {
            let pr = paragraphs[p]
            guard pr.length <= maxChunkLength, !ProtectedTokens.covers(protected, pr) else { return nil }
            let sentences = Self.sentences(in: ns, range: pr)
            var foreign = Set<Int>()
            if options.englishOnly {
                foreign = LanguageGate.foreignSentences(paragraph: pr, sentences: sentences, blanked: blanked,
                                                        isForeign: { isForeign($0) })
                if foreign.count == sentences.count { return nil }
            }
            return Plan(sentences: sentences, foreign: foreign)
        }
        func units(_ plan: Plan) -> [Unit] {
            resolve(plan.sentences, ns: ns, variant: options.variant).map { u in
                guard u.entry == nil, plan.foreign.contains(u.sentences.lowerBound) else { return u }
                return Unit(sentences: u.sentences, entry: .corrected(ns.substring(with: plan.sentences[u.sentences.lowerBound])))
            }
        }
        // Requests started ahead, by paragraph: each is used (its reply cached) when its paragraph's turn comes.
        struct Ahead {
            var span: String
            var spanRange: NSRange
            var run: ClosedRange<Int>
            var task: Task<LLMClient.Reply, Error>
        }
        var ahead: [Int: [Ahead]] = [:]
        var aheadCount = 0
        var aheadCost = 0
        let budget = tokenBudget
        var nextAhead = 0  // position in `selected` to look ahead from
        let lanes = maxConcurrentRequests
        defer { for list in ahead.values { for a in list { a.task.cancel() } } }
        /// Starts the requests of the paragraphs after position `pos`, planned against the cache as it is now,
        /// until `lanes` are busy (the request awaited counts as one).
        /// `awaiting`: the token cost of the request being awaited.
        func fillAhead(from pos: Int, awaiting: Int) {
            guard lanes > 1, control?.isStopped != true else { return }
            var k = max(nextAhead, pos + 1)
            var full = false
            while !full, k < selected.count, aheadCount < lanes - 1 {
                let p = selected[k]
                guard ahead[p] == nil, let pl = plan(p) else { k += 1; continue }
                let runs = Self.missingRuns(units(pl), sentences: pl.sentences, cursor: scope.cursor)
                var list: [Ahead] = []
                for run in runs {
                    let r = NSUnionRange(pl.sentences[run.lowerBound], pl.sentences[run.upperBound])
                    let span = ns.substring(with: r)
                    let cost = Self.tokenCost(span)
                    guard aheadCount + list.count < lanes - 1, awaiting + aheadCost + cost <= budget else { full = true; break }
                    aheadCost += cost
                    list.append(Ahead(span: span, spanRange: r, run: run,
                                      task: Task { try await client.correct(span, system: system) }))
                }
                // A paragraph that got none of its requests is looked at again next time.
                if list.isEmpty, full { break }
                aheadCount += list.count
                ahead[p] = list
                k += 1
            }
            nextAhead = k
        }
        /// Awaits `task` for `span`; nil when the request failed for this text only (not cached, no fixes).
        func reply(_ span: String, _ task: Task<LLMClient.Reply, Error>) async throws -> LLMClient.Reply? {
            control?.setInFlight(span)
            defer { control?.setInFlight(nil) }
            requests += 1
            do {
                let r = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                return r.truncated ? nil : r
            } catch let e as LLMClient.Failure {
                if e.fatal { throw e }
                return nil
            }
        }

        for (pos, p) in selected.enumerated() {
            let pr = paragraphs[p]
            if pr.length > maxChunkLength { skipped += 1; covered.append(pr); continue }
            // A paragraph inside a code block: nothing the model may change.
            if ProtectedTokens.covers(protected, pr) { covered.append(pr); continue }
            // Sentences that aren't English: never sent, never cached, and no edits inside them.
            guard let pl = plan(p) else { foreignChunks += 1; covered.append(pr); continue }
            let sentences = pl.sentences, foreign = pl.foreign
            func resolveUnits() -> [Unit] { units(pl) }
            var failed = Set<Int>()  // sentence indices whose request failed in this pass (not cached)

            var asked = false
            // Taken one at a time, so a stop or a fatal error leaves the rest in `ahead` for the defer to cancel.
            while let a = ahead[p]?.first {
                ahead[p]!.removeFirst()
                aheadCount -= 1
                aheadCost -= Self.tokenCost(a.span)
                if control?.isStopped == true { a.task.cancel(); throw CancellationError() }
                fillAhead(from: pos, awaiting: Self.tokenCost(a.span))
                asked = true
                guard let r = try await reply(a.span, a.task) else { failed.formUnion(a.run); continue }
                store(PostFilter.judge(input: a.span, rawOutput: r.text), span: a.spanRange, run: a.run,
                      sentences: sentences, ns: ns, variant: options.variant)
            }
            var units = resolveUnits()
            for run in Self.missingRuns(units, sentences: sentences, cursor: scope.cursor) where failed.isDisjoint(with: run) {
                if control?.isStopped == true { throw CancellationError() }
                try Task.checkCancellation()
                let spanRange = NSUnionRange(sentences[run.lowerBound], sentences[run.upperBound])
                let span = ns.substring(with: spanRange)
                let task = Task { try await client.correct(span, system: system) }
                fillAhead(from: pos, awaiting: Self.tokenCost(span))
                asked = true
                guard let r = try await reply(span, task) else { failed.formUnion(run); continue }
                store(PostFilter.judge(input: span, rawOutput: r.text), span: spanRange, run: run,
                      sentences: sentences, ns: ns, variant: options.variant)
            }
            if asked { units = resolveUnits() }

            // The paragraph as the model would have it: cached corrections, everything else as written.
            var corrected = ""
            var pos = pr.location
            var unusable = false
            // Each unit's text as written and as it goes into `corrected` (as written unless corrected).
            let unitRanges = units.map { NSUnionRange(sentences[$0.sentences.lowerBound], sentences[$0.sentences.upperBound]) }
            let written = unitRanges.map { ns.substring(with: $0) }
            let fixed = units.indices.map { i -> String in
                if case .corrected(let t)? = units[i].entry { return t }
                return written[i]
            }
            for (i, u) in units.enumerated() {
                let r = unitRanges[i]
                corrected += ns.substring(with: NSRange(location: pos, length: r.location - pos))
                switch u.entry {
                case .corrected(let t)?:
                    corrected += i + 1 < units.count
                        ? Self.keepingSentenceEnd(written[i], t, nextWritten: written[i + 1], nextFixed: fixed[i + 1])
                        : t
                case .rejected?: unusable = true; corrected += ns.substring(with: r)
                case nil:
                    if !failed.isDisjoint(with: u.sentences) { unusable = true }
                    corrected += ns.substring(with: r)
                }
                pos = NSMaxRange(r)
            }
            corrected += ns.substring(with: NSRange(location: pos, length: NSMaxRange(pr) - pos))
            if unusable { rejected += 1 }
            let chunk = ns.substring(with: pr)
            if corrected != chunk {
                let foreignRanges = foreign.sorted().map {
                    NSRange(location: sentences[$0].location - pr.location, length: sentences[$0].length)
                }
                let typed = scope.typing ? scope.cursor.flatMap { Self.wordBeingTyped(in: ns, caret: $0) } : nil
                found[p] = ProofreadEngine.edits(chunk: chunk, corrected: corrected, options: options,
                                                 protected: ProtectedTokens.clip(protected, to: pr), foreign: foreignRanges)
                    .map { var e = $0; e.range.location += pr.location; return e }
                    .filter { e in typed.map { !Self.touchesWord(e.range, $0) } ?? true }
            }
            covered.append(pr)
            partial?(result(complete: false))
        }
        return result(complete: true)
    }

    // MARK: Paragraph order and scope

    /// Paragraph indices to check, in order: the cursor's paragraph first, then by distance from the cursor
    /// (text order without a cursor), limited by `scope.visible` and `scope.maxLength`.
    static func order(_ paragraphs: [NSRange], scope: Scope) -> [Int] {
        func distance(_ r: NSRange, _ c: Int) -> Int {
            c < r.location ? r.location - c : max(0, c - NSMaxRange(r))
        }
        var idx = Array(paragraphs.indices)
        if let c = scope.cursor {
            idx.sort { (distance(paragraphs[$0], c), $0) < (distance(paragraphs[$1], c), $1) }
        }
        let cursorPara = scope.cursor.flatMap { c in idx.first.flatMap { distance(paragraphs[$0], c) == 0 ? $0 : nil } }
        if let v = scope.visible {
            idx = idx.filter { i in
                let r = paragraphs[i]
                return i == cursorPara || (r.location <= NSMaxRange(v) && v.location <= NSMaxRange(r))
            }
        }
        var out: [Int] = [], total = 0
        for i in idx {
            let len = paragraphs[i].length
            if !out.isEmpty, i != cursorPara, len > scope.maxLength - total { break }
            out.append(i)
            total += len
        }
        return out
    }

    // MARK: Sentences and units

    /// Trimmed sentence ranges (absolute UTF-16) inside paragraph `range`. Together they hold every
    /// non-space character of the paragraph; only the whitespace between them is left out.
    static func sentences(in ns: NSString, range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        ns.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, r, _, _ in
            if let t = trimmed(ns, r) { out.append(t) }
        }
        // Whatever the tokenizer left out (it shouldn't) would be missed by the check: fall back to one unit.
        let visible = ns.substring(with: range).filter { !$0.isWhitespace }.utf16.count
        let inSentences = out.map { ns.substring(with: $0).filter { !$0.isWhitespace }.utf16.count }.reduce(0, +)
        if out.isEmpty || inSentences != visible { return [range] }
        return out
    }

    static func trimmed(_ ns: NSString, _ r: NSRange) -> NSRange? {
        var lo = r.location, hi = NSMaxRange(r)
        let ws = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool { UnicodeScalar(ns.character(at: i)).map(ws.contains) ?? false }
        while lo < hi, isSpace(lo) { lo += 1 }
        while hi > lo, isSpace(hi - 1) { hi -= 1 }
        return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
    }

    struct Unit: Equatable {
        /// Sentence indices (inclusive).
        var sentences: ClosedRange<Int>
        /// The cached result; nil when the model hasn't seen this text yet.
        var entry: Cache.Entry?
    }

    /// Splits the paragraph's sentences into units: a cached sentence, a cached run of sentences (a fix
    /// joined them), or a sentence not in the cache.
    func resolve(_ sentences: [NSRange], ns: NSString, variant: EnglishVariant) -> [Unit] {
        var units: [Unit] = []
        var i = 0
        while i < sentences.count {
            var hit: Unit?
            for j in i..<min(sentences.count, i + Self.maxUnitSentences) {
                let text = ns.substring(with: NSUnionRange(sentences[i], sentences[j]))
                if let e = cache.get(Cache.Key(variant: variant, text: text)) { hit = Unit(sentences: i...j, entry: e); break }
            }
            units.append(hit ?? Unit(sentences: i...i, entry: nil))
            i = units.last!.sentences.upperBound + 1
        }
        return units
    }

    /// The word the caret sits right after (letters, digits, apostrophes, hyphens), when nothing word-like
    /// follows the caret: the word that may still be being typed. Nil when the caret is after a space or
    /// punctuation, or inside a word.
    static func wordBeingTyped(in ns: NSString, caret: Int) -> NSRange? {
        guard caret > 0, caret <= ns.length else { return nil }
        func isWord(_ i: Int) -> Bool {
            guard let u = UnicodeScalar(ns.character(at: i)) else { return true }  // a surrogate half: emoji or rare letter
            return CharacterSet.alphanumerics.contains(u) || "'’-_".unicodeScalars.contains(u)
        }
        guard isWord(caret - 1), caret == ns.length || !isWord(caret) else { return nil }
        var start = caret - 1
        while start > 0, isWord(start - 1) { start -= 1 }
        return NSRange(location: start, length: caret - start)
    }

    /// True when an edit's range changes the word or adds text right next to it.
    static func touchesWord(_ range: NSRange, _ word: NSRange) -> Bool {
        range.location <= NSMaxRange(word) && NSMaxRange(range) >= word.location
    }

    /// A cached unit's correction with its sentence end put back when the model dropped it but the next
    /// sentence still starts as written. Dropping the period only makes sense together with a change at the
    /// next sentence's start ("product. like" → "product like"); the cache keeps each sentence's half of such
    /// a fix on its own, so once the next sentence changes and is checked again, the dropped period would
    /// otherwise come back alone ("product. Like" → "product Like"). `written`/`fixed`: the unit as written
    /// and as cached; `nextWritten`/`nextFixed`: the unit after it in the same paragraph.
    static func keepingSentenceEnd(_ written: String, _ fixed: String, nextWritten: String, nextFixed: String) -> String {
        // The next sentence's start changed too ("Like" → "like", "\"Like" → "\"like"): a real join, leave it.
        // Compared on the first letter or digit, so a leading quote or bracket doesn't hide the change.
        let a = nextWritten.first { $0.isLetter || $0.isNumber }
        let b = nextFixed.first { $0.isLetter || $0.isNumber }
        guard let first = a, b == first else { return fixed }
        return restoringEnd(written, fixed)
    }

    /// `fixed` with the sentence end of `written` put back when the model dropped it (or put a comma or
    /// semicolon in its place). Used when a unit is cached: a unit never ends inside a join (`store` joins the
    /// sentences a fix spans), so a dropped end there is never part of a fix. Otherwise the cache would keep
    /// it, and a later reply for the next sentence that lowercases its start would turn it into a join the
    /// model never proposed ("early. Then" → "early then").
    static func restoringEnd(_ written: String, _ fixed: String) -> String {
        let enders = CharacterSet(charactersIn: ".!?…")
        let w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let ending = String(String.UnicodeScalarView(w.unicodeScalars.reversed().prefix { enders.contains($0) }.reversed()))
        guard !ending.isEmpty else { return fixed }
        // Trailing whitespace of the correction stays where it is.
        let body = fixed.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let tail = String(fixed.dropFirst(body.count))
        guard let last = body.unicodeScalars.last, !enders.contains(last) else { return fixed }
        // A comma or semicolon the model put in place of the period goes too.
        let kept = body.replacingOccurrences(of: "[,;:]+$", with: "", options: .regularExpression)
        return kept + ending + tail
    }

    /// Runs of uncached sentences next to each other: one request each. The run at (or nearest) the
    /// cursor goes first.
    static func missingRuns(_ units: [Unit], sentences: [NSRange], cursor: Int?) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for u in units where u.entry == nil {
            if let last = runs.last, last.upperBound + 1 == u.sentences.lowerBound {
                runs[runs.count - 1] = last.lowerBound...u.sentences.upperBound
            } else {
                runs.append(u.sentences)
            }
        }
        guard let c = cursor else { return runs }
        func distance(_ run: ClosedRange<Int>) -> Int {
            let r = NSUnionRange(sentences[run.lowerBound], sentences[run.upperBound])
            return c < r.location ? r.location - c : max(0, c - NSMaxRange(r))
        }
        return runs.enumerated().sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }.map(\.element)
    }

    /// Caches the judged reply for one run. A correction is split back into its sentences; sentences that a
    /// single fix spans are cached together as one unit. An entry already in the cache stays: a request started
    /// ahead (`maxConcurrentRequests`) may cover a sentence another paragraph cached meanwhile, and a reply
    /// rejected because of some other sentence must not wipe its good result.
    func store(_ verdict: PostFilter.Verdict, span: NSRange, run: ClosedRange<Int>, sentences: [NSRange],
               ns: NSString, variant: EnglishVariant) {
        func put(_ r: NSRange, _ e: Cache.Entry) {
            let key = Cache.Key(variant: variant, text: ns.substring(with: r))
            guard !cache.contains(key) else { return }
            cache.set(key, e, capacity: cacheCapacity)
        }
        switch verdict {
        case .unchanged:
            for i in run { put(sentences[i], .corrected(ns.substring(with: sentences[i]))) }
        case .rejected:
            // Which sentence made the reply unusable isn't known: each gives no fixes until it changes.
            for i in run { put(sentences[i], .rejected) }
        case .corrected(let fixed):
            let spanText = ns.substring(with: span)
            // Relative to the span.
            let local = run.map { NSRange(location: sentences[$0].location - span.location, length: sentences[$0].length) }
            // Merged: changes one space apart are one edit, so a change at a sentence's end together with one
            // at the next sentence's start ("product. Like" → "product like") is one edit across the boundary.
            // Cached apart, each half would later come back alone ("product. Like" → "product Like").
            let edits = Diff.edits(from: spanText, to: fixed, merge: true)
            // Each edit belongs to the sentences it touches (first...last); an edit in the space between
            // two sentences, or across it, joins them into one unit.
            var joinsNext = [Bool](repeating: false, count: local.count)
            var owner: [Int] = []  // edit index → its first sentence
            for e in edits {
                let start = e.range.location, end = NSMaxRange(e.range)
                let first = local.lastIndex { $0.location <= start } ?? 0
                let last = max(first, local.firstIndex { NSMaxRange($0) >= end } ?? local.count - 1)
                for k in first..<last { joinsNext[k] = true }
                owner.append(first)
            }
            // Two edits with only spaces, quotes or brackets between them, in neighbouring sentences, are one
            // join too ("left. \"Like" → "left, \"like": the quote keeps the diff from merging them).
            let spanNS = spanText as NSString
            for (e, f) in zip(edits, edits.dropFirst()) {
                let gap = NSRange(location: NSMaxRange(e.range), length: f.range.location - NSMaxRange(e.range))
                guard gap.length >= 0, NSMaxRange(gap) <= spanNS.length,
                      spanNS.substring(with: gap).allSatisfy({ !$0.isLetter && !$0.isNumber }) else { continue }
                let a = local.firstIndex { NSMaxRange($0) >= NSMaxRange(e.range) } ?? local.count - 1
                let b = local.lastIndex { $0.location <= f.range.location } ?? 0
                for k in a..<max(a, b) { joinsNext[k] = true }
            }
            var k = 0
            while k < local.count {
                var m = k
                while m + 1 < local.count, joinsNext[m] { m += 1 }
                let unit = NSUnionRange(local[k], local[m])
                let inside = edits.indices.filter { (k...m).contains(owner[$0]) }
                    .map { var e = edits[$0]; e.range.location -= unit.location; return e }
                let original = (spanText as NSString).substring(with: unit)
                let abs = NSRange(location: unit.location + span.location, length: unit.length)
                put(abs, .corrected(Self.restoringEnd(original, Diff.apply(inside, to: original))))
                k = m + 1
            }
        }
    }

    // MARK: Cache

    struct Cache {
        struct Key: Hashable {
            var variant: EnglishVariant
            var text: String
        }

        enum Entry: Equatable {
            /// The model's text for the unit after `PostFilter.judge`; equal to the original when unchanged.
            case corrected(String)
            /// The reply was unusable: no fixes until the text changes.
            case rejected
        }

        private var map: [Key: (entry: Entry, used: Int)] = [:]
        private var clock = 0

        var count: Int { map.count }

        func contains(_ key: Key) -> Bool { map[key] != nil }

        mutating func get(_ key: Key) -> Entry? {
            guard let hit = map[key] else { return nil }
            clock += 1
            map[key] = (hit.entry, clock)
            return hit.entry
        }

        mutating func set(_ key: Key, _ entry: Entry, capacity: Int) {
            clock += 1
            map[key] = (entry, clock)
            guard map.count > capacity else { return }
            let drop = map.sorted { $0.value.used < $1.value.used }.prefix(max(1, map.count / 4)).map(\.key)
            for k in drop { map.removeValue(forKey: k) }
        }

        mutating func removeAll() { map.removeAll() }
    }
}

/// Shared between a `CheckScheduler` and the pass it started: the scheduler stops the pass when the text
/// changes, and reads which text the pass is waiting on, to cancel that request when the text is gone.
public final class PassControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var inFlight: String?

    public init() {}

    public var isStopped: Bool { lock.withLock { stopped } }
    public func stop() { lock.withLock { stopped = true } }

    /// The text of the request the pass is waiting on, if any.
    public var inFlightText: String? { lock.withLock { inFlight } }
    func setInFlight(_ text: String?) { lock.withLock { inFlight = text } }
}

/// Runs `CheckPipeline` passes as the user types: waits for a typing pause, runs one pass at a time,
/// and drops passes for text that's gone.
///
/// - Each `textChanged` restarts the pause timer (`delay`, ~600 ms).
/// - A running pass is stopped before its next request. The request it's waiting on is cancelled too
///   when its text is no longer in the field (the user edited that sentence); otherwise it finishes and
///   its result is cached for the next pass.
/// - `onUpdate` gets partial results after each paragraph and a final one (`done`). It's called off the
///   main thread. The receiver must still check that `Update.text` is the field's current text before
///   showing anything: an update can race with the next keystroke.
public actor CheckScheduler {
    public struct Update: Sendable {
        /// Increases with every `textChanged`, `checkNow` and `cancel`; only the latest matters.
        public var generation: Int
        /// The text the result's ranges refer to.
        public var text: String
        public var result: CheckPipeline.Result?
        /// A check that failed as a whole (server down, bad key).
        public var error: String?
        /// True for the last update of a pass.
        public var done: Bool
    }

    public let pipeline: CheckPipeline
    public let delay: Duration
    private let onUpdate: @Sendable (Update) -> Void
    private var generation = 0
    private var debounce: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var control: PassControl?

    public init(pipeline: CheckPipeline, delay: Duration = .milliseconds(600),
                onUpdate: @escaping @Sendable (Update) -> Void) {
        self.pipeline = pipeline
        self.delay = delay
        self.onUpdate = onUpdate
    }

    /// The field's text changed: check it after a typing pause.
    public func textChanged(_ text: String, scope: CheckPipeline.Scope = .init()) {
        schedule(text, scope: scope, after: delay)
    }

    /// Check now, without waiting for a pause (focus moved to a field, the hotkey).
    public func checkNow(_ text: String, scope: CheckPipeline.Scope = .init()) {
        schedule(text, scope: scope, after: .zero)
    }

    /// Stop everything (the field lost focus, the app was paused). Cancels the request in flight.
    public func cancel() {
        generation += 1
        debounce?.cancel()
        debounce = nil
        control?.stop()
        pass?.cancel()
    }

    public var currentGeneration: Int { generation }

    private func schedule(_ text: String, scope: CheckPipeline.Scope, after wait: Duration) {
        generation += 1
        let gen = generation
        debounce?.cancel()
        if let control {
            control.stop()
            if let waiting = control.inFlightText, !text.contains(waiting) { pass?.cancel() }
        }
        debounce = Task { [weak self] in
            if wait > .zero {
                do { try await Task.sleep(for: wait) } catch { return }
            }
            await self?.start(gen, text: text, scope: scope)
        }
    }

    private func start(_ gen: Int, text: String, scope: CheckPipeline.Scope) {
        guard gen == generation else { return }
        let previous = pass
        let control = PassControl()
        self.control = control
        pass = Task { [pipeline, onUpdate] in
            // One pass at a time: a stopped pass ends after its current request.
            await previous?.value
            guard !control.isStopped, !Task.isCancelled else { return }
            do {
                let r = try await pipeline.check(text, scope: scope, control: control) { partial in
                    if !control.isStopped { onUpdate(Update(generation: gen, text: text, result: partial, error: nil, done: false)) }
                }
                if !control.isStopped {
                    onUpdate(Update(generation: gen, text: text, result: r, error: nil, done: true))
                }
            } catch {
                // Stopped or cancelled passes end quietly; anything else is a real failure.
                if !control.isStopped, !Task.isCancelled {
                    onUpdate(Update(generation: gen, text: text, result: nil,
                                    error: error.localizedDescription, done: true))
                }
            }
        }
    }
}
