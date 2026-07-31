import Foundation

/// What the previous accepted run recorded for one case.
public struct BaselineEntry: Sendable, Hashable, Codable {
    public let caseID: String
    public let score: Double
    public let promptVersion: PromptVersion
    public let modelBuild: String
    /// Recent scores, oldest first, excluding the baseline score itself.
    /// Used only for flakiness detection.
    public let history: [Double]

    public init(
        caseID: String,
        score: Double,
        promptVersion: PromptVersion,
        modelBuild: String,
        history: [Double] = []
    ) {
        self.caseID = caseID
        self.score = score
        self.promptVersion = promptVersion
        self.modelBuild = modelBuild
        self.history = history
    }
}

/// The accepted state of the suite: the thing a PR is compared against.
public struct Baseline: Sendable, Hashable, Codable {
    public let runID: String
    public let recordedAt: Date
    public let entries: [String: BaselineEntry]

    public init(runID: String, recordedAt: Date, entries: [BaselineEntry]) {
        self.runID = runID
        self.recordedAt = recordedAt
        var map: [String: BaselineEntry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries { map[entry.caseID] = entry }
        self.entries = map
    }

    public func entry(for caseID: String) -> BaselineEntry? { entries[caseID] }

    /// Folds a run into a new baseline, keeping a bounded score history per case.
    ///
    /// The history window is capped deliberately: unbounded history makes the
    /// committed baseline file grow without limit and makes the flakiness
    /// statistic reflect a version of the prompt nobody is running any more.
    public func advanced(with run: EvalRun, historyLimit: Int = 10) -> Baseline {
        let cappedLimit = max(1, historyLimit)
        var updated: [BaselineEntry] = []
        updated.reserveCapacity(run.results.count)

        for result in run.results {
            guard let score = result.score else { continue }
            let previous = entries[result.caseID]
            var history = previous.map { $0.history + [$0.score] } ?? []
            if history.count > cappedLimit {
                history = Array(history.suffix(cappedLimit))
            }
            updated.append(
                BaselineEntry(
                    caseID: result.caseID,
                    score: score.value,
                    promptVersion: run.promptVersion,
                    modelBuild: run.model.build,
                    history: history
                )
            )
        }

        return Baseline(runID: run.runID, recordedAt: run.startedAt, entries: updated)
    }

    public static func empty() -> Baseline {
        Baseline(runID: "none", recordedAt: Date(timeIntervalSince1970: 0), entries: [])
    }
}

/// Per-case judgement, and the reason for it.
public enum CaseVerdict: Sendable, Hashable {
    case pass
    case newCase
    case improvement(delta: Double)
    /// Score dropped **and** the prompt revision changed: this PR caused it.
    case promptRegression(delta: Double)
    /// Score dropped with the prompt untouched: the provider moved under you.
    case modelDrift(delta: Double, fromBuild: String, toBuild: String)
    /// Historically unstable. Reported, but does not block a merge.
    case quarantinedFlaky(standardDeviation: Double)
    case harnessFailure(reason: String)
    case skipped(reason: String)

    /// Whether this verdict should stop a merge.
    ///
    /// Flaky cases deliberately do not block. A gate that blocks on noise gets
    /// switched off within a month, and a gate nobody runs protects nothing.
    public var isBlocking: Bool {
        switch self {
        case .promptRegression, .modelDrift, .harnessFailure, .skipped:
            return true
        case .pass, .newCase, .improvement, .quarantinedFlaky:
            return false
        }
    }
}

public struct RegressionPolicy: Sendable, Hashable, Codable {
    /// How far a score may fall before it counts as a regression.
    public let tolerance: Double
    /// How far it must rise before it is called an improvement rather than noise.
    public let improvementThreshold: Double
    /// Standard deviation above which a case is quarantined as flaky.
    public let flakyStandardDeviation: Double
    /// Samples needed before flakiness is a meaningful claim. Two points is a
    /// line, not a distribution.
    public let minimumHistoryForFlakiness: Int

    public init(
        tolerance: Double = 0.05,
        improvementThreshold: Double = 0.05,
        flakyStandardDeviation: Double = 0.15,
        minimumHistoryForFlakiness: Int = 3
    ) {
        self.tolerance = max(0, tolerance)
        self.improvementThreshold = max(0, improvementThreshold)
        self.flakyStandardDeviation = max(0, flakyStandardDeviation)
        self.minimumHistoryForFlakiness = max(2, minimumHistoryForFlakiness)
    }

    public static let `default` = RegressionPolicy()
}

/// Turns "the number moved" into "here is who moved it".
///
/// The classification order below is itself the design, and it is deliberate:
///
/// 1. **Harness failures first.** A cache miss is not a quality signal.
/// 2. **No baseline → new case.** New cases never block; they establish one.
/// 3. **Flakiness before regression.** A historically unstable case is
///    quarantined *before* its delta is interpreted, otherwise noise is
///    permanently indistinguishable from regression and the gate cries wolf.
/// 4. **Improvement, then within-tolerance pass.**
/// 5. **Only then** is a real drop attributed — to the prompt if the revision
///    changed, to the model otherwise.
///
/// Step 5 is the whole point of versioning prompts in the transcript key. Without
/// it, every drop looks identical and every investigation starts from zero.
public enum RegressionClassifier {

    public static func classify(
        run: EvalRun,
        baseline: Baseline?,
        policy: RegressionPolicy = .default
    ) -> [String: CaseVerdict] {
        var verdicts: [String: CaseVerdict] = [:]
        verdicts.reserveCapacity(run.results.count)

        for result in run.results {
            verdicts[result.caseID] = verdict(for: result, run: run, baseline: baseline, policy: policy)
        }
        return verdicts
    }

    private static func verdict(
        for result: CaseResult,
        run: EvalRun,
        baseline: Baseline?,
        policy: RegressionPolicy
    ) -> CaseVerdict {
        switch result.outcome {
        case .failed(let reason):
            return .harnessFailure(reason: reason)
        case .skipped(let reason):
            return .skipped(reason: reason)
        case .scored(let breakdown, _):
            guard let entry = baseline?.entry(for: result.caseID) else {
                return .newCase
            }

            let sample = entry.history + [entry.score]
            if sample.count >= policy.minimumHistoryForFlakiness {
                let deviation = standardDeviation(sample)
                if deviation > policy.flakyStandardDeviation {
                    return .quarantinedFlaky(standardDeviation: deviation)
                }
            }

            let delta = breakdown.score.value - entry.score
            if delta >= policy.improvementThreshold {
                return .improvement(delta: delta)
            }
            if delta >= -policy.tolerance {
                return .pass
            }
            if entry.promptVersion != run.promptVersion {
                return .promptRegression(delta: delta)
            }
            return .modelDrift(delta: delta, fromBuild: entry.modelBuild, toBuild: run.model.build)
        }
    }

    /// Population standard deviation.
    ///
    /// Returns 0 for fewer than two samples instead of dividing by zero — the
    /// arithmetic that turns a statistics helper into a crash report.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let count = Double(values.count)
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        return variance > 0 ? variance.squareRoot() : 0
    }
}
