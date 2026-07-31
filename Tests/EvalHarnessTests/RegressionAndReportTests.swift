import Foundation
import XCTest
@testable import EvalHarness

final class RegressionAndReportTests: XCTestCase {

    // MARK: - Helpers

    private func result(_ id: String, slice: String = "general", score: Double) -> CaseResult {
        CaseResult(
            caseID: id,
            slice: slice,
            outcome: .scored(
                breakdown: ScoreBreakdown(score: Score(score), components: []),
                response: Fixture.response("x")
            )
        )
    }

    private func run(
        results: [CaseResult],
        promptVersion: PromptVersion = Fixture.promptV1,
        model: ModelDescriptor = Fixture.onDevice,
        budget: BudgetSnapshot = BudgetSnapshot(
            inputTokens: 10, outputTokens: 10, costUSD: 0.01, p95LatencySeconds: 0.2, breaches: []
        )
    ) -> EvalRun {
        EvalRun(
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0),
            promptVersion: promptVersion,
            model: model,
            results: results,
            budget: budget
        )
    }

    private func baseline(
        _ entries: [BaselineEntry],
        at time: TimeInterval = 0
    ) -> Baseline {
        Baseline(runID: "base", recordedAt: Date(timeIntervalSince1970: time), entries: entries)
    }

    // MARK: - Classification

    func testCaseWithNoBaselineIsNewAndDoesNotBlock() {
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.4)]),
            baseline: baseline([])
        )
        XCTAssertEqual(verdicts["a"], .newCase)
        XCTAssertEqual(verdicts["a"]?.isBlocking, false)
    }

    func testSmallDropWithinToleranceIsAPass() {
        let entry = BaselineEntry(caseID: "a", score: 0.90, promptVersion: Fixture.promptV1, modelBuild: "b1")
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.87)]),
            baseline: baseline([entry]),
            policy: RegressionPolicy(tolerance: 0.05)
        )
        XCTAssertEqual(verdicts["a"], .pass)
    }

    func testDropWithAChangedPromptRevisionIsAttributedToThePrompt() {
        // Same case, same model build, but the prompt revision moved — so the
        // change in this PR is the cause.
        let entry = BaselineEntry(caseID: "a", score: 0.9, promptVersion: Fixture.promptV1, modelBuild: "2026.07.1")
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.4)], promptVersion: Fixture.promptV2),
            baseline: baseline([entry])
        )
        guard case .promptRegression(let delta)? = verdicts["a"] else {
            return XCTFail("expected .promptRegression, got \(String(describing: verdicts["a"]))")
        }
        XCTAssertEqual(delta, -0.5, accuracy: 0.0001)
        XCTAssertTrue(verdicts["a"]?.isBlocking == true)
    }

    func testDropWithAnUnchangedPromptIsAttributedToModelDrift() {
        // Nobody touched the prompt; the provider shipped a new build.
        let entry = BaselineEntry(caseID: "a", score: 0.9, promptVersion: Fixture.promptV1, modelBuild: "2026.06.1")
        let newBuild = ModelDescriptor(identifier: "apple.foundation-models", build: "2026.07.1", tier: .onDevice)
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.4)], promptVersion: Fixture.promptV1, model: newBuild),
            baseline: baseline([entry])
        )
        guard case .modelDrift(let delta, let from, let to)? = verdicts["a"] else {
            return XCTFail("expected .modelDrift, got \(String(describing: verdicts["a"]))")
        }
        XCTAssertEqual(delta, -0.5, accuracy: 0.0001)
        XCTAssertEqual(from, "2026.06.1")
        XCTAssertEqual(to, "2026.07.1")
    }

    func testLargeRiseIsReportedAsAnImprovement() {
        let entry = BaselineEntry(caseID: "a", score: 0.4, promptVersion: Fixture.promptV1, modelBuild: "b1")
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.9)]),
            baseline: baseline([entry])
        )
        guard case .improvement? = verdicts["a"] else {
            return XCTFail("expected .improvement, got \(String(describing: verdicts["a"]))")
        }
    }

    func testHistoricallyUnstableCaseIsQuarantinedBeforeItsDeltaIsInterpreted() {
        // A gate that blocks on noise gets switched off. This case swings wildly
        // across history, so it is quarantined rather than called a regression.
        let entry = BaselineEntry(
            caseID: "a",
            score: 0.9,
            promptVersion: Fixture.promptV1,
            modelBuild: "b1",
            history: [0.1, 0.95, 0.2, 0.85]
        )
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.2)]),
            baseline: baseline([entry])
        )
        guard case .quarantinedFlaky? = verdicts["a"] else {
            return XCTFail("expected .quarantinedFlaky, got \(String(describing: verdicts["a"]))")
        }
        XCTAssertEqual(verdicts["a"]?.isBlocking, false, "flaky cases must not block merges")
    }

    func testStableHistoryDoesNotTriggerQuarantine() {
        let entry = BaselineEntry(
            caseID: "a",
            score: 0.90,
            promptVersion: Fixture.promptV1,
            modelBuild: "b1",
            history: [0.90, 0.91, 0.89, 0.90]
        )
        let verdicts = RegressionClassifier.classify(
            run: run(results: [result("a", score: 0.30)]),
            baseline: baseline([entry])
        )
        guard case .modelDrift? = verdicts["a"] else {
            return XCTFail("expected .modelDrift, got \(String(describing: verdicts["a"]))")
        }
    }

    func testHarnessFailuresAreNotTreatedAsQualitySignals() {
        let failed = CaseResult(caseID: "a", slice: "general", outcome: .failed(reason: "cache miss"))
        let verdicts = RegressionClassifier.classify(run: run(results: [failed]), baseline: baseline([]))
        guard case .harnessFailure? = verdicts["a"] else {
            return XCTFail("expected .harnessFailure, got \(String(describing: verdicts["a"]))")
        }
        XCTAssertTrue(verdicts["a"]?.isBlocking == true)
    }

    func testStandardDeviationGuardsSmallSamples() {
        XCTAssertEqual(RegressionClassifier.standardDeviation([]), 0, accuracy: 0.0001)
        XCTAssertEqual(RegressionClassifier.standardDeviation([0.5]), 0, accuracy: 0.0001)
        XCTAssertEqual(RegressionClassifier.standardDeviation([0.5, 0.5, 0.5]), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(RegressionClassifier.standardDeviation([0.0, 1.0]), 0.4)
    }

    func testBaselineHistoryIsBounded() {
        var current = Baseline.empty()
        for index in 0..<25 {
            let scored = run(results: [result("a", score: Double(index % 2))])
            current = current.advanced(with: scored, historyLimit: 5)
        }
        let entry = current.entry(for: "a")
        XCTAssertNotNil(entry)
        XCTAssertLessThanOrEqual(entry?.history.count ?? 999, 5)
    }

    func testBaselineIgnoresUnscoredResults() {
        let failed = CaseResult(caseID: "a", slice: "general", outcome: .failed(reason: "boom"))
        let advanced = Baseline.empty().advanced(with: run(results: [failed]))
        XCTAssertNil(advanced.entry(for: "a"))
    }

    // MARK: - Gate

    func testEmptyRunFailsTheGateInsteadOfPassingVacuously() {
        // The headline failure mode this whole harness exists to prevent.
        let report = EvalReport(run: run(results: []), verdicts: [:])
        XCTAssertFalse(report.gate.isPass)
        XCTAssertEqual(report.globalMeanScore, 0, accuracy: 0.0001)
        XCTAssertTrue(report.gate.reasons.contains { $0.contains("no results") })
    }

    func testHealthyGlobalAverageDoesNotRescueACollapsedSlice() {
        // 18 strong cases in one slice, 2 collapsed cases in another. The global
        // mean is 0.9 — comfortably green under an aggregate-only gate — while
        // the refusal slice has gone to zero. This is the vanity metric, and the
        // gate must fail on it.
        var results = (0..<18).map { result("ok-\($0)", slice: "summarisation", score: 1.0) }
        results.append(result("refusal-0", slice: "refusal", score: 0.0))
        results.append(result("refusal-1", slice: "refusal", score: 0.0))

        let report = EvalReport(
            run: run(results: results),
            verdicts: [:],
            thresholds: GateThresholds(minGlobalMeanScore: 0.85, minSliceMeanScore: 0.7)
        )

        XCTAssertEqual(report.globalMeanScore, 0.9, accuracy: 0.0001)
        XCTAssertGreaterThan(report.globalMeanScore, 0.85, "the aggregate is healthy…")
        XCTAssertFalse(report.gate.isPass, "…and the gate must still fail on the collapsed slice")
        XCTAssertTrue(report.gate.reasons.contains { $0.contains("refusal") })
        XCTAssertEqual(report.worstSlice?.slice, "refusal")
    }

    func testGateFailsOnBudgetBreachEvenWhenQualityIsPerfect() {
        let breachedBudget = BudgetSnapshot(
            inputTokens: 100_000,
            outputTokens: 100_000,
            costUSD: 42,
            p95LatencySeconds: 9,
            breaches: [.cost(used: 42, limit: 1)]
        )
        let report = EvalReport(
            run: run(results: [result("a", score: 1.0)], budget: breachedBudget),
            verdicts: [:]
        )
        XCTAssertFalse(report.gate.isPass)
        XCTAssertTrue(report.gate.reasons.contains { $0.contains("cost budget") })
    }

    func testGateFailsWhenACaseCouldNotBeEvaluated() {
        let results = [
            result("a", score: 1.0),
            CaseResult(caseID: "b", slice: "general", outcome: .failed(reason: "cache miss")),
        ]
        let report = EvalReport(run: run(results: results), verdicts: [:])
        XCTAssertFalse(report.gate.isPass)
        XCTAssertTrue(report.gate.reasons.contains { $0.contains("could not be evaluated") })
    }

    func testHealthySuitePasses() {
        let results = [
            result("a", slice: "summarisation", score: 0.95),
            result("b", slice: "refusal", score: 0.92),
        ]
        let report = EvalReport(
            run: run(results: results),
            verdicts: ["a": .pass, "b": .pass]
        )
        XCTAssertTrue(report.gate.isPass, "reasons: \(report.gate.reasons)")
    }

    func testBlockingVerdictCountIsEnforced() {
        let report = EvalReport(
            run: run(results: [result("a", score: 1.0), result("b", score: 1.0)]),
            verdicts: ["a": .pass, "b": .promptRegression(delta: -0.4)],
            thresholds: GateThresholds(maxBlockingVerdicts: 0)
        )
        XCTAssertFalse(report.gate.isPass)
        XCTAssertEqual(report.blockingVerdicts.map(\.caseID), ["b"])
    }

    func testFlakyVerdictsDoNotCountTowardsTheBlockingLimit() {
        let report = EvalReport(
            run: run(results: [result("a", score: 0.95), result("b", score: 0.95)]),
            verdicts: ["a": .pass, "b": .quarantinedFlaky(standardDeviation: 0.3)],
            thresholds: GateThresholds(minGlobalMeanScore: 0.8, minSliceMeanScore: 0.7, maxBlockingVerdicts: 0)
        )
        XCTAssertTrue(report.gate.isPass, "reasons: \(report.gate.reasons)")
    }

    func testMarkdownSummaryNamesTheWorstSliceAndTheReasons() {
        var results = (0..<4).map { result("ok-\($0)", slice: "summarisation", score: 1.0) }
        results.append(result("refusal-0", slice: "refusal", score: 0.0))

        let report = EvalReport(
            run: run(results: results),
            verdicts: ["refusal-0": .promptRegression(delta: -1.0)]
        )
        let markdown = report.markdownSummary()

        XCTAssertTrue(markdown.contains("Eval gate: FAIL"))
        XCTAssertTrue(markdown.contains("Worst slice"))
        XCTAssertTrue(markdown.contains("refusal"))
        XCTAssertTrue(markdown.contains("PROMPT REGRESSION"))
        XCTAssertTrue(markdown.contains("| Slice | Cases | Mean | Blocking |"))
    }

    // MARK: - Dual-target comparison

    func testCapabilityGapBetweenOnDeviceAndCloudIsSurfaced() {
        let cloudRun = run(
            results: [result("a", score: 0.95), result("b", score: 0.90)],
            model: Fixture.cloud
        )
        let deviceRun = run(
            results: [result("a", score: 0.93), result("b", score: 0.30)],
            model: Fixture.onDevice
        )

        let comparison = TargetComparison(primaryRun: cloudRun, secondaryRun: deviceRun)
        XCTAssertEqual(comparison.capabilityGaps.map(\.caseID), ["b"])
        XCTAssertEqual(comparison.parityRate, 0.5, accuracy: 0.0001)
    }

    func testAsymmetricSuitesAreReportedRatherThanSilentlyDropped() {
        let primary = run(results: [result("a", score: 1.0)], model: Fixture.cloud)
        let secondary = run(results: [result("z", score: 1.0)], model: Fixture.onDevice)
        let comparison = TargetComparison(primaryRun: primary, secondaryRun: secondary)

        XCTAssertEqual(comparison.deltas.map(\.caseID), ["a", "z"])
        XCTAssertTrue(comparison.deltas.allSatisfy {
            if case .incomparable = $0.classification { return true }
            return false
        })
        XCTAssertEqual(comparison.parityRate, 0, accuracy: 0.0001, "nothing comparable must not report parity")
    }
}
