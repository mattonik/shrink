import Foundation

public struct VideoInfo: Equatable, Sendable {
    /// Dimensions as stored in the file, before any rotation is applied.
    public var size: PixelSize
    public var durationSeconds: Double
    public var byteCount: Int64
    public var videoCodec: String
    public var hasAudio: Bool
    /// Indexes of the subtitle streams MP4 can carry. Only text converts to
    /// MP4's mov_text: picture subtitles from DVDs and Blu-rays make ffmpeg
    /// refuse the whole conversion, so they are left out.
    public var subtitleStreams: [Int]
    /// Display-matrix rotation in degrees; iPhone portrait clips carry -90.
    public var rotationDegrees: Int

    public init(
        size: PixelSize,
        durationSeconds: Double,
        byteCount: Int64,
        videoCodec: String,
        hasAudio: Bool,
        subtitleStreams: [Int] = [],
        rotationDegrees: Int = 0
    ) {
        self.size = size
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.videoCodec = videoCodec
        self.hasAudio = hasAudio
        self.subtitleStreams = subtitleStreams
        self.rotationDegrees = rotationDegrees
    }

    /// The size the viewer actually sees. A phone records portrait footage as
    /// landscape frames plus a 90-degree display matrix, and ffmpeg applies
    /// that rotation before any filter runs — so every sizing decision has to
    /// use these dimensions, not the coded ones, or portrait video gets
    /// squashed into a landscape frame.
    public var displaySize: PixelSize {
        let normalized = ((rotationDegrees % 360) + 360) % 360
        return normalized == 90 || normalized == 270
            ? PixelSize(width: size.height, height: size.width)
            : size
    }

    public var isPortrait: Bool { displaySize.height > displaySize.width }
}

public enum TranscodeError: LocalizedError {
    case toolsMissing
    case noVideoStream(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolsMissing:
            "ffmpeg and ffprobe were not found. Install them with: brew install ffmpeg"
        case .noVideoStream(let name):
            "\(name) has no video track"
        case .failed(let message):
            message
        }
    }
}

