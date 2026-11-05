import Foundation

public let videoFileExtensions: Set<String> = [
    "mp4", "mov", "m4v", "webm", "mkv", "avi", "mpg", "mpeg", "wmv", "flv",
]

public func isVideoFile(_ url: URL) -> Bool {
    videoFileExtensions.contains(url.pathExtension.lowercased())
}

/// `65` -> `1:05`, `3725` -> `1:02:05`.
public func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    let total = Int(seconds.rounded())
    let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

public func formatBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

/// Percentage saved, for the "−72%" badge. Nil when the file grew or the
/// source size is unknown, so the badge is only ever shown when it is a win.
public func savingsPercent(source: Int64, output: Int64) -> Int? {
    guard source > 0, output > 0, output < source else { return nil }
    return Int(((1 - Double(output) / Double(source)) * 100).rounded())
}
