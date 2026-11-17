import Foundation

/// Post-filters for the settings in `CheckOptions` (design_code.md §8.2, §8.4) and for what the prompt
/// asks the model to keep. They run after `PostFilter.judge`, and only ever drop or shrink changes, never
/// add text.
///
/// - `casualText` (casual mode) restyles the model's whole corrected text before the diff.
/// - `apply` filters the diff's edits: protected tokens → US/UK respelling (`SpellingVariant`) → chat slang
///   → British collective nouns (UK) → casual lowercase starts → check level.
public enum EditFilter {
    /// The edits of one chunk with the settings applied. `protected`: protected ranges relative to `chunk`.
    public static func apply(_ edits: [Edit], in chunk: String, options: CheckOptions, protected: [NSRange]) -> [Edit] {
        edits.flatMap { e -> [Edit] in
            if options.protectTokens, ProtectedTokens.touches(e.range, protected) { return [] }
            guard var e = SpellingVariant.restore(e) else { return [] }
            if expandsSlang(e) { return [] }
            if options.variant == .uk, singularizesCollective(e, in: chunk) { return [] }
            if options.casual {
                guard let c = keepLowercaseStarts(e) else { return [] }
                e = c
            }
            return filter(e, level: options.level, in: chunk)
        }
    }

    /// The edit, or the parts of it that belong to `level`. The diff merges changes one space apart
    /// ("definately has" → "definitely have"), so each part is classified on its own.
    static func filter(_ edit: Edit, level: CheckLevel, in chunk: String) -> [Edit] {
        if level == .full { return [edit] }
        let parts = Diff.edits(from: edit.original, to: edit.replacement, merge: false).map { p -> Edit in
            var p = p
            p.range.location += edit.range.location
            return p
        }
        guard parts.count > 1 else { return allows(edit, level: level, in: chunk) ? [edit] : [] }
        let kept = parts.filter { allows($0, level: level, in: chunk) }
        return kept.count == parts.count ? [edit] : kept
    }

    // MARK: Chat slang

    /// Chat abbreviations the prompt asks the model to keep ("Keep casual style, slang"). An edit that only
    /// spells one out ("u" → "you", "lmk" → "let me know", "thx" → "thanks") is dropped, in any app.
    static let slang: Set<String> = [
        "u", "ur", "r", "y", "k", "kk", "ok", "thx", "thnx", "thanx", "ty", "tysm", "pls", "plz", "lmk", "brb", "np",
        "btw", "imo", "imho", "idk", "tbh", "fyi", "asap", "omg", "lol", "lmao", "rofl", "gm", "gn", "gg", "nvm",
        "jk", "rn", "tho", "cuz", "bc", "ya", "yea", "yep", "yup", "nope", "gonna", "wanna", "gotta", "dunno",
        "kinda", "sorta", "abt", "msg", "pic", "pics", "convo", "tmrw", "tmr", "b4", "gr8", "sry", "ppl", "smth",
        "sth", "obv", "obvs", "prob", "probs", "def", "eod", "eta", "afaik", "iirc", "hbu", "wbu", "ikr", "smh",
        "fr", "ngl", "atm", "irl", "dm", "ooo", "wfh", "ttyl", "cya", "l8r", "w8", "2day", "2nite", "bday", "congrats",
    ]

    /// The edit replaces chat slang words with something else (and changes nothing but those words).
    static func expandsSlang(_ edit: Edit) -> Bool {
        let words = edit.original.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
        return !words.isEmpty && words.allSatisfy { slang.contains($0) }
            && edit.replacement.lowercased().trimmingCharacters(in: .whitespaces)
                != edit.original.lowercased().trimmingCharacters(in: .whitespaces)
    }

    // MARK: British collective nouns

    /// Nouns that take a plural verb in British English ("the team are").
    static let collectiveNouns: Set<String> = [
        "team", "staff", "government", "family", "company", "committee", "board", "band", "crew", "audience",
        "management", "council", "jury", "group", "club", "public", "class", "department", "firm", "squad",
        "orchestra", "choir", "party", "press", "union", "majority", "minority", "school", "university",
    ]

