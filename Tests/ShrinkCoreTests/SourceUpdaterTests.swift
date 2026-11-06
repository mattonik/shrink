import Foundation
import Testing

@testable import ShrinkCore

/// A git repository standing in for GitHub. Each commit carries a build.sh
/// that lays out Shrink.app the way the real one does, in seconds rather
/// than minutes: it reports the version in version.txt and packs marker.txt.
private struct SourceFixture {
    let directory: URL
    let remote: URL
    let installed: URL
    let checkout: URL
    let bundleIdentifier = "sk.icebear.shrink"

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "shrink-source-\(UUID().uuidString)")
        remote = directory.appending(path: "remote")
        checkout = directory.appending(path: "Support/Source")
        installed = directory.appending(path: "Applications/Shrink.app")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git("init", "--quiet", "--initial-branch=main")
        try makeInstalledApp(version: "1.0.0")
    }

    func makeInstalledApp(version: String) throws {
        let contents = installed.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: contents.appending(path: "marker.txt"))
        let info: NSDictionary = ["CFBundleIdentifier": bundleIdentifier, "CFBundleShortVersionString": version]
        try info.write(to: installed.appending(path: "Contents/Info.plist"))
    }

    /// Commits a source tree whose build reports `version` (or fails), and
    /// tags the commit when `tag` is given.
    func commit(version: String, marker: String, tag: String? = nil, failing: Bool = false) throws {
        let build = failing
            ? """
            #!/bin/bash
            echo "Compiling Shrink ShrinkApp.swift"
            echo "/Users/someone/src/Sources/Shrink/ShrinkApp.swift:3:1: error: cannot find 'oops' in scope"
            exit 1
            """
            : """
            #!/bin/bash
            set -euo pipefail
            cd "$(dirname "$0")"
            APP="$1/Shrink.app"
            mkdir -p "$APP/Contents/Resources"
            cp marker.txt "$APP/Contents/Resources/marker.txt"
            /usr/bin/plutil -create xml1 "$APP/Contents/Info.plist"
            /usr/bin/plutil -insert CFBundleIdentifier -string "\(bundleIdentifier)" "$APP/Contents/Info.plist"
            /usr/bin/plutil -insert CFBundleShortVersionString -string "$(cat version.txt)" "$APP/Contents/Info.plist"
            """
        try Data(build.utf8).write(to: remote.appending(path: "build.sh"))
        try Data(version.utf8).write(to: remote.appending(path: "version.txt"))
        try Data(marker.utf8).write(to: remote.appending(path: "marker.txt"))
        try git("add", "-A")
        try git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", marker)
        if let tag { try git("tag", tag) }
    }

    func release(_ version: String) -> Release {
        let unused = URL(string: "https://example.invalid/unused")!
        return Release(
            version: SemanticVersion(version)!, notesURL: unused, archiveURL: unused, checksumURL: unused)
    }

    func updater(environment: [String: String] = SourceUpdater.defaultEnvironment) -> SourceUpdater {
        SourceUpdater(
            remote: remote.path, bundleIdentifier: bundleIdentifier, checkout: checkout, environment: environment)
    }

    func prepare(_ version: String, over current: String = "1.0.0") async throws -> PreparedUpdate {
        try await updater().prepare(release(version), replacing: installed, currentVersion: SemanticVersion(current))
    }

    var installedVersion: String? {
        (NSDictionary(contentsOf: installed.appending(path: "Contents/Info.plist")) as? [String: Any])?[
            "CFBundleShortVersionString"] as? String
    }

    var installedMarker: String? {
        try? String(contentsOf: installed.appending(path: "Contents/Resources/marker.txt"), encoding: .utf8)
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", remote.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.notInstallable("git \(arguments) failed") }
    }
}

@Suite struct SourceUpdaterTests {
    @Test func buildsEachReleaseFromItsTag() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.commit(version: "1.1.0", marker: "release 1.1.0", tag: "v1.1.0")
        // Work on main after the tag must never ship until it is released.
        try fixture.commit(version: "1.1.0", marker: "unreleased work on main")

        let first = try await fixture.prepare("1.1.0")
        #expect(fixture.installedVersion == "1.0.0", "nothing changes until install")
        try first.install(replacing: fixture.installed)
        #expect(fixture.installedVersion == "1.1.0")
        #expect(fixture.installedMarker == "release 1.1.0")
        #expect(!FileManager.default.fileExists(atPath: first.scratch.path), "scratch folder left behind")

