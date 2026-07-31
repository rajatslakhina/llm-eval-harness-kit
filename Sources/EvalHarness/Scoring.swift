import Foundation

/// A score in `0...1`, clamped at construction, remembering whether it had to
/// be clamped.
///
/// Clamping silently would hide a broken scorer; refusing to clamp would crash
/// a CI run on a judge that emitted `1.2`. Clamping *and flagging* keeps the run
/// alive and still surfaces the defect.
public struct Score: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: Double
    public let wasClamped: Bool

    public init(_ raw: Double) {
        if raw.isNaN {
            // NaN propagates through every subsequent mean and comparison, so it
            // is trapped here at the boundary.
            self.value = 0
            self.wasClamped = true
        } else if raw < 0 {
            self.value = 0
            self.wasClamped = true
        } else if raw > 1 {
            self.value = 1
            self.wasClamped = true
        } else {
            self.value = raw
            self.wasClamped = false
        }
    }

    public static func < (lhs: Score, rhs: Score) -> Bool { lhs.value < rhs.value }

    public var description: String {
        let rounded = (value * 1000).rounded() / 1000
        return String(rounded)
    }
}

/// Anomalies worth surfacing that are not, by themselves, failures.
public enum ScoreFlag: String, Sendable, Hashable, Codable, CaseIterable {
    case scoreClamped
    case judgeDisagreement
    case emptyResponse
}

/// A score plus the per-check detail that produced it.
///
/// Reviewers do not act on a number; they act on which check failed. Keeping the
/// breakdown alongside the score is what makes a red gate diagnosable instead of
/// merely alarming.
public struct ScoreBreakdown: Sendable, Hashable {
    public struct Component: Sendable, Hashable {
        public let name: String
        public let weight: Double
        public let passed: Bool
        public let detail: String

        public init(name: String, weight: Double, passed: Bool, detail: String) {
            self.name = name
            self.weight = weight
            self.passed = passed
            self.detail = detail
        }
    }

    public let score: Score
    public let components: [Component]
    public let flags: Set<ScoreFlag>
    public let notes: [String]

    public init(
        score: Score,
        components: [Component],
        flags: Set<ScoreFlag> = [],
        notes: [String] = []
    ) {
        self.score = score
        self.components = components
        var allFlags = flags
        if score.wasClamped { allFlags.insert(.scoreClamped) }
        self.flags = allFlags
        self.notes = notes
    }

    public var failedComponents: [Component] { components.filter { !$0.passed } }
}

public protocol Scorer: Sendable {
    var name: String { get }
    func score(response: ModelResponse, for goldenCase: GoldenCase) async throws -> ScoreBreakdown
}

// MARK: - Rubric scoring

/// Deterministic, offline, zero-cost scoring against a case's rubric.
public struct RubricScorer: Scorer {
    public let name = "rubric"

    public init() {}

    public func score(response: ModelResponse, for goldenCase: GoldenCase) async throws -> ScoreBreakdown {
        let rubric = goldenCase.rubric
        var components: [ScoreBreakdown.Component] = []
        components.reserveCapacity(rubric.checks.count)
        var earned = 0.0

        for check in rubric.checks {
            let outcome = evaluate(check.kind, against: response.text)
            if outcome.passed { earned += check.weight }
            components.append(
                ScoreBreakdown.Component(
                    name: check.name,
                    weight: check.weight,
                    passed: outcome.passed,
                    detail: outcome.detail
                )
            )
        }

        // `totalWeight` is guaranteed > 0 by `Rubric.init`, so this division is
        // safe without a further guard.
        var flags: Set<ScoreFlag> = []
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flags.insert(.emptyResponse)
        }

