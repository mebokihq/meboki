import Foundation

/// English variant (design_code.md §8.2). Picks the session's system prompt (`Prompt.system(for:)`).
/// Respellings between variants are dropped with either variant (`SpellingVariant`).
public enum EnglishVariant: String, CaseIterable, Sendable {
    case us = "US", uk = "UK"
}

/// How much the check fixes (design_code.md §8.2 "Check for"). Applied by `EditFilter.allows` to the
/// classified edits, so the prompt (and its cache) stays the same for every level.
public enum CheckLevel: String, CaseIterable, Sendable {
    /// Typos, capitalization, repeated words, and apostrophes missing inside a word ("dont" → "don't").
    case spelling
    /// Spelling plus grammar and apostrophe fixes. Drops edits that only add or remove commas, periods,
    /// dashes and similar punctuation.
    case grammar
    /// Everything the model fixes (the benchmarked behavior).
    case full
}

/// Settings that change a check. Only `variant` reaches the model (`Prompt.system(for:)`, fixed for a
/// session); the rest are post-filters on the edits (`EditFilter`), so the prompt cache survives
/// per-app changes such as Casual.
public struct CheckOptions: Sendable, Equatable {
    public var variant: EnglishVariant
    public var level: CheckLevel
    /// Casual mode (chat apps, or an app set to Casual): keeps the writer's lowercase starts and
    /// missing final periods.
    public var casual: Bool
    /// Drop edits that touch URLs, emails, @mentions, #tags, `code`, paths, identifiers, emoji and
    /// non-Latin words (`ProtectedTokens`).
    public var protectTokens: Bool
    /// Text that isn't English (`LanguageGate`) is never sent to the model, and edits that touch it are
    /// dropped. Settings › Writing › "Skip text that isn't English", default off.
    public var englishOnly: Bool
    /// A sentence with many changes that belong together is one "Rewrite" fix (`RewriteDetector`).
    public var groupRewrites: Bool

    public init(variant: EnglishVariant = .us, level: CheckLevel = .full, casual: Bool = false, protectTokens: Bool = true,
                englishOnly: Bool = false, groupRewrites: Bool = true) {
        self.groupRewrites = groupRewrites
        self.variant = variant
        self.level = level
        self.casual = casual
        self.protectTokens = protectTokens
        self.englishOnly = englishOnly
    }

}
