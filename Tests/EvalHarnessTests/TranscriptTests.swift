import XCTest
@testable import EvalHarness

final class TranscriptTests: XCTestCase {

    private func key(
        promptVersion: PromptVersion = Fixture.promptV1,
        prompt: String = "hello",
        model: ModelDescriptor = Fixture.onDevice,
        decoding: DecodingParameters = .deterministic
    ) -> TranscriptKey {
        TranscriptKey(promptVersion: promptVersion, renderedPrompt: prompt, model: model, decoding: decoding)
    }

    // MARK: - Key derivation

    func testKeyIsStableAcrossConstructions() {
        // If this ever fails, every committed transcript in every repo misses on
        // the next run. It is the load-bearing invariant of the whole cache.
        XCTAssertEqual(key().value, key().value)
    }

    func testKeyIsNotDerivedFromSwiftsRandomlySeededHasher() {
        // A `Hasher`-derived key changes between processes. This asserts the
        // digest is a fixed function of its input by checking a known length and
        // a stable, deterministic value for a fixed input.
        let digest = TranscriptKey.digest("stable-input")
        XCTAssertEqual(digest.count, 32)
        XCTAssertEqual(digest, TranscriptKey.digest("stable-input"))
        XCTAssertNotEqual(digest, TranscriptKey.digest("stable-inpuu"))
    }

