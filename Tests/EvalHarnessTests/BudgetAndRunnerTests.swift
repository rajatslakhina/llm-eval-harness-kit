import Foundation
import XCTest
@testable import EvalHarness

final class BudgetAndRunnerTests: XCTestCase {

    // MARK: - Percentile edge cases

    func testPercentileOfNothingIsNilNotZero() async {
        // "We measured nothing" and "we measured zero seconds" must not gate the
        // same way.
        let ledger = BudgetLedger(budget: .unlimited)
        let value = await ledger.percentile(0.95)
        XCTAssertNil(value)
    }

    func testPercentileOfSingleSampleDoesNotIndexPastTheEnd() async {
        let ledger = BudgetLedger(budget: .unlimited)
        await ledger.charge(Fixture.response("a", latency: 1.5))
        let p95 = await ledger.percentile(0.95)
        let p100 = await ledger.percentile(1.0)
        XCTAssertEqual(p95 ?? -1, 1.5, accuracy: 0.0001)
        XCTAssertEqual(p100 ?? -1, 1.5, accuracy: 0.0001)
    }

    func testPercentileClampsOutOfRangeInputs() async {
        let ledger = BudgetLedger(budget: .unlimited)
        for value in [0.1, 0.2, 0.3, 0.4] {
            await ledger.charge(Fixture.response("a", latency: value))
        }
        // p > 1 and p < 0 are clamped rather than producing an invalid index.
        let above = await ledger.percentile(5.0)
        let below = await ledger.percentile(-5.0)
        XCTAssertEqual(above ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(below ?? -1, 0.1, accuracy: 0.0001)
    }

    // MARK: - Budget breaches

    func testTokenBudgetBreachIsDetected() async {
        let ledger = BudgetLedger(budget: RunBudget(maxTotalTokens: 40))
        await ledger.charge(Fixture.response("a", inputTokens: 20, outputTokens: 15))
        var snapshot = await ledger.snapshot()
        XCTAssertTrue(snapshot.isWithinBudget)

        await ledger.charge(Fixture.response("b", inputTokens: 20, outputTokens: 15))
        snapshot = await ledger.snapshot()
        XCTAssertFalse(snapshot.isWithinBudget)
        XCTAssertEqual(snapshot.totalTokens, 70)
    }

    func testCostAndLatencyBreachesAreReportedSeparately() async {
        let budget = RunBudget(maxTotalCostUSD: 0.001, maxP95LatencySeconds: 0.5)
        let ledger = BudgetLedger(budget: budget)
        await ledger.charge(Fixture.response("a", latency: 2.0, cost: 0.01))
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.breaches.count, 2)
    }

    // MARK: - Runner configuration

    func testZeroConcurrencyIsRejectedRatherThanDeadlocking() {
        XCTAssertThrowsError(try EvalRunConfiguration(maxConcurrentCases: 0)) { error in
            XCTAssertEqual(error as? EvalError, .invalidConcurrency(0))
        }
    }

    func testNegativeConcurrencyIsRejected() {
        XCTAssertThrowsError(try EvalRunConfiguration(maxConcurrentCases: -3)) { error in
            XCTAssertEqual(error as? EvalError, .invalidConcurrency(-3))
        }
    }

    // MARK: - Running

    private func makeSet(count: Int) throws -> GoldenSet {
        try GoldenSet(cases: (0..<count).map { index in
            GoldenCase(
                id: String(format: "case-%03d", index),
                prompt: "prompt-\(index)",
                slice: index.isMultiple(of: 2) ? "even" : "odd",
                rubric: try Rubric(checks: [
                    .init(name: "ok", weight: 1, kind: .contains("ok", caseSensitive: false))
                ]),
                provenance: Fixture.provenance()
            )
        })
    }

