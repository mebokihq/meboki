import Foundation

/// Post-filters for the settings in `CheckOptions` (design_code.md §8.2, §8.4) and for what the prompt
/// asks the model to keep. They run after `PostFilter.judge`, and only ever drop or shrink changes, never
/// add text.
///
/// - `casualText` (casual mode) restyles the model's whole corrected text before the diff.
/// - `apply` filters the diff's edits: changes that are never right (`dropNoise`: numbers, quote style,
///   spacing) → protected tokens → US/UK respelling (`SpellingVariant`) → chat slang → British collective
///   nouns (UK) → casual lowercase starts → check level.
public enum EditFilter {
    /// The edits of one chunk with the settings applied. `protected`: protected ranges relative to `chunk`.
    public static func apply(_ edits: [Edit], in chunk: String, options: CheckOptions, protected: [NSRange]) -> [Edit] {
        let numbers = numberRanges(in: chunk)
        return edits.flatMap { dropNoise($0, in: chunk, numbers: numbers) }.flatMap { e -> [Edit] in
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
        return keepParts(of: edit, in: chunk) { allows($0, level: level, in: chunk) }
    }

    /// The edit if `keep` takes all its parts (`Diff` with `merge: false`), otherwise the parts it keeps.
    /// The parts of one edit aren't always independent: "10kg " → "10 kg " diffs as "10kg" → "10" plus an
    /// inserted "kg ", and keeping the insertion alone would write "10kg kg". So a kept part that only inserts
    /// or only deletes, with nothing but whitespace between it and a dropped part, is dropped with it.
    static func keepParts(of edit: Edit, in chunk: String, keep: (Edit) -> Bool) -> [Edit] {
        let parts = Diff.edits(from: edit.original, to: edit.replacement, merge: false).map { p -> Edit in
            var p = p
            p.range.location += edit.range.location
            return p
        }
        guard parts.count > 1 else { return keep(edit) ? [edit] : [] }
        var kept = parts.map(keep)
        if kept.allSatisfy({ $0 }) { return [edit] }
        let ns = chunk as NSString
        func onlySpaceBetween(_ a: Edit, _ b: Edit) -> Bool {
            let gap = NSRange(location: NSMaxRange(a.range), length: b.range.location - NSMaxRange(a.range))
            guard gap.length >= 0, NSMaxRange(gap) <= ns.length else { return false }
            return ns.substring(with: gap).allSatisfy(\.isWhitespace)
        }
        func oneSided(_ e: Edit) -> Bool { e.original.isEmpty || e.replacement.isEmpty }
        var changed = true
        while changed {
            changed = false
            for i in parts.indices where kept[i] && oneSided(parts[i]) {
                let left = i > 0 && !kept[i - 1] && onlySpaceBetween(parts[i - 1], parts[i])
                let right = i + 1 < parts.count && !kept[i + 1] && onlySpaceBetween(parts[i], parts[i + 1])
                if left || right { kept[i] = false; changed = true }
            }
        }
        return parts.indices.filter { kept[$0] }.map { parts[$0] }
    }

    // MARK: Noise

    /// The edit without its parts that are never a real fix, with any setting. The diff merges changes one
    /// space apart, so each part is judged on its own (`keepParts`); a part that is noise goes, the others
    /// stay. Spacing next to a number is also judged on the whole edit and on each two neighbouring parts:
    /// "10kg " → "10 kg " diffs as "10kg" → "10" plus an inserted "kg ", and neither part alone is spacing.
    static func dropNoise(_ edit: Edit, in chunk: String, numbers: [NSRange]) -> [Edit] {
        if isSpacingNearNumber(edit, numbers: numbers) { return [] }
        let parts = Diff.edits(from: edit.original, to: edit.replacement, merge: false).map { p -> Edit in
            var p = p
            p.range.location += edit.range.location
            return p
        }
        let ns = chunk as NSString
        var noisy: [Edit] = []
        for (a, b) in zip(parts, parts.dropFirst()) {
            let gap = NSRange(location: NSMaxRange(a.range), length: b.range.location - NSMaxRange(a.range))
            guard gap.length >= 0, NSMaxRange(gap) <= ns.length else { continue }
            let between = ns.substring(with: gap)
            guard between.allSatisfy(\.isWhitespace) else { continue }
            let both = Edit(range: NSUnionRange(a.range, b.range), original: ns.substring(with: NSUnionRange(a.range, b.range)),
                            replacement: a.replacement + between + b.replacement)
            if isSpacingNearNumber(both, numbers: numbers) { noisy += [a, b] }
        }
        // A lowercased sentence start whose ending this fix leaves alone ("early. Then" → "early. then").
        for p in parts {
            if let end = sentenceEndBeforeLowercasedStart(p, in: chunk), !NSLocationInRange(end, edit.range) { noisy.append(p) }
        }
        return keepParts(of: edit, in: chunk) { !noisy.contains($0) && !isNoise($0, in: chunk, numbers: numbers) }
    }

    /// Only spacing changes, and the change has a digit in it or touches a number ("10kg" → "10 kg",
    /// "5pm" → "5 pm", "5 🎉3" → "5 🎉 3").
    static func isSpacingNearNumber(_ e: Edit, numbers: [NSRange]) -> Bool {
        guard e.original != e.replacement,
              e.original.filter({ !$0.isWhitespace }) == e.replacement.filter({ !$0.isWhitespace }) else { return false }
        if e.original.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        return numbers.contains { n in e.range.location <= NSMaxRange(n) && NSMaxRange(e.range) >= n.location }
    }

    /// A change no grammar fix makes:
    /// - digits change ("2" → "two", "1st" → "first", "1,000" → "1,001"), except chat digits used as words
    ///   (`isDigitWord`: "I want 2 go" → "to");
    /// - a number is reformatted: the change cuts into a number or its sign, symbol or separators
    ///   ("500,000" → "500 000", "500,000+" → "500,000", "5-6" → "5–6", "$5" → "5$"); a change that carries
    ///   the whole number over stays ("1990's" → "1990s", "5 year old" → "5-year-old", "In 2024 we" →
    ///   "In 2024, we");
    /// - only spacing changes next to a number ("10kg" → "10 kg", "5pm" → "5 pm");
    /// - an ellipsis is removed ("Wait… we" → "Wait we");
    /// - only the quote, dash or ellipsis style changes ("don't" → "don’t", straight ↔ curly double quotes,
    ///   "-" → "–", "..." → "…"); `keepingStyle` already puts most of these back before the diff;
    /// - only the amount or kind of whitespace changes (two spaces → one, a line break → a space);
    /// - only invisible characters are added or removed (`withoutInvisible`: "ho\u{8}nest" → "honest"): the
    ///   card would show the same word on both sides.
    /// `dropNoise` also drops a lowercased sentence start (`sentenceEndBeforeLowercasedStart`).
    static func isNoise(_ e: Edit, in chunk: String, numbers: [NSRange]) -> Bool {
        if isDigitWord(e, in: chunk) { return false }
        if digits(e.original) != digits(e.replacement) { return true }
        for n in numbers {
            if e.range.length == 0 {
                if n.location < e.range.location && e.range.location < NSMaxRange(n) { return true }
                continue
            }
            guard NSIntersectionRange(e.range, n).length > 0 else { continue }
            // Cut into, or not carried over whole.
            let whole = (chunk as NSString).substring(with: n)
            if NSIntersectionRange(e.range, n) != n || !e.replacement.contains(whole) { return true }
        }
        if isSpacingNearNumber(e, numbers: numbers) { return true }
        if ellipses(e.original) > ellipses(e.replacement) { return true }
        if e.original != e.replacement, withoutInvisible(e.original) == withoutInvisible(e.replacement) { return true }
        // A sign, currency or percent put right next to a number ("$5" → "5$" moves the "$").
        let symbols = CharacterSet(charactersIn: "+-−$€£¥#~%")
        let added = e.replacement.trimmingCharacters(in: .whitespaces)
        if !added.isEmpty, added.unicodeScalars.allSatisfy(symbols.contains),
           numbers.contains(where: { e.range.location == NSMaxRange($0) || NSMaxRange(e.range) == $0.location }) {
            return true
        }
        if foldStyle(e.original) == foldStyle(e.replacement) { return true }
        if collapseSpace(e.original) == collapseSpace(e.replacement) { return true }
        return false
    }

    /// Abbreviations that end with a period but don't end a sentence ("e.g. the", "Dr. smith" stays a fix).
    static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "jr", "sr",
                                             "approx", "incl", "no", "fig", "cf", "al", "p", "pp", "vol", "ch"]

