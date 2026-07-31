import Foundation

/// Template identity plus a monotonic revision.
///
/// This is the single most load-bearing type in the harness. The revision is
/// what lets the classifier separate "an engineer changed the prompt and the
/// score moved" from "nobody touched anything and the score moved anyway".
public struct PromptVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let templateID: String
    public let revision: Int

    public init(templateID: String, revision: Int) {
        self.templateID = templateID
        self.revision = revision
    }

    public static func < (lhs: PromptVersion, rhs: PromptVersion) -> Bool {
        if lhs.templateID == rhs.templateID { return lhs.revision < rhs.revision }
        return lhs.templateID < rhs.templateID
    }

    public var description: String { "\(templateID)@r\(revision)" }
}

/// Content-addressed key for one recorded completion.
///
/// The key covers prompt version, rendered prompt, model identity **and build**,
/// and decoding parameters. Editing a prompt therefore invalidates exactly the
/// entries that prompt touched and nothing else, which is what makes the
/// committed transcript cache maintainable instead of a monolith that has to be
/// re-recorded wholesale every time anyone changes a word.
public struct TranscriptKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public let value: String

    public init(
        promptVersion: PromptVersion,
        renderedPrompt: String,
        model: ModelDescriptor,
        decoding: DecodingParameters
    ) {
        // Field-separated with a byte that cannot appear in the inputs, so that
        // ("ab", "c") and ("a", "bc") cannot collide by concatenation.
        let canonical = [
            promptVersion.templateID,
            String(promptVersion.revision),
            renderedPrompt,
            model.identifier,
            model.build,
            model.tier.rawValue,
            // Bit patterns rather than formatted decimals: exact, and immune to
            // locale or float-formatting differences between platforms.
            String(decoding.temperature.bitPattern),
            String(decoding.topP.bitPattern),
            String(decoding.maxOutputTokens),
            String(decoding.seed),
        ].joined(separator: "\u{1F}")

        self.value = TranscriptKey.digest(canonical)
    }

    /// Escape hatch for tests and for reading keys back out of a serialised
    /// cache.
    public init(rawValue: String) {
        self.value = rawValue
    }

    public var description: String { value }

    // MARK: - Hashing

    /// A 128-bit FNV-1a digest, rendered as hex.
    ///
    /// Deliberately *not* `Hasher`: Swift's standard hasher is seeded randomly
    /// per process, so a key derived from it changes on every launch and a
    /// committed cache would never hit. Deliberately not CryptoKit either — it
    /// does not exist on Linux, and this is a cache key, not a security
    /// boundary. Collision risk at suite sizes (thousands of entries, not
    /// billions) is negligible, and a collision degrades to a wrong replay that
    /// the rubric then scores, not to silent data loss.
    static func digest(_ string: String) -> String {
        let bytes = Array(string.utf8)
        let a = fnv1a64(bytes, offset: 0xcbf2_9ce4_8422_2325)
        let b = fnv1a64(bytes.reversed(), offset: 0x9e37_79b9_7f4a_7c15)
        return hex(a) + hex(b)
    }

    /// Zero-padded 16-character lowercase hex. Written by hand rather than via
    /// `String(format:)` so the output cannot vary with platform or locale.
    private static func hex(_ value: UInt64) -> String {
        let digits = Array("0123456789abcdef")
        var characters = [Character](repeating: "0", count: 16)
        var remaining = value
        var index = 15
        while index >= 0 {
            // `digits` is a fixed 16-element array and the mask is 0...15, so
            // this index is provably in bounds.
            characters[index] = digits[Int(remaining & 0xF)]
            remaining >>= 4
            index -= 1
        }
        return String(characters)
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S, offset: UInt64) -> UInt64
    where S.Element == UInt8 {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash = offset
        for byte in bytes {
            hash ^= UInt64(byte)
            // Wrapping multiply: overflow is the algorithm, not a bug.
            hash = hash &* prime
        }
        return hash
    }
}
