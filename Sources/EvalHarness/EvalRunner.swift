import Foundation

/// Result for a single golden case.
public struct CaseResult: Sendable, Hashable, Identifiable {
    public enum Outcome: Sendable, Hashable {
        case scored(breakdown: ScoreBreakdown, response: ModelResponse)
        /// The harness could not produce a trustworthy score for this case —
        /// a cache miss, an unparseable judge, a transport failure.
        case failed(reason: String)
        /// The run stopped before reaching this case (fail-fast budget breach).
        case skipped(reason: String)
    }

    public let caseID: String
    public let slice: String
    public let outcome: Outcome

    public var id: String { caseID }

    public init(caseID: String, slice: String, outcome: Outcome) {
        self.caseID = caseID
        self.slice = slice
        self.outcome = outcome
    }

    public var score: Score? {
        if case .scored(let breakdown, _) = outcome { return breakdown.score }
        return nil
    }

    public var breakdown: ScoreBreakdown? {
        if case .scored(let breakdown, _) = outcome { return breakdown }
        return nil
    }

    public var response: ModelResponse? {
        if case .scored(_, let response) = outcome { return response }
        return nil
    }

    public var isScored: Bool { score != nil }
}

/// Everything one execution of the suite produced.
public struct EvalRun: Sendable, Hashable {
    public let runID: String
    public let startedAt: Date
    public let promptVersion: PromptVersion
    public let model: ModelDescriptor
    /// Always sorted by case ID — report output is code-reviewed, so it must not
    /// depend on which task happened to finish first.
    public let results: [CaseResult]
    public let budget: BudgetSnapshot

    public init(
        runID: String,
        startedAt: Date,
        promptVersion: PromptVersion,
        model: ModelDescriptor,
        results: [CaseResult],
        budget: BudgetSnapshot
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.promptVersion = promptVersion
        self.model = model
        self.results = results.sorted { $0.caseID < $1.caseID }
        self.budget = budget
    }
}

public struct EvalRunConfiguration: Sendable, Hashable {
    public let maxConcurrentCases: Int
    public let budget: RunBudget
    public let decoding: DecodingParameters

    /// - Throws: ``EvalError/invalidConcurrency(_:)`` for values below 1.
    ///   Zero concurrency would deadlock the task group rather than fail loudly,
    ///   which is the worst kind of misconfiguration.
    public init(
        maxConcurrentCases: Int = 4,
        budget: RunBudget = .unlimited,
        decoding: DecodingParameters = .deterministic
    ) throws {
        guard maxConcurrentCases >= 1 else {
            throw EvalError.invalidConcurrency(maxConcurrentCases)
        }
        self.maxConcurrentCases = maxConcurrentCases
        self.budget = budget
        self.decoding = decoding
    }
}

/// Executes a golden set with bounded concurrency.
///
/// Two decisions worth defending in review:
///
/// **A failing case does not fail the run.** Per-case errors are captured as
/// ``CaseResult/Outcome/failed(reason:)``. Letting one cache miss throw out of
/// the task group would destroy the report for the other 200 cases, and the
/// report is the thing CI needs in order to explain itself.
///
/// **A budget breach does not throw either.** It ends scheduling and comes back
/// as a red gate with a snapshot attached. An exception would tell the engineer
/// that something went wrong; a report tells them what it cost.
public struct EvalRunner: Sendable {
    private let configuration: EvalRunConfiguration

    public init(configuration: EvalRunConfiguration) {
        self.configuration = configuration
    }

