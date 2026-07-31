# llm-eval-harness-kit

**You cannot unit-test a feature whose output is non-deterministic — but you still have to gate the merge.**

`EvalHarness` is a Swift package that turns "did the LLM feature get worse?" into a hermetic,
free, repeatable CI signal, and — the part most eval tooling skips — tells you **who broke it**:
the engineer who edited the prompt, or the provider who shipped a new build underneath you.

---

## Why this matters

Every team shipping an LLM-backed iOS feature hits the same wall in roughly this order:

1. **The tests can't assert.** `XCTAssertEqual(response, "…")` is worthless against a model.
2. **So the suite goes manual.** Someone eyeballs 20 outputs before each release.
3. **So it stops happening.** Manual review does not survive contact with a release train.
4. **So regressions ship.** And nobody can say whether it was the prompt change in PR #4471
   or the provider's Tuesday deployment, because nothing recorded the difference.

The instinct is to reach for "LLM-as-judge" and call it solved. That trades a correctness
problem for three new ones: every PR now costs money, every PR now flakes, and the judge itself
is an uncalibrated instrument nobody validates.

This package takes a different position. **Most of an eval suite should never call a model at
all** — it should replay a committed transcript and score it with deterministic rubrics. The
judge is reserved for the residual subjective signal, is sampled for self-consistency, and is
replayed from the same cache as everything else.

---

## The core idea: attribution, not just detection

Detecting that a score dropped is easy. Naming the cause is the part that changes how a team
works. The transcript cache key covers **prompt version, rendered prompt, model identity, model
build and decoding parameters** — which is exactly enough information to separate these:

| Verdict | What happened | Blocks merge? |
|---|---|---|
| `promptRegression` | Score fell **and** the prompt revision changed in this PR | Yes |
| `modelDrift` | Score fell with the prompt untouched — the provider moved | Yes |
| `quarantinedFlaky` | The case has been oscillating for runs; this is noise | **No** |
| `improvement` / `pass` | Above threshold, or within tolerance | No |
| `harnessFailure` | Cache miss, unparseable judge — no trustworthy score exists | Yes |

That third row is a deliberate concession. A gate that blocks on noise gets switched off within
a month, and a gate nobody runs protects nothing. Flaky cases are reported loudly and merged
anyway.

---

## The other core idea: aggregate pass rate is a vanity metric

A suite of 200 cases where the 12 refusal cases have collapsed to zero still reports a **94%
global mean** and still goes green under an aggregate-only gate.

So `EvalReport` fails the gate if **any single slice** falls below its floor, independently of
the global average, and the report leads with the worst slice rather than the headline number.
There is a test named exactly that (`testHealthyGlobalAverageDoesNotRescueACollapsedSlice`)
because it is the claim the whole design rests on.

Cost and latency are gate conditions too, not dashboard metrics. A prompt change that improves
quality by one point and triples token spend is a regression; a suite that only measures quality
waves it through and the finance conversation happens a quarter later with no attribution.

---

## Architecture

```
EvalHarness (Foundation only — builds and tests on Linux)
├── GoldenSet / GoldenCase / Rubric      curated cases, validated at construction
├── PromptVersion / TranscriptKey        content-addressed cache key (FNV-1a, not Hasher)
├── TranscriptStore / ReplayingModel     hermeticity: record locally, replay in CI
├── TranscriptAuditor                    cache-rot detection (orphans + gaps)
├── Scoring                              deterministic weighted rubrics, exact match, composition
├── JudgeScorer                          LLM-as-judge with self-consistency + disagreement flags
├── BudgetLedger                         actor-isolated token/cost/p95 accounting
├── EvalRunner                           bounded concurrency, deterministic result ordering
├── RegressionClassifier                 prompt-regression vs. model-drift vs. flaky
├── EvalReport                           per-slice gate, CI markdown summary
└── TargetComparison                     on-device vs. cloud capability gap

EvalHarnessUI (SwiftUI, guarded by #if canImport(SwiftUI))
└── EvalDashboardView + DemoScenario     offline reproduction of all three verdicts
```

The only protocol a consumer has to implement is four lines:

```swift
public protocol EvalModel: Sendable {
    var descriptor: ModelDescriptor { get }
    func complete(prompt: String, decoding: DecodingParameters) async throws -> ModelResponse
}
```

Everything else — replay, budgeting, judging, dual-target comparison — composes on top of that
one method. Swapping an on-device Foundation Models session for a cloud provider is a
configuration change, not a rewrite.

---

## Design decisions, and what was rejected

**The cache key is a hand-rolled FNV-1a digest, not `Hasher`.**
Swift's standard `Hasher` is seeded randomly per process, so a key derived from it changes on
every launch and a committed cache would never hit — a bug that presents as "replay is broken on
CI only". CryptoKit was rejected because it does not exist on Linux and this is a cache key, not
a security boundary. A collision degrades to a wrong replay that the rubric then scores, not to
silent data loss.

