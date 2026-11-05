import Foundation
import Testing

@testable import Shrink
import ShrinkCore
import ShrinkTestSupport

/// Drives the app's real conversion queue — the code behind the Shrink and
/// Cancel buttons — against real files, without opening a window.
@MainActor
@Suite(
    .enabled(
        if: ToolPaths.locate() != nil && ToolPaths.locateGhostscript() != nil,
        "requires ffmpeg and Ghostscript"))
struct AppModelTests {
    let ffmpeg = ToolPaths.locate()!.ffmpeg

    func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "shrink-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func waitUntil(
        _ what: String, timeout: Duration = .seconds(90), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func state(of url: URL, in model: AppModel) -> AppModel.Item.State? {
        model.items.first { $0.url == url.standardizedFileURL }?.state
    }

    func isConverting(_ state: AppModel.Item.State?) -> Bool {
        if case .converting(let fraction) = state { fraction > 0 } else { false }
    }

    @Test func convertsAMixedBatchEndToEnd() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try VideoFixtures.make(ffmpeg: ffmpeg, in: directory, name: "demo.mp4", size: "1280x720")
        let scan = directory.appending(path: "scan.pdf")
        try PDFFixtures.imageHeavy(at: scan, pages: 2)
        let contract = directory.appending(path: "contract.pdf")
        try PDFFixtures.signed(at: contract)
        let notes = directory.appending(path: "notes.txt")
        try Data("not a video".utf8).write(to: notes)

        let model = AppModel()
        model.add(urls: [video, scan, contract, notes])
        #expect(model.items.count == 3, "the text file is not accepted")
        try await waitUntil("files to be read") { model.items.allSatisfy { $0.source != nil } }

        // The signed contract is set aside before anything runs.
        guard case .skipped(let reason) = state(of: contract, in: model) else {
            Issue.record("signed PDF should be skipped up front")
            return
        }
        #expect(reason.contains("signed"))

        model.convert()
        try await waitUntil("the batch to finish") { !model.isConverting }

        guard case .done(let videoOutput, _) = state(of: video, in: model),
            case .done(let pdfOutput, _) = state(of: scan, in: model)
        else {
            Issue.record("expected both conversions to finish: \(model.items.map(\.state))")
            return
        }
        #expect(videoOutput.lastPathComponent == "demo-720p.mp4")
        #expect(pdfOutput.lastPathComponent == "scan-ebook.pdf")
        #expect(FileManager.default.fileExists(atPath: videoOutput.path))
        #expect(FileManager.default.fileExists(atPath: pdfOutput.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "contract-ebook.pdf").path))
    }

    /// The compressor never writes to the destination until a result is kept,
    /// so whatever sits there on cancel belongs to the user — the queue must
    /// not run the video path's partial-file cleanup over it.
    @Test func cancellingAPDFLeavesAFileAlreadyAtItsOutputPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "long.pdf")
        try PDFFixtures.imageHeavy(at: input, pages: 24, pixels: 900)
        let existing = directory.appending(path: "long-ebook.pdf")
        try Data("keep me".utf8).write(to: existing)

        let model = AppModel()
        model.add(urls: [input])
        try await waitUntil("the PDF to be read") { model.items.first?.source != nil }
        model.convert()
        try await waitUntil("compression to start") { isConverting(model.items.first?.state) }
        model.cancel()
        try await waitUntil("the cancel to land") { !model.isConverting }

        #expect(model.items.first?.state == .cancelled)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    /// ffmpeg writes straight to its output, so a cancelled video leaves a
    /// truncated file that has to go — and stay gone: after SIGTERM ffmpeg
    /// still spends ~0.25 s on its +faststart pass, and the check below waits
    /// well past that.
    @Test func cancellingAVideoRemovesItsPartialOutputForGood() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try VideoFixtures.makeLong(ffmpeg: ffmpeg, in: directory)

        let model = AppModel()
        model.settings = EncodeSettings(resolution: .original, quality: .high)
        model.add(urls: [input])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        model.convert()
        try await waitUntil("encoding to start") { isConverting(model.items.first?.state) }
        model.cancel()
        try await waitUntil("the cancel to land") { !model.isConverting }

        #expect(model.items.first?.state == .cancelled)
        let output = directory.appending(path: model.settings.outputFileName(for: input))
        // Give a still-exiting ffmpeg every chance to put the file back.
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: output.path), "partial video came back")
    }
}