    public func run(
        goldenSet: GoldenSet,
        promptVersion: PromptVersion,
        modelDescriptor: ModelDescriptor,
        modelProvider: @escaping @Sendable (GoldenCase) -> any EvalModel,
        scorer: any Scorer,
        runID: String = UUID().uuidString,
        startedAt: Date = Date()
    ) async -> EvalRun {
        let ledger = BudgetLedger(budget: configuration.budget)
        let cases = goldenSet.cases
        let limit = min(configuration.maxConcurrentCases, max(cases.count, 1))
        let decoding = configuration.decoding
        let failFast = configuration.budget.onBreach == .failFast

        // Everything mutable lives inside the task-group body and is handed back
        // as the group's result, so nothing is captured across the concurrency
        // boundary. `scheduledCount` tells the caller how far the run got.
        let groupOutcome = await withTaskGroup(
            of: CaseResult.self,
            returning: ([CaseResult], Int).self
        ) { group in
            var collected: [CaseResult] = []
            collected.reserveCapacity(cases.count)
            var nextIndex = 0
            var stopScheduling = false

            let initialBatch = min(limit, cases.count)
            while nextIndex < initialBatch {
                let goldenCase = cases[nextIndex]  // nextIndex < initialBatch <= cases.count
                nextIndex += 1
                group.addTask {
                    await Self.evaluate(
                        goldenCase: goldenCase,
                        model: modelProvider(goldenCase),
                        scorer: scorer,
                        decoding: decoding,
                        ledger: ledger
                    )
                }
            }

            while let result = await group.next() {
                collected.append(result)

                if failFast, !stopScheduling {
                    let breaches = await ledger.snapshot().breaches
                    if !breaches.isEmpty { stopScheduling = true }
                }

                if !stopScheduling, nextIndex < cases.count {
                    let goldenCase = cases[nextIndex]  // guarded above
                    nextIndex += 1
                    group.addTask {
                        await Self.evaluate(
                            goldenCase: goldenCase,
                            model: modelProvider(goldenCase),
                            scorer: scorer,
                            decoding: decoding,
                            ledger: ledger
                        )
                    }
                }
            }

            return (collected, nextIndex)
        }

        var results = groupOutcome.0
        let scheduledCount = groupOutcome.1

        // Anything never scheduled because of a fail-fast breach is reported
        // explicitly rather than silently absent from the totals.
        if scheduledCount < cases.count {
            let reason = "run stopped early: budget exhausted (policy .failFast)"
            for index in scheduledCount..<cases.count {
                let goldenCase = cases[index]
                results.append(
                    CaseResult(caseID: goldenCase.id, slice: goldenCase.slice, outcome: .skipped(reason: reason))
                )
            }
        }

        return EvalRun(
            runID: runID,
            startedAt: startedAt,
            promptVersion: promptVersion,
            model: modelDescriptor,
            results: results,
            budget: await ledger.snapshot()
        )
    }

    /// Convenience overload for a single shared model instance.
    public func run(
        goldenSet: GoldenSet,
        promptVersion: PromptVersion,
        model: any EvalModel,
        scorer: any Scorer,
        runID: String = UUID().uuidString,
        startedAt: Date = Date()
    ) async -> EvalRun {
        await run(
            goldenSet: goldenSet,
            promptVersion: promptVersion,
            modelDescriptor: model.descriptor,
            modelProvider: { _ in model },
            scorer: scorer,
            runID: runID,
            startedAt: startedAt
        )
    }

    private static func evaluate(
        goldenCase: GoldenCase,
        model: any EvalModel,
        scorer: any Scorer,
        decoding: DecodingParameters,
        ledger: BudgetLedger
    ) async -> CaseResult {
        do {
            let response = try await model.complete(prompt: goldenCase.prompt, decoding: decoding)
            await ledger.charge(response)
            let breakdown = try await scorer.score(response: response, for: goldenCase)
            return CaseResult(
                caseID: goldenCase.id,
                slice: goldenCase.slice,
                outcome: .scored(breakdown: breakdown, response: response)
            )
        } catch {
            let reason = (error as? EvalError)?.errorDescription ?? String(describing: error)
            return CaseResult(caseID: goldenCase.id, slice: goldenCase.slice, outcome: .failed(reason: reason))
        }
    }
}