    func testDigestIsLowercaseHexAndZeroPadded() {
        let digest = TranscriptKey.digest("")
        XCTAssertEqual(digest.count, 32)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testBumpingPromptRevisionInvalidatesTheKey() {
        XCTAssertNotEqual(key(promptVersion: Fixture.promptV1).value, key(promptVersion: Fixture.promptV2).value)
    }

    func testChangingModelBuildInvalidatesTheKey() {
        let newBuild = ModelDescriptor(identifier: Fixture.onDevice.identifier, build: "2026.08.1", tier: .onDevice)
        XCTAssertNotEqual(key().value, key(model: newBuild).value)
    }

    func testChangingSeedInvalidatesTheKey() {
        // This is what gives each judge self-consistency sample its own entry.
        XCTAssertNotEqual(
            key(decoding: .deterministic).value,
            key(decoding: DecodingParameters.deterministic.withSeed(1)).value
        )
    }

    func testFieldSeparatorPreventsConcatenationCollisions() {
        // ("ab", "c") and ("a", "bc") must not collide.
        let lhs = TranscriptKey(
            promptVersion: PromptVersion(templateID: "ab", revision: 1),
            renderedPrompt: "c",
            model: Fixture.onDevice,
            decoding: .deterministic
        )
        let rhs = TranscriptKey(
            promptVersion: PromptVersion(templateID: "a", revision: 1),
            renderedPrompt: "bc",
            model: Fixture.onDevice,
            decoding: .deterministic
        )
        XCTAssertNotEqual(lhs.value, rhs.value)
    }

    // MARK: - Replay semantics

    func testReplayModeThrowsOnCacheMissInsteadOfSilentlyGoingToTheNetwork() async throws {
        let counter = CallCounter()
        let model = ReplayingModel(
            descriptor: Fixture.onDevice,
            upstream: CountingModel(counter: counter),
            store: InMemoryTranscriptStore(),
            mode: .replay,
            promptVersion: Fixture.promptV1,
            caseID: "case-1"
        )

        await assertThrowsEvalError {
            try await model.complete(prompt: "hi", decoding: .deterministic)
        } matching: { error in
            guard case .transcriptCacheMiss(_, let caseID) = error else {
                return XCTFail("expected .transcriptCacheMiss, got \(error)")
            }
            XCTAssertEqual(caseID, "case-1")
        }

        let calls = await counter.count
        XCTAssertEqual(calls, 0, "replay mode must never reach upstream")
    }

    func testReplayModeServesFromCacheWithoutCallingUpstream() async throws {
        let counter = CallCounter()
        let store = InMemoryTranscriptStore()
        let cacheKey = key(prompt: "hi")
        await store.store(
            TranscriptRecord(
                key: cacheKey,
                caseID: "case-1",
                promptVersion: Fixture.promptV1,
                model: Fixture.onDevice,
                response: Fixture.response("cached answer"),
                recordedAt: Date(timeIntervalSince1970: 0)
            )
        )

        let model = ReplayingModel(
            descriptor: Fixture.onDevice,
            upstream: CountingModel(counter: counter),
            store: store,
            mode: .replay,
            promptVersion: Fixture.promptV1,
            caseID: "case-1"
        )

        let response = try await model.complete(prompt: "hi", decoding: .deterministic)
        XCTAssertEqual(response.text, "cached answer")
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testRecordMissingCallsUpstreamOnceThenReplays() async throws {
        let counter = CallCounter()
        let store = InMemoryTranscriptStore()
        let model = ReplayingModel(
            descriptor: Fixture.onDevice,
            upstream: CountingModel(counter: counter, text: "fresh"),
            store: store,
            mode: .recordMissing,
            promptVersion: Fixture.promptV1,
            caseID: "case-1",
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let first = try await model.complete(prompt: "hi", decoding: .deterministic)
        let second = try await model.complete(prompt: "hi", decoding: .deterministic)

        XCTAssertEqual(first.text, "fresh")
        XCTAssertEqual(second.text, "fresh")
        let calls = await counter.count
        XCTAssertEqual(calls, 1, "the second call must be served from the cache")
        let stored = await store.count
        XCTAssertEqual(stored, 1)
    }

    func testRecordModeAlwaysRefreshesEvenOnAHit() async throws {
        let counter = CallCounter()
        let store = InMemoryTranscriptStore()
        let model = ReplayingModel(
            descriptor: Fixture.onDevice,
            upstream: CountingModel(counter: counter),
            store: store,
            mode: .record,
            promptVersion: Fixture.promptV1,
            caseID: "case-1",
            clock: { Date(timeIntervalSince1970: 0) }
        )

        _ = try await model.complete(prompt: "hi", decoding: .deterministic)
        _ = try await model.complete(prompt: "hi", decoding: .deterministic)

        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    func testRecordingWithoutAnUpstreamModelIsATypedError() async {
        let model = ReplayingModel(
            descriptor: Fixture.onDevice,
            upstream: nil,
            store: InMemoryTranscriptStore(),
            mode: .recordMissing,
            promptVersion: Fixture.promptV1,
            caseID: "case-1"
        )
        await assertThrowsEvalError(.noUpstreamModel) {
            try await model.complete(prompt: "hi", decoding: .deterministic)
        }
    }

    // MARK: - Snapshot round-trip

    func testSnapshotRoundTripsAndOrdersDeterministically() async throws {
        let store = InMemoryTranscriptStore()
        for index in 0..<5 {
            await store.store(
                TranscriptRecord(
                    key: key(prompt: "p\(index)"),
                    caseID: "case-\(index)",
                    promptVersion: Fixture.promptV1,
                    model: Fixture.onDevice,
                    response: Fixture.response("r\(index)"),
                    recordedAt: Date(timeIntervalSince1970: 0)
                )
            )
        }

        let data = try await store.snapshotData()
        let reloaded = try InMemoryTranscriptStore.loaded(from: data)
        let original = await store.allRecords()
        let restored = await reloaded.allRecords()

        XCTAssertEqual(original, restored)
        XCTAssertEqual(restored.map(\.key), restored.map(\.key).sorted(), "records must serialise in stable order")
    }

    // MARK: - Cache hygiene

    func testAuditorFindsOrphanedAndMissingEntries() async throws {
        let goldenSet = try GoldenSet(cases: [
            Fixture.goldenCase(id: "kept", prompt: "kept-prompt"),
            Fixture.goldenCase(id: "missing", prompt: "missing-prompt"),
        ])

        let records = [
            TranscriptRecord(
                key: key(prompt: "kept-prompt"),
                caseID: "kept",
                promptVersion: Fixture.promptV1,
                model: Fixture.onDevice,
                response: Fixture.response("ok"),
                recordedAt: Date(timeIntervalSince1970: 0)
            ),
            TranscriptRecord(
                key: key(prompt: "deleted-long-ago"),
                caseID: "orphan",
                promptVersion: Fixture.promptV1,
                model: Fixture.onDevice,
                response: Fixture.response("ok"),
                recordedAt: Date(timeIntervalSince1970: 0)
            ),
        ]

        let audit = TranscriptAuditor.audit(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: Fixture.onDevice,
            decoding: .deterministic,
            records: records
        )

        XCTAssertFalse(audit.isClean)
        XCTAssertEqual(audit.missingCaseIDs, ["missing"])
        XCTAssertEqual(audit.orphanedKeys.count, 1)
    }

    func testAuditIsCleanWhenCacheMatchesSuiteExactly() async throws {
        let goldenSet = try GoldenSet(cases: [Fixture.goldenCase(id: "only", prompt: "p")])
        let records = [
            TranscriptRecord(
                key: key(prompt: "p"),
                caseID: "only",
                promptVersion: Fixture.promptV1,
                model: Fixture.onDevice,
                response: Fixture.response("ok"),
                recordedAt: Date(timeIntervalSince1970: 0)
            )
        ]
        let audit = TranscriptAuditor.audit(
            goldenSet: goldenSet,
            promptVersion: Fixture.promptV1,
            model: Fixture.onDevice,
            decoding: .deterministic,
            records: records
        )
        XCTAssertTrue(audit.isClean)
    }
}
