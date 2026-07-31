import Foundation

/// Identity of the thing producing completions.
///
/// `build` matters as much as `identifier`: "same model, new server build" is
/// precisely the situation the harness has to be able to name, because it is
/// the difference between a regression somebody caused and drift somebody
/// merely inherited.
public struct ModelDescriptor: Sendable, Hashable, Codable {
    public enum Tier: String, Sendable, Hashable, Codable {
        case onDevice
        case cloud
    }

    public let identifier: String
    public let build: String
    public let tier: Tier

    public init(identifier: String, build: String, tier: Tier) {
        self.identifier = identifier
        self.build = build
        self.tier = tier
    }
}

/// Decoding knobs that materially change output, and therefore participate in
/// the transcript cache key.
public struct DecodingParameters: Sendable, Hashable, Codable {
    public let temperature: Double
    public let topP: Double
    public let maxOutputTokens: Int
    /// Sampling seed. Also used by ``JudgeScorer`` to give each
    /// self-consistency sample a distinct cache key.
    public let seed: UInt64

    public init(temperature: Double, topP: Double, maxOutputTokens: Int, seed: UInt64) {
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.seed = seed
    }

    /// Greedy decoding — the default for eval runs, because sampling noise is
    /// variance you are paying for and cannot attribute.
    public static let deterministic = DecodingParameters(
        temperature: 0, topP: 1, maxOutputTokens: 512, seed: 0
    )

    public func withSeed(_ seed: UInt64) -> DecodingParameters {
        DecodingParameters(
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            seed: seed
        )
    }
}

/// A single completion plus the accounting the budget gate needs.
public struct ModelResponse: Sendable, Hashable, Codable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let latencySeconds: Double
    public let costUSD: Double

    public init(
        text: String,
        inputTokens: Int,
        outputTokens: Int,
        latencySeconds: Double,
        costUSD: Double
    ) {
        self.text = text
        // Negative counts are meaningless and would corrupt every downstream
        // total, so they are clamped at the boundary rather than trusted.
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.latencySeconds = max(0, latencySeconds)
        self.costUSD = max(0, costUSD)
    }

    public var totalTokens: Int { inputTokens + outputTokens }
}

/// Anything that can produce a completion: a cloud provider, an on-device
/// Foundation Models session, a fixture, or a replay decorator over any of them.
///
/// The protocol is intentionally this small. Everything the harness does —
/// replay, budgeting, judging, dual-target comparison — composes on top of a
/// one-method surface, which is what makes swapping an on-device model for a
/// cloud one a configuration change rather than a rewrite.
public protocol EvalModel: Sendable {
    var descriptor: ModelDescriptor { get }
    func complete(prompt: String, decoding: DecodingParameters) async throws -> ModelResponse
}