    /// When the edit lowercases the first letter of a sentence that follows ".", "!" or "?" (not an
    /// abbreviation): where that ending is (UTF-16). The lowercasing is noise unless the same fix also changes
    /// that ending (a join: "home. And" → "home, and"), which `dropNoise` checks.
    static func sentenceEndBeforeLowercasedStart(_ e: Edit, in chunk: String) -> Int? {
        guard let o = e.original.first, let r = e.replacement.first, o.isUppercase, r.isLowercase,
              String(o).lowercased() == String(r) else { return nil }
        let ns = chunk as NSString
        let before = ns.substring(to: e.range.location)
        guard before.last?.isWhitespace == true else { return nil }
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = lead.last, ".!?".contains(end) else { return nil }
        let word = lead.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let stem = word.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")).lowercased()
        if end == ".", abbreviations.contains(stem) || stem.contains(".") || stem.count == 1 { return nil }
        return (lead as NSString).length - 1
    }

    /// Chat digits used as words: a lone "2" → "to"/"too" or "4" → "for", with a word after it and a word or
    /// the sentence start before it ("I want 2 go", "thanks 4 the help", "2 much salt").
    static func isDigitWord(_ e: Edit, in chunk: String) -> Bool {
        let o = e.original, r = e.replacement.lowercased()
        guard (o == "2" && (r == "to" || r == "too")) || (o == "4" && r == "for") else { return false }
        let ns = chunk as NSString
        let before = ns.substring(to: e.range.location), after = ns.substring(from: NSMaxRange(e.range))
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceStart = lead.isEmpty || ".!?…".contains(lead.last!)
        let wordBefore = sentenceStart || (before.last == " " && (before.dropLast().last?.isLetter ?? false))
        let wordAfter = after.first == " " && (after.dropFirst().first?.isLetter ?? false)
        return wordBefore && wordAfter
    }

