import AppKit
import Foundation
import Observation
import ShrinkCore

@MainActor
@Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case available(Release)
        case installing(Release)
        case installFailed(Release, String)
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// What a build needs to update itself. Nil for local builds made before a
    /// Team ID is configured, and for `swift run`, which has no app bundle.
    struct Configuration {
        let repository: String
        let verifier: DeveloperIDVerifier
        let currentVersion: SemanticVersion?
        let appURL: URL
    }

    typealias Fetch = @Sendable (_ repository: String, _ userAgent: String) async throws -> Release?

    private(set) var phase: Phase = .idle
    /// Result of a check the user asked for; background checks stay silent.
    var notice: Notice?
    let configuration: Configuration?

    private let fetch: Fetch
    private let defaults: UserDefaults
    static let lastCheckKey = "lastUpdateCheck"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        fetch: @escaping Fetch = { try await ReleaseFeed.latest(repository: $0, userAgent: $1) }
    ) {
        configuration = Self.configuration(from: bundle)
        self.defaults = defaults
        self.fetch = fetch
    }

    static func configuration(from bundle: Bundle) -> Configuration? {
        guard bundle.bundleURL.pathExtension == "app",
            let info = bundle.infoDictionary,
            let repository = info["ShrinkUpdateRepository"] as? String, !repository.isEmpty,
            let teamID = info["ShrinkUpdateTeamID"] as? String, !teamID.isEmpty,
            let identifier = bundle.bundleIdentifier,
            let verifier = try? DeveloperIDVerifier(teamID: teamID, bundleIdentifier: identifier)
        else { return nil }
        return Configuration(
            repository: repository,
            verifier: verifier,
            currentVersion: (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
            appURL: bundle.bundleURL)
    }

    /// GitHub allows 60 unauthenticated requests an hour per IP address, which
    /// a shared office connection can exhaust — so at most one check a day.
    func checkInBackgroundIfDue(now: Date = Date()) {
        guard configuration != nil else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard let configuration else {
            if userInitiated {
                notice = Notice(
                    title: "This build can't update itself",
                    message: "Only signed releases from GitHub update themselves. To update a build you made yourself, run build.sh again.")
            }
            return
        }
        switch phase {
        case .checking, .installing: return
        case .idle, .available, .installFailed: break
        }

        phase = .checking
        let current = configuration.currentVersion
        do {
            let release = try await fetch(
                configuration.repository, "Shrink/\(current?.description ?? "unknown")")
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if let release, current.map({ release.version > $0 }) ?? true {
                phase = .available(release)
            } else {
                phase = .idle
                if userInitiated {
                    notice = Notice(
                        title: "You're up to date",
                        message: "Shrink \(current?.description ?? "") is the latest version.")
                }
            }
        } catch {
            phase = .idle
            if userInitiated {
                notice = Notice(title: "Couldn't check for updates", message: error.localizedDescription)
            }
        }
    }

    func dismiss() {
        phase = .idle
    }

    func install(_ release: Release) async {
        guard let configuration else { return }
        phase = .installing(release)
        do {
            let installer = UpdateInstaller(
                verifier: configuration.verifier,
                bundleIdentifier: configuration.verifier.bundleIdentifier)
            let prepared = try await installer.prepare(
                release, replacing: configuration.appURL, currentVersion: configuration.currentVersion)
            try installer.install(prepared, replacing: configuration.appURL)
            relaunch(configuration.appURL)
        } catch {
            phase = .installFailed(release, error.localizedDescription)
        }
    }

    /// Waits for this process to exit, then opens the freshly installed copy.
    private func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // The path travels as $1, never spliced into the script text.
        process.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
            "sh", app.path,
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}
