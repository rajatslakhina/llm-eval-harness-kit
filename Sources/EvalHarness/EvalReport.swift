import Foundation

/// Aggregate for one behavioural slice.
public struct SliceReport: Sendable, Hashable, Identifiable {
    public let slice: String
    public let caseCount: Int
    public let scoredCount: Int
    public let meanScore: Double
    public let blockingVerdicts: Int
    public let worstCaseID: String?

    public var id: String { slice }
}

/// The conditions a run must satisfy to let a merge through.
public struct GateThresholds: Sendable, Hashable, Codable {
    public let minGlobalMeanScore: Double
    /// Floor applied to **every** slice independently.
    public let minSliceMeanScore: Double
    public let maxBlockingVerdicts: Int
    public let requireWithinBudget: Bool
    public let allowHarnessFailures: Bool

    public init(
        minGlobalMeanScore: Double = 0.8,
        minSliceMeanScore: Double = 0.7,
        maxBlockingVerdicts: Int = 0,
        requireWithinBudget: Bool = true,
        allowHarnessFailures: Bool = false
    ) {
        self.minGlobalMeanScore = minGlobalMeanScore
        self.minSliceMeanScore = minSliceMeanScore
        self.maxBlockingVerdicts = maxBlockingVerdicts
        self.requireWithinBudget = requireWithinBudget
        self.allowHarnessFailures = allowHarnessFailures
    }

    public static let `default` = GateThresholds()
}

/// A case whose verdict stops a merge, paired with the verdict that did it.
public struct BlockingCase: Sendable, Hashable, Identifiable {
    public let caseID: String
    public let verdict: CaseVerdict

    public var id: String { caseID }

    public init(caseID: String, verdict: CaseVerdict) {
        self.caseID = caseID
        self.verdict = verdict
    }
}

public enum GateOutcome: Sendable, Hashable {
    case pass
    case fail(reasons: [String])

    public var isPass: Bool {
        if case .pass = self { return true }
        return false
    }

    public var reasons: [String] {
        if case .fail(let reasons) = self { return reasons }
        return []
    }
}

/// A run, its verdicts, its slices and its gate decision.
///
/// The central claim this type encodes: **aggregate pass rate is a vanity
/// metric.** A suite of 200 cases where the 12 refusal cases have collapsed to
/// zero still shows a 94% global mean and still goes green under a global-only
/// gate. So the gate here fails if *any* slice falls below its floor, regardless
/// of how healthy the average looks — and ``markdownSummary()`` prints the worst
/// slice *above* the global mean, so the number that hides the problem does not
/// get to go first.
public struct EvalReport: Sendable {
    public let run: EvalRun
    public let verdicts: [String: CaseVerdict]
    public let thresholds: GateThresholds
    public let slices: [SliceReport]
    public let globalMeanScore: Double
    public let gate: GateOutcome

    public init(run: EvalRun, verdicts: [String: CaseVerdict], thresholds: GateThresholds = .default) {
        self.run = run
        self.verdicts = verdicts
        self.thresholds = thresholds

        let scored = run.results.compactMap { $0.score?.value }
        // An empty or entirely-unscored run means 0, not 1. This is the
        // "empty suite reports 100%" bug, closed at the source.
        self.globalMeanScore = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)

