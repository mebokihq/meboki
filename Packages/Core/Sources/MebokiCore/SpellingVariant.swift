import Foundation

/// British ↔ American spelling pairs. A correctly spelled word is never respelled into the other variant,
/// in either direction and with either English variant selected ("colour" and "color", "organise" and
/// "organize", "math" and "maths" stay as written), as the prompt asks; small models still do it
/// (E4B: "colour" → "color" with the US prompt, "apologize" → "apologise" with the UK prompt). The English
/// variant setting picks the prompt, which steers British usage ("the team are") and new corrections.
///
/// Rules are deliberately narrow (suffix patterns and a word list), so a real typo fix is never mistaken
/// for a respelling: "tollerate" → "tolerate" is not a UK/US pair.
public enum SpellingVariant {
    /// British stem → American stem, matched at the start of the word, so inflections follow
    /// ("cheques" → "checks", "programmes" → "programs").
    static let stems: [(String, String)] = [
        ("grey", "gray"), ("programme", "program"), ("cheque", "check"), ("tyre", "tire"), ("kerb", "curb"),
        ("aluminium", "aluminum"), ("plough", "plow"), ("mould", "mold"), ("smould", "smold"), ("sceptic", "skeptic"),
        ("draught", "draft"), ("cosy", "cozy"), ("cosie", "cozie"), ("pyjama", "pajama"), ("learnt", "learned"),
        ("spelt", "spelled"), ("burnt", "burned"), ("dreamt", "dreamed"), ("judgement", "judgment"),
        ("ageing", "aging"), ("acknowledgement", "acknowledgment"), ("enrolment", "enrollment"),
        ("enrol", "enroll"), ("fulfil", "fulfill"), ("skilful", "skillful"), ("wilful", "willful"),
        ("instalment", "installment"), ("jewellery", "jewelry"), ("manoeuvr", "maneuver"),
        ("defence", "defense"), ("offence", "offense"), ("licence", "license"), ("pretence", "pretense"),
        ("practis", "practic"), ("maths", "math"), ("doughnut", "donut"), ("artefact", "artifact"),
    ]

    /// Lowercased American forms one or two rule steps away from the British `word`.
    static func americanForms(of word: String) -> Set<String> {
        let w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        let one = step(w)
        return one.union(one.flatMap { step($0) })
    }

    /// One rule application at each place it fits.
    static func step(_ w: String) -> Set<String> {
        var out = Set<String>()
        let c = Array(w)
        let vowels = Set("aeiou")
        // colour → color, behaviour → behavior, favourite → favorite (not at the start, words of 5+ letters).
        if c.count >= 5 {
            for i in 1..<(c.count - 2) where c[i] == "o" && c[i + 1] == "u" && c[i + 2] == "r" {
                var d = c; d.remove(at: i + 1); out.insert(String(d))
            }
        }
        // organise → organize, analysed → analyzed, organisation → organization.
        for i in 1..<max(1, c.count - 1) where c[i] == "s" && "iy".contains(c[i - 1]) && "eai".contains(c[i + 1]) {
            var d = c; d[i] = "z"; out.insert(String(d))
        }
        // centre → center, theatres → theaters, centred → centered (a consonant before "re").
        for suffix in ["re", "res", "red"] where w.hasSuffix(suffix) && c.count > suffix.count + 2 {
            let before = c[c.count - suffix.count - 1]
            guard !vowels.contains(before) else { continue }
            let stem = String(c.dropLast(suffix.count))
            out.insert(stem + "er" + suffix.dropFirst(2))
        }
        // travelled → traveled, cancelling → canceling, counsellor → counselor (a vowel before "ll").
        for suffix in ["ed", "ing", "ings", "er", "ers", "or", "ors"] where w.hasSuffix("ll" + suffix) {
            let stem = c.dropLast(suffix.count + 2)
            guard stem.count >= 2, let last = stem.last, vowels.contains(last) else { continue }
            out.insert(String(stem) + "l" + suffix)
        }
        // catalogue → catalog, dialogues → dialogs.
        for (uk, us) in [("ogue", "og"), ("ogues", "ogs")] where w.hasSuffix(uk) && c.count > uk.count + 1 {
            out.insert(String(w.dropLast(uk.count)) + us)
        }
        // anaemia → anemia, paediatric → pediatric, oestrogen → estrogen (6+ letters, not at the end).
        if c.count >= 6 {
            for i in 0..<(c.count - 2) where (c[i] == "a" || c[i] == "o") && c[i + 1] == "e" {
                var d = c; d.remove(at: i); out.insert(String(d))
            }
        }
        for (uk, us) in stems where w.hasPrefix(uk) {
            out.insert(us + w.dropFirst(uk.count))
        }
        out.remove(w)
        return out
    }

    /// True when `replacement` only respells `original` into the other variant ("colour" ↔ "color").
    /// Case-insensitive.
    public static func isRespelling(_ original: String, _ replacement: String) -> Bool {
        let o = original.lowercased(), r = replacement.lowercased()
        guard o != r, !o.isEmpty, !r.isEmpty else { return false }
        return americanForms(of: o).contains(r) || americanForms(of: r).contains(o)
    }

    /// The edit with every word that only respells its original into the other variant put back.
    /// Returns nil when nothing else is left to change. Edits whose word counts differ are kept as they are.
    public static func restore(_ edit: Edit) -> Edit? {
        let a = Diff.tokenize(edit.original), b = Diff.tokenize(edit.replacement)
        guard a.count == b.count else { return edit }
        var out = edit
        var parts: [String] = []
        var changed = false
        for (x, y) in zip(a, b) {
            if x.text != y.text, isRespelling(x.text, y.text) {
                parts.append(x.text); changed = true
            } else {
                parts.append(y.text)
            }
        }
        guard changed else { return edit }
        out.replacement = parts.joined()
        return out.replacement == out.original ? nil : out
    }
}
