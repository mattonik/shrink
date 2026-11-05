import Foundation

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum ResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case p1080
    case p720
    case p480
    case pct75
    case pct50

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .original: "Keep original"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .pct75: "75%"
        case .pct50: "50%"
        }
    }

    /// Filename tag, so the settings that produced a file stay readable on disk.
    var suffix: String? {
        switch self {
        case .original: nil
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .pct75: "75pct"
        case .pct50: "50pct"
        }
    }
}

public enum Quality: String, CaseIterable, Identifiable, Sendable {
    case smallest
    case balanced
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smallest: "Smallest file"
        case .balanced: "Balanced"
        case .high: "High quality"
        }
    }
}

public enum Codec: String, Sendable {
    case h264
    case h265
}

public struct EncodeSettings: Equatable, Sendable {
    public var resolution: ResolutionPreset
    public var quality: Quality
    public var keepAudio: Bool
    public var useHEVC: Bool

    public init(
        resolution: ResolutionPreset = .p720,
        quality: Quality = .balanced,
        keepAudio: Bool = true,
        useHEVC: Bool = false
    ) {
        self.resolution = resolution
        self.quality = quality
        self.keepAudio = keepAudio
        self.useHEVC = useHEVC
    }

    public var codec: Codec { useHEVC ? .h265 : .h264 }

    /// x264 and x265 are not on the same CRF scale: x265 reaches roughly the
    /// same perceived quality about four points further up.
    public var crf: Int {
        switch (codec, quality) {
        case (.h264, .smallest): 30
        case (.h264, .balanced): 26
        case (.h264, .high): 22
        case (.h265, .smallest): 32
        case (.h265, .balanced): 28
        case (.h265, .high): 24
        }
    }

    /// Target pixel size, or nil to pass the source resolution through.
    /// Only ever scales down — asking 1080p of a 720p source returns nil rather
    /// than upscaling into a bigger file that holds no extra detail.
    public func targetSize(for source: PixelSize) -> PixelSize? {
        guard source.width > 0, source.height > 0 else { return nil }

        let factor: Double
        switch resolution {
        case .original: return nil
        case .pct50: factor = 0.5
        case .pct75: factor = 0.75
        case .p1080: factor = 1080.0 / Double(source.height)
        case .p720: factor = 720.0 / Double(source.height)
        case .p480: factor = 480.0 / Double(source.height)
        }
        guard factor < 1 else { return nil }

        return PixelSize(
            width: evenDimension(Double(source.width) * factor),
            height: evenDimension(Double(source.height) * factor)
        )
    }

    /// yuv420p subsamples chroma by two, so both axes have to stay even.
    private func evenDimension(_ value: Double) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }

    /// `demo.mov` with 720p and muted becomes `demo-720p-muted.mp4`.
    public func outputFileName(for input: URL) -> String {
        let base = input.deletingPathExtension().lastPathComponent
        var parts: [String] = []
        if let suffix = resolution.suffix { parts.append(suffix) }
        if useHEVC { parts.append("h265") }
        if !keepAudio { parts.append("muted") }
        if quality != .balanced { parts.append(quality.rawValue) }
        return "\(base)-\(parts.isEmpty ? "compressed" : parts.joined(separator: "-")).mp4"
    }

    public func arguments(input: URL, output: URL, info: VideoInfo) -> [String] {
        let target = targetSize(for: info.size)
        let withAudio = keepAudio && info.hasAudio
        // Soft subtitles cost almost nothing and some sources carry them, so
        // they ride along rather than being silently dropped.
        let withSubtitles = info.hasSubtitles

        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
        if let target {
            args += ["-vf", "scale=\(target.width):\(target.height):flags=lanczos"]
        }
        args += ["-map", "0:v:0"]
        if withAudio { args += ["-map", "0:a:0?"] }
        if withSubtitles { args += ["-map", "0:s?"] }
        args += [
            "-c:v", codec == .h265 ? "libx265" : "libx264",
            "-preset", "medium",
            "-crf", String(crf),
            "-pix_fmt", "yuv420p",
        ]
        // Without the hvc1 tag, QuickTime and Safari refuse to play HEVC in MP4.
        if codec == .h265 { args += ["-tag:v", "hvc1"] }
        args += withAudio ? ["-c:a", "aac", "-b:a", "96k"] : ["-an"]
        if withSubtitles { args += ["-c:s", "mov_text"] }
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        return args
    }
}