        self.slices = EvalReport.buildSlices(results: run.results, verdicts: verdicts)
        self.gate = EvalReport.evaluateGate(
            results: run.results,
            slices: slices,
            verdicts: verdicts,
            globalMean: globalMeanScore,
            budget: run.budget,
            thresholds: thresholds
        )
    }

    public var blockingVerdicts: [BlockingCase] {
        verdicts
            .filter { $0.value.isBlocking }
            .map { BlockingCase(caseID: $0.key, verdict: $0.value) }
            .sorted { $0.caseID < $1.caseID }
    }

    /// The slice a reviewer should look at first, or `nil` for an empty run.
    public var worstSlice: SliceReport? {
        slices.min { lhs, rhs in
            if lhs.meanScore == rhs.meanScore { return lhs.slice < rhs.slice }
            return lhs.meanScore < rhs.meanScore
        }
    }

    // MARK: - Construction

    private static func buildSlices(
        results: [CaseResult],
        verdicts: [String: CaseVerdict]
    ) -> [SliceReport] {
        var grouped: [String: [CaseResult]] = [:]
        for result in results { grouped[result.slice, default: []].append(result) }

        return grouped.keys.sorted().map { slice in
            // `grouped[slice]` is present because `slice` came from its keys;
            // the `?? []` keeps this total rather than force-unwrapping.
            let members = grouped[slice] ?? []
            let scored = members.compactMap { $0.score?.value }
            let mean = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)
            let blocking = members.filter { verdicts[$0.caseID]?.isBlocking == true }.count

            let worst = members
                .filter { $0.isScored }
                .min { lhs, rhs in
                    let left = lhs.score?.value ?? 0
                    let right = rhs.score?.value ?? 0
                    if left == right { return lhs.caseID < rhs.caseID }
                    return left < right
                }?
                .caseID

            return SliceReport(
                slice: slice,
                caseCount: members.count,
                scoredCount: scored.count,
                meanScore: mean,
                blockingVerdicts: blocking,
                worstCaseID: worst
            )
        }
    }

    private static func evaluateGate(
        results: [CaseResult],
        slices: [SliceReport],
        verdicts: [String: CaseVerdict],
        globalMean: Double,
        budget: BudgetSnapshot,
        thresholds: GateThresholds
    ) -> GateOutcome {
        var reasons: [String] = []

        if results.isEmpty {
            reasons.append("run produced no results — an empty gate is a broken gate, not a passing one")
        }

        if globalMean < thresholds.minGlobalMeanScore {
            reasons.append(
                "global mean \(rounded(globalMean)) below floor \(rounded(thresholds.minGlobalMeanScore))"
            )
        }

        for slice in slices where slice.meanScore < thresholds.minSliceMeanScore {
            reasons.append(
                "slice '\(slice.slice)' mean \(rounded(slice.meanScore)) "
                + "below floor \(rounded(thresholds.minSliceMeanScore))"
            )
        }

        let blocking = verdicts.values.filter(\.isBlocking).count
        if blocking > thresholds.maxBlockingVerdicts {
            reasons.append("\(blocking) blocking verdicts, limit \(thresholds.maxBlockingVerdicts)")
        }

        if !thresholds.allowHarnessFailures {
            let failures = results.filter {
                if case .failed = $0.outcome { return true }
                return false
            }
            if !failures.isEmpty {
                reasons.append(
                    "\(failures.count) case(s) could not be evaluated: "
                    + failures.map(\.caseID).sorted().joined(separator: ", ")
                )
            }
        }

        if thresholds.requireWithinBudget {
            for breach in budget.breaches { reasons.append(breach.summary) }
        }

        return reasons.isEmpty ? .pass : .fail(reasons: reasons)
    }

    private static func rounded(_ value: Double) -> String {
        String((value * 1000).rounded() / 1000)
    }

    // MARK: - Rendering

    /// Markdown suitable for a CI job summary or a PR comment.
    public func markdownSummary() -> String {
        var lines: [String] = []
        lines.append("## Eval gate: \(gate.isPass ? "PASS" : "FAIL")")
        lines.append("")
        lines.append("- Prompt: `\(run.promptVersion)`")
        lines.append("- Model: `\(run.model.identifier)` build `\(run.model.build)` (\(run.model.tier.rawValue))")
        // Worst slice first, deliberately: the headline average is the number
        // that hides the problem, so it does not get to go at the top.
        if let worst = worstSlice {
            lines.append(
                "- Worst slice: **\(worst.slice)** at \(EvalReport.rounded(worst.meanScore))"
                + (worst.worstCaseID.map { " (worst case `\($0)`)" } ?? "")
            )
        }
        lines.append("- Global mean: \(EvalReport.rounded(globalMeanScore))")
        lines.append(
            "- Spend: \(run.budget.totalTokens) tokens, $\(EvalReport.rounded(run.budget.costUSD))"
            + (run.budget.p95LatencySeconds.map { ", p95 \(EvalReport.rounded($0))s" } ?? "")
        )

        if case .fail(let reasons) = gate {
            lines.append("")
            lines.append("### Why it failed")
            for reason in reasons { lines.append("- \(reason)") }
        }

        lines.append("")
        lines.append("### Slices")
        lines.append("| Slice | Cases | Mean | Blocking |")
        lines.append("|---|---:|---:|---:|")
        for slice in slices {
            lines.append(
                "| \(slice.slice) | \(slice.caseCount) | \(EvalReport.rounded(slice.meanScore)) "
                + "| \(slice.blockingVerdicts) |"
            )
        }

        let blocking = blockingVerdicts
        if !blocking.isEmpty {
            lines.append("")
            lines.append("### Blocking cases")
            for item in blocking {
                lines.append("- `\(item.caseID)` — \(EvalReport.describe(item.verdict))")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func describe(_ verdict: CaseVerdict) -> String {
        switch verdict {
        case .pass: return "pass"
        case .newCase: return "new case (no baseline)"
        case .improvement(let delta): return "improved by \(rounded(delta))"
        case .promptRegression(let delta):
            return "PROMPT REGRESSION \(rounded(delta)) — the prompt revision changed in this run"
        case .modelDrift(let delta, let from, let to):
            return "MODEL DRIFT \(rounded(delta)) — build \(from) → \(to), prompt unchanged"
        case .quarantinedFlaky(let deviation):
            return "quarantined as flaky (σ \(rounded(deviation))) — not blocking"
        case .harnessFailure(let reason): return "harness failure — \(reason)"
        case .skipped(let reason): return "skipped — \(reason)"
        }
    }
}
