import Foundation
import Security
import Testing

@testable import ShrinkCore

@Test func comparesVersionsNumericallyNotAlphabetically() throws {
    let v190 = try #require(SemanticVersion("1.9.0"))
    let v1100 = try #require(SemanticVersion("v1.10.0"))
    #expect(v1100 > v190, "1.10 is newer than 1.9 even though it sorts first as text")
    #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
    #expect(SemanticVersion("v2.0.0")?.description == "2.0.0")
}

@Test func rejectsVersionsItCannotOrder() {
    #expect(SemanticVersion("1.2.3-beta") == nil)
    #expect(SemanticVersion("1.2.3.4") == nil)
    #expect(SemanticVersion("latest") == nil)
    #expect(SemanticVersion("") == nil)
    #expect(SemanticVersion("1..2") == nil)
}

private func releaseJSON(
    tag: String = "v1.4.0", assets: [String] = ["Shrink.zip", "Shrink.zip.sha256"],
    draft: Bool = false, prerelease: Bool = false
) -> Data {
    let assetJSON = assets.map {
        #"{"name":"\#($0)","browser_download_url":"https://github.com/mattonik/shrink/releases/download/\#(tag)/\#($0)"}"#
    }.joined(separator: ",")
    return Data(
        #"{"tag_name":"\#(tag)","html_url":"https://github.com/mattonik/shrink/releases/tag/\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(assetJSON)]}"#
            .utf8)
}

@Test func readsTheLatestReleaseFromGitHub() throws {
    let release = try #require(try Release.parse(releaseJSON()))
    #expect(release.version == SemanticVersion("1.4.0"))
    #expect(release.archiveURL.lastPathComponent == "Shrink.zip")
    #expect(release.checksumURL.lastPathComponent == "Shrink.zip.sha256")
    #expect(release.notesURL.absoluteString.hasSuffix("/releases/tag/v1.4.0"))
}

@Test func ignoresReleasesItCannotInstall() throws {
    // Still uploading: no checksum yet.
    #expect(try Release.parse(releaseJSON(assets: ["Shrink.zip"])) == nil)
    #expect(try Release.parse(releaseJSON(draft: true)) == nil)
    #expect(try Release.parse(releaseJSON(prerelease: true)) == nil)
    #expect(try Release.parse(releaseJSON(tag: "nightly")) == nil)
}

@Test func readsShasumOutput() {
    let hash = String(repeating: "ab", count: 32)
    #expect(UpdateInstaller.parseChecksum("\(hash)  Shrink.zip\n") == hash)
    #expect(UpdateInstaller.parseChecksum(hash.uppercased()) == hash)
    #expect(UpdateInstaller.parseChecksum("not-a-hash  Shrink.zip") == nil)
    #expect(UpdateInstaller.parseChecksum("") == nil)
}

@Test func pinsTheSigningRequirementToOneTeamAndApp() throws {
    let verifier = try DeveloperIDVerifier(teamID: "ABCDE12345", bundleIdentifier: "com.mpuskac.shrink")
    #expect(verifier.requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
    #expect(verifier.requirement.contains(#"identifier "com.mpuskac.shrink""#))
    // The string must compile, or every update would fail at install time.
    var compiled: SecRequirement?
    #expect(SecRequirementCreateWithString(verifier.requirement as CFString, [], &compiled) == errSecSuccess)
}

@Test func refusesMalformedTeamIDs() {
    for bad in ["", "abcde12345", "ABCDE1234", "ABCDE12345X", #"ABCDE1234""#, "ABCDE 2345"] {
        #expect(throws: UpdateError.self) {
            try DeveloperIDVerifier(teamID: bad, bundleIdentifier: "com.mpuskac.shrink")
        }
    }
}
