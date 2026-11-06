import Foundation
import Testing

@testable import Shrink
@testable import ShrinkCore

private actor FeedCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
@Suite struct UpdateControllerTests {
    /// A real `.app` folder with the Info.plist keys build.sh writes.
    func bundle(version: String = "1.0.0", teamID: String = "ABCDE12345", method: String? = nil) throws
        -> (Bundle, URL)
    {
        let root = URL.temporaryDirectory.appending(path: "shrink-ctl-\(UUID().uuidString)")
        let contents = root.appending(path: "Shrink.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: String] = [
            "CFBundleIdentifier": "sk.icebear.shrink",
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
            "ShrinkUpdateRepository": "mattonik/shrink",
            "ShrinkUpdateTeamID": teamID,
        ]
        info["ShrinkUpdateMethod"] = method
        try (info as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        return (try #require(Bundle(url: root.appending(path: "Shrink.app"))), root)
    }

    func release(_ version: String) -> Release {
        let base = URL(string: "https://github.com/mattonik/shrink/releases/download/v\(version)")!
        return Release(
            version: SemanticVersion(version)!,
            notesURL: URL(string: "https://github.com/mattonik/shrink/releases/tag/v\(version)")!,
            archiveURL: base.appending(path: "Shrink.zip"), checksumURL: base.appending(path: "Shrink.zip.sha256"))
    }

    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "shrink-tests-\(UUID().uuidString)")!
    }

    @Test func offersANewerRelease() async throws {
        let (bundle, root) = try bundle(version: "1.0.0")
        defer { try? FileManager.default.removeItem(at: root) }
        let newer = release("1.1.0")
        let controller = UpdateController(bundle: bundle, defaults: freshDefaults()) { _, _ in newer }

        await controller.check(userInitiated: false)

        #expect(controller.phase == .available(newer))
        #expect(controller.notice == nil)
    }

    @Test func staysQuietWhenAlreadyUpToDate() async throws {
        let (bundle, root) = try bundle(version: "1.1.0")
        defer { try? FileManager.default.removeItem(at: root) }
        let same = release("1.1.0")
        let controller = UpdateController(bundle: bundle, defaults: freshDefaults()) { _, _ in same }

        await controller.check(userInitiated: false)
        #expect(controller.phase == .idle)
        #expect(controller.notice == nil, "background checks never interrupt")

        await controller.check(userInitiated: true)
        #expect(controller.notice?.title == "You're up to date")
    }

    @Test func reportsFailuresOnlyWhenAsked() async throws {
        let (bundle, root) = try bundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UpdateController(bundle: bundle, defaults: freshDefaults()) { _, _ in
            throw UpdateError.unavailable("GitHub's rate limit was reached, try again later")
        }

        await controller.check(userInitiated: false)
        #expect(controller.phase == .idle)
        #expect(controller.notice == nil)

        await controller.check(userInitiated: true)
        #expect(controller.notice?.title == "Couldn't check for updates")
    }

    @Test func checksInTheBackgroundAtMostOnceADay() async throws {
        let (bundle, root) = try bundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = freshDefaults()
        let calls = FeedCalls()
        let controller = UpdateController(bundle: bundle, defaults: defaults) { _, _ in
            await calls.record()
            return nil
        }

        defaults.set(Date().addingTimeInterval(-60 * 60), forKey: UpdateController.lastCheckKey)
        controller.checkInBackgroundIfDue()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await calls.count == 0, "checked again within the hour")

        defaults.set(Date().addingTimeInterval(-25 * 60 * 60), forKey: UpdateController.lastCheckKey)
        controller.checkInBackgroundIfDue()
        for _ in 0..<40 where await calls.count == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await calls.count == 1)
    }

    @Test func signedReleasesUpdateByDownloadingTheNextRelease() throws {
        let (bundle, root) = try bundle(method: "release")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UpdateController(bundle: bundle, defaults: freshDefaults()) { _, _ in nil }

        guard case .download(let verifier) = controller.configuration?.method else {
            Issue.record("expected a download configuration, got \(String(describing: controller.configuration?.method))")
            return
        }
        #expect(verifier.teamID == "ABCDE12345")
        #expect(!controller.buildsFromSource)
    }

    /// A copy built with build.sh rebuilds from source, which involves no
    /// signature, so it updates even when no Team ID was ever configured.
    @Test func copiesBuiltFromSourceUpdateWithoutATeamID() async throws {
        let (bundle, root) = try bundle(teamID: "", method: "source")
        defer { try? FileManager.default.removeItem(at: root) }
        let newer = release("1.1.0")
        let controller = UpdateController(bundle: bundle, defaults: freshDefaults()) { _, _ in newer }

        #expect(controller.buildsFromSource)
        await controller.check(userInitiated: false)
        #expect(controller.phase == .available(newer))
    }

    @Test func releaseBuildsWithoutATeamIDNeverReachTheNetwork() async throws {
        let (bundle, root) = try bundle(teamID: "")
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = FeedCalls()
        let controller = UpdateController(bundle: bundle, defaults: freshDefaults()) { _, _ in
            await calls.record()
            return nil
        }

        #expect(controller.configuration == nil)
        controller.checkInBackgroundIfDue()
        await controller.check(userInitiated: true)

        #expect(await calls.count == 0)
        #expect(controller.notice?.title == "This build can't update itself")
    }
}
