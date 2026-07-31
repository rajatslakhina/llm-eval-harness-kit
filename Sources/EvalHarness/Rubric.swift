import Foundation

/// A deterministic, weighted set of checks over a model's output.
///
/// Rubrics exist so that the *majority* of an eval suite never needs a judge
/// model at all. Judges are expensive, slow and themselves non-deterministic;
/// every assertion that can be expressed as "must contain this claim", "must be
/// valid JSON with these keys", "must not leak this token" belongs here instead.
public struct Rubric: Sendable, Hashable {

    /// The kinds of assertion a rubric can make about a response.
    public enum Kind: Sendable, Hashable {
        case contains(String, caseSensitive: Bool)
        case doesNotContain(String, caseSensitive: Bool)
        case matchesRegex(String)
        case isValidJSON
        case jsonHasKeys([String])
        /// Extracts the first capture group of `pattern` and asserts it parses
        /// as a number inside `range`.
        case numericWithin(ClosedRange<Double>, extractedBy: String)
        case maxCharacters(Int)
    }

    public struct Check: Sendable, Hashable {
        public let name: String
        /// Relative weight. Must be > 0; a zero-weight check is a check nobody
        /// can fail, which is worse than no check at all.
        public let weight: Double
        public let kind: Kind

        public init(name: String, weight: Double = 1.0, kind: Kind) {
            self.name = name
            self.weight = weight
            self.kind = kind
        }
    }

    public let checks: [Check]

    /// Sum of all check weights. Guaranteed > 0 by the initialiser, so scoring
    /// can divide by it without a zero guard at every call site.
    public let totalWeight: Double

    /// - Throws: ``EvalError/invalidRubric(reason:)`` for empty or
    ///   non-positively-weighted rubrics, and
    ///   ``EvalError/invalidRubricPattern(pattern:)`` if any regex is malformed.
    ///
    /// Trade-off, deliberately taken: patterns are validated here by compiling
    /// them and then thrown away, so `Rubric` stays a plain `Hashable` value
    /// type that can be diffed, stored and compared. The scorer recompiles at
    /// use time. That costs a regex compile per check per case — negligible
    /// against a model call — and buys a rubric that is trivially serialisable.
    /// The rejected alternative (caching `NSRegularExpression` inside the
    /// struct) would have made `Rubric` reference-holding and non-`Hashable`.
    public init(checks: [Check]) throws {
        guard !checks.isEmpty else {
            throw EvalError.invalidRubric(reason: "a rubric must contain at least one check")
        }
        for check in checks {
            guard check.weight > 0 else {
                throw EvalError.invalidRubric(
                    reason: "check '\(check.name)' has non-positive weight \(check.weight)"
                )
            }
            try Rubric.validatePattern(in: check.kind)
        }
        let total = checks.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else {
            throw EvalError.invalidRubric(reason: "total weight must be greater than zero")
        }
        self.checks = checks
        self.totalWeight = total
    }

    private static func validatePattern(in kind: Kind) throws {
        let pattern: String?
        switch kind {
        case .matchesRegex(let p): pattern = p
        case .numericWithin(_, let p): pattern = p
        case .contains, .doesNotContain, .isValidJSON, .jsonHasKeys, .maxCharacters:
            pattern = nil
        }
        guard let pattern else { return }
        guard (try? NSRegularExpression(pattern: pattern)) != nil else {
            throw EvalError.invalidRubricPattern(pattern: pattern)
        }
    }
}
