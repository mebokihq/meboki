import Foundation

/// Splits text into checkable chunks, asks the model, filters, and returns edits
/// with ranges relative to the full input text.
public struct ProofreadEngine: Sendable {
    public var client: any Corrector
    /// The check's settings. `options.variant` picks the session's system prompt; the rest are edit filters.
    public var options: CheckOptions
    /// Paragraphs longer than this (UTF-16 units) are skipped. With the output cap
    /// (`LLMClient.maxTokens`) and the ~200-token prompt this stays inside the server's 8192-token context.
    public var maxChunkLength = 3000

    public init(client: any Corrector, options: CheckOptions = CheckOptions()) {
        self.client = client
        self.options = options
    }

    public struct Result: Sendable {
        public var edits: [Edit]
        /// Paragraphs whose model reply was unusable (too different, cut off, or a server error).
        public var rejectedChunks: Int
        /// Paragraphs too long to check.
        public var skippedChunks: Int
        /// Paragraphs not sent because they aren't in English (`LanguageGate`). A foreign sentence inside an
        /// English paragraph isn't counted.
        public var foreignChunks: Int = 0
    }

    /// Chunk = one paragraph (line), trimmed. Returns UTF-16 ranges relative to `text`.
    public static func chunks(of text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { sub, range, _, _ in
            guard let sub, sub.rangeOfCharacter(from: .letters) != nil else { return }
            // Trim surrounding whitespace so edits don't touch indentation.
            let lead = sub.prefix(while: { $0.isWhitespace }).utf16.count
            let trail = String(sub.reversed().prefix(while: { $0.isWhitespace })).utf16.count
            out.append(NSRange(location: range.location + lead, length: range.length - lead - trail))
        }
        return out
    }

    public enum ChunkOutcome: Equatable, Sendable {
        case unchanged
        case rejected(reason: String)
        /// Edits relative to the chunk.
        case edits([Edit])
    }

    /// Everything after the model for one chunk: clean and judge the reply (`PostFilter`), diff it, and apply
    /// the settings' edit filters (`EditFilter`). `protected`: protected ranges relative to `chunk`; nil
    /// finds them in the chunk. Also used by `eval/filter` to score the settings on recorded model replies.
    public static func process(chunk: String, rawOutput: String, options: CheckOptions,
                               protected: [NSRange]? = nil) -> ChunkOutcome {
        switch PostFilter.judge(input: chunk, rawOutput: rawOutput) {
        case .unchanged: return .unchanged
        case .rejected(let reason): return .rejected(reason: reason)
        case .corrected(let fixed):
            let edits = Self.edits(chunk: chunk, corrected: fixed, options: options, protected: protected)
            return edits.isEmpty ? .unchanged : .edits(edits)
        }
    }

    /// The part of `process` after `PostFilter.judge`: casual mode, diff, and the settings' edit filters on a
    /// corrected text the judge already accepted. `CheckPipeline` runs it on a paragraph it put together from
    /// cached sentences, so both paths filter the same way. `foreign`: ranges relative to `chunk` that aren't
    /// English (`LanguageGate`); edits that touch them are dropped whatever the settings.
    public static func edits(chunk: String, corrected fixed: String, options: CheckOptions,
                             protected: [NSRange]? = nil, foreign: [NSRange] = []) -> [Edit] {
        let styled = EditFilter.keepingStyle(original: chunk, corrected: fixed)
        let target = options.casual ? EditFilter.casualText(original: chunk, corrected: styled) : styled
        let raw = Diff.edits(from: chunk, to: target).filter { !ProtectedTokens.touches($0.range, foreign) }
        let prot = options.protectTokens ? (protected ?? ProtectedTokens.ranges(in: chunk)) : []
        let kept = EditFilter.apply(raw, in: chunk, options: options, protected: prot)
        return options.groupRewrites ? RewriteDetector.group(kept, in: chunk) : kept
    }

    /// `protectBlocks`: runs of code lines in the text are protected too (off for a selection).
    public func check(_ text: String, protectBlocks: Bool = true,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Result {
        let ns = text as NSString
        let ranges = Self.chunks(of: text)
        // Found on the whole text, so a fenced code block across paragraphs is seen as one.
        let blocks = options.protectTokens && protectBlocks ? CodeDetector.blocks(in: text) : []
        let protected = options.protectTokens ? ProtectedTokens.ranges(in: text, extra: blocks) : []
        let system = Prompt.system(for: options.variant)
        let blanked = options.englishOnly ? LanguageGate.blanked(text, extra: blocks) : ns
        var edits: [Edit] = []
        var rejected = 0, skipped = 0, foreign = 0
        for (i, p) in ranges.enumerated() {
            try Task.checkCancellation()
            progress?(i, ranges.count)
            if p.length > maxChunkLength { skipped += 1; continue }
            // A paragraph inside a code block: nothing the model may change.
            if ProtectedTokens.covers(protected, p) { continue }
            // Text that isn't English never goes to the model. A paragraph with foreign sentences is sent as
            // its English runs, one request each: what `CheckPipeline` sends with an empty cache.
            var parts = [p]
            if options.englishOnly {
                let sentences = CheckPipeline.sentences(in: ns, range: p)
                let other = LanguageGate.foreignSentences(paragraph: p, sentences: sentences, blanked: blanked,
                                                          isForeign: { LanguageGate.foreignLanguage($0) != nil })
                if other.count == sentences.count { foreign += 1; continue }
                if !other.isEmpty { parts = LanguageGate.englishRuns(sentences, foreign: other) }
            }
            for r in parts {
                let chunk = ns.substring(with: r)
                let reply: LLMClient.Reply
                do {
                    reply = try await client.correct(chunk, system: system)
                } catch let e as LLMClient.Failure {
                    // A bad key or an unknown model fails every paragraph: stop with the reason.
                    if e.fatal { throw e }
                    // A bad reply for one paragraph (e.g. HTTP 400) shouldn't fail the others.
                    rejected += 1
                    continue
                }
                if reply.truncated { rejected += 1; continue }
                switch Self.process(chunk: chunk, rawOutput: reply.text, options: options,
                                    protected: ProtectedTokens.clip(protected, to: r)) {
                case .unchanged: break
                case .rejected: rejected += 1
                case .edits(let found):
                    for var e in found {
                        e.range.location += r.location
                        edits.append(e)
                    }
                }
            }
        }
        progress?(ranges.count, ranges.count)
        return Result(edits: edits, rejectedChunks: rejected, skippedChunks: skipped, foreignChunks: foreign)
    }
}