        return ScoreBreakdown(
            score: Score(earned / rubric.totalWeight),
            components: components,
            flags: flags
        )
    }

    private func evaluate(_ kind: Rubric.Kind, against text: String) -> (passed: Bool, detail: String) {
        switch kind {
        case .contains(let needle, let caseSensitive):
            let hit = caseSensitive
                ? text.contains(needle)
                : text.range(of: needle, options: .caseInsensitive) != nil
            return (hit, hit ? "found '\(needle)'" : "missing '\(needle)'")

        case .doesNotContain(let needle, let caseSensitive):
            let hit = caseSensitive
                ? text.contains(needle)
                : text.range(of: needle, options: .caseInsensitive) != nil
            return (!hit, hit ? "unexpectedly contains '\(needle)'" : "absent as required")

        case .matchesRegex(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                // Unreachable in practice: `Rubric.init` compiles every pattern.
                // Kept as a non-trapping fallback rather than a `try!`.
                return (false, "pattern failed to compile")
            }
            let range = NSRange(text.startIndex..., in: text)
            let hit = regex.firstMatch(in: text, range: range) != nil
            return (hit, hit ? "matched /\(pattern)/" : "no match for /\(pattern)/")

        case .isValidJSON:
            let data = Data(text.utf8)
            let valid = (try? JSONSerialization.jsonObject(with: data)) != nil
            return (valid, valid ? "parsed as JSON" : "not valid JSON")

        case .jsonHasKeys(let keys):
            let data = Data(text.utf8)
            guard
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any]
            else {
                return (false, "not a JSON object")
            }
            let missing = keys.filter { dictionary[$0] == nil }
            return (missing.isEmpty, missing.isEmpty ? "all keys present" : "missing \(missing.sorted())")

        case .numericWithin(let range, let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return (false, "pattern failed to compile")
            }
            let nsRange = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange) else {
                return (false, "no numeric match for /\(pattern)/")
            }
            // Prefer capture group 1 when the pattern defines one, else the
            // whole match. `numberOfRanges` is always >= 1 for a match.
            let groupIndex = match.numberOfRanges > 1 ? 1 : 0
            let matchedRange = match.range(at: groupIndex)
            guard
                matchedRange.location != NSNotFound,
                let swiftRange = Range(matchedRange, in: text),
                let number = Double(text[swiftRange])
            else {
                return (false, "matched text was not a number")
            }
            let inRange = range.contains(number)
            return (inRange, "\(number) \(inRange ? "within" : "outside") \(range.lowerBound)...\(range.upperBound)")

        case .maxCharacters(let limit):
            let withinLimit = text.count <= limit
            return (withinLimit, "\(text.count) chars, limit \(limit)")
        }
    }
}

// MARK: - Exact match

/// Baseline scorer for cases that genuinely have one right answer.
public struct ExactMatchScorer: Scorer {
    public let name = "exact-match"
    private let trimmingWhitespace: Bool

    public init(trimmingWhitespace: Bool = true) {
        self.trimmingWhitespace = trimmingWhitespace
    }

    public func score(response: ModelResponse, for goldenCase: GoldenCase) async throws -> ScoreBreakdown {
        guard let reference = goldenCase.referenceOutput else {
            return ScoreBreakdown(
                score: Score(0),
                components: [
                    .init(name: "reference-present", weight: 1, passed: false, detail: "case has no referenceOutput")
                ],
                notes: ["ExactMatchScorer requires a referenceOutput; scoring 0."]
            )
        }
        let lhs = trimmingWhitespace
            ? response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : response.text
        let rhs = trimmingWhitespace
            ? reference.trimmingCharacters(in: .whitespacesAndNewlines)
            : reference
        let matched = lhs == rhs
        return ScoreBreakdown(
            score: Score(matched ? 1 : 0),
            components: [
                .init(name: "exact-match", weight: 1, passed: matched, detail: matched ? "identical" : "differs")
            ]
        )
    }
}

// MARK: - Composition

/// Weighted combination of scorers — typically a cheap rubric carrying most of
/// the weight with a judge supplying the residual subjective signal.
public struct CompositeScorer: Scorer {
    public struct Entry: Sendable {
        public let scorer: any Scorer
        public let weight: Double

        public init(scorer: any Scorer, weight: Double) {
            self.scorer = scorer
            self.weight = weight
        }
    }

    public let name: String
    private let entries: [Entry]
    private let totalWeight: Double

    /// Entries with non-positive weight are dropped rather than trusted. If that
    /// leaves nothing, the composite degrades to a hard zero with an explanatory
    /// component instead of dividing by zero.
    public init(name: String = "composite", entries: [Entry]) {
        let usable = entries.filter { $0.weight > 0 }
        self.name = name
        self.entries = usable
        self.totalWeight = usable.reduce(0.0) { $0 + $1.weight }
    }

    public func score(response: ModelResponse, for goldenCase: GoldenCase) async throws -> ScoreBreakdown {
        guard !entries.isEmpty, totalWeight > 0 else {
            return ScoreBreakdown(
                score: Score(0),
                components: [
                    .init(name: "composite", weight: 1, passed: false, detail: "no positively-weighted scorers")
                ],
                notes: ["CompositeScorer was configured with no usable entries."]
            )
        }

        var weighted = 0.0
        var components: [ScoreBreakdown.Component] = []
        var flags: Set<ScoreFlag> = []
        var notes: [String] = []

        for entry in entries {
            let breakdown = try await entry.scorer.score(response: response, for: goldenCase)
            weighted += breakdown.score.value * entry.weight
            flags.formUnion(breakdown.flags)
            notes.append(contentsOf: breakdown.notes)
            components.append(
                .init(
                    name: entry.scorer.name,
                    weight: entry.weight,
                    passed: breakdown.failedComponents.isEmpty,
                    detail: "score \(breakdown.score)"
                )
            )
            components.append(contentsOf: breakdown.components.map {
                .init(name: "\(entry.scorer.name).\($0.name)", weight: $0.weight, passed: $0.passed, detail: $0.detail)
            })
        }

        return ScoreBreakdown(
            score: Score(weighted / totalWeight),
            components: components,
            flags: flags,
            notes: notes
        )
    }
}