public struct ToolPaths: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Homebrew's bin directories are searched explicitly: an app launched from
    /// Finder inherits a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) that
    /// never contains them, so relying on PATH alone works from a terminal and
    /// then mysteriously fails on a double-click.
    static let searchDirectories = [
        "/opt/homebrew/bin",  // Homebrew on Apple silicon
        "/usr/local/bin",  // Homebrew on Intel
        "/opt/local/bin",  // MacPorts
        "/usr/bin",
    ]

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ToolPaths?
    {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = searchDirectories + pathDirectories
        guard let ffmpeg = firstExecutable(named: "ffmpeg", in: candidates),
            let ffprobe = firstExecutable(named: "ffprobe", in: candidates)
        else { return nil }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// Ghostscript is optional: without it videos still work and PDFs report
    /// how to install it. Found the same way as ffmpeg, for the same reason.
    public static func locateGhostscript(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return firstExecutable(named: "gs", in: searchDirectories + pathDirectories)
    }

    static func firstExecutable(named name: String, in directories: [String]) -> URL? {
        let fileManager = FileManager.default
        for directory in directories where !directory.isEmpty {
            let candidate = URL(filePath: directory).appending(path: name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Microseconds elapsed, read from one `-progress pipe:1` line.
///
/// ffmpeg's `out_time_ms` key is misnamed and actually reports microseconds,
/// the same as `out_time_us`, so both are parsed on the microsecond scale.
public func parseProgressMicroseconds(line: String) -> Int64? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    for key in ["out_time_us=", "out_time_ms="] where trimmed.hasPrefix(key) {
        return Int64(trimmed.dropFirst(key.count))
    }
    return nil
}

public struct Transcoder: Sendable {
    public let tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    public func probe(_ url: URL) async throws -> VideoInfo {
        let output = try await runCollectingOutput(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
            ]
        )
        return try Self.parseProbe(output, byteCount: fileByteCount(url), name: url.lastPathComponent)
    }

    /// Text subtitle formats, which convert to mov_text. Anything else, such as
    /// dvd_subtitle or hdmv_pgs_subtitle, is a picture and can't.
    static let textSubtitleCodecs: Set<String> = ["mov_text", "subrip", "srt", "ass", "ssa", "webvtt", "text"]

    static func parseProbe(_ data: Data, byteCount: Int64, name: String) throws -> VideoInfo {
        struct Payload: Decodable {
            struct SideData: Decodable {
                let rotation: Double?
            }
            struct Stream: Decodable {
                let index: Int?
                let codec_type: String?
                let codec_name: String?
                let width: Int?
                let height: Int?
                let side_data_list: [SideData]?
                let tags: [String: String]?
            }
            struct Format: Decodable {
                let duration: String?
            }
            let streams: [Stream]?
            let format: Format?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let streams = payload.streams ?? []
        guard let video = streams.first(where: { $0.codec_type == "video" }) else {
            throw TranscodeError.noVideoStream(name)
        }
        // Modern ffprobe reports rotation in the Display Matrix side data;
        // older files only carry a `rotate` tag, so both are read. Typed step
        // by step: Swift 6.2 can't infer the types of the whole chain at once.
        let matrixRotation: Double? = video.side_data_list?.compactMap(\.rotation).first
        let tagRotation: Double? = video.tags?["rotate"].flatMap { Double($0) }
        let rotation: Double = matrixRotation ?? tagRotation ?? 0

        return VideoInfo(
            size: PixelSize(width: video.width ?? 0, height: video.height ?? 0),
            durationSeconds: Double(payload.format?.duration ?? "0") ?? 0,
            byteCount: byteCount,
            videoCodec: video.codec_name ?? "unknown",
            hasAudio: streams.contains { $0.codec_type == "audio" },
            subtitleStreams: streams.compactMap { stream in
                stream.codec_type == "subtitle" && textSubtitleCodecs.contains(stream.codec_name ?? "")
                    ? stream.index : nil
            },
            rotationDegrees: Int(rotation.rounded())
        )
    }

    /// Streams conversion progress as a 0...1 fraction, then the outcome.
    /// Cancelling the consuming task terminates ffmpeg. ffmpeg is launched
    /// directly with an argument array and no shell, so filenames cannot be
    /// interpreted as commands.
    ///
    /// ffmpeg writes into a scratch folder, and the result only replaces
    /// `output` once ffmpeg has finished it. Written in place, a failed or
    /// cancelled run would leave a truncated file, or destroy one already there.
    ///
    /// As with PDFs, a result that saves less than `Savings.minimum` is thrown
    /// away, because re-encoding an already compact video costs quality and can
    /// even make it bigger. A copy with the sound taken out is always kept:
    /// the original still has its sound, so it can't stand in for the copy.
    public func transcode(
        input: URL,
        output: URL,
        settings: EncodeSettings,
        info: VideoInfo
    ) -> AsyncThrowingStream<ConversionEvent, Error> {
        let executable = tools.ffmpeg
        let duration = info.durationSeconds
        let removesSound = !settings.keepAudio && info.hasAudio

        return AsyncThrowingStream { continuation in
            let task = Task {
                var scratch: ScratchFolder?
                defer { scratch?.remove() }
                do {
                    let folder = try ScratchFolder(for: output)
                    scratch = folder
                    // Same name, so ffmpeg still picks MP4 from the extension.
                    let temporary = folder.url.appending(path: output.lastPathComponent)
                    let result = try await runStreamingLines(
                        executable: executable,
                        arguments: settings.arguments(input: input, output: temporary, info: info)
                    ) { line in
                        guard let microseconds = parseProgressMicroseconds(line: line), duration > 0
                        else { return }
                        let fraction = Double(microseconds) / 1_000_000 / duration
                        continuation.yield(.progress(min(1, max(0, fraction))))
                    }
                    guard result.status == 0 else {
                        throw TranscodeError.failed(result.failureMessage(tool: "ffmpeg"))
                    }
                    let outputBytes = fileByteCount(temporary)
                    guard removesSound || Savings.worthKeeping(outputBytes: outputBytes, originalBytes: info.byteCount)
                    else {
                        let reason = Savings.keptOriginalReason(outputBytes: outputBytes, originalBytes: info.byteCount)
                        continuation.yield(.finished(.keptOriginal(reason: reason)))
                        continuation.finish()
                        return
                    }
                    try ScratchFolder.commit(temporary, to: output)
                    continuation.yield(.progress(1))
                    continuation.yield(.finished(.compressed(output: output, byteCount: outputBytes, warning: nil)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
