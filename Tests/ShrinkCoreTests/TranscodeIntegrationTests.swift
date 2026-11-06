import Foundation
import Testing

@testable import ShrinkCore
import ShrinkTestSupport

/// Exercises the real ffmpeg pipeline: process launch, progress parsing on
/// stdout, stderr draining, and cancellation. The unit tests only cover the
/// argument strings, so this is what proves a conversion actually runs.
@Suite(.enabled(if: ToolPaths.locate() != nil, "requires ffmpeg on this machine"))
struct TranscodeIntegrationTests {
    let tools = ToolPaths.locate()!

    func makeSample(
        in directory: URL,
        name: String = "sample.mp4",
        size: String = "640x360",
        seconds: Int = 3,
        audio: Bool = true,
        pattern: String = "testsrc"
    ) throws -> URL {
        try VideoFixtures.make(
            ffmpeg: tools.ffmpeg, in: directory, name: name, size: size, seconds: seconds,
            audio: audio, pattern: pattern)
    }

    func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "shrink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func probesARealFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try makeSample(in: directory)

        let info = try await Transcoder(tools: tools).probe(sample)

        #expect(info.size == PixelSize(width: 640, height: 360))
        #expect(abs(info.durationSeconds - 3) < 0.3)
        #expect(info.hasAudio)
        #expect(info.byteCount > 0)
    }

    @Test func transcodesDownscalesAndReportsProgress() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try makeSample(in: directory, size: "1280x720", seconds: 3)
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .p480, quality: .balanced, keepAudio: true)
        let output = directory.appending(path: settings.outputFileName(for: sample))

        let fractions = try await { () async throws -> [Double] in
            let info = try await transcoder.probe(sample)
            var seen: [Double] = []
            for try await event in transcoder.transcode(
                input: sample, output: output, settings: settings, info: info
            ) {
                if case .progress(let fraction) = event { seen.append(fraction) }
            }
            return seen
        }()

        #expect(!fractions.isEmpty, "ffmpeg reported no progress")
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(fractions.last == 1)
        #expect(FileManager.default.fileExists(atPath: output.path))

        // The converted file is genuinely 480p and genuinely smaller.
        let result = try await transcoder.probe(output)
        #expect(result.size == PixelSize(width: 852, height: 480))
        #expect(result.hasAudio)
        let source = try await transcoder.probe(sample)
        #expect(result.byteCount < source.byteCount)
    }

    @Test func muteProducesAFileWithNoAudioTrack() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try makeSample(in: directory, seconds: 2)
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .original, keepAudio: false)
        let output = directory.appending(path: settings.outputFileName(for: sample))

        let result = try await { () async throws -> VideoInfo in
            let info = try await transcoder.probe(sample)
            for try await _ in transcoder.transcode(
                input: sample, output: output, settings: settings, info: info
            ) {}
            return try await transcoder.probe(output)
        }()

        #expect(!result.hasAudio)
    }

    /// Wraps a clip in a display matrix, the way a phone stores portrait video:
    /// landscape frames plus a rotation flag.
    func makeRotatedSample(in directory: URL, degrees: Int, size: String = "640x360") throws -> URL {
        let landscape = try makeSample(in: directory, name: "landscape.mp4", size: size, audio: false)
        let output = directory.appending(path: "portrait.mov")
        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-display_rotation", String(degrees), "-i", landscape.path,
            "-c", "copy", output.path,
        ]
        try process.run()
        process.waitUntilExit()
        return output
    }

    @Test func readsRotationFromARealRotatedFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rotated = try makeRotatedSample(in: directory, degrees: 90)

        let info = try await Transcoder(tools: tools).probe(rotated)

        #expect(info.size == PixelSize(width: 640, height: 360), "coded size stays landscape")
        #expect(info.displaySize == PixelSize(width: 360, height: 640), "displays as portrait")
        #expect(info.isPortrait)
    }

    /// The regression this suite exists for: a portrait phone clip used to come
    /// out as a squashed landscape file, because sizing read the coded
    /// dimensions while ffmpeg had already rotated the frames.
    @Test func keepsAPortraitClipPortrait() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 1920x1080 coded + 90 degrees = 1080x1920 on screen, like a phone clip.
        let rotated = try makeRotatedSample(in: directory, degrees: 90, size: "1920x1080")
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .p480, keepAudio: false)
        let output = directory.appending(path: settings.outputFileName(for: rotated))

        let result = try await { () async throws -> VideoInfo in
            let info = try await transcoder.probe(rotated)
            for try await _ in transcoder.transcode(
                input: rotated, output: output, settings: settings, info: info
            ) {}
            return try await transcoder.probe(output)
        }()

        // 480p caps the shorter side, so the result is 480 wide, not 480 tall.
        #expect(result.displaySize == PixelSize(width: 480, height: 852))
        #expect(result.displaySize.height > result.displaySize.width, "must stay portrait")
        // ffmpeg bakes the rotation into the pixels, so the output needs no flag.
        #expect(result.rotationDegrees == 0)
    }

    /// A portrait clip already smaller than the preset is passed through rather
    /// than blown up — the same no-upscale rule as landscape, measured on the
    /// displayed shorter side.
    @Test func doesNotUpscaleASmallPortraitClip() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rotated = try makeRotatedSample(in: directory, degrees: 90, size: "640x360")
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .p480, keepAudio: false)
        let output = directory.appending(path: settings.outputFileName(for: rotated))

        let result = try await { () async throws -> VideoInfo in
            let info = try await transcoder.probe(rotated)
            for try await _ in transcoder.transcode(
                input: rotated, output: output, settings: settings, info: info
            ) {}
            return try await transcoder.probe(output)
        }()

        #expect(result.displaySize == PixelSize(width: 360, height: 640))
    }

    @Test func leavesLandscapeClipsLandscape() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try makeSample(in: directory, size: "1920x1080", seconds: 2, audio: false)
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .p720, keepAudio: false)
        let output = directory.appending(path: settings.outputFileName(for: sample))

        let result = try await { () async throws -> VideoInfo in
            let info = try await transcoder.probe(sample)
            for try await _ in transcoder.transcode(
                input: sample, output: output, settings: settings, info: info
            ) {}
            return try await transcoder.probe(output)
        }()

        #expect(result.displaySize == PixelSize(width: 1280, height: 720))
    }

    /// A recording of part of the screen can have odd sides, which x264
    /// refuses for yuv420p. Keeping its size used to fail the whole file.
    @Test func encodesAnOddSizedRecordingAtItsOwnSize() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try VideoFixtures.make(
            ffmpeg: tools.ffmpeg, in: directory, name: "window.mp4", size: "1437x899", seconds: 1,
            audio: false, pixelFormat: "yuv444p")
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .original, keepAudio: false)
        let output = directory.appending(path: settings.outputFileName(for: recording))

        let result = try await { () async throws -> VideoInfo in
            let info = try await transcoder.probe(recording)
            for try await _ in transcoder.transcode(
                input: recording, output: output, settings: settings, info: info
            ) {}
            return try await transcoder.probe(output)
        }()

        #expect(result.displaySize == PixelSize(width: 1436, height: 898))
    }

    /// Picture subtitles can't become MP4 text, and asking ffmpeg to convert
    /// them fails the whole file, so a Blu-ray rip used to fail outright. Now
    /// the picture track is left behind and the text track still comes along.
    @Test func convertsAFileWithPictureSubtitlesKeepingTheTextOnes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try VideoFixtures.makeWithSubtitles(ffmpeg: tools.ffmpeg, in: directory)
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .original, keepAudio: false)
        let output = directory.appending(path: settings.outputFileName(for: movie))

        let info = try await transcoder.probe(movie)
        #expect(info.subtitleStreams == [2], "the PGS track at 1 is a picture, the SRT at 2 is text")
        for try await _ in transcoder.transcode(input: movie, output: output, settings: settings, info: info) {}

        let streams = try await runCollectingOutput(
            executable: tools.ffprobe,
            arguments: ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", output.path])
        #expect(String(decoding: streams, as: UTF8.self).split(separator: "\n") == ["h264", "mov_text"])
    }

    func finalEvent(_ input: URL, _ settings: EncodeSettings) async throws -> (ConversionEvent?, URL) {
        let transcoder = Transcoder(tools: tools)
        let output = input.deletingLastPathComponent().appending(path: settings.outputFileName(for: input))
        let info = try await transcoder.probe(input)
        var last: ConversionEvent?
        for try await event in transcoder.transcode(input: input, output: output, settings: settings, info: info) {
            last = event
        }
        return (last, output)
    }

    /// Re-encoding an already compact video costs quality and here even makes
    /// it bigger, so, as with PDFs, the original is the answer.
    @Test func keepsTheOriginalWhenReencodingDoesNotShrinkIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compact = try VideoFixtures.makeCompact(ffmpeg: tools.ffmpeg, in: directory)

        let (last, output) = try await finalEvent(compact, EncodeSettings(resolution: .original))

        guard case .finished(.keptOriginal(let reason)) = last else {
            Issue.record("expected the original to be kept, got \(String(describing: last))")
            return
        }
        #expect(reason.contains("kept the original"))
        #expect(!FileManager.default.fileExists(atPath: output.path), "a result that was thrown away was written")
    }

    /// A muted copy is kept even when it saves almost nothing: the original
    /// still has its sound, so it can't stand in for what was asked for.
    @Test func keepsAMutedCopyEvenWhenItIsHardlySmaller() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compact = try VideoFixtures.makeCompact(ffmpeg: tools.ffmpeg, in: directory)
        let sourceBytes = try #require(try compact.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let (last, output) = try await finalEvent(compact, EncodeSettings(resolution: .original, keepAudio: false))

        guard case .finished(.compressed(_, let bytes, _)) = last else {
            Issue.record("expected the muted copy to be kept, got \(String(describing: last))")
            return
        }
        #expect(Double(bytes) > Double(sourceBytes) * 0.9, "the fixture must save too little to pass on size alone")
        #expect(try await Transcoder(tools: tools).probe(output).hasAudio == false)
    }

    /// A cancel that lands before the tool exists used to find nothing to
    /// stop, and the tool then ran to the end with nobody watching.
    @Test func aToolStartedAfterItsTaskWasCancelledIsStoppedAtOnce() async throws {
        let duration = "30.\(Int.random(in: 100_000...999_999))"  // unique, to find it with pgrep
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runStreamingLines(executable: URL(filePath: "/bin/sleep"), arguments: [duration]) { _ in }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await waitUntilNoProcess(matching: "sleep \(duration)"), "sleep is still running")
    }

    @Test func cancellingStopsFFmpeg() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try VideoFixtures.makeLong(ffmpeg: tools.ffmpeg, in: directory)
        let transcoder = Transcoder(tools: tools)
        let settings = EncodeSettings(resolution: .original, quality: .high)
        let output = directory.appending(path: settings.outputFileName(for: sample))
        let info = try await transcoder.probe(sample)

        var progressEvents = 0
        for try await _ in transcoder.transcode(
            input: sample, output: output, settings: settings, info: info
        ) {
            progressEvents += 1
            break  // dropping the stream is how the app cancels
        }

        #expect(progressEvents == 1)
        #expect(await waitUntilNoProcess(matching: directory.lastPathComponent), "ffmpeg still running")
    }

    @Test func reportsAnErrorForAFileFFmpegCannotRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.mp4")
        try Data("this is not a video".utf8).write(to: broken)

        await #expect(throws: (any Error).self) {
            try await Transcoder(tools: tools).probe(broken)
        }
    }
}
