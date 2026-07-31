import Foundation

/// Where a golden case came from. Provenance is not decoration: a suite whose
/// cases nobody can trace back to real traffic drifts into synthetic
/// self-congratulation within about two quarters.
public struct CaseProvenance: Sendable, Hashable, Codable {
    /// Identifier of the production trace this case was distilled from, if any.
    public let sourceTraceID: String?
    public let capturedAt: Date
    /// Why this case is in the suite — usually the incident or bug it encodes.
    public let rationale: String

    public init(sourceTraceID: String? = nil, capturedAt: Date, rationale: String) {
        self.sourceTraceID = sourceTraceID
        self.capturedAt = capturedAt
        self.rationale = rationale
    }
}

/// One curated input/expectation pair.
public struct GoldenCase: Sendable, Hashable, Identifiable {
    public let id: String
    /// The fully-rendered prompt sent to the model.
    public let prompt: String
    /// The behavioural slice this case belongs to (for example `"tool-call"`,
    /// `"refusal"`, `"summarisation"`). Slices are how the gate avoids the
    /// aggregate-pass-rate vanity metric — see ``GateThresholds``.
    public let slice: String
    public let rubric: Rubric
    /// Optional reference answer, for exact-match or similarity scorers.
    public let referenceOutput: String?
    public let provenance: CaseProvenance

    public init(
        id: String,
        prompt: String,
        slice: String,
        rubric: Rubric,
        referenceOutput: String? = nil,
        provenance: CaseProvenance
    ) {
        self.id = id
        self.prompt = prompt
        self.slice = slice
        self.rubric = rubric
        self.referenceOutput = referenceOutput
        self.provenance = provenance
    }
}

/// A validated, non-empty collection of golden cases with unique identifiers.
public struct GoldenSet: Sendable, Hashable {
    public let cases: [GoldenCase]

    /// Slice names present in the set, in stable sorted order.
    public let slices: [String]

    /// - Throws: ``EvalError/emptyGoldenSet`` or
    ///   ``EvalError/duplicateCaseID(_:)``.
    ///
    /// Both invariants are enforced at construction rather than at run time so
    /// that no downstream component has to defend against them.
    public init(cases: [GoldenCase]) throws {
        guard !cases.isEmpty else { throw EvalError.emptyGoldenSet }

        var seen = Set<String>()
        seen.reserveCapacity(cases.count)
        for goldenCase in cases {
            guard seen.insert(goldenCase.id).inserted else {
                throw EvalError.duplicateCaseID(goldenCase.id)
            }
        }

        // Stable ordering by ID. Report output is diffed in code review, so it
        // must not depend on the order somebody happened to append cases in.
        self.cases = cases.sorted { $0.id < $1.id }
        self.slices = Set(cases.map(\.slice)).sorted()
    }

    public var count: Int { cases.count }

    /// All cases in a given slice. Returns an empty array for unknown slices
    /// rather than trapping.
    public func cases(in slice: String) -> [GoldenCase] {
        cases.filter { $0.slice == slice }
    }
}
