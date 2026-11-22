import Foundation

/// List labels at the start of a paragraph's text ("• ", "2. ", "b) "), for apps that put them in the paragraph
/// field's value but won't let anyone select them (LibreOffice Writer: a write whose range starts in the label
/// can't select it, so the fix can't be applied).
public enum ParagraphLabels {
    private static let bullets: Set<Character> = ["•", "◦", "▪", "‣", "●", "○", "■", "□", "▸", "►", "–", "-"]

    /// UTF-16 length of the label at the start of `paragraph` (the label and the one space or tab after it), or 0.
    public static func length(in paragraph: String) -> Int {
        let chars = Array(paragraph)
        guard chars.count >= 2 else { return 0 }
        func blank(_ c: Character) -> Bool { c == " " || c == "\t" }
        var end = 0
        if bullets.contains(chars[0]) {
            end = 1
        } else if chars[0].isNumber || chars[0].isLetter {
            // 1 to 3 digits, or one letter, then "." or ")".
            var i = 0
            if chars[0].isLetter {
                i = 1
            } else {
                while i < chars.count, i < 4, chars[i].isASCII, chars[i].isNumber { i += 1 }
                guard i >= 1, i <= 3 else { return 0 }
            }
            guard i < chars.count, chars[i] == "." || chars[i] == ")" else { return 0 }
            end = i + 1
        } else {
            return 0
        }
        guard end < chars.count, blank(chars[end]) else { return 0 }
        return String(chars[0...end]).utf16.count
    }

    /// `edits` (relative to `scope`, a part of `text` starting at UTF-16 offset `scopeLocation`; the whole text
    /// for scope 0) without the label part. An edit that starts inside a paragraph's label is cut to start after
    /// it when the label stays as it is (its original and its replacement both begin with the label), and
    /// dropped otherwise (a change to the label itself, or an edit that ends inside it). Edits that don't reach a
    /// label come back unchanged, in the same order.
    public static func trim(_ edits: [Edit], in text: String, scopeLocation: Int = 0,
                            label: (String) -> Int = length(in:)) -> [Edit] {
        guard !edits.isEmpty else { return [] }
        let ns = text as NSString
        var starts: [(start: Int, label: Int)] = []
        var location = 0
        for line in text.components(separatedBy: "\n") {
            starts.append((location, label(line)))
            location += (line as NSString).length + 1
        }
        var out: [Edit] = []
        for e in edits {
            let at = scopeLocation + e.range.location
            guard let p = starts.last(where: { $0.start <= at }), p.label > 0, at < p.start + p.label else {
                out.append(e)
                continue
            }
            let labelText = ns.substring(with: NSRange(location: p.start, length: p.label))
            let orig = e.original as NSString, repl = e.replacement as NSString
            // The label sits where the edit starts only if it begins exactly at the paragraph start.
            guard at == p.start, orig.length >= p.label, repl.length >= p.label,
                  orig.substring(to: p.label) == labelText, repl.substring(to: p.label) == labelText else { continue }
            let trimmed = Edit(range: NSRange(location: e.range.location + p.label, length: e.range.length - p.label),
                               original: orig.substring(from: p.label), replacement: repl.substring(from: p.label))
            if trimmed.original != trimmed.replacement { out.append(trimmed) }
        }
        return out
    }
}
