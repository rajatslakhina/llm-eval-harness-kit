import XCTest
@testable import EvalHarness

/// These are the "would have crashed or lied" tests: empty collections, index
/// arithmetic, and divide-by-zero paths, all closed at construction time.
final class GoldenSetAndRubricTests: XCTestCase {

    // MARK: - GoldenSet invariants

    func testEmptyGoldenSetIsRejected() throws {
        // The single most dangerous state for an eval gate: a suite with nothing
        // in it that nonetheless reports success.
        XCTAssertThrowsError(try GoldenSet(cases: [])) { error in
            XCTAssertEqual(error as? EvalError, .emptyGoldenSet)
        }
    }

    func testDuplicateCaseIDsAreRejected() throws {
        let first = try Fixture.goldenCase(id: "dup")
        let second = try Fixture.goldenCase(id: "dup", prompt: "different prompt")
        XCTAssertThrowsError(try GoldenSet(cases: [first, second])) { error in
            XCTAssertEqual(error as? EvalError, .duplicateCaseID("dup"))
        }
    }

    func testCasesAreSortedForStableReportOutput() throws {
        let set = try GoldenSet(cases: [
            Fixture.goldenCase(id: "c"),
            Fixture.goldenCase(id: "a"),
            Fixture.goldenCase(id: "b"),
        ])
        XCTAssertEqual(set.cases.map(\.id), ["a", "b", "c"])
    }

    func testSlicesAreDeduplicatedAndSorted() throws {
        let set = try GoldenSet(cases: [
            Fixture.goldenCase(id: "a", slice: "refusal"),
            Fixture.goldenCase(id: "b", slice: "summarisation"),
            Fixture.goldenCase(id: "c", slice: "refusal"),
        ])
        XCTAssertEqual(set.slices, ["refusal", "summarisation"])
    }

    func testUnknownSliceReturnsEmptyArrayRatherThanTrapping() throws {
        let set = try GoldenSet(cases: [Fixture.goldenCase(id: "a", slice: "refusal")])
        XCTAssertTrue(set.cases(in: "does-not-exist").isEmpty)
    }

    // MARK: - Rubric invariants

    func testRubricWithNoChecksIsRejected() {
        XCTAssertThrowsError(try Rubric(checks: [])) { error in
            guard case .invalidRubric = (error as? EvalError) else {
                return XCTFail("expected .invalidRubric, got \(error)")
            }
        }
    }

    func testZeroWeightCheckIsRejected() {
        // A zero-weight check divides into the total as nothing, so it can never
        // fail — worse than not having written it.
        let checks = [Rubric.Check(name: "noop", weight: 0, kind: .isValidJSON)]
        XCTAssertThrowsError(try Rubric(checks: checks)) { error in
            guard case .invalidRubric = (error as? EvalError) else {
                return XCTFail("expected .invalidRubric, got \(error)")
            }
        }
    }

    func testNegativeWeightCheckIsRejected() {
        let checks = [Rubric.Check(name: "negative", weight: -1, kind: .isValidJSON)]
        XCTAssertThrowsError(try Rubric(checks: checks)) { error in
            guard case .invalidRubric = (error as? EvalError) else {
                return XCTFail("expected .invalidRubric, got \(error)")
            }
        }
    }

    func testMalformedRegexIsRejectedAtConstructionNotAtRunTime() {
        let checks = [Rubric.Check(name: "bad", weight: 1, kind: .matchesRegex("([unclosed"))]
        XCTAssertThrowsError(try Rubric(checks: checks)) { error in
            XCTAssertEqual(error as? EvalError, .invalidRubricPattern(pattern: "([unclosed"))
        }
    }

    func testMalformedNumericExtractionPatternIsRejected() {
        let checks = [
            Rubric.Check(name: "bad-numeric", weight: 1, kind: .numericWithin(0...1, extractedBy: "(("))
        ]
        XCTAssertThrowsError(try Rubric(checks: checks)) { error in
            XCTAssertEqual(error as? EvalError, .invalidRubricPattern(pattern: "(("))
        }
    }

    func testTotalWeightIsPositiveSoScoringNeverDividesByZero() throws {
        let rubric = try Rubric(checks: [
            .init(name: "a", weight: 2, kind: .isValidJSON),
            .init(name: "b", weight: 3, kind: .maxCharacters(10)),
        ])
        XCTAssertEqual(rubric.totalWeight, 5, accuracy: 0.0001)
        XCTAssertGreaterThan(rubric.totalWeight, 0)
    }

    // MARK: - Response sanitisation

    func testNegativeTokenCountsAreClampedAtTheBoundary() {
        let response = ModelResponse(
            text: "x", inputTokens: -5, outputTokens: -7, latencySeconds: -1, costUSD: -2
        )
        XCTAssertEqual(response.inputTokens, 0)
        XCTAssertEqual(response.outputTokens, 0)
        XCTAssertEqual(response.totalTokens, 0)
        XCTAssertEqual(response.latencySeconds, 0)
        XCTAssertEqual(response.costUSD, 0)
    }
}
