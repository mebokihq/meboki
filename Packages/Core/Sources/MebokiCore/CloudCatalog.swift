import Foundation

/// A cloud provider the user brings their own API key for (BYOK, PLAN.md §4). Both speak the OpenAI
/// Responses API (`POST {baseURL}/responses`), which `ResponsesClient` calls.
public enum CloudProvider: String, CaseIterable, Sendable {
    case openRouter = "openrouter"
    case openAI = "openai"

    public var name: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        }
    }

    /// The API root; `ResponsesClient` appends `responses`.
    public var baseURL: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/")!
        case .openAI: URL(string: "https://api.openai.com/v1/")!
        }
    }

    /// Where the user creates a key.
    public var keysPage: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// Placeholder for the key field.
    public var keyPlaceholder: String {
        switch self {
        case .openRouter: "sk-or-v1-…"
        case .openAI: "sk-proj-…"
        }
    }

    /// A pasted key that can't be this provider's (a likely mix-up), with the reason. Nil when it looks right.
    public func keyProblem(_ key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return "Paste a key first." }
        if k.contains(where: \.isWhitespace) { return "A key has no spaces." }
        switch self {
        case .openRouter:
            if !k.hasPrefix("sk-or-") { return "OpenRouter keys start with “sk-or-”." }
        case .openAI:
            if k.hasPrefix("sk-or-") { return "That's an OpenRouter key. Pick OpenRouter above." }
            if !k.hasPrefix("sk-") { return "OpenAI keys start with “sk-”." }
        }
        return nil
    }
}

/// A cloud model with the request settings that work for it (PLAN.md §4 "Reasoning controls differ by model").
public struct CloudModel: Hashable, Sendable, Identifiable {
    /// The provider's model ID ("anthropic/claude-haiku-5.5" on OpenRouter, "gpt-6-luna" on OpenAI).
    public let id: String
    public let name: String
    public let provider: CloudProvider
    /// `reasoning.effort` to send ("none" turns thinking off). Nil sends no reasoning settings.
    public var reasoningEffort: String?
    /// The model accepts `temperature` (most reasoning models reject it).
    public var supportsTemperature: Bool
    /// From the 2026-11-14 cloud benchmark (PLAN.md §4). Nil for a model the user typed in.
    public var errorsFixed: Int?
    public var latencySeconds: Double?
    public var costPer1000Checks: Double?

    public init(id: String, name: String, provider: CloudProvider, reasoningEffort: String? = nil,
                supportsTemperature: Bool = false, errorsFixed: Int? = nil, latencySeconds: Double? = nil,
                costPer1000Checks: Double? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.supportsTemperature = supportsTemperature
        self.errorsFixed = errorsFixed
        self.latencySeconds = latencySeconds
        self.costPer1000Checks = costPer1000Checks
    }

    /// A model ID the user typed in: no reasoning or temperature settings, no benchmark numbers.
    public static func custom(_ id: String, provider: CloudProvider) -> CloudModel {
        CloudModel(id: id, name: id, provider: provider)
    }

    public var isCustom: Bool { !CloudCatalog.models(for: provider).contains { $0.id == id } }
}

/// Cloud models offered for BYOK (PLAN.md §4 "Cloud Catalog"). OpenRouter entries are limited to models with
/// zero-data-retention endpoints, since every OpenRouter request asks for `zdr: true`.
public enum CloudCatalog {
    public static let all: [CloudModel] = [
        CloudModel(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5", provider: .openRouter,
                   reasoningEffort: "none", errorsFixed: 45, latencySeconds: 0.68, costPer1000Checks: 0.036),
        CloudModel(id: "openai/gpt-6-luna", name: "GPT-6 Luna", provider: .openRouter,
                   reasoningEffort: "none", errorsFixed: 44, latencySeconds: 0.98, costPer1000Checks: 0.026),
        CloudModel(id: "google/gemini-3.1-flash-lite", name: "Gemini 3.1 Flash-Lite", provider: .openRouter,
                   reasoningEffort: "none", supportsTemperature: true, errorsFixed: 45, latencySeconds: 0.73,
                   costPer1000Checks: 0.062),
        CloudModel(id: "gpt-6-luna", name: "GPT-6 Luna", provider: .openAI,
                   reasoningEffort: "none", errorsFixed: 44, latencySeconds: 0.98, costPer1000Checks: 0.026),
    ]

    public static func models(for provider: CloudProvider) -> [CloudModel] {
        all.filter { $0.provider == provider }
    }

    /// The default per provider: Claude Haiku 5.5 on OpenRouter (PLAN.md §9 decision 7), GPT-6 Luna on OpenAI.
    public static func recommended(for provider: CloudProvider) -> CloudModel {
        models(for: provider)[0]
    }

    /// The catalog entry for `id`, or a custom model when the user typed an ID that isn't listed. Nil or empty
    /// gives the provider's default.
    public static func model(id: String?, provider: CloudProvider) -> CloudModel {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return recommended(for: provider)
        }
        return models(for: provider).first { $0.id == id } ?? .custom(id, provider: provider)
    }
}
