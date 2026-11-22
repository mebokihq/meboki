import Foundation

/// Apps that turn typed or pasted quotes into curly ones (Slack turns a pasted "doesn't" into "doesn’t",
/// 2026-11-22): a write that went in reads back with other quotes. Comparisons that verify a write fold them, so
/// that swap isn't taken for a failed write. Every quote is one UTF-16 unit on both sides, so offsets don't move.
public enum QuoteFolding {
    /// `s` with curly single and double quotes as straight ones.
    public static func fold(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { map[$0] != nil }) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars { out.append(map[u] ?? u) }
        return String(out)
    }

    private static let map: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
    ]
}