    /// With UK English: the edit only makes the verb after a collective noun singular ("the team are" → "is"),
    /// which is correct British usage. E2B does it even with the UK prompt.
    static func singularizesCollective(_ edit: Edit, in chunk: String) -> Bool {
        let pairs: Set<String> = ["are|is", "were|was", "have|has", "are|'s", "aren't|isn't", "weren't|wasn't", "haven't|hasn't"]
        let o = FixClassifier.trimmed(edit.original).lowercased(), r = FixClassifier.trimmed(edit.replacement).lowercased()
        guard pairs.contains(o + "|" + r.replacingOccurrences(of: "’", with: "'")) else { return false }
        let ns = chunk as NSString
        guard edit.range.location <= ns.length,
              let before = FixClassifier.lastWord(ns.substring(to: edit.range.location)) else { return false }
        return collectiveNouns.contains(before.lowercased())
    }

    // MARK: Casual

    static let punctuation = CharacterSet(charactersIn: ".,!?;:…—–")

    /// Casual mode on the model's whole corrected text: words whose case alone changed keep the writer's
    /// case ("i" stays "i", "brb" stays "brb"), and punctuation the model added or removed is put back as
    /// written (no added final periods, commas after "lol", question marks). Word fixes stay.
    public static func casualText(original: String, corrected: String) -> String {
        let a = Diff.tokenize(original), b = Diff.tokenize(corrected)
        func isPunct(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { punctuation.contains($0) } }
        var out = ""
        for op in Diff.align(a, b, ignoringCase: true) {
            switch op {
            case .same(let i, _): out += a[i].text
            case .del(let i): if isPunct(a[i].text) { out += a[i].text }
            case .ins(let j): if !isPunct(b[j].text) { out += b[j].text }
            }
        }
        return out
    }

    /// Casual mode on one edit: a word the model fixed and capitalized keeps the writer's lowercase start
    /// ("teh" → "The" becomes "teh" → "the"). Per word when the word counts match, otherwise the first word.
    /// Nil when nothing is left to change.
    static func keepLowercaseStarts(_ edit: Edit) -> Edit? {
        var e = edit
        let a = Diff.tokenize(e.original), b = Diff.tokenize(e.replacement)
        if a.count == b.count {
            e.replacement = zip(a, b).map { lowerFirst($1.text, like: $0.text) }.joined()
        } else if let first = b.first, let orig = a.first {
            e.replacement = lowerFirst(first.text, like: orig.text) + b.dropFirst().map(\.text).joined()
        }
        return e.replacement == e.original ? nil : e
    }

    /// `word` with its first letter lowercased when `original` starts with the same letter in lowercase.
    static func lowerFirst(_ word: String, like original: String) -> String {
        guard let w = word.first, let o = original.first, w.isUppercase, o.isLowercase,
              String(w).lowercased() == String(o) else { return word }
        return String(o) + word.dropFirst()
    }

    // MARK: Check level

    /// True when the edit belongs to `level` (design_code.md §8.2 "Check for"), using `FixClassifier`:
    /// - full: every edit;
    /// - grammar: all but punctuation-only edits that leave the words alone (an added comma or period);
    /// - spelling: spelling (typos, capitalization), repeated words, and apostrophes inside a word that
    ///   aren't a grammar pair ("dont" → "don't" yes, "its" → "it's" no).
    public static func allows(_ edit: Edit, level: CheckLevel, in chunk: String) -> Bool {
        if level == .full { return true }
        let category = FixClassifier.classify(edit, in: chunk)
        let wordsOnly = category == .punctuation && wordKey(edit.original) == wordKey(edit.replacement)
        switch level {
        case .full: return true
        case .grammar: return !wordsOnly
        case .spelling:
            switch category {
            case .spelling, .clarity: return true
            case .punctuation: return !wordsOnly && !FixClassifier.isGrammarPair(edit.original, edit.replacement)
            case .grammar, .rewrite: return false
            }
        }
    }

    /// Lowercased letters, digits and apostrophes: what's left when commas, periods and spacing are ignored.
    static func wordKey(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "'’")
        return String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { allowed.contains($0) }))
            .replacingOccurrences(of: "’", with: "'")
    }
}
