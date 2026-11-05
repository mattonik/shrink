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
        pattern: String = "testsrc"
    ) throws -> URL {
        let output = directory.appending(path: name)
        var args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "\(pattern)=size=\(size):rate=25:duration=\(seconds)",
        ]
        if audio {
            args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-c:a", "aac"]
        }
        args += ["-c:v", "libx264", "-crf", "18", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
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
}