**A cache miss in replay mode is a hard error, not a fall-back to the network.**
The tempting behaviour is to quietly call the provider when the cache misses. That makes the run
non-hermetic, non-free and non-comparable to the baseline — and it does so invisibly. Missing
entries fail loudly and tell you to re-record.

**A failing case does not fail the run.** Per-case errors are captured as results. Letting one
cache miss throw out of the task group would destroy the report for the other 199 cases, and the
report is the thing CI needs in order to explain itself.

**A budget breach does not throw either.** It stops scheduling (under `.failFast`) and comes back
as a red gate with a snapshot attached. An exception tells the engineer that something went
wrong; a report tells them what it cost.

**An unparseable judge is a harness error, not a score of zero.** Scoring it zero would
masquerade as a model regression and send somebody hunting a bug that does not exist.

**An empty golden set throws.** A suite with nothing in it that reports "100% pass" is the single
most common way an eval gate silently stops protecting anything. Both `GoldenSet.init` and the
gate itself refuse to treat zero cases as success.

**`Rubric` recompiles its regexes at use time.** Patterns are validated (compiled and discarded)
at construction so a malformed pattern can never surface mid-run, but the compiled objects are
not stored. That costs one regex compile per check — negligible against a model call — and keeps
`Rubric` a plain `Hashable` value type that can be diffed, serialised and compared. Caching
`NSRegularExpression` inside the struct was rejected for making it reference-holding and
non-`Hashable`.

**Judge self-consistency varies the seed, not the call.** Each sample gets a distinct seed, which
gives it a distinct transcript key. Without that, all N samples would share one cache entry and
"self-consistency" would silently collapse into a single draw replayed N times. There is a
regression test for exactly this.

---

## Crash-safety

The library is written to be un-crashable on adversarial input, and the test suite exercises the
paths that would otherwise trap:

- No force unwraps, no `try!`, no `as!`, no implicitly-unwrapped optionals, no `fatalError`.
- `Score` clamps out-of-range values **and NaN**, and flags that it did — one NaN otherwise
  poisons every downstream mean and comparison.
- The percentile helper clamps its rank into `0..<count` and returns `nil` for an empty sample,
  rather than indexing one past the end at `p = 1.0`.
- Standard deviation returns `0` below two samples instead of dividing by zero.
- `Rubric.totalWeight` is guaranteed positive at construction, so scoring never divides by zero.
- Negative token counts, costs and latencies are clamped at the `ModelResponse` boundary.
- Every collection access is either bounds-guarded or provably in range with a comment saying why.

---

## Testing

`Tests/EvalHarnessTests` covers the core logic and, deliberately, the edge cases that would
otherwise crash or lie:

| File | What it pins down |
|---|---|
| `GoldenSetAndRubricTests` | Empty sets, duplicate IDs, zero/negative weights, malformed regex, boundary clamping |
| `TranscriptTests` | Key stability across processes, invalidation on prompt/build/seed change, replay vs. record semantics, cache-rot audit |
| `ScoringTests` | NaN and out-of-range scores, weighted partial credit, malformed JSON, no-match numeric extraction, judge median/parse/disagreement |
| `BudgetAndRunnerTests` | Percentile on empty and single samples, `p = 1.0`, zero concurrency, one failing case not destroying the report, fail-fast accounting |
| `RegressionAndReportTests` | Prompt-regression vs. model-drift attribution, flaky quarantine ordering, empty-run gate, healthy-average-collapsed-slice, budget gate |

Run them with:

```bash
swift test
```

---

## Using it

```swift
let goldenSet = try GoldenSet(cases: myCases)

let configuration = try EvalRunConfiguration(
    maxConcurrentCases: 4,
    budget: RunBudget(maxTotalTokens: 200_000, maxTotalCostUSD: 2.00, onBreach: .failFast)
)

let run = await EvalRunner(configuration: configuration).run(
    goldenSet: goldenSet,
    promptVersion: PromptVersion(templateID: "support-assistant", revision: 7),
    modelDescriptor: descriptor,
    modelProvider: { goldenCase in
        ReplayingModel(
            descriptor: descriptor,
            upstream: liveProvider,          // nil in CI
            store: committedTranscriptStore,
            mode: .replay,                   // .recordMissing locally
            promptVersion: promptVersion,
            caseID: goldenCase.id
        )
    },
    scorer: RubricScorer()
)

let verdicts = RegressionClassifier.classify(run: run, baseline: committedBaseline)
let report = EvalReport(run: run, verdicts: verdicts, thresholds: .default)

print(report.markdownSummary())          // → CI job summary
exit(report.gate.isPass ? 0 : 1)         // → merge gate
```

---

## Demo app

The runnable demo lives in its own repository and consumes this package as a **remote** Swift
package dependency, exactly the way any external consumer would:

> Demo app: (added after the companion repo is pushed — see below)

---

## Verification

See the demo repository for the record of what was actually run and screenshotted.

## Licence

MIT — see [LICENSE](LICENSE).
