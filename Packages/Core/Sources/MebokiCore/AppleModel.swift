import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (`FoundationModels`, macOS 26+) as a zero-download choice (PLAN.md §3 "Apple
/// Intelligence"). The types here compile on every macOS the app runs on; only `AppleModelClient` needs
/// macOS 26, and the framework is weak-linked so the app still launches on macOS 14 and 15.

/// Whether Apple's model can answer on this Mac. A plain mirror of `SystemLanguageModel.Availability` plus
/// `osTooOld`, so the app and the tests never touch the framework's types.
public enum AppleModelAvailability: String, CaseIterable, Sendable {
    case available
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// macOS is still downloading or preparing the model.
    case modelNotReady
    /// The Mac (or its region or language setting) doesn't support Apple Intelligence.
    case deviceNotEligible
    /// macOS 14 or 15, or a build without the framework.
    case osTooOld

    public var isAvailable: Bool { self == .available }

    /// The system's answer right now. Cheap enough to ask on each status refresh.
    public static func system() -> AppleModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return AppleModelAvailability(SystemLanguageModel.default.availability)
        }
        #endif
        return .osTooOld
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
extension AppleModelAvailability {
    public init(_ a: SystemLanguageModel.Availability) {
        switch a {
        case .available: self = .available
        case .unavailable(.appleIntelligenceNotEnabled): self = .notEnabled
        case .unavailable(.modelNotReady): self = .modelNotReady
        case .unavailable(.deviceNotEligible): self = .deviceNotEligible
        // A reason added in a later macOS: not usable, and nothing the user can switch on that we know of.
        case .unavailable: self = .deviceNotEligible
        }
    }
}
#endif

/// Why one request to Apple's model failed (`LanguageModelSession.GenerationError`, plus availability).
/// `failure` is what the check pipeline sees: refusals and per-text limits leave that text unchanged; a
/// model that is gone, or a system rate limit, stops the check with a message.
public enum AppleModelError: Error, Equatable, Sendable {
    case unavailable(AppleModelAvailability)
    case assetsUnavailable
    case guardrail
    case refusal
    case unsupportedLanguage
    case contextOverflow
    case rateLimited
    case concurrentRequests
    case decodingFailure
    case other(String)

    /// Short name for logs and the eval runner's `error` field.
    public var name: String {
        switch self {
        case .unavailable(let a): "unavailable:\(a.rawValue)"
        case .assetsUnavailable: "assetsUnavailable"
        case .guardrail: "guardrailViolation"
        case .refusal: "refusal"
        case .unsupportedLanguage: "unsupportedLanguageOrLocale"
        case .contextOverflow: "exceededContextWindowSize"
        case .rateLimited: "rateLimited"
        case .concurrentRequests: "concurrentRequests"
        case .decodingFailure: "decodingFailure"
        case .other: "other"
        }
    }

    /// Every following request would fail the same way: stop the check instead of skipping each paragraph.
    public var isFatal: Bool {
        switch self {
        case .unavailable, .assetsUnavailable, .rateLimited: true
        case .guardrail, .refusal, .unsupportedLanguage, .contextOverflow, .concurrentRequests, .decodingFailure,
             .other: false
        }
    }

    public var failure: LLMClient.Failure {
        LLMClient.Failure(message: message, fatal: isFatal)
    }

    public var message: String {
        switch self {
        case .unavailable(let a): AppleModel.unavailableMessage(a)
        case .assetsUnavailable: "Apple Intelligence isn't available right now"
        case .guardrail, .refusal: "Apple Intelligence declined this text"
        case .unsupportedLanguage: "Apple Intelligence doesn't support this text's language"
        case .contextOverflow: "The text is too long for Apple Intelligence"
        case .rateLimited: "macOS is limiting Apple Intelligence requests right now. Try again in a moment"
        case .concurrentRequests: "Apple Intelligence is busy with another request"
        case .decodingFailure: "Apple Intelligence gave an unreadable answer"
        case .other(let m): "Apple Intelligence failed: \(m)"
        }
    }
}

/// Constants and pure rules of the Apple backend (unit-tested without the framework).
public enum AppleModel {
    /// Shown in the UI and logs. Never the Apple logo next to it (design_code.md §8.3).
    public static let displayName = "Apple Intelligence"
    /// Pipeline cache key (`CheckPipeline` is per model).
    public static let cacheKey = "apple:system"
    /// Requests in flight at once. Not measured yet (PLAN.md §3, benchmark pending): one, until the eval
    /// runner's 1 / 2 / 4 lane numbers say more is faster.
    public static let requestLanes = 1

    /// Output cap in tokens: twice the input's UTF-16 length plus slack. Larger than `LLMClient.maxTokens(for:)`
    /// because the framework doesn't say whether a reply stopped at the cap; with this cap only a reply at least
    /// twice as long as the input can have hit it, and such a reply is never a correction (`isTruncated`).
    public static func maxTokens(for text: String) -> Int { 2 * text.utf16.count + 64 }

    /// A reply that may have been cut at the cap (a token is at least one UTF-16 unit, so a cut reply has at
    /// least `maxTokens` units). Never applied, like a truncated `llama-server` reply.
    public static func isTruncated(reply: String, input: String) -> Bool {
        reply.utf16.count >= maxTokens(for: input)
    }

    public static func unavailableMessage(_ a: AppleModelAvailability) -> String {
        switch a {
        case .available: "Apple Intelligence is available"
        case .notEnabled: "Apple Intelligence is off. Turn it on in System Settings › Apple Intelligence & Siri"
        case .modelNotReady: "macOS is still preparing the Apple Intelligence model"
        case .deviceNotEligible: "Apple Intelligence isn't supported on this Mac"
        case .osTooOld: "Apple Intelligence needs macOS 26"
        }
    }
}

#if canImport(FoundationModels)
/// Proofreads one chunk with Apple's on-device model. A fresh `LanguageModelSession` per call: calls stay
/// independent (no transcript grows) and each fits the model's 4,096-token context. Same prompt as the
/// local model (`Prompt.system(for:)` as instructions, `Prompt.user` as the prompt), greedy sampling.
@available(macOS 26, *)
public struct AppleModelClient: Corrector {
    /// `permissiveContentTransformations` is Apple's guardrail setting for turning the user's own text into
    /// text (summaries, rewrites), which is what a proofreader does; it should refuse less ordinary text.
    public var permissiveGuardrails: Bool

    public init(permissiveGuardrails: Bool = true) {
        self.permissiveGuardrails = permissiveGuardrails
    }

    /// One answer with timings, for the eval runner.
    public struct Timed: Sendable {
        public var reply: LLMClient.Reply
        /// Seconds to the first non-empty streamed text (streaming only).
        public var firstToken: TimeInterval?
    }

    public func correct(_ text: String, system: String) async throws -> LLMClient.Reply {
        do {
            return try await respond(text, system: system).reply
        } catch let e as AppleModelError {
            throw e.failure
        }
    }

    /// Throws `AppleModelError` (or `CancellationError`).
    public func respond(_ text: String, system: String, stream: Bool = false) async throws -> Timed {
        let model = SystemLanguageModel(guardrails: permissiveGuardrails ? .permissiveContentTransformations : .default)
        let availability = AppleModelAvailability(model.availability)
        guard availability.isAvailable else { throw AppleModelError.unavailable(availability) }
        let session = LanguageModelSession(model: model, instructions: system)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: AppleModel.maxTokens(for: text))
        let prompt = Prompt.user(text)
        do {
            var output = ""
            var firstToken: TimeInterval?
            if stream {
                let started = Date()
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    if firstToken == nil, !snapshot.content.isEmpty { firstToken = Date().timeIntervalSince(started) }
                    output = snapshot.content
                }
            } else {
                output = try await session.respond(to: prompt, options: options).content
            }
            return Timed(reply: LLMClient.Reply(text: output, truncated: AppleModel.isTruncated(reply: output, input: text)),
                         firstToken: firstToken)
        } catch let e as LanguageModelSession.GenerationError {
            throw AppleModelError(e)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppleModelError.other(error.localizedDescription)
        }
    }

    /// Loads the model's resources ahead of the first check (after the user picks it).
    public static func prewarm(system: String) {
        LanguageModelSession(instructions: system).prewarm()
    }
}

@available(macOS 26, *)
extension AppleModelError {
    init(_ e: LanguageModelSession.GenerationError) {
        switch e {
        case .exceededContextWindowSize: self = .contextOverflow
        case .assetsUnavailable: self = .assetsUnavailable
        case .guardrailViolation: self = .guardrail
        case .unsupportedGuide: self = .other("unsupported guide")
        case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
        case .decodingFailure: self = .decodingFailure
        case .rateLimited: self = .rateLimited
        case .concurrentRequests: self = .concurrentRequests
        case .refusal: self = .refusal
        @unknown default: self = .other(e.localizedDescription)
        }
    }
}
#endif
