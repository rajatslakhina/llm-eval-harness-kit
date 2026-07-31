import Foundation

/// How the harness treats a cache miss.
public enum TranscriptMode: String, Sendable, Hashable, Codable {
    /// Never call upstream. A miss is a hard failure.
    ///
    /// This is the CI mode. It is what makes a PR run hermetic, free and
    /// repeatable, and it is why the cache has to be committed alongside the
    /// prompts it was recorded against.
    case replay

    /// Replay hits, record misses. The mode an engineer uses locally after
    /// adding cases or bumping a prompt revision.
    case recordMissing

    /// Always call upstream and overwrite. Used to deliberately refresh a
    /// suite against a new provider build.
    case record
}

/// One cached completion, with enough metadata to audit it later.
public struct TranscriptRecord: Sendable, Hashable, Codable {
    public let key: String
    public let caseID: String
    public let promptVersion: PromptVersion
    public let model: ModelDescriptor
    public let response: ModelResponse
    public let recordedAt: Date

    public init(
        key: TranscriptKey,
        caseID: String,
        promptVersion: PromptVersion,
        model: ModelDescriptor,
        response: ModelResponse,
        recordedAt: Date
    ) {
        self.key = key.value
        self.caseID = caseID
        self.promptVersion = promptVersion
        self.model = model
        self.response = response
        self.recordedAt = recordedAt
    }
}

public protocol TranscriptStore: Sendable {
    func record(for key: TranscriptKey) async -> TranscriptRecord?
    func store(_ record: TranscriptRecord) async
    func allRecords() async -> [TranscriptRecord]
}

/// Reference store. Actor-isolated because a bounded-concurrency run reads and
/// writes it from many tasks at once.
public actor InMemoryTranscriptStore: TranscriptStore {
    private var records: [String: TranscriptRecord]

    public init(records: [TranscriptRecord] = []) {
        var map: [String: TranscriptRecord] = [:]
        map.reserveCapacity(records.count)
        for record in records { map[record.key] = record }
        self.records = map
    }

    public func record(for key: TranscriptKey) -> TranscriptRecord? {
        records[key.value]
    }

    public func store(_ record: TranscriptRecord) {
        records[record.key] = record
    }

    public func allRecords() -> [TranscriptRecord] {
        // Stable ordering so a serialised cache produces a minimal git diff.
        records.values.sorted { $0.key < $1.key }
    }

    public var count: Int { records.count }

    /// JSON snapshot suitable for committing next to the golden set.
    public func snapshotData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(allRecords())
    }

    public static func loaded(from data: Data) throws -> InMemoryTranscriptStore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return InMemoryTranscriptStore(records: try decoder.decode([TranscriptRecord].self, from: data))
    }
}

/// Wraps any ``EvalModel`` so that completions are served from, and written to,
/// a transcript cache.
///
/// This decorator is the whole hermeticity story. Note that it wraps the *judge*
/// as readily as the model under test — judge calls are model calls, and an
/// un-cached judge would reintroduce cost and non-determinism through the back
/// door, which is the most common way a "deterministic" eval suite quietly
/// stops being either.
public struct ReplayingModel: EvalModel {
    public let descriptor: ModelDescriptor
    private let upstream: EvalModel?
    private let store: any TranscriptStore
    private let mode: TranscriptMode
    private let promptVersion: PromptVersion
    private let caseID: String
    private let clock: @Sendable () -> Date

    public init(
        descriptor: ModelDescriptor,
        upstream: EvalModel? = nil,
        store: any TranscriptStore,
        mode: TranscriptMode,
        promptVersion: PromptVersion,
        caseID: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.descriptor = descriptor
        self.upstream = upstream
        self.store = store
        self.mode = mode
        self.promptVersion = promptVersion
        self.caseID = caseID
        self.clock = clock
    }

    public func complete(prompt: String, decoding: DecodingParameters) async throws -> ModelResponse {
        let key = TranscriptKey(
            promptVersion: promptVersion,
            renderedPrompt: prompt,
            model: descriptor,
            decoding: decoding
        )

        if mode != .record, let cached = await store.record(for: key) {
            return cached.response
        }

        guard mode != .replay else {
            throw EvalError.transcriptCacheMiss(key: key.value, caseID: caseID)
        }
        guard let upstream else {
            throw EvalError.noUpstreamModel
        }

        let response = try await upstream.complete(prompt: prompt, decoding: decoding)
        await store.store(
            TranscriptRecord(
                key: key,
                caseID: caseID,
                promptVersion: promptVersion,
                model: descriptor,
                response: response,
                recordedAt: clock()
            )
        )
        return response
    }
}

/// Health report for a committed transcript cache.
public struct TranscriptAudit: Sendable, Hashable {
    /// Cached entries whose prompt revision no longer matches anything live.
    /// Left unattended these grow until the cache is larger than the suite and
    /// nobody dares delete any of it.
    public let orphanedKeys: [String]
    /// Case IDs the suite needs but the cache cannot serve — the set that will
    /// hard-fail a replay run.
    public let missingCaseIDs: [String]

    public var isClean: Bool { orphanedKeys.isEmpty && missingCaseIDs.isEmpty }
}

public enum TranscriptAuditor {
    /// Cross-checks a cache against the suite it is supposed to serve.
    ///
    /// Run this in CI *next to* the eval gate, not inside it: a stale cache is a
    /// hygiene problem to report, whereas a missing entry is a correctness
    /// problem that fails the run.
    public static func audit(
        goldenSet: GoldenSet,
        promptVersion: PromptVersion,
        model: ModelDescriptor,
        decoding: DecodingParameters,
        records: [TranscriptRecord]
    ) -> TranscriptAudit {
        var expected: [String: String] = [:]  // key -> caseID
        for goldenCase in goldenSet.cases {
            let key = TranscriptKey(
                promptVersion: promptVersion,
                renderedPrompt: goldenCase.prompt,
                model: model,
                decoding: decoding
            )
            expected[key.value] = goldenCase.id
        }

        let presentKeys = Set(records.map(\.key))
        let orphaned = presentKeys.subtracting(expected.keys).sorted()
        let missing = expected
            .filter { !presentKeys.contains($0.key) }
            .values
            .sorted()

        return TranscriptAudit(orphanedKeys: orphaned, missingCaseIDs: missing)
    }
}
