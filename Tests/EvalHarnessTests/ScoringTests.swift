import XCTest
@testable import EvalHarness

final class ScoringTests: XCTestCase {

    // MARK: - Score boundary handling

    func testScoreClampsAboveOneAndFlagsIt() {
        let score = Score(1.4)
        XCTAssertEqual(score.value, 1)
        XCTAssertTrue(score.wasClamped)
    }

    func testScoreClampsBelowZeroAndFlagsIt() {
        let score = Score(-0.3)
        XCTAssertEqual(score.value, 0)
        XCTAssertTrue(score.wasClamped)
    }

    func testNaNIsTrappedAtTheBoundary() {
        // Without this, one NaN poisons every mean and every comparison
        // downstream, and the gate silently stops working.
        let score = Score(Double.nan)
        XCTAssertEqual(score.value, 0)
        XCTAssertTrue(score.wasClamped)
        XCTAssertFalse(score.value.isNaN)
    }

    func testInRangeScoreIsNotFlagged() {
        let score = Score(0.5)
        XCTAssertEqual(score.value, 0.5, accuracy: 0.0001)
        XCTAssertFalse(score.wasClamped)
    }

    func testBreakdownPropagatesClampFlagAutomatically() {
        let breakdown = ScoreBreakdown(score: Score(2), components: [])
        XCTAssertTrue(breakdown.flags.contains(.scoreClamped))
    }

    // MARK: - Rubric scoring

    func testAllChecksPassingScoresOne() async throws {
        let rubric = try Rubric(checks: [
            .init(name: "greeting", weight: 1, kind: .contains("hello", caseSensitive: false)),
            .init(name: "brief", weight: 1, kind: .maxCharacters(50)),
        ])
        let goldenCase = GoldenCase(
            id: "c1", prompt: "p", slice: "general", rubric: rubric, provenance: Fixture.provenance()
        )
        let breakdown = try await RubricScorer().score(response: Fixture.response("Hello there"), for: goldenCase)
        XCTAssertEqual(breakdown.score.value, 1, accuracy: 0.0001)
        XCTAssertTrue(breakdown.failedComponents.isEmpty)
    }

    func testPartialCreditIsWeightedNotCounted() async throws {
        // A 3-weight check passing and a 1-weight check failing is 0.75, not 0.5.
        let rubric = try Rubric(checks: [
            .init(name: "important", weight: 3, kind: .contains("refund", caseSensitive: false)),
            .init(name: "minor", weight: 1, kind: .contains("sincerely", caseSensitive: false)),
        ])
        let goldenCase = GoldenCase(
            id: "c1", prompt: "p", slice: "general", rubric: rubric, provenance: Fixture.provenance()
        )
        let breakdown = try await RubricScorer().score(
            response: Fixture.response("Your refund is on its way."), for: goldenCase
        )
        XCTAssertEqual(breakdown.score.value, 0.75, accuracy: 0.0001)
        XCTAssertEqual(breakdown.failedComponents.map(\.name), ["minor"])
    }

    func testDoesNotContainCheckGuardsAgainstLeakedTokens() async throws {
        let rubric = try Rubric(checks: [
            .init(name: "no-system-prompt-leak", weight: 1, kind: .doesNotContain("SYSTEM:", caseSensitive: true))
        ])
        let goldenCase = GoldenCase(
            id: "c1", prompt: "p", slice: "safety", rubric: rubric, provenance: Fixture.provenance()
        )
        let clean = try await RubricScorer().score(response: Fixture.response("All good"), for: goldenCase)
        let leaked = try await RubricScorer().score(response: Fixture.response("SYSTEM: you are"), for: goldenCase)
        XCTAssertEqual(clean.score.value, 1, accuracy: 0.0001)
        XCTAssertEqual(leaked.score.value, 0, accuracy: 0.0001)
    }

