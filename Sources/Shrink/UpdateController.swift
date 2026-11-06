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
        case installFailed(Release, Failure)
    }

    /// Why an install failed: the banner shows the message, Details the rest.
    struct Failure: Equatable {
        let message: String
        /// Everything a failed source build printed.
        let log: String?
        let logURL: URL?

        init(_ error: any Error) {
            message = error.localizedDescription
            let build = error as? BuildFailure
            log = build?.log
            logURL = build?.logURL
        }
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// What a build needs to update itself. Nil for `swift run`, which has no
    /// app bundle, and for a release build without a Team ID to check against.
    struct Configuration: Sendable {
        /// A copy updates the way it was installed, which build.sh records.
        enum Method: Sendable {
            /// A signed release: download the next one and check who signed it.
            case download(DeveloperIDVerifier)
            /// Built on this Mac by build.sh: build the next release here too.
            case build
        }

        let repository: String
        let bundleIdentifier: String
        let method: Method
        let currentVersion: SemanticVersion?
        let appURL: URL
    }

    typealias Fetch = @Sendable (_ repository: String, _ userAgent: String) async throws -> Release?
    /// Downloads or builds a release, ready to swap in.
    typealias Prepare = @Sendable (Release, Configuration) async throws -> PreparedUpdate

    private(set) var phase: Phase = .idle
    /// Result of a check the user asked for; background checks stay silent.
    var notice: Notice?
    let configuration: Configuration?

    private let fetch: Fetch
    private let prepare: Prepare
    private let defaults: UserDefaults
    static let lastCheckKey = "lastUpdateCheck"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        fetch: @escaping Fetch = { try await ReleaseFeed.latest(repository: $0, userAgent: $1) },
        prepare: @escaping Prepare = UpdateController.prepareUpdate
    ) {
        configuration = Self.configuration(from: bundle)
        self.defaults = defaults
        self.fetch = fetch
        self.prepare = prepare
    }

    static let prepareUpdate: Prepare = { release, configuration in
        switch configuration.method {
        case .download(let verifier):
            try await UpdateInstaller(verifier: verifier, bundleIdentifier: configuration.bundleIdentifier)
                .prepare(release, replacing: configuration.appURL, currentVersion: configuration.currentVersion)
        case .build:
            try await SourceUpdater(
                remote: SourceUpdater.gitHubRemote(configuration.repository),
                bundleIdentifier: configuration.bundleIdentifier
            ).prepare(release, replacing: configuration.appURL, currentVersion: configuration.currentVersion)
        }
    }

    static func configuration(from bundle: Bundle) -> Configuration? {
        guard bundle.bundleURL.pathExtension == "app",
            let info = bundle.infoDictionary,
            let repository = info["ShrinkUpdateRepository"] as? String, !repository.isEmpty,
            let identifier = bundle.bundleIdentifier
        else { return nil }

        let method: Configuration.Method
        if info["ShrinkUpdateMethod"] as? String == "source" {
            method = .build
        } else {
            guard let teamID = info["ShrinkUpdateTeamID"] as? String, !teamID.isEmpty,
                let verifier = try? DeveloperIDVerifier(teamID: teamID, bundleIdentifier: identifier)
            else { return nil }
            method = .download(verifier)
        }
        return Configuration(
            repository: repository,
            bundleIdentifier: identifier,
            method: method,
            currentVersion: (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
            appURL: bundle.bundleURL)
    }

    var buildsFromSource: Bool {
        if case .build = configuration?.method { true } else { false }
    }

    var isInstalling: Bool {
        if case .installing = phase { true } else { false }
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
                    message: "Only Shrink.app updates itself, whether it came from GitHub Releases or from build.sh.")
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
            let prepared = try await prepare(release, configuration)
            try prepared.install(replacing: configuration.appURL)
            relaunch(configuration.appURL)
        } catch {
            phase = .installFailed(release, Failure(error))
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