    func testResultsAreOrderedByCaseIDRegardlessOfCompletionOrder() async throws {
        let goldenSet = try makeSet(count: 12)
        let configuration = try EvalRunConfiguration(maxConcurrentCases: 6)
        let run = await EvalRunner(configuration: configuration).run(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: StubModel(alwaysReturning: "ok"),
            scorer: RubricScorer(),
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(run.results.count, 12)
        XCTAssertEqual(run.results.map(\.caseID), run.results.map(\.caseID).sorted())
        XCTAssertTrue(run.results.allSatisfy { $0.score?.value == 1 })
    }

    func testConcurrencyHigherThanCaseCountIsSafe() async throws {
        let goldenSet = try makeSet(count: 2)
        let configuration = try EvalRunConfiguration(maxConcurrentCases: 64)
        let run = await EvalRunner(configuration: configuration).run(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: StubModel(alwaysReturning: "ok"),
            scorer: RubricScorer(),
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(run.results.count, 2)
    }

    func testOneFailingCaseDoesNotDestroyTheWholeReport() async throws {
        // The report is what CI needs in order to explain itself. Letting a
        // single cache miss throw out of the task group would take the other
        // results with it.
        let goldenSet = try makeSet(count: 4)
        let configuration = try EvalRunConfiguration(maxConcurrentCases: 2)
        let run = await EvalRunner(configuration: configuration).run(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            modelDescriptor: Fixture.cloud,
            modelProvider: { goldenCase -> any EvalModel in
                if goldenCase.id == "case-002" { return ExplodingModel() }
                return StubModel(alwaysReturning: "ok")
            },
            scorer: RubricScorer(),
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(run.results.count, 4)
        let failed = run.results.filter { if case .failed = $0.outcome { return true } else { return false } }
        XCTAssertEqual(failed.map(\.caseID), ["case-002"])
        XCTAssertEqual(run.results.filter(\.isScored).count, 3)
    }

    func testFailFastBudgetStopsSchedulingAndMarksTheRemainderSkipped() async throws {
        let goldenSet = try makeSet(count: 20)
        let budget = RunBudget(maxTotalTokens: 30, onBreach: .failFast)
        let configuration = try EvalRunConfiguration(maxConcurrentCases: 1, budget: budget)
        let run = await EvalRunner(configuration: configuration).run(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: StubModel(alwaysReturning: "ok"),
            scorer: RubricScorer(),
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0)
        )

        // Every case is still accounted for — skipped, not silently missing.
        XCTAssertEqual(run.results.count, 20)
        let skipped = run.results.filter { if case .skipped = $0.outcome { return true } else { return false } }
        XCTAssertFalse(skipped.isEmpty, "fail-fast must stop scheduling")
        XCTAssertFalse(run.budget.isWithinBudget)
    }

    func testCompleteAndReportPolicyFinishesTheSuiteDespiteBreach() async throws {
        let goldenSet = try makeSet(count: 6)
        let budget = RunBudget(maxTotalTokens: 1, onBreach: .completeAndReport)
        let configuration = try EvalRunConfiguration(maxConcurrentCases: 3, budget: budget)
        let run = await EvalRunner(configuration: configuration).run(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: StubModel(alwaysReturning: "ok"),
            scorer: RubricScorer(),
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(run.results.filter(\.isScored).count, 6)
        XCTAssertFalse(run.budget.isWithinBudget)
    }

    func testBudgetAccumulatesAcrossConcurrentCases() async throws {
        let goldenSet = try makeSet(count: 5)
        let configuration = try EvalRunConfiguration(maxConcurrentCases: 5)
        let run = await EvalRunner(configuration: configuration).run(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: StubModel(alwaysReturning: "ok"),
            scorer: RubricScorer(),
            runID: "run-1",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        // 5 cases × (10 in + 20 out) tokens.
        XCTAssertEqual(run.budget.totalTokens, 150)
        XCTAssertEqual(run.budget.costUSD, 0.005, accuracy: 0.0001)
    }
}
