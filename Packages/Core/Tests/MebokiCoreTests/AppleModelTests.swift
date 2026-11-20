import Foundation
import Testing
@testable import MebokiCore

/// The Apple backend's pure rules (PLAN.md §3 "Apple Intelligence"). The model itself needs macOS 26 and
/// Apple Intelligence; these run anywhere.
@Suite struct AppleModelTests {
    @Test func backendFollowsSourceWithoutSwitching() {
        #expect(ModelBackend.choose(source: .local, apple: .available, localInstalled: true, cloudKey: true) == .local)
        #expect(ModelBackend.choose(source: .local, apple: .available, localInstalled: false, cloudKey: true)
            == .unusable(.noLocalModel))
        #expect(ModelBackend.choose(source: .apple, apple: .available, localInstalled: false, cloudKey: false) == .apple)
        // Apple selected but gone: says why, never falls back to the local model by itself.
        for a in AppleModelAvailability.allCases where a != .available {
            #expect(ModelBackend.choose(source: .apple, apple: a, localInstalled: true, cloudKey: true)
                == .unusable(.apple(a)))
        }
        #expect(ModelBackend.choose(source: .cloud, apple: .available, localInstalled: true, cloudKey: true) == .cloud)
        #expect(ModelBackend.choose(source: .cloud, apple: .available, localInstalled: true, cloudKey: false)
            == .unusable(.noCloudKey))
    }

    @Test func appleIsDefaultOnlyOnAFreshInstall() {
        func fresh(_ source: String? = nil, _ model: String? = nil, done: Bool = false,
                   _ apple: AppleModelAvailability = .available, on: Bool = true) -> ModelSource? {
            ModelBackend.freshInstallSource(storedSource: source, storedModelID: model, onboardingDone: done,
                                            apple: apple, appleIsDefault: on)
        }
        #expect(fresh() == .apple)
        #expect(fresh("local") == nil)
        #expect(fresh("cloud") == nil)
        #expect(fresh(nil, "gemma-4-e4b-q4_0") == nil)
        // Used the default Gemma for a while without ever picking it: not fresh.
        #expect(fresh(done: true) == nil)
        #expect(fresh(on: false) == nil)
        for a in AppleModelAvailability.allCases where a != .available { #expect(fresh(nil, nil, a) == nil) }
    }

    @Test func onDeviceSources() {
        #expect(ModelSource.local.onDevice)
        #expect(ModelSource.apple.onDevice)
        #expect(!ModelSource.cloud.onDevice)
        #expect(ModelSource(rawValue: "apple") == .apple)
    }

    @Test func errorsThatStopTheCheck() {
        let fatal: [AppleModelError] = [.unavailable(.notEnabled), .assetsUnavailable, .rateLimited]
        let skip: [AppleModelError] = [.guardrail, .refusal, .unsupportedLanguage, .contextOverflow,
                                       .concurrentRequests, .decodingFailure, .other("x")]
        for e in fatal { #expect(e.failure.fatal, "\(e.name)") }
        for e in skip { #expect(!e.failure.fatal, "\(e.name)") }
        #expect(AppleModelError.unavailable(.notEnabled).failure.message.contains("System Settings"))
    }

    @Test func truncationRule() {
        let input = "She have two cat."
        #expect(AppleModel.maxTokens(for: input) == 2 * 17 + 64)
        #expect(!AppleModel.isTruncated(reply: "She has two cats.", input: input))
        #expect(!AppleModel.isTruncated(reply: String(repeating: "a", count: 97), input: input))
        #expect(AppleModel.isTruncated(reply: String(repeating: "a", count: 98), input: input))
    }

    @Test func unavailableBuildsSayOsTooOld() {
        // This test host may be macOS 14/15 (always osTooOld) or 26 (any value); it must never crash.
        let a = AppleModelAvailability.system()
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 { #expect(a == .osTooOld) }
    }

    /// A refusal leaves the paragraph unchanged (counted as rejected); a lost model stops the check.
    @Test func pipelineSkipsRefusalsAndStopsOnFatal() async throws {
        struct Throwing: Corrector {
            let error: AppleModelError
            func correct(_ text: String, system: String) async throws -> LLMClient.Reply { throw error.failure }
        }
        let refused = ProofreadEngine(client: Throwing(error: .guardrail), options: CheckOptions())
        let r = try await refused.check("She have two cat.")
        #expect(r.edits.isEmpty)
        #expect(r.rejectedChunks == 1)

        let gone = ProofreadEngine(client: Throwing(error: .unavailable(.notEnabled)), options: CheckOptions())
        await #expect(throws: LLMClient.Failure.self) { _ = try await gone.check("She have two cat.") }
    }
}
