import Foundation

/// A source build that failed, with everything it printed. The banner has
/// room for the summary; the app shows the whole log on request.
public struct BuildFailure: LocalizedError, Equatable {
    public let summary: String
    public let log: String
    /// Where the same log is kept on disk.
    public let logURL: URL

    public var errorDescription: String? { summary }
}

/// Updates a copy of Shrink that was built on this Mac by building the new
/// release here too: what `git pull && ./build.sh` does by hand.
///
/// Nothing pre-built is downloaded. The release's tag is fetched into a clone
/// the app keeps for itself, never a checkout anyone works in, and that tag's
/// own build.sh builds it into a scratch folder. There is no signature to
/// check, because the code is compiled here: as when building by hand, the
/// trust is in the repository. What is checked is that the result is this
/// app at the version the release names, which also proves the tag was built.
public struct SourceUpdater: Sendable {
    public let remote: String
    public let checkout: URL
    public let bundleIdentifier: String
    public let appName: String
    let environment: [String: String]

    public init(
        remote: String,
        bundleIdentifier: String,
        checkout: URL = SourceUpdater.defaultCheckout,
        appName: String = "Shrink",
        environment: [String: String] = SourceUpdater.defaultEnvironment
    ) {
        self.remote = remote
        self.bundleIdentifier = bundleIdentifier
        self.checkout = checkout
        self.appName = appName
        self.environment = environment
    }

    public static func gitHubRemote(_ repository: String) -> String {
        "https://github.com/\(repository).git"
    }

    public static var defaultCheckout: URL {
        URL.applicationSupportDirectory.appending(path: "Shrink/Source", directoryHint: .isDirectory)
    }

    /// What an app opened from the Finder gets anyway. Pinning it means a copy
    /// started from a terminal builds with the same system tools, not whatever
    /// that shell's PATH finds first. Git must never stop to ask for a password.
    public static var defaultEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    /// The complete output of the latest build, for when one fails.
    public var logURL: URL {
        checkout.deletingLastPathComponent().appending(path: "update-build.log")
    }

    /// Fetches and builds `release` in a scratch folder next to `current`,
    /// returning an app that is ready to swap in. The scratch folder is
    /// removed if anything fails, and `current` is never touched.
    public func prepare(
        _ release: Release, replacing current: URL, currentVersion: SemanticVersion?
    ) async throws -> PreparedUpdate {
        try PreparedUpdate.checkReplaceable(current, with: release.version, currentVersion: currentVersion)
        try await requireDeveloperTools()
        try await checkOut(release.tag)

        let scratch = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        do {
            try await build(release.version, into: scratch)
            let app = scratch.appending(path: "\(appName).app")
            try PreparedUpdate.checkBundle(app, bundleIdentifier: bundleIdentifier, expectedVersion: release.version)
            return PreparedUpdate(app: app, version: release.version, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Without Xcode or its Command Line Tools, /usr/bin/git and swift are
    /// stubs that pop up an installer dialog, so this runs before either.
    /// xcode-select only reports the folder in use and never prompts.
    private func requireDeveloperTools() async throws {
        let output = try? await runCollectingOutput(
            executable: URL(filePath: "/usr/bin/xcode-select"), arguments: ["-p"], environment: environment)
        let folder = output.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let folder, !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else {
            throw UpdateError.notInstallable(
                "Building this update needs Xcode or its Command Line Tools. "
                    + "Install them with xcode-select --install, then try again.")
        }
    }

    /// Fetches only the release's tag, with the history build.sh numbers the
    /// build from, and checks it out. Everything is forced: the clone belongs
    /// to the app, so there is nothing in it worth keeping. Every argument the
    /// tag lands in starts with "+" or "refs/", so git never reads it as an
    /// option; a tag naming another version builds a bundle that fails the
    /// version check.
    private func checkOut(_ tag: String) async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: checkout.appending(path: ".git").path) {
            try? fileManager.removeItem(at: checkout)
            try fileManager.createDirectory(at: checkout, withIntermediateDirectories: true)
            try await git("init", "--quiet")
        }
        do {
            try await git("fetch", "--quiet", "--no-tags", remote, "+refs/tags/\(tag):refs/tags/\(tag)")
        } catch {
            throw UpdateError.notInstallable(
                "Couldn't download the source of Shrink \(tag): \(error.localizedDescription)")
        }
        try await git("checkout", "--quiet", "--force", "--detach", "refs/tags/\(tag)")
    }

    /// Runs the release's own build.sh, so a release that changes how Shrink
    /// is built still builds. It installs into `scratch`, never over the
    /// running copy, and only quits a Shrink running from there, which none is.
    private func build(_ version: SemanticVersion, into scratch: URL) async throws {
        var lines: [String] = []
        let result = try await runStreamingLines(
            executable: URL(filePath: "/bin/bash"),
            arguments: [checkout.appending(path: "build.sh").path, scratch.path],
            environment: environment
        ) { lines.append($0) }
        lines += result.standardError.split(separator: "\n").map(String.init)
        let log = lines.joined(separator: "\n")
        try? log.write(to: logURL, atomically: true, encoding: .utf8)

        guard result.status == 0 else {
            // Compiler errors arrive as "/long/path/File.swift:3:1: error: …".
            let reason = lines.last { $0.contains("error:") }
                .map { ": " + $0[$0.range(of: "error:")!.lowerBound...] } ?? ""
            throw BuildFailure(summary: "Building Shrink \(version) failed\(reason).", log: log, logURL: logURL)
        }
    }

    @discardableResult
    private func git(_ arguments: String...) async throws -> Data {
        try await runCollectingOutput(
            executable: URL(filePath: "/usr/bin/git"), arguments: ["-C", checkout.path] + arguments,
            environment: environment)
    }
}
