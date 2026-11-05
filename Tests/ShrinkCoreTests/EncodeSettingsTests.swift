import Foundation
import Testing

@testable import ShrinkCore

private let fullHD = PixelSize(width: 1920, height: 1080)

private func info(
    size: PixelSize = fullHD,
    duration: Double = 6,
    bytes: Int64 = 233_135,
    audio: Bool = true,
    subtitles: Bool = false
) -> VideoInfo {
    VideoInfo(
        size: size,
        durationSeconds: duration,
        byteCount: bytes,
        videoCodec: "h264",
        hasAudio: audio,
        hasSubtitles: subtitles
    )
}

@Test func scalesHeightPresetsPreservingAspectRatio() {
    let settings = EncodeSettings(resolution: .p720)
    #expect(settings.targetSize(for: fullHD) == PixelSize(width: 1280, height: 720))

    // 1920*(480/1080) is 853.3; rounding lands on odd, so it steps down to even.
    #expect(EncodeSettings(resolution: .p480).targetSize(for: fullHD) == PixelSize(width: 852, height: 480))
    #expect(EncodeSettings(resolution: .pct50).targetSize(for: fullHD) == PixelSize(width: 960, height: 540))
}

@Test func neverUpscales() {
    let hd = PixelSize(width: 1280, height: 720)
    #expect(EncodeSettings(resolution: .p720).targetSize(for: hd) == nil)
    #expect(EncodeSettings(resolution: .p1080).targetSize(for: hd) == nil)
    #expect(EncodeSettings(resolution: .original).targetSize(for: fullHD) == nil)
}

@Test func forcesEvenDimensionsForChromaSubsampling() throws {
    let target = try #require(
        EncodeSettings(resolution: .pct75).targetSize(for: PixelSize(width: 1366, height: 768))
    )
    #expect(target.width.isMultiple(of: 2))
    #expect(target.height.isMultiple(of: 2))
    #expect(target == PixelSize(width: 1024, height: 576))
}

@Test func buildsArgumentsThatScaleAndKeepAudio() {
    let settings = EncodeSettings(resolution: .p720, quality: .balanced, keepAudio: true)
    let args = settings.arguments(
        input: URL(filePath: "/v/demo.mp4"),
        output: URL(filePath: "/v/demo-720p.mp4"),
        info: info()
    )

    #expect(args.contains("libx264"))
    #expect(args.contains("scale=1280:720:flags=lanczos"))
    #expect(consecutive(args, "-crf") == "26")
    #expect(args.contains("0:a:0?"))
    #expect(consecutive(args, "-c:a") == "aac")
    #expect(consecutive(args, "-b:a") == "96k")
    #expect(!args.contains("-an"))
    #expect(args.contains("+faststart"))
    #expect(args.last == "/v/demo-720p.mp4")
    // Progress has to stay on stdout for the per-file progress bars.
    #expect(args.contains("-progress"))
    #expect(consecutive(args, "-progress") == "pipe:1")
}

@Test func dropsAudioStreamWhenSoundIsOff() {
    let args = EncodeSettings(keepAudio: false).arguments(
        input: URL(filePath: "/v/in.mp4"),
        output: URL(filePath: "/v/out.mp4"),
        info: info()
    )

    #expect(args.contains("-an"))
    #expect(!args.contains("0:a:0?"))
    #expect(!args.contains("aac"))
}

@Test func doesNotMapAudioWhenSourceIsSilent() {
    let args = EncodeSettings(keepAudio: true).arguments(
        input: URL(filePath: "/v/in.mp4"),
        output: URL(filePath: "/v/out.mp4"),
        info: info(audio: false)
    )

    #expect(args.contains("-an"))
    #expect(!args.contains("0:a:0?"))
}

@Test func omitsScaleFilterWhenKeepingResolution() {
    let args = EncodeSettings(resolution: .original).arguments(
        input: URL(filePath: "/v/in.mp4"),
        output: URL(filePath: "/v/out.mp4"),
        info: info()
    )

    #expect(!args.contains("-vf"))
}

@Test func tagsHEVCAsHvc1ForQuickTime() {
    let settings = EncodeSettings(resolution: .original, useHEVC: true)
    let args = settings.arguments(
        input: URL(filePath: "/v/in.mp4"),
        output: URL(filePath: "/v/out.mp4"),
        info: info()
    )

    #expect(args.contains("libx265"))
    #expect(consecutive(args, "-tag:v") == "hvc1")
    #expect(consecutive(args, "-crf") == "28")
}