    /// Numbers with their sign or currency, separators and a trailing % or +: "500,000+", "$5", "10:30", "-6", "3/4".
    static func numberRanges(in text: String) -> [NSRange] {
        let re = try! NSRegularExpression(pattern: "[+\\-−$€£¥#~]?\\d+(?:[.,:/]\\d+)*[%+]?")
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    static func digits(_ s: String) -> String { String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init)) }

    /// Quotes, dashes and ellipses in one style each: what's left when only the typography differs.
    static func foldStyle(_ s: String) -> String {
        var t = s
        for c in ["‘", "’", "‛", "′", "`", "´"] { t = t.replacingOccurrences(of: c, with: "'") }
        for c in ["“", "”", "„", "″"] { t = t.replacingOccurrences(of: c, with: "\"") }
        t = t.replacingOccurrences(of: "...", with: "…")
        t = t.replacingOccurrences(of: "--", with: "-")
        for c in ["–", "—", "−", "‐", "‑"] { t = t.replacingOccurrences(of: c, with: "-") }
        return t
    }

    /// `s` without invisible characters: control characters other than whitespace (U+0008), format characters
    /// (zero-width space, soft hyphen, BOM, joiners) and variation selectors.
    static func withoutInvisible(_ s: String) -> String {
        // By category, not `CharacterSet.whitespaces`: that set counts the zero-width space as whitespace.
        String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            if "\n\r\t".unicodeScalars.contains(u) { return true }
            switch u.properties.generalCategory {
            case .control, .format: return false
            default: return !(0xFE00...0xFE0F).contains(u.value)
            }
        }))
    }

    /// Ellipses in `s`: "…" and "..." each count once.
    static func ellipses(_ s: String) -> Int { foldStyle(s).filter { $0 == "…" }.count }

    /// The model's corrected text with the writer's typography put back: a token the model changed only in
    /// quote, dash or ellipsis style ("don't" → "don’t", "\"" → "“", "-" → "–") is taken as written, so that
    /// change never becomes a fix, even next to a real one (`"it" .` → `“it”.` keeps the straight quotes).
    public static func keepingStyle(original: String, corrected: String) -> String {
        let a = Diff.tokenize(original), b = Diff.tokenize(corrected)
        var out = ""
        for op in Diff.align(a, b, key: { foldStyle($0) }) {
            switch op {
            case .same(let i, _): out += a[i].text
            case .del: break
            case .ins(let j): out += b[j].text
            }
        }
        return out
    }

    static func collapseSpace(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
