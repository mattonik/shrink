import Foundation

public enum VideoFixtures {
    /// Generates a real clip with ffmpeg's lavfi test sources.
    public static func make(
        ffmpeg: URL,
        in directory: URL,
        name: String = "sample.mp4",
        size: String = "640x360",
        seconds: Int = 3,
        audio: Bool = true,
        pattern: String = "testsrc",
        pixelFormat: String = "yuv420p"
    ) throws -> URL {
        let output = directory.appending(path: name)
        var args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "\(pattern)=size=\(size):rate=25:duration=\(seconds)",
        ]
        if audio {
            args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-c:a", "aac"]
        }
        args += ["-c:v", "libx264", "-crf", "18", "-preset", "ultrafast", "-pix_fmt", pixelFormat]
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args + [output.path]
        try process.run()
        process.waitUntilExit()
        return output
    }

    /// Two minutes of busy 1080p: about 12 s to encode on an M-series Mac and
    /// longer on CI, so a process that ignores cancellation is still running
    /// when a test looks. Looping a 10 s clip with stream copy makes it cheap.
    public static func makeLong(ffmpeg: URL, in directory: URL, name: String = "long.mp4") throws -> URL {
        let clip = try make(
            ffmpeg: ffmpeg, in: directory, name: "clip-\(name)", size: "1920x1080", seconds: 10,
            audio: false, pattern: "testsrc2")
        let output = directory.appending(path: name)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-stream_loop", "11", "-i", clip.path, "-c", "copy", output.path,
        ]
        try process.run()
        process.waitUntilExit()
        try FileManager.default.removeItem(at: clip)
        return output
    }

    /// A clip encoded harder than Shrink ever would (CRF 40, 16 kbps sound),
    /// so re-encoding it at Balanced makes it bigger.
    public static func makeCompact(ffmpeg: URL, in directory: URL, name: String = "compact.mp4") throws -> URL {
        let output = directory.appending(path: name)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "libx264", "-crf", "40", "-preset", "medium", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "16k", output.path,
        ]
        try process.run()
        process.waitUntilExit()
        return output
    }

    /// A Matroska clip with two subtitle tracks, as a Blu-ray rip often has:
    /// Blu-ray (PGS) picture subtitles at stream 1 and SRT text at stream 2.
    public static func makeWithSubtitles(ffmpeg: URL, in directory: URL, name: String = "movie.mkv") throws -> URL {
        let clip = try make(ffmpeg: ffmpeg, in: directory, name: "clip-\(name).mp4", seconds: 2, audio: false)
        let pictures = directory.appending(path: "pictures.sup")
        try pgsSubtitles().write(to: pictures)
        let text = directory.appending(path: "text.srt")
        try "1\n00:00:00,500 --> 00:00:01,500\nHello\n".write(to: text, atomically: true, encoding: .utf8)
        let output = directory.appending(path: name)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", clip.path, "-i", pictures.path, "-i", text.path,
            "-map", "0", "-map", "1", "-map", "2", "-c", "copy", output.path,
        ]
        try process.run()
        process.waitUntilExit()
        for file in [clip, pictures, text] { try FileManager.default.removeItem(at: file) }
        return output
    }

    /// The smallest stream ffmpeg reads as hdmv_pgs_subtitle: a 100x20 box on
    /// screen from 0.5 s to 1.5 s. Every segment is "PG", a 90 kHz PTS and
    /// DTS, a type and a length.
    static func pgsSubtitles() -> Data {
        func bigEndian(_ value: Int, _ count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
        }
        func segment(_ type: UInt8, _ payload: [UInt8], at pts: Int) -> [UInt8] {
            Array("PG".utf8) + bigEndian(pts, 4) + bigEndian(0, 4) + [type] + bigEndian(payload.count, 2) + payload
        }
        func displaySet(at pts: Int, showing: Bool) -> [UInt8] {
            // Composition: 640x360, then an epoch start with one object, or a clear.
            var composition = bigEndian(640, 2) + bigEndian(360, 2) + [0x10] + bigEndian(showing ? 1 : 2, 2)
            composition += [showing ? 0x80 : 0x00, 0, 0, showing ? 1 : 0]
            if showing { composition += bigEndian(0, 2) + [0, 0] + bigEndian(270, 2) + bigEndian(300, 2) }
            var set = segment(0x16, composition, at: pts)
            set += segment(0x17, [1, 0] + bigEndian(270, 2) + bigEndian(300, 2) + bigEndian(100, 2) + bigEndian(20, 2), at: pts)
            if showing {
                set += segment(0x14, [0, 0, 1, 235, 128, 128, 255], at: pts)  // palette: entry 1 is white
                // Run-length rows: 100 pixels of entry 1, then end of line.
                let row: [UInt8] = [0x00, 0xC0, 100, 0x01, 0x00, 0x00]
                let object = bigEndian(100, 2) + bigEndian(20, 2) + Array(repeating: row, count: 20).flatMap { $0 }
                set += segment(0x15, bigEndian(0, 2) + [0, 0xC0] + bigEndian(object.count, 3) + object, at: pts)
            }
            return set + segment(0x80, [], at: pts)
        }
        return Data(displaySet(at: 45_000, showing: true) + displaySet(at: 135_000, showing: false))
    }
}
