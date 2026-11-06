import Foundation
import Testing

@testable import ShrinkCore

/// Lets the install mechanics be tested without a Developer ID certificate.
/// The real verifier has its own tests below.
private struct AcceptAnything: UpdateVerifying {
    func verify(_ app: URL) async throws {}
}

/// Builds update archives the way the release workflow does: a signed
/// `Shrink.app`, zipped with `ditto -c -k --keepParent`, plus its checksum.
private struct Fixture {
    let directory: URL
    let installed: URL
    let bundleIdentifier = "sk.icebear.shrink"

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "shrink-update-\(UUID().uuidString)")
        let installedFolder = directory.appending(path: "Applications")
        try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        installed = installedFolder.appending(path: "Shrink.app")
        try makeApp(at: installed, version: "1.0.0")
    }

    func makeApp(at app: URL, version: String, identifier: String? = nil) throws {
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "Shrink"))
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier ?? bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Shrink",
            "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }

    /// A published release of `version` whose bundle reports `bundleVersion`.
    func release(
        _ version: String, bundleVersion: String? = nil, identifier: String? = nil,
        corruptChecksum: Bool = false
    ) throws -> Release {
        let build = directory.appending(path: "build-\(UUID().uuidString)")
        try makeApp(at: build.appending(path: "Shrink.app"), version: bundleVersion ?? version, identifier: identifier)
        let archive = build.appending(path: "Shrink.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", build.appending(path: "Shrink.app").path, archive.path])
        return try publish(archive, version: version, corruptChecksum: corruptChecksum)
    }

    func publish(_ archive: URL, version: String, corruptChecksum: Bool = false) throws -> Release {
        let hash = corruptChecksum ? String(repeating: "0", count: 64) : UpdateInstaller.sha256(of: archive)!
        let checksum = archive.deletingLastPathComponent().appending(path: "Shrink.zip.sha256")
        try Data("\(hash)  Shrink.zip\n".utf8).write(to: checksum)
        return Release(
            version: SemanticVersion(version)!, notesURL: URL(string: "https://example.invalid")!,
            archiveURL: archive, checksumURL: checksum)
    }

    var installedVersion: String? {
        (NSDictionary(contentsOf: installed.appending(path: "Contents/Info.plist")) as? [String: Any])?[
            "CFBundleShortVersionString"] as? String
    }

    func installer(_ verifier: any UpdateVerifying = AcceptAnything()) -> UpdateInstaller {
        UpdateInstaller(verifier: verifier, bundleIdentifier: bundleIdentifier)
    }

    func prepare(_ release: Release, with verifier: any UpdateVerifying = AcceptAnything()) async throws
        -> PreparedUpdate
    {
        try await installer(verifier).prepare(
            release, replacing: installed, currentVersion: SemanticVersion("1.0.0"))
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.notInstallable("\(tool) failed") }
    }
}

@Suite struct UpdateInstallerTests {
    @Test func installsAVerifiedUpdate() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let prepared = try await fixture.prepare(try fixture.release("1.1.0"))
        #expect(fixture.installedVersion == "1.0.0", "nothing changes until install")
        try prepared.install(replacing: fixture.installed)

        #expect(fixture.installedVersion == "1.1.0")
        #expect(!FileManager.default.fileExists(atPath: prepared.scratch.path), "scratch folder left behind")
    }

    @Test func theRealVerifierRejectsAnAppNotSignedByTheTeam() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let verifier = try DeveloperIDVerifier(teamID: "ABCDE12345", bundleIdentifier: fixture.bundleIdentifier)

        // Ad-hoc signed: a valid signature, but from nobody in particular.
        await #expect(throws: UpdateError.self) {
            _ = try await fixture.prepare(try fixture.release("1.1.0"), with: verifier)
        }
        #expect(fixture.installedVersion == "1.0.0")
    }

    /// Calculator is validly signed and Gatekeeper accepts it — just not from
    /// this team or with this identifier, so only the requirement can stop it.
    @Test func theRealVerifierRejectsATrustedAppFromSomeoneElse() async throws {
        let verifier = try DeveloperIDVerifier(teamID: "ABCDE12345", bundleIdentifier: "sk.icebear.shrink")
        await #expect(throws: UpdateError.self) {
            try await verifier.verify(URL(filePath: "/System/Applications/Calculator.app"))
        }
    }

    @Test func rejectsACorruptedDownload() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: UpdateError.checksumMismatch) {
            _ = try await fixture.prepare(try fixture.release("1.1.0", corruptChecksum: true))
        }
        #expect(fixture.installedVersion == "1.0.0")
    }

    /// Extraction must never write outside the scratch folder, because it runs
    /// before the signature is checked. ditto guarantees that; this pins it in
    /// case anyone swaps ditto for a tool that honours hostile paths.
    @Test func aHostileArchiveWritesNothingOutsideTheScratchFolder() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = fixture.directory.appending(path: "escaped.txt")
        let archive = fixture.directory.appending(path: "hostile/Shrink.zip")
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        // zip(1) won't store such names, so write the entries directly: an
        // absolute path aimed at a known location, and a symlink to write through.
        let python = Process()
        python.executableURL = URL(filePath: "/usr/bin/python3")
        python.arguments = [
            "-c",
            """
            import sys, zipfile, stat
            z = zipfile.ZipFile(sys.argv[1], 'w')
            z.writestr('Shrink.app/Contents/Info.plist', 'x')
            z.writestr(zipfile.ZipInfo(sys.argv[2]), 'pwned')
            link = zipfile.ZipInfo('Shrink.app/link')
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(link, sys.argv[3])
            z.writestr('Shrink.app/link/through-link.txt', 'pwned')
            z.close()
            """,
            archive.path, target.path, fixture.directory.path,
        ]
        try python.run()
        python.waitUntilExit()

        await #expect(throws: (any Error).self) {
            _ = try await fixture.prepare(try fixture.publish(archive, version: "1.1.0"))
        }
        #expect(!FileManager.default.fileExists(atPath: target.path), "absolute entry escaped")
        #expect(
            !FileManager.default.fileExists(atPath: fixture.directory.appending(path: "through-link.txt").path),
            "write through a symlink escaped")
        #expect(fixture.installedVersion == "1.0.0")
    }

    @Test func rejectsABundleWhoseVersionDoesNotMatchTheRelease() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: UpdateError.self) {
            _ = try await fixture.prepare(try fixture.release("1.2.0", bundleVersion: "1.1.0"))
        }
        #expect(fixture.installedVersion == "1.0.0")
    }

    @Test func rejectsADifferentApp() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: UpdateError.self) {
            _ = try await fixture.prepare(try fixture.release("1.1.0", identifier: "com.example.other"))
        }
        #expect(fixture.installedVersion == "1.0.0")
    }

    @Test func refusesToReinstallOrDowngrade() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for version in ["1.0.0", "0.9.0"] {
            await #expect(throws: UpdateError.self) {
                _ = try await fixture.prepare(try fixture.release(version))
            }
        }
        #expect(fixture.installedVersion == "1.0.0")
    }

    /// Runs in the release workflow against the freshly signed, notarised and
    /// stapled build, so a release the updater would refuse is never published.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHRINK_VERIFY_APP"] != nil))
    func acceptsTheReleaseBuild() async throws {
        let environment = ProcessInfo.processInfo.environment
        let app = URL(filePath: try #require(environment["SHRINK_VERIFY_APP"]))
        let verifier = try DeveloperIDVerifier(
            teamID: try #require(environment["SHRINK_TEAM_ID"]), bundleIdentifier: "sk.icebear.shrink")
        try await verifier.verify(app)
    }
}