@Test func carriesSoftSubtitlesThrough() {
    let args = EncodeSettings().arguments(
        input: URL(filePath: "/v/in.mp4"),
        output: URL(filePath: "/v/out.mp4"),
        info: info(subtitles: true)
    )

    #expect(args.contains("0:s?"))
    #expect(consecutive(args, "-c:s") == "mov_text")
}

@Test func hevcSitsHigherOnCRFLadderThanH264() {
    #expect(EncodeSettings(quality: .balanced, useHEVC: true).crf > EncodeSettings(quality: .balanced).crf)
    #expect(EncodeSettings(quality: .smallest).crf > EncodeSettings(quality: .high).crf)
}

@Test func namesOutputAfterTheSettingsThatProducedIt() {
    let input = URL(filePath: "/v/demo.mov")
    #expect(EncodeSettings(resolution: .p720).outputFileName(for: input) == "demo-720p.mp4")
    #expect(
        EncodeSettings(resolution: .p720, keepAudio: false).outputFileName(for: input)
            == "demo-720p-muted.mp4"
    )
    #expect(
        EncodeSettings(resolution: .original, useHEVC: true).outputFileName(for: input)
            == "demo-h265.mp4"
    )
    #expect(
        EncodeSettings(resolution: .original, quality: .smallest).outputFileName(for: input)
            == "demo-smallest.mp4"
    )
    #expect(EncodeSettings(resolution: .original).outputFileName(for: input) == "demo-compressed.mp4")
}

@Test func parsesProbeJSON() throws {
    let json = """
        {"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
        {"codec_type":"audio","codec_name":"aac"},{"codec_type":"subtitle","codec_name":"mov_text"}],
        "format":{"duration":"6.000000"}}
        """
    let parsed = try Transcoder.parseProbe(Data(json.utf8), byteCount: 233_135, name: "demo.mp4")

    #expect(parsed.size == fullHD)
    #expect(parsed.durationSeconds == 6)
    #expect(parsed.byteCount == 233_135)
    #expect(parsed.hasAudio)
    #expect(parsed.hasSubtitles)
}

@Test func rejectsFileWithNoVideoTrack() {
    let json = #"{"streams":[{"codec_type":"audio"}],"format":{"duration":"3"}}"#
    #expect(throws: TranscodeError.self) {
        try Transcoder.parseProbe(Data(json.utf8), byteCount: 10, name: "audio.m4a")
    }
}

@Test func readsProgressAsMicrosecondsFromEitherKey() {
    // ffmpeg's out_time_ms is misnamed and also carries microseconds.
    #expect(parseProgressMicroseconds(line: "out_time_us=5933333") == 5_933_333)
    #expect(parseProgressMicroseconds(line: "out_time_ms=2000000") == 2_000_000)
    #expect(parseProgressMicroseconds(line: "frame=180") == nil)
    #expect(parseProgressMicroseconds(line: "progress=end") == nil)
}

@Test func locatesToolsInHomebrewEvenWithoutPath() {
    // Finder-launched apps get a minimal PATH, so the Homebrew directories must
    // be searched explicitly rather than discovered through the environment.
    #expect(ToolPaths.searchDirectories.contains("/opt/homebrew/bin"))
    #expect(ToolPaths.searchDirectories.contains("/usr/local/bin"))
    #expect(ToolPaths.locate(environment: [:]) != nil)
}

@Test func recognisesVideoFilesByExtension() {
    #expect(isVideoFile(URL(filePath: "/v/a.MP4")))
    #expect(isVideoFile(URL(filePath: "/v/a.mov")))
    #expect(isVideoFile(URL(filePath: "/v/a.mkv")))
    #expect(!isVideoFile(URL(filePath: "/v/a.pdf")))
    #expect(!isVideoFile(URL(filePath: "/v/a.mp3")))
}

@Test func formatsDurationsAndSavings() {
    #expect(formatDuration(65) == "1:05")
    #expect(formatDuration(3725) == "1:02:05")
    #expect(formatDuration(6) == "0:06")
    #expect(savingsPercent(source: 1000, output: 250) == 75)
    // A file that grew gets no savings badge.
    #expect(savingsPercent(source: 1000, output: 1200) == nil)
    #expect(savingsPercent(source: 0, output: 100) == nil)
}

/// The value directly after `flag`, for asserting on ffmpeg argument pairs.
private func consecutive(_ args: [String], _ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}
