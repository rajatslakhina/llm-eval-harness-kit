import Foundation
import XCTest
@testable import EvalHarness

// MARK: - Fixtures

enum Fixture {
    static let onDevice = ModelDescriptor(
        identifier: "apple.foundation-models",
        build: "2026.07.1",
        tier: .onDevice
    )

    static let cloud = ModelDescriptor(
        identifier: "vendor.frontier",
        build: "2026-07-15",
        tier: .cloud
    )

    static let promptV1 = PromptVersion(templateID: "support-reply", revision: 1)
    static let promptV2 = PromptVersion(templateID: "support-reply", revision: 2)

    static func provenance(_ rationale: String = "regression from INC-4471") -> CaseProvenance {
        CaseProvenance(
            sourceTraceID: "trace-001",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rationale: rationale
        )
    }

    static func rubric(_ checks: [Rubric.Check]) throws -> Rubric {
        try Rubric(checks: checks)
    }

    static func containsRubric(_ needle: String) throws -> Rubric {
        try Rubric(checks: [.init(name: "contains-\(needle)", weight: 1, kind: .contains(needle, caseSensitive: false))])
    }

    static func goldenCase(
        id: String,
        slice: String = "general",
        prompt: String = "prompt",
        needle: String = "ok",
        reference: String? = nil
    ) throws -> GoldenCase {
        GoldenCase(
            id: id,
            prompt: prompt,
            slice: slice,
            rubric: try containsRubric(needle),
            referenceOutput: reference,
            provenance: provenance()
        )
    }

    static func response(
        _ text: String,
        inputTokens: Int = 10,
        outputTokens: Int = 20,
        latency: Double = 0.1,
        cost: Double = 0.001
    ) -> ModelResponse {
        ModelResponse(
            text: text,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            latencySeconds: latency,
            costUSD: cost
        )
    }
}

// MARK: - Test doubles

/// Deterministic model driven by a closure.
struct StubModel: EvalModel {
    let descriptor: ModelDescriptor
    let responder: @Sendable (String, DecodingParameters) -> ModelResponse

    init(
        descriptor: ModelDescriptor = Fixture.onDevice,
        responder: @escaping @Sendable (String, DecodingParameters) -> ModelResponse
    ) {
        self.descriptor = descriptor
        self.responder = responder
    }

    init(descriptor: ModelDescriptor = Fixture.onDevice, alwaysReturning text: String) {
        self.init(descriptor: descriptor) { _, _ in Fixture.response(text) }
    }

    func complete(prompt: String, decoding: DecodingParameters) async throws -> ModelResponse {
        responder(prompt, decoding)
    }
}

/// Model that always throws — used to prove per-case failures are captured
/// rather than propagated out of the run.
struct ExplodingModel: EvalModel {
    let descriptor: ModelDescriptor = Fixture.cloud
    struct Boom: Error {}

    func complete(prompt: String, decoding: DecodingParameters) async throws -> ModelResponse {
        throw Boom()
    }
}

/// Counts upstream calls so replay behaviour can be asserted, not assumed.
actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

struct CountingModel: EvalModel {
    let descriptor: ModelDescriptor
    let counter: CallCounter
    let text: String

    init(descriptor: ModelDescriptor = Fixture.onDevice, counter: CallCounter, text: String = "ok") {
        self.descriptor = descriptor
        self.counter = counter
        self.text = text
    }

    func complete(prompt: String, decoding: DecodingParameters) async throws -> ModelResponse {
        await counter.increment()
        return Fixture.response(text)
    }
}

// MARK: - Assertions

/// `XCTAssertThrowsError` has no async form. A trailing async closure is used
/// rather than an `@autoclosure` so that `try await` reads normally at the call
/// site and effect handling is unambiguous.
func assertThrowsEvalError<T>(
    _ expected: EvalError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected) but the call returned normally", file: file, line: line)
    } catch let error as EvalError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected) but got \(error)", file: file, line: line)
    }
}

func assertThrowsEvalError<T>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T,
    matching check: (EvalError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an EvalError but the call returned normally", file: file, line: line)
    } catch let error as EvalError {
        check(error)
    } catch {
        XCTFail("expected an EvalError but got \(error)", file: file, line: line)
    }
}
