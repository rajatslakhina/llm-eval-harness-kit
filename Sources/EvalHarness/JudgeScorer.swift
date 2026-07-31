import Foundation

/// LLM-as-judge scoring with self-consistency sampling.
///
/// The design position here is that a judge is a *measuring instrument*, and an
/// instrument you never calibrate is decoration. Three things follow from that
/// and are enforced below:
///
/// 1. The judge is itself an ``EvalModel``, so it can be wrapped in a
///    ``ReplayingModel`` and replayed from the committed cache. A judge that
///    calls the network on every PR is a per-PR bill and a per-PR coin flip.
/// 2. It is sampled `samples` times with distinct seeds, and the *median* is
///    taken. A single judge call is one draw from a distribution nobody
///    characterised.
/// 3. Spread across those samples is reported as
///    ``ScoreFlag/judgeDisagreement``. A case the judge cannot agree with
///    itself about is a bad case, and averaging quietly hides that.
public struct JudgeScorer: Scorer {
    public let name: String

    private let judge: any EvalModel
    private let samples: Int
    private let disagreementThreshold: Double
    private let passThreshold: Double
    private let decoding: DecodingParameters
    private let promptBuilder: @Sendable (GoldenCase, ModelResponse) -> String

    /// - Parameters:
    ///   - samples: Number of judge draws. Must be >= 1. Odd values are
    ///     preferable so the median is an actual observation.
    ///   - disagreementThreshold: Spread (max − min) above which the case is
    ///     flagged. Defaults to 0.25 — a quarter of the scale.
    ///   - passThreshold: Per-sample score at or above which that sample counts
    ///     as passing. This exists so that a judge's ``ScoreBreakdown``
    ///     reports real failures: a breakdown whose components can never fail
    ///     silently tells ``CompositeScorer`` that a 0.0 judgement "passed", and
    ///     the red gate stops being diagnosable.
    /// - Throws: ``EvalError/invalidJudgeConfiguration(reason:)``
    public init(
        name: String = "judge",
        judge: any EvalModel,
        samples: Int = 3,
        disagreementThreshold: Double = 0.25,
        passThreshold: Double = 0.5,
        decoding: DecodingParameters = .deterministic,
        promptBuilder: @escaping @Sendable (GoldenCase, ModelResponse) -> String = JudgeScorer.defaultPrompt
    ) throws {
        guard samples >= 1 else {
            throw EvalError.invalidJudgeConfiguration(reason: "samples must be at least 1, got \(samples)")
        }
        guard disagreementThreshold >= 0 else {
            throw EvalError.invalidJudgeConfiguration(
                reason: "disagreementThreshold must be non-negative, got \(disagreementThreshold)"
            )
        }
        guard (0...1).contains(passThreshold) else {
            throw EvalError.invalidJudgeConfiguration(
                reason: "passThreshold must be within 0...1, got \(passThreshold)"
            )
        }
        self.name = name
        self.judge = judge
        self.samples = samples
        self.disagreementThreshold = disagreementThreshold
        self.passThreshold = passThreshold
        self.decoding = decoding
        self.promptBuilder = promptBuilder
    }

    public static let defaultPrompt: @Sendable (GoldenCase, ModelResponse) -> String = { goldenCase, response in
        """
        You are grading a model response against a rubric.

        TASK:
        \(goldenCase.prompt)

        RESPONSE:
        \(response.text)

        RUBRIC:
        \(goldenCase.rubric.checks.map { "- \($0.name)" }.joined(separator: "\n"))

        Reply with exactly one line in the form:
        SCORE: <number between 0 and 1>
        """
    }

    public func score(response: ModelResponse, for goldenCase: GoldenCase) async throws -> ScoreBreakdown {
        let prompt = promptBuilder(goldenCase, response)
        var values: [Double] = []
        values.reserveCapacity(samples)

        for index in 0..<samples {
            // A distinct seed per sample gives each draw its own transcript key,
            // so self-consistency survives replay instead of collapsing into the
            // same cached answer N times.
            let sampleDecoding = decoding.withSeed(decoding.seed &+ UInt64(index))
            let judgement = try await judge.complete(prompt: prompt, decoding: sampleDecoding)
            guard let parsed = JudgeScorer.parseScore(from: judgement.text) else {
                throw EvalError.judgeParseFailure(caseID: goldenCase.id, rawOutput: judgement.text)
            }
            values.append(parsed)
        }

        // `samples >= 1` is enforced in `init`, and the loop above appends
        // exactly `samples` values, so `values` is provably non-empty here.
        // The guard is kept anyway so the invariant is local and cheap.
        guard let spreadMin = values.min(), let spreadMax = values.max() else {
            throw EvalError.invalidJudgeConfiguration(reason: "no judge samples were produced")
        }

        let spread = spreadMax - spreadMin
        var flags: Set<ScoreFlag> = []
        var notes: [String] = []
        if spread > disagreementThreshold {
            flags.insert(.judgeDisagreement)
            notes.append(
                "Judge disagreed with itself across \(samples) samples "
                + "(spread \(String(format: "%.2f", spread)) > \(disagreementThreshold)). "
                + "Treat this case as ambiguous, not as a model regression."
            )
        }

        let median = JudgeScorer.median(of: values)

        return ScoreBreakdown(
            score: Score(median),
            components: values.enumerated().map { index, value in
                .init(
                    name: "sample-\(index)",
                    weight: 1,
                    passed: value >= passThreshold,
                    detail: "score \(value) (pass threshold \(passThreshold))"
                )
            },
            flags: flags,
            notes: notes
        )
    }

    // MARK: - Helpers

    /// Extracts `SCORE: <number>`. Returns `nil` rather than a default so the
    /// caller can raise a harness error instead of inventing a quality signal.
    static func parseScore(from text: String) -> Double? {
        let pattern = "SCORE\\s*:\\s*([0-9]*\\.?[0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1
        else { return nil }
        let captured = match.range(at: 1)
        guard captured.location != NSNotFound, let swiftRange = Range(captured, in: text) else {
            return nil
        }
        return Double(text[swiftRange])
    }

    /// Median of a non-empty array. Returns 0 for an empty input rather than
    /// trapping on an out-of-range index.
    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            // `middle` < count for any non-empty array.
            return sorted[middle]
        }
        // Even count >= 2, so `middle` and `middle - 1` are both in bounds.
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
