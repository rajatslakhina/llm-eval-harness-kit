#if canImport(SwiftUI)
import SwiftUI
import EvalHarness

/// Drives the dashboard. `@MainActor` because every mutation of it lands
/// directly in SwiftUI's rendering; the actual eval work happens off it.
@MainActor
@Observable
public final class EvalDashboardModel {
    public private(set) var outcome: DemoRunOutcome?
    public private(set) var isRunning = false
    public private(set) var errorMessage: String?

    // No property observer here on purpose: the `@Observable` macro rewrites
    // stored properties into computed ones, and `didSet` on a tracked property
    // is not supported. The banner instead states which scenario the displayed
    // report belongs to, so a stale result can never be misread.
    public var scenario = DemoScenario()

    private let store = InMemoryTranscriptStore()
    private let counter = UpstreamCallCounter()

    public init() {}

    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            outcome = try await DemoRunner.run(scenario: scenario, store: store, counter: counter)
        } catch {
            errorMessage = (error as? EvalError)?.errorDescription ?? error.localizedDescription
            outcome = nil
        }
    }
}

@MainActor
public struct EvalDashboardView: View {
    @State private var model = EvalDashboardModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ScenarioControls(model: model)

                    if let message = model.errorMessage {
                        CalloutCard(
                            title: "Harness error",
                            message: message,
                            tint: .orange
                        )
                    }

                    if let outcome = model.outcome {
                        GateBanner(report: outcome.report)
                        HermeticityCard(outcome: outcome)
                        SlicesCard(report: outcome.report)
                        CasesCard(outcome: outcome)
                    } else if !model.isRunning {
                        CalloutCard(
                            title: "No run yet",
                            message: """
                            Pick a prompt revision and a provider build, then run the suite. \
                            The gate is deliberately configured with a loose global floor (0.70) \
                            and a strict per-slice floor (0.70) so you can watch a healthy average \
                            fail to rescue a collapsed slice.
                            """,
                            tint: .secondary
                        )
                    }
                }
                .padding(20)
            }
            .navigationTitle("Eval Gate")
            .background(Color(white: 0.96).ignoresSafeArea())
        }
    }
}

// MARK: - Controls

private struct ScenarioControls: View {
    @Bindable var model: EvalDashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scenario")
                .font(.headline)

            LabeledPicker(title: "Prompt revision") {
                Picker("Prompt revision", selection: $model.scenario.promptRevision) {
                    Text("r1 (baseline)").tag(1)
                    Text("r2 (edited)").tag(2)
                }
                .pickerStyle(.segmented)
            }

            LabeledPicker(title: "Provider build") {
                Picker("Provider build", selection: $model.scenario.modelBuild) {
                    Text("June").tag(DemoScenario.juneBuild)
                    Text("July").tag(DemoScenario.julyBuild)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Tight cost budget ($0.002)", isOn: $model.scenario.tightBudget)
                .font(.subheadline)

            Button {
                Task { await model.run() }
            } label: {
                HStack(spacing: 8) {
                    if model.isRunning { ProgressView() }
                    Text(model.isRunning ? "Running suite…" : "Run eval suite")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LabeledPicker<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Gate

private struct GateBanner: View {
    let report: EvalReport

    private var passed: Bool { report.gate.isPass }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.title2)
                Text(passed ? "GATE PASS" : "GATE FAIL")
                    .font(.title3.weight(.bold))
                Spacer()
                Text(Format.score(report.globalMeanScore))
                    .font(.title3.monospacedDigit())
            }
            .foregroundStyle(.white)

            Text("Global mean across \(report.run.results.count) cases")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))

            Text("prompt \(report.run.promptVersion.description) · build \(report.run.model.build)")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))

            if let worst = report.worstSlice {
                Text("Worst slice: \(worst.slice) at \(Format.score(worst.meanScore))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }

            let reasons = report.gate.reasons
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(reasons.enumerated()), id: \.offset) { pair in
                        Text("• \(pair.element)")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(passed ? Color.green.opacity(0.85) : Color.red.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Hermeticity

private struct HermeticityCard: View {
    let outcome: DemoRunOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hermeticity & spend")
                .font(.headline)
            StatRow(label: "Upstream calls (cumulative)", value: "\(outcome.upstreamCalls)")
            StatRow(label: "Cached transcripts", value: "\(outcome.cachedTranscripts)")
            StatRow(label: "Tokens", value: "\(outcome.report.run.budget.totalTokens)")
            StatRow(label: "Cost", value: Format.money(outcome.report.run.budget.costUSD))
            if let p95 = outcome.report.run.budget.p95LatencySeconds {
                StatRow(label: "p95 latency", value: "\(Format.score(p95))s")
            }
            Text("Re-run the same scenario: the cumulative upstream count stops rising because every case is served from the transcript cache.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
        }
    }
}

// MARK: - Slices

private struct SlicesCard: View {
    let report: EvalReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Slices")
                .font(.headline)
            Text("The gate fails if any single slice falls below its floor, however healthy the average looks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if report.slices.isEmpty {
                Text("No slices to show.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.slices) { slice in
                    let belowFloor = slice.meanScore < report.thresholds.minSliceMeanScore
                    HStack(spacing: 10) {
                        Circle()
                            .fill(belowFloor ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slice.slice)
                                .font(.subheadline.weight(.medium))
                            Text("\(slice.caseCount) case(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.score(slice.meanScore))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(belowFloor ? .red : .primary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Cases

private struct CasesCard: View {
    let outcome: DemoRunOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cases")
                .font(.headline)

            if outcome.report.run.results.isEmpty {
                Text("No cases were evaluated.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(outcome.report.run.results) { result in
                    CaseRow(
                        result: result,
                        verdict: outcome.verdicts[result.caseID] ?? .newCase
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CaseRow: View {
    let result: CaseResult
    let verdict: CaseVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.caseID)
                    .font(.subheadline.weight(.medium).monospaced())
                Spacer()
                Text(result.score.map { Format.score($0.value) } ?? "—")
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 6) {
                VerdictChip(verdict: verdict)
                Text(result.slice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let breakdown = result.breakdown, !breakdown.failedComponents.isEmpty {
                Text("failed: " + breakdown.failedComponents.map(\.name).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let breakdown = result.breakdown, !breakdown.flags.isEmpty {
                Text("flags: " + breakdown.flags.map(\.rawValue).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        Divider()
    }
}

private struct VerdictChip: View {
    let verdict: CaseVerdict

    var body: some View {
        Text(Format.verdictLabel(verdict))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Format.verdictTint(verdict).opacity(0.18), in: Capsule())
            .foregroundStyle(Format.verdictTint(verdict))
    }
}

// MARK: - Shared bits

private struct CalloutCard: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

enum Format {
    static func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func money(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    static func verdictLabel(_ verdict: CaseVerdict) -> String {
        switch verdict {
        case .pass: return "pass"
        case .newCase: return "new"
        case .improvement: return "improved"
        case .promptRegression: return "prompt regression"
        case .modelDrift: return "model drift"
        case .quarantinedFlaky: return "flaky · quarantined"
        case .harnessFailure: return "harness failure"
        case .skipped: return "skipped"
        }
    }

    static func verdictTint(_ verdict: CaseVerdict) -> Color {
        switch verdict {
        case .pass: return .green
        case .newCase: return .blue
        case .improvement: return .teal
        case .promptRegression: return .red
        case .modelDrift: return .purple
        case .quarantinedFlaky: return .orange
        case .harnessFailure, .skipped: return .brown
        }
    }
}

#Preview {
    EvalDashboardView()
}
#endif
