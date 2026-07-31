import Foundation

/// Every failure this harness can produce, as a closed set.
///
/// Design note: these are deliberately *infrastructure* errors, not quality
/// signals. A model that answers badly is not an error — it is a low score.
/// An error means the harness itself could not produce a trustworthy verdict,
/// which is a different and much louder failure for CI to report.
public enum EvalError: Error, Equatable, Sendable {

    /// A golden set was constructed with no cases.
    ///
    /// This is an error rather than a trivially-passing run on purpose: an
    /// empty suite that reports "100% pass" is the single most common way an
    /// eval gate silently stops protecting anything.
    case emptyGoldenSet

    /// Two golden cases shared an identifier. Case IDs are the join key for
    /// baselines, transcripts and history, so collisions are unrecoverable.
    case duplicateCaseID(String)

    /// A rubric had no checks, or its weights summed to zero.
    case invalidRubric(reason: String)

    /// A regex in a rubric check failed to compile. Detected at `Rubric`
    /// construction time so it can never surface mid-run.
    case invalidRubricPattern(pattern: String)

    /// Replay mode hit a key that is not in the committed transcript cache.
    ///
    /// This is intentionally fatal for the case rather than a silent fall-back
    /// to a live call: a PR run that quietly reaches the network is no longer
    /// hermetic, and its result is no longer comparable to the baseline.
    case transcriptCacheMiss(key: String, caseID: String)

    /// Record mode was requested without an upstream model to record from.
    case noUpstreamModel

    /// The judge model returned text the score parser could not read.
    ///
    /// Also deliberately an error, not a zero. An unparseable judge is a broken
    /// harness; scoring it 0 would masquerade as a model regression.
    case judgeParseFailure(caseID: String, rawOutput: String)

    /// Judge self-consistency was configured with fewer than one sample.
    case invalidJudgeConfiguration(reason: String)

    /// Runner concurrency was configured below 1.
    case invalidConcurrency(Int)
}

extension EvalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyGoldenSet:
            return "Golden set is empty. An eval gate with no cases must fail, not pass."
        case .duplicateCaseID(let id):
            return "Duplicate golden case identifier '\(id)'. Case IDs must be unique."
        case .invalidRubric(let reason):
            return "Invalid rubric: \(reason)"
        case .invalidRubricPattern(let pattern):
            return "Rubric regex failed to compile: /\(pattern)/"
        case .transcriptCacheMiss(let key, let caseID):
            return """
            Transcript cache miss for case '\(caseID)' (key \(key)). \
            Re-record the golden set locally and commit the transcript before merging.
            """
        case .noUpstreamModel:
            return "Recording requires an upstream model, but none was supplied."
        case .judgeParseFailure(let caseID, let raw):
            return "Judge output for case '\(caseID)' was unparseable: \(raw.prefix(120))"
        case .invalidJudgeConfiguration(let reason):
            return "Invalid judge configuration: \(reason)"
        case .invalidConcurrency(let value):
            return "Runner concurrency must be at least 1, got \(value)."
        }
    }
}