        // The next release reuses the clone the first update made.
        try fixture.commit(version: "1.2.0", marker: "release 1.2.0", tag: "v1.2.0")
        try await fixture.prepare("1.2.0", over: "1.1.0").install(replacing: fixture.installed)
        #expect(fixture.installedVersion == "1.2.0")
        #expect(fixture.installedMarker == "release 1.2.0")
    }

    @Test func aFailedBuildChangesNothingAndSaysWhy() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.commit(version: "1.1.0", marker: "broken", tag: "v1.1.0", failing: true)

        let error = await #expect(throws: UpdateError.self) { _ = try await fixture.prepare("1.1.0") }
        let message = try #require(error?.localizedDescription)
        #expect(message.contains("error: cannot find 'oops' in scope"))
        #expect(!message.contains("/Users/someone"), "the compiler's long path belongs in the log, not the banner")
        let log = try String(contentsOf: fixture.updater().logURL, encoding: .utf8)
        #expect(log.contains("Compiling Shrink"))
        #expect(fixture.installedMarker == "installed")
    }

    /// The version check is what proves the tag was built, not something else.
    @Test func refusesABuildThatIsNotTheRelease() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.commit(version: "1.0.5", marker: "mislabelled", tag: "v1.1.0")

        await #expect(throws: UpdateError.self) { _ = try await fixture.prepare("1.1.0") }
        #expect(fixture.installedMarker == "installed")
    }

    @Test func aReleaseWithNoTagChangesNothing() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.commit(version: "1.1.0", marker: "untagged")

        let error = await #expect(throws: UpdateError.self) { _ = try await fixture.prepare("1.1.0") }
        #expect(error?.localizedDescription.contains("Couldn't download the source of Shrink v1.1.0") == true)
        #expect(fixture.installedMarker == "installed")
    }

    /// Without developer tools, git itself would pop up an installer dialog,
    /// so the check has to come before git ever runs.
    @Test func asksForTheDeveloperToolsBeforeRunningGit() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.commit(version: "1.1.0", marker: "release 1.1.0", tag: "v1.1.0")
        var environment = SourceUpdater.defaultEnvironment
        environment["DEVELOPER_DIR"] = fixture.directory.appending(path: "no-tools-here").path

        let error = await #expect(throws: UpdateError.self) {
            _ = try await fixture.updater(environment: environment).prepare(
                fixture.release("1.1.0"), replacing: fixture.installed, currentVersion: SemanticVersion("1.0.0"))
        }
        #expect(error?.localizedDescription.contains("xcode-select --install") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkout.path), "git ran anyway")
    }

    @Test func refusesToReinstallOrDowngrade() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for version in ["1.0.0", "0.9.0"] {
            try fixture.commit(version: version, marker: "old \(version)", tag: "v\(version)")
            await #expect(throws: UpdateError.self) { _ = try await fixture.prepare(version) }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.checkout.path), "fetched before refusing")
        #expect(fixture.installedMarker == "installed")
    }

    /// Builds the real app from a tagged clone of this repository, with the
    /// stripped-down environment an app opened from the Finder runs in. It
    /// compiles Shrink from scratch, so it only runs when asked:
    /// `SHRINK_SOURCE_BUILD=1 swift test --filter buildsTheRealAppFromSource`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHRINK_SOURCE_BUILD"] != nil))
    func buildsTheRealAppFromSource() async throws {
        let fixture = try SourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let clone = fixture.directory.appending(path: "clone")
        for arguments in [
            ["clone", "--quiet", repository.path, clone.path],
            ["-C", clone.path, "tag", "v99.0.0"],
        ] {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0",
        ]
        let updater = SourceUpdater(
            remote: clone.path, bundleIdentifier: fixture.bundleIdentifier, checkout: fixture.checkout,
            environment: environment)

        let prepared = try await updater.prepare(
            fixture.release("99.0.0"), replacing: fixture.installed, currentVersion: SemanticVersion("1.0.0"))
        let info = try #require(NSDictionary(contentsOf: prepared.app.appending(path: "Contents/Info.plist")))
        #expect(info["ShrinkUpdateMethod"] as? String == "source", "the rebuilt copy must keep updating from source")
        #expect(info["CFBundleShortVersionString"] as? String == "99.0.0")

        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--strict", prepared.app.path]
        try codesign.run()
        codesign.waitUntilExit()
        #expect(codesign.terminationStatus == 0)
        try prepared.install(replacing: fixture.installed)
        #expect(fixture.installedVersion == "99.0.0")
    }
}
