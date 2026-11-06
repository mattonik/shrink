import Foundation

/// What a video or PDF conversion streams: progress, then one outcome.
public enum ConversionEvent: Equatable, Sendable {
    case progress(Double)
    case finished(ConversionOutcome)
}

public enum ConversionOutcome: Equatable, Sendable {
    case compressed(output: URL, byteCount: Int64, warning: String?)
    /// Nothing was written; the reason says why the original is the answer.
    case keptOriginal(reason: String)
}

/// Whether a result is worth having in place of the file it came from.
enum Savings {
    /// Results saving less than this are thrown away. A Word export typically
    /// shrinks 1–2%, and an already compact video can even grow: neither is
    /// worth a copy that has lost quality or accessibility tagging on the way.
    static let minimum = 0.10

    static func worthKeeping(outputBytes: Int64, originalBytes: Int64) -> Bool {
        outputBytes > 0 && Double(outputBytes) <= Double(originalBytes) * (1 - minimum)
    }

    /// What the row says when the original is kept.
    static func keptOriginalReason(outputBytes: Int64, originalBytes: Int64) -> String {
        savingsPercent(source: originalBytes, output: outputBytes).map { "Only \($0)% smaller — kept the original" }
            ?? "Already compact — kept the original"
    }
}

func fileByteCount(_ url: URL) -> Int64 {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
}
