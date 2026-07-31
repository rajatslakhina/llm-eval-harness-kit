import Foundation
import XCTest
import EvalHarness
import EvalHarnessUI

/// Pins the three outcomes the demo app advertises.
///
/// These use the **public** API only — no `@testable` — so they double as proof
/// that the package is usable from another module the way a real consumer would
/// use it. Every number quoted in the demo app's README is asserted here.
final class DemoScenarioTests: XCTestCase {

    private func run(_ scenario: DemoScenario) async throws -> DemoRunOutcome {
        try await DemoRunner.run(
            scenario: scenario,
            store: InMemoryTranscriptStore(),
            counter: UpstreamCallCounter()
        )
    }

    // MARK: - Thresholds

    func testTheSliceFloorIsGenuinelyStricterThanTheGlobalFloor() {
        let thresholds = DemoScenario().thresholds
        XCTAssertEqual(thresholds.minGlobalMeanScore, 0.70, accuracy: 0.0001)
        XCTAssertEqual(thresholds.minSliceMeanScore, 0.80, accuracy: 0.0001)
        XCTAssertGreaterThan(
            thresholds.minSliceMeanScore,
            thresholds.minGlobalMeanScore,
            "the gap between these two numbers is the entire demonstration"
        )
    }

    // MARK: - Healthy baseline

    func testAcceptedPromptOnTheOldBuildPassesTheGate() async throws {
        let outcome = try await run(DemoScenario(promptRevision: 1, modelBuild: DemoScenario.juneBuild))
        XCTAssertTrue(outcome.report.gate.isPass, "reasons: \(outcome.report.gate.reasons)")
        XCTAssertEqual(outcome.report.globalMeanScore, 0.9375, accuracy: 0.0001)
        XCTAssertEqual(outcome.report.run.results.count, 8)
    }

    func testTheAmbiguousCaseIsQuarantinedAsFlakyAndDoesNotBlock() async throws {
        let outcome = try await run(DemoScenario())
        guard case .quarantinedFlaky? = outcome.verdicts["summary-03"] else {
            return XCTFail("expected .quarantinedFlaky, got \(String(describing: outcome.verdicts["summary-03"]))")
        }
        XCTAssertEqual(outcome.verdicts["summary-03"]?.isBlocking, false)
    }

    // MARK: - Prompt regression

    func testEditedPromptFailsTheRefusalSliceWhileTheGlobalMeanStaysHealthy() async throws {
        let outcome = try await run(DemoScenario(promptRevision: 2, modelBuild: DemoScenario.juneBuild))
        let report = outcome.report

        // The headline claim of the whole project, asserted.
        XCTAssertEqual(report.globalMeanScore, 0.8125, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(report.globalMeanScore, report.thresholds.minGlobalMeanScore)
        XCTAssertFalse(report.gate.isPass)
        XCTAssertEqual(report.worstSlice?.slice, "refusal")
        XCTAssertEqual(report.worstSlice?.meanScore ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertTrue(report.gate.reasons.contains { $0.contains("refusal") })

        guard case .promptRegression? = outcome.verdicts["refusal-01"] else {
            return XCTFail("expected .promptRegression, got \(String(describing: outcome.verdicts["refusal-01"]))")
        }
    }

    // MARK: - Model drift

    func testNewProviderBuildFailsTheToolCallSliceAndIsNamedAsDrift() async throws {
        let outcome = try await run(DemoScenario(promptRevision: 1, modelBuild: DemoScenario.julyBuild))
        let report = outcome.report

        XCTAssertEqual(report.globalMeanScore, 0.8125, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(report.globalMeanScore, report.thresholds.minGlobalMeanScore)
        XCTAssertFalse(report.gate.isPass)
        XCTAssertEqual(report.worstSlice?.slice, "tool-call")

        guard case .modelDrift(_, let fromBuild, let toBuild)? = outcome.verdicts["toolcall-02"] else {
            return XCTFail("expected .modelDrift, got \(String(describing: outcome.verdicts["toolcall-02"]))")
        }
        XCTAssertEqual(fromBuild, DemoScenario.juneBuild)
        XCTAssertEqual(toBuild, DemoScenario.julyBuild)
    }

    // MARK: - Budget

    func testTightBudgetFailsOnCostAloneWithQualityUntouched() async throws {
        let outcome = try await run(
            DemoScenario(promptRevision: 1, modelBuild: DemoScenario.juneBuild, tightBudget: true)
        )
        let report = outcome.report

        // Quality is identical to the passing scenario …
        XCTAssertEqual(report.globalMeanScore, 0.9375, accuracy: 0.0001)
        XCTAssertTrue(report.blockingVerdicts.isEmpty)
        // … and the gate is red anyway, for exactly one reason.
        XCTAssertFalse(report.gate.isPass)
        XCTAssertEqual(report.gate.reasons.count, 1)
        XCTAssertTrue(report.gate.reasons.contains { $0.contains("cost budget") })
    }

    // MARK: - Hermeticity

    func testTheSecondRunIsServedEntirelyFromTheTranscriptCache() async throws {
        let store = InMemoryTranscriptStore()
        let counter = UpstreamCallCounter()
        let scenario = DemoScenario()

        let first = try await DemoRunner.run(scenario: scenario, store: store, counter: counter)
        let second = try await DemoRunner.run(scenario: scenario, store: store, counter: counter)

        XCTAssertEqual(first.upstreamCalls, 8, "the first run has to populate the cache")
        XCTAssertEqual(second.upstreamCalls, first.upstreamCalls, "the second run must not reach upstream at all")
        XCTAssertEqual(second.cachedTranscripts, 8)
        XCTAssertEqual(
            first.report.run.results.compactMap { $0.score?.value },
            second.report.run.results.compactMap { $0.score?.value }
        )
    }

    // MARK: - Staleness

    func testTheScenarioSummaryDistinguishesBudgetSettings() {
        let loose = DemoScenario(tightBudget: false).summary
        let tight = DemoScenario(tightBudget: true).summary
        XCTAssertNotEqual(loose, tight, "a displayed report must be attributable to its budget setting")
    }
}
