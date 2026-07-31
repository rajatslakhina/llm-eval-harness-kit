import Foundation

/// One case, evaluated against two targets.
public struct TargetDelta: Sendable, Hashable, Identifiable {
    public enum Classification: Sendable, Hashable {
        case parity
        /// The primary target is materially better — usually "cloud beats
        /// on-device", the gap that decides whether a feature can ship offline.
        case primaryAhead(delta: Double)
        case secondaryAhead(delta: Double)
        /// One side could not be scored, so no comparison is possible.
        case incomparable(reason: String)
    }

    public let caseID: String
    public let slice: String
    public let primaryScore: Double?
    public let secondaryScore: Double?
    public let classification: Classification

    public var id: String { caseID }
}

/// Side-by-side capability report for two model targets.
///
/// The reason this belongs in the harness rather than in a one-off script: the
/// on-device-versus-cloud gap is a *product* decision (can this feature work in
/// airplane mode?) that changes silently every time either side ships a new
/// build. Measuring it once during a spike tells you nothing six weeks later.
/// Measuring it on every run turns it into a tracked, defensible number.
public struct TargetComparison: Sendable {
    public let primary: ModelDescriptor
    public let secondary: ModelDescriptor
    public let deltas: [TargetDelta]
    /// Tolerance below which the two targets are called equivalent.
    public let parityTolerance: Double

    public init(
        primaryRun: EvalRun,
        secondaryRun: EvalRun,
        parityTolerance: Double = 0.05
    ) {
        self.primary = primaryRun.model
        self.secondary = secondaryRun.model
        self.parityTolerance = max(0, parityTolerance)

        var secondaryByID: [String: CaseResult] = [:]
        secondaryByID.reserveCapacity(secondaryRun.results.count)
        for result in secondaryRun.results { secondaryByID[result.caseID] = result }

        let tolerance = max(0, parityTolerance)
        var computed: [TargetDelta] = []
        computed.reserveCapacity(primaryRun.results.count)

        for primaryResult in primaryRun.results {
            let secondaryResult = secondaryByID[primaryResult.caseID]
            let primaryScore = primaryResult.score?.value
            let secondaryScore = secondaryResult?.score?.value

            let classification: TargetDelta.Classification
            if secondaryResult == nil {
                classification = .incomparable(reason: "case absent from the secondary run")
            } else if let lhs = primaryScore, let rhs = secondaryScore {
                let delta = lhs - rhs
                if abs(delta) <= tolerance {
                    classification = .parity
                } else if delta > 0 {
                    classification = .primaryAhead(delta: delta)
                } else {
                    classification = .secondaryAhead(delta: -delta)
                }
            } else {
                classification = .incomparable(reason: "at least one target produced no score")
            }

            computed.append(
                TargetDelta(
                    caseID: primaryResult.caseID,
                    slice: primaryResult.slice,
                    primaryScore: primaryScore,
                    secondaryScore: secondaryScore,
                    classification: classification
                )
            )
        }

        // Cases the secondary run has and the primary does not are reported too,
        // rather than dropped — an asymmetric suite is itself a finding.
        let primaryIDs = Set(primaryRun.results.map(\.caseID))
        for result in secondaryRun.results where !primaryIDs.contains(result.caseID) {
            computed.append(
                TargetDelta(
                    caseID: result.caseID,
                    slice: result.slice,
                    primaryScore: nil,
                    secondaryScore: result.score?.value,
                    classification: .incomparable(reason: "case absent from the primary run")
                )
            )
        }

        self.deltas = computed.sorted { $0.caseID < $1.caseID }
    }

    /// Cases where the primary target is meaningfully ahead — the capability
    /// gap a product decision has to absorb.
    public var capabilityGaps: [TargetDelta] {
        deltas.filter {
            if case .primaryAhead = $0.classification { return true }
            return false
        }
    }

    /// Share of comparable cases at parity. Returns 0 when nothing is
    /// comparable, rather than a flattering 1.
    public var parityRate: Double {
        let comparable = deltas.filter {
            if case .incomparable = $0.classification { return false }
            return true
        }
        guard !comparable.isEmpty else { return 0 }
        let atParity = comparable.filter {
            if case .parity = $0.classification { return true }
            return false
        }
        return Double(atParity.count) / Double(comparable.count)
    }
}
