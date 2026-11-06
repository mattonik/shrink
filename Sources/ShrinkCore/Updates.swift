import CryptoKit
import Foundation
import Security

public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    /// `v1.2.3`, `1.2.3` or `1.2`. Pre-release tags are rejected: GitHub's
    /// "latest release" never points at one, and they have no ordering here.
    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = numbers.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

public struct Release: Equatable, Sendable {
    public let version: SemanticVersion
    public let notesURL: URL
    public let archiveURL: URL
    public let checksumURL: URL
    /// The git tag, which a copy built from source fetches and builds.
    public let tag: String

    public static let archiveName = "Shrink.zip"
    public static let checksumName = "Shrink.zip.sha256"

    public init(
        version: SemanticVersion, notesURL: URL, archiveURL: URL, checksumURL: URL, tag: String? = nil
    ) {
        self.version = version
        self.notesURL = notesURL
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
        self.tag = tag ?? "v\(version)"
    }

    /// The GitHub "latest release" payload, or nil when it lacks a usable
    /// version or either asset — a release still uploading looks like this.
    public static func parse(_ data: Data) throws -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true,
            let version = SemanticVersion(payload.tag_name),
            let archive = payload.assets.first(where: { $0.name == archiveName }),
            let checksum = payload.assets.first(where: { $0.name == checksumName })
        else { return nil }
        return Release(
            version: version, notesURL: payload.html_url,
            archiveURL: archive.browser_download_url, checksumURL: checksum.browser_download_url,
            tag: payload.tag_name)
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case unavailable(String)
    case checksumMismatch
    case unsafeArchive(String)
    case untrustedSignature(String)
    case wrongBundle(String)
    case notInstallable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Couldn't check for updates: \(detail)"
        case .checksumMismatch: "The download was corrupted — its checksum doesn't match. Nothing was changed."
        case .unsafeArchive(let detail): "The update archive was refused: \(detail). Nothing was changed."
        case .untrustedSignature(let detail): "The update isn't signed by Shrink's developer (\(detail)). Nothing was changed."
        case .wrongBundle(let detail): "The update doesn't match this app: \(detail). Nothing was changed."
        case .notInstallable(let detail): detail
        }
    }
}

public enum ReleaseFeed {
    /// Asks GitHub for the newest published release. Unauthenticated, so it is
    /// rate-limited per IP address — the app checks at most once a day.
    public static func latest(
        repository: String, userAgent: String, session: URLSession = .shared
    ) async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.unavailable("invalid repository \(repository)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try Release.parse(data)
        case 404: return nil  // no release published yet
        case 403, 429: throw UpdateError.unavailable("GitHub's rate limit was reached, try again later")
        default: throw UpdateError.unavailable("GitHub answered \(status)")
        }
    }
}

/// Decides whether an unpacked update may replace the running app.
public protocol UpdateVerifying: Sendable {
    func verify(_ app: URL) async throws
}

/// Accepts only apps signed with a Developer ID certificate issued to one
/// team, with a valid signature over every file, and accepted by Gatekeeper —
/// which for a Developer ID app means Apple has notarised it.
///
/// This is origin checking, not just integrity: the checksum only proves the
/// zip arrived intact, and it is fetched from the same place as the zip.
public struct DeveloperIDVerifier: UpdateVerifying {
    public let teamID: String
    public let bundleIdentifier: String

    public init(teamID: String, bundleIdentifier: String) throws {
        // Team IDs are ten uppercase letters and digits; anything else is a
        // misconfiguration, and must never reach the requirement string.
        guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
        else { throw UpdateError.notInstallable("Updates are misconfigured: bad team ID \"\(teamID)\"") }
        guard bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { throw UpdateError.notInstallable("Updates are misconfigured: bad bundle identifier") }
        self.teamID = teamID
        self.bundleIdentifier = bundleIdentifier
    }

