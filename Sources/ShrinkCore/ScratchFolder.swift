import Foundation

/// Where ffmpeg and Ghostscript write, so that only a finished result ever
/// reaches the destination. A failed, rejected or cancelled run then never
/// touches a file the user already has at that path, such as the result of
/// converting the same file with the same settings last week.
struct ScratchFolder {
    let url: URL

    /// On the destination's volume where possible, so committing is a rename.
    init(for destination: URL) throws {
        let fileManager = FileManager.default
        url =
            (try? fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true))
            ?? fileManager.temporaryDirectory.appending(path: "shrink-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Moves `file` to `destination`, replacing whatever is there.
    static func commit(_ file: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: file)
        } else {
            try fileManager.moveItem(at: file, to: destination)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