    func testJSONChecksHandleMalformedOutputWithoutCrashing() async throws {
        let rubric = try Rubric(checks: [
            .init(name: "json", weight: 1, kind: .isValidJSON),
            .init(name: "keys", weight: 1, kind: .jsonHasKeys(["intent", "confidence"])),
        ])
        let goldenCase = GoldenCase(
            id: "c1", prompt: "p", slice: "tool-call", rubric: rubric, provenance: Fixture.provenance()
        )

        let good = try await RubricScorer().score(
            response: Fixture.response(#"{"intent":"refund","confidence":0.9}"#), for: goldenCase
        )
        XCTAssertEqual(good.score.value, 1, accuracy: 0.0001)

        let garbage = try await RubricScorer().score(
            response: Fixture.response("I'm sorry, I can't do that"), for: goldenCase
        )
        XCTAssertEqual(garbage.score.value, 0, accuracy: 0.0001)

        let partial = try await RubricScorer().score(
            response: Fixture.response(#"{"intent":"refund"}"#), for: goldenCase
        )
        XCTAssertEqual(partial.score.value, 0.5, accuracy: 0.0001)
    }

    func testNumericExtractionHandlesMissingAndNonNumericMatches() async throws {
        let rubric = try Rubric(checks: [
            .init(
                name: "confidence-range",
                weight: 1,
                kind: .numericWithin(0.0...1.0, extractedBy: "confidence[\": ]+([0-9.]+)")
            )
        ])
        let goldenCase = GoldenCase(
            id: "c1", prompt: "p", slice: "tool-call", rubric: rubric, provenance: Fixture.provenance()
        )

        let inRange = try await RubricScorer().score(
            response: Fixture.response(#"{"confidence": 0.42}"#), for: goldenCase
        )
        XCTAssertEqual(inRange.score.value, 1, accuracy: 0.0001)

        let outOfRange = try await RubricScorer().score(
            response: Fixture.response(#"{"confidence": 4.2}"#), for: goldenCase
        )
        XCTAssertEqual(outOfRange.score.value, 0, accuracy: 0.0001)

        // No match at all must score zero, not trap on a NSNotFound range.
        let noMatch = try await RubricScorer().score(response: Fixture.response("no numbers here"), for: goldenCase)
        XCTAssertEqual(noMatch.score.value, 0, accuracy: 0.0001)
    }

    func testEmptyResponseIsFlagged() async throws {
        let goldenCase = try Fixture.goldenCase(id: "c1", needle: "anything")
        let breakdown = try await RubricScorer().score(response: Fixture.response("   \n "), for: goldenCase)
        XCTAssertTrue(breakdown.flags.contains(.emptyResponse))
    }

    func testExactMatchWithoutReferenceScoresZeroAndSaysWhy() async throws {
        let goldenCase = try Fixture.goldenCase(id: "c1")
        let breakdown = try await ExactMatchScorer().score(response: Fixture.response("x"), for: goldenCase)
        XCTAssertEqual(breakdown.score.value, 0, accuracy: 0.0001)
        XCTAssertFalse(breakdown.notes.isEmpty)
    }

    func testExactMatchTrimsWhitespaceByDefault() async throws {
        let goldenCase = try Fixture.goldenCase(id: "c1", reference: "yes")
        let breakdown = try await ExactMatchScorer().score(response: Fixture.response("  yes \n"), for: goldenCase)
        XCTAssertEqual(breakdown.score.value, 1, accuracy: 0.0001)
    }

    // MARK: - Composition

    func testCompositeWithNoUsableEntriesDegradesInsteadOfDividingByZero() async throws {
        let composite = CompositeScorer(entries: [
            .init(scorer: RubricScorer(), weight: 0),
            .init(scorer: RubricScorer(), weight: -1),
        ])
        let goldenCase = try Fixture.goldenCase(id: "c1")
        let breakdown = try await composite.score(response: Fixture.response("ok"), for: goldenCase)
        XCTAssertEqual(breakdown.score.value, 0, accuracy: 0.0001)
        XCTAssertFalse(breakdown.notes.isEmpty)
    }

    func testCompositeWeightsSubScorers() async throws {
        let goldenCase = try Fixture.goldenCase(id: "c1", needle: "ok", reference: "different")
        // rubric scores 1 (contains "ok"), exact-match scores 0.
        let composite = CompositeScorer(entries: [
            .init(scorer: RubricScorer(), weight: 3),
            .init(scorer: ExactMatchScorer(), weight: 1),
        ])
        let breakdown = try await composite.score(response: Fixture.response("ok"), for: goldenCase)
        XCTAssertEqual(breakdown.score.value, 0.75, accuracy: 0.0001)
    }

    // MARK: - Judge

    func testJudgeRequiresAtLeastOneSample() throws {
        XCTAssertThrowsError(
            try JudgeScorer(judge: StubModel(alwaysReturning: "SCORE: 1"), samples: 0)
        ) { error in
            guard case .invalidJudgeConfiguration = (error as? EvalError) else {
                return XCTFail("expected .invalidJudgeConfiguration, got \(error)")
            }
        }
    }

    func testJudgeScoreParsing() {
        XCTAssertEqual(JudgeScorer.parseScore(from: "SCORE: 0.8"), 0.8)
        XCTAssertEqual(JudgeScorer.parseScore(from: "score:1"), 1)
        XCTAssertEqual(JudgeScorer.parseScore(from: "blah\nSCORE:   .25\nblah"), 0.25)
        XCTAssertNil(JudgeScorer.parseScore(from: "I think it was pretty good"))
        XCTAssertNil(JudgeScorer.parseScore(from: ""))
    }

    func testMedianHandlesOddEvenAndEmptyInputs() {
        XCTAssertEqual(JudgeScorer.median(of: [0.1, 0.9, 0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(JudgeScorer.median(of: [0.2, 0.4]), 0.3, accuracy: 0.0001)
        // Empty must return 0, not index into an empty array.
        XCTAssertEqual(JudgeScorer.median(of: []), 0, accuracy: 0.0001)
        XCTAssertEqual(JudgeScorer.median(of: [0.7]), 0.7, accuracy: 0.0001)
    }

    func testUnparseableJudgeIsAHarnessErrorNotAZeroScore() async throws {
        // Scoring an unreadable judge as 0 would masquerade as a model
        // regression and send somebody hunting for a bug that isn't there.
        let scorer = try JudgeScorer(judge: StubModel(alwaysReturning: "seems fine to me"), samples: 1)
        let goldenCase = try Fixture.goldenCase(id: "c1")
        await assertThrowsEvalError {
            try await scorer.score(response: Fixture.response("x"), for: goldenCase)
        } matching: { error in
            guard case .judgeParseFailure(let caseID, _) = error else {
                return XCTFail("expected .judgeParseFailure, got \(error)")
            }
            XCTAssertEqual(caseID, "c1")
        }
    }

    func testJudgeDisagreementIsFlaggedRatherThanAveragedAway() async throws {
        // Each sample gets a distinct seed; this stub varies its answer by seed
        // to simulate a judge that cannot make up its mind.
        let judge = StubModel { _, decoding in
            let value = decoding.seed == 0 ? 0.1 : (decoding.seed == 1 ? 0.55 : 0.95)
            return Fixture.response("SCORE: \(value)")
        }
        let scorer = try JudgeScorer(judge: judge, samples: 3, disagreementThreshold: 0.25)
        let goldenCase = try Fixture.goldenCase(id: "c1")
        let breakdown = try await scorer.score(response: Fixture.response("x"), for: goldenCase)

        XCTAssertTrue(breakdown.flags.contains(.judgeDisagreement))
        XCTAssertEqual(breakdown.score.value, 0.55, accuracy: 0.0001, "median, not mean")
        XCTAssertFalse(breakdown.notes.isEmpty)
    }

    func testConsistentJudgeIsNotFlagged() async throws {
        let scorer = try JudgeScorer(judge: StubModel(alwaysReturning: "SCORE: 0.8"), samples: 3)
        let goldenCase = try Fixture.goldenCase(id: "c1")
        let breakdown = try await scorer.score(response: Fixture.response("x"), for: goldenCase)
        XCTAssertFalse(breakdown.flags.contains(.judgeDisagreement))
        XCTAssertEqual(breakdown.score.value, 0.8, accuracy: 0.0001)
    }

    func testJudgeSamplesUseDistinctSeedsSoReplayDoesNotCollapseThem() async throws {
        // Regression guard: if every sample shared a seed they would share a
        // transcript key, and self-consistency would silently become one draw.
        let seeds = SeedRecorder()
        let judge = StubModel { _, decoding in
            seeds.record(decoding.seed)
            return Fixture.response("SCORE: 0.5")
        }
        let scorer = try JudgeScorer(judge: judge, samples: 3)
        _ = try await scorer.score(response: Fixture.response("x"), for: try Fixture.goldenCase(id: "c1"))
        XCTAssertEqual(seeds.snapshot().count, 3)
    }
}

/// Thread-safe recorder for seeds observed by a stub judge.
final class SeedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds: Set<UInt64> = []

    func record(_ seed: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        seeds.insert(seed)
    }

    func snapshot() -> Set<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        return seeds
    }
}