    /// Apple's own designated requirement for a Developer ID app (the two
    /// certificate fields mark the Developer ID CA and an Application
    /// certificate), pinned to one team and one bundle identifier.
    public var requirement: String {
        """
        identifier "\(bundleIdentifier)" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
    }

    public func verify(_ app: URL) async throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.untrustedSignature("no code signature found")
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
            let compiled
        else { throw UpdateError.notInstallable("Updates are misconfigured: invalid signing requirement") }

        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, compiled)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw UpdateError.untrustedSignature(reason)
        }

        do {
            _ = try await runCollectingOutput(
                executable: URL(filePath: "/usr/sbin/spctl"),
                arguments: ["--assess", "--type", "execute", app.path])
        } catch {
            throw UpdateError.untrustedSignature("Gatekeeper rejected it — is it notarised?")
        }
    }
}

public struct PreparedUpdate: Sendable {
    public let app: URL
    public let version: SemanticVersion
    let scratch: URL

    /// Swaps the prepared app in. The running copy keeps working from memory
    /// until it quits; the next launch starts the new version.
    public func install(replacing current: URL) throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
    }

    /// Checks that apply however the update arrives: it must be newer, and the
    /// folder the app lives in must let it be replaced.
    static func checkReplaceable(
        _ current: URL, with version: SemanticVersion, currentVersion: SemanticVersion?
    ) throws {
        if let currentVersion, version <= currentVersion {
            throw UpdateError.wrongBundle("\(version) is not newer than \(currentVersion)")
        }
        let folder = current.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else {
            throw UpdateError.notInstallable(
                "Shrink can't replace itself in \(folder). "
                    + "Move it to your Applications folder in your home folder and try again.")
        }
    }

    /// The new app must be this app, at exactly the version being installed.
    static func checkBundle(_ app: URL, bundleIdentifier: String, expectedVersion: SemanticVersion) throws {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw UpdateError.wrongBundle("it has no readable Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.wrongBundle("bundle identifier \(info["CFBundleIdentifier"] ?? "missing")")
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
            version == expectedVersion
        else {
            throw UpdateError.wrongBundle(
                "it reports version \(info["CFBundleShortVersionString"] ?? "missing"), expected \(expectedVersion)")
        }
    }
}

public struct UpdateInstaller: Sendable {
    public let verifier: any UpdateVerifying
    public let bundleIdentifier: String
    public let appName: String

    public init(verifier: any UpdateVerifying, bundleIdentifier: String, appName: String = "Shrink") {
        self.verifier = verifier
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }

    /// Downloads and fully checks `release` in a scratch folder next to
    /// `current`, returning an app that is safe to swap in. Nothing outside
    /// the scratch folder is touched, and it is removed if any check fails.
    public func prepare(
        _ release: Release, replacing current: URL, currentVersion: SemanticVersion?,
        session: URLSession = .shared
    ) async throws -> PreparedUpdate {
        try PreparedUpdate.checkReplaceable(current, with: release.version, currentVersion: currentVersion)
        let fileManager = FileManager.default

        let scratch = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        do {
            let archive = try await download(release.archiveURL, session: session, into: scratch)
            let checksum = try await String(
                contentsOf: download(release.checksumURL, session: session, into: scratch), encoding: .utf8)
            guard let expected = Self.parseChecksum(checksum), Self.sha256(of: archive) == expected else {
                throw UpdateError.checksumMismatch
            }

            // ditto confines every entry to the destination: a leading "../",
            // a "../" mid-path and an absolute path all land inside it, and a
            // symlink entry is written as a plain file, so nothing extracted
            // can reach outside the scratch folder before verification runs.
            let unpacked = scratch.appending(path: "unpacked")
            _ = try await runCollectingOutput(
                executable: URL(filePath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, unpacked.path])
            let app = unpacked.appending(path: "\(appName).app")
            guard fileManager.fileExists(atPath: app.path) else {
                throw UpdateError.unsafeArchive("it doesn't contain \(appName).app")
            }

            try PreparedUpdate.checkBundle(
                app, bundleIdentifier: bundleIdentifier, expectedVersion: release.version)
            try await verifier.verify(app)
            return PreparedUpdate(app: app, version: release.version, scratch: scratch)
        } catch {
            try? fileManager.removeItem(at: scratch)
            throw error
        }
    }

    static func parseChecksum(_ text: String) -> String? {
        let hash = text.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
        guard let hash, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash
    }

    static func sha256(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func download(_ url: URL, session: URLSession, into directory: URL) async throws -> URL {
        let (temporary, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.unavailable("download failed with \(http.statusCode)")
        }
        let destination = directory.appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
