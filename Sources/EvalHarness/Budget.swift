import Foundation

/// What the harness does when a budget is exceeded mid-run.
public enum BreachPolicy: String, Sendable, Hashable, Codable {
    /// Stop scheduling new cases immediately. Correct for cost ceilings, where
    /// the point is to not spend the money.
    case failFast
    /// Finish the run and report. Correct for latency ceilings, where a partial
    /// suite tells you less than a complete one.
    case completeAndReport
}

/// Per-run resource ceilings, enforced as a merge gate.
///
/// Treating cost and latency as gate conditions — not dashboard metrics — is the
/// deliberate position here. A prompt change that improves quality by one point
/// and triples token spend is a regression; a suite that only measures quality
/// will wave it through, and the finance conversation happens a quarter later
/// with no attribution.
public struct RunBudget: Sendable, Hashable, Codable {
    public let maxTotalTokens: Int?
    public let maxTotalCostUSD: Double?
    public let maxP95LatencySeconds: Double?
    public let onBreach: BreachPolicy

    public init(
        maxTotalTokens: Int? = nil,
        maxTotalCostUSD: Double? = nil,
        maxP95LatencySeconds: Double? = nil,
        onBreach: BreachPolicy = .completeAndReport
    ) {
        self.maxTotalTokens = maxTotalTokens
        self.maxTotalCostUSD = maxTotalCostUSD
        self.maxP95LatencySeconds = maxP95LatencySeconds
        self.onBreach = onBreach
    }

    /// No ceilings. Useful for local exploration, never for CI.
    public static let unlimited = RunBudget()
}

public enum BudgetBreach: Sendable, Hashable, Codable {
    case tokens(used: Int, limit: Int)
    case cost(used: Double, limit: Double)
    case latencyP95(observed: Double, limit: Double)

    public var summary: String {
        switch self {
        case .tokens(let used, let limit):
            return "token budget exceeded: \(used) > \(limit)"
        case .cost(let used, let limit):
            return "cost budget exceeded: $\(used) > $\(limit)"
        case .latencyP95(let observed, let limit):
            return "p95 latency exceeded: \(observed)s > \(limit)s"
        }
    }
}

/// Immutable view of the ledger, safe to carry into a report.
public struct BudgetSnapshot: Sendable, Hashable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
    public let p95LatencySeconds: Double?
    public let breaches: [BudgetBreach]

    public var totalTokens: Int { inputTokens + outputTokens }
    public var isWithinBudget: Bool { breaches.isEmpty }
}

/// Accumulates spend across a concurrent run.
///
/// An actor rather than a lock: the runner charges it from many child tasks at
/// once, and the alternative — a mutable struct passed around — is exactly the
/// data race Swift 6 exists to reject.
public actor BudgetLedger {
    private let budget: RunBudget
    private var inputTokens = 0
    private var outputTokens = 0
    private var costUSD = 0.0
    private var latencies: [Double] = []

    public init(budget: RunBudget) {
        self.budget = budget
    }

    /// Charges one response and returns whether the run is still inside budget.
    @discardableResult
    public func charge(_ response: ModelResponse) -> [BudgetBreach] {
        inputTokens += response.inputTokens
        outputTokens += response.outputTokens
        costUSD += response.costUSD
        latencies.append(response.latencySeconds)
        return currentBreaches()
    }

    public func snapshot() -> BudgetSnapshot {
        BudgetSnapshot(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            p95LatencySeconds: percentile(0.95),
            breaches: currentBreaches()
        )
    }

    private func currentBreaches() -> [BudgetBreach] {
        var breaches: [BudgetBreach] = []
        let total = inputTokens + outputTokens
        if let limit = budget.maxTotalTokens, total > limit {
            breaches.append(.tokens(used: total, limit: limit))
        }
        if let limit = budget.maxTotalCostUSD, costUSD > limit {
            breaches.append(.cost(used: costUSD, limit: limit))
        }
        if let limit = budget.maxP95LatencySeconds, let observed = percentile(0.95), observed > limit {
            breaches.append(.latencyP95(observed: observed, limit: limit))
        }
        return breaches
    }

    /// Nearest-rank percentile.
    ///
    /// Returns `nil` for an empty sample rather than inventing a zero, because
    /// "we measured nothing" and "we measured zero seconds" must not gate the
    /// same way. The rank is clamped into `0..<count`, which is the guard that
    /// stops a `p == 1.0` request from indexing one past the end — the classic
    /// way a percentile helper crashes in production.
    func percentile(_ p: Double) -> Double? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        let clampedP = min(max(p, 0), 1)
        let rank = Int((clampedP * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}
