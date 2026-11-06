import AppKit
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import Shrink
import ShrinkCore
import ShrinkTestSupport

/// Drives the app's real conversion queue — the code behind the Shrink and
/// Cancel buttons — against real files, without opening a window.
///
/// One test at a time: the sleep assertion a run holds belongs to the whole
/// test process, so a parallel run would hide whether this one released it.
@MainActor
@Suite(
    .serialized,
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

    /// ffmpeg writes into a scratch folder, so a cancelled video never
    /// reaches its output path, even though after SIGTERM ffmpeg still spends
    /// ~0.25 s on its +faststart pass. The check below waits well past that.
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

    /// Converting the same file with the same settings again names the same
    /// output. ffmpeg used to overwrite it from the first frame, and a cancel
    /// or failure then deleted it, so the earlier good result was lost.
    @Test func aCancelledVideoLeavesAFileAlreadyAtItsOutputPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try VideoFixtures.makeLong(ffmpeg: ffmpeg, in: directory)
        let model = AppModel()
        model.settings = EncodeSettings(resolution: .original, quality: .high)
        let existing = directory.appending(path: model.settings.outputFileName(for: input))
        try Data("last week's result".utf8).write(to: existing)

        model.add(urls: [input])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        model.convert()
        try await waitUntil("encoding to start") { isConverting(model.items.first?.state) }
        model.cancel()
        try await waitUntil("the cancel to land") { !model.isConverting }

        #expect(model.items.first?.state == .cancelled)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "last week's result")
    }

    @Test func aFailedVideoLeavesAFileAlreadyAtItsOutputPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try VideoFixtures.make(ffmpeg: ffmpeg, in: directory, name: "demo.mp4")
        let model = AppModel()
        let existing = directory.appending(path: model.settings.outputFileName(for: input))
        try Data("last week's result".utf8).write(to: existing)

        model.add(urls: [input])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        try FileManager.default.removeItem(at: input)  // moved away before the run starts
        model.convert()
        try await waitUntil("the run to finish") { !model.isConverting }

        guard case .failed = model.items.first?.state else {
            Issue.record("expected the conversion to fail, got \(String(describing: model.items.first?.state))")
            return
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "last week's result")
    }

    /// The second row used to stay on "Reading…" for good: the probe result
    /// is filed by URL and only ever reached the first.
    @Test func aFileOpenedTwiceAtOnceIsListedOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try VideoFixtures.make(ffmpeg: ffmpeg, in: directory, name: "demo.mp4")

        let model = AppModel()
        model.add(urls: [video, video])

        #expect(model.items.count == 1)
    }

    /// On battery a Mac idles to sleep, which used to stop a long batch until
    /// someone woke it.
    @Test func keepsTheMacAwakeOnlyWhileConverting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try VideoFixtures.makeLong(ffmpeg: ffmpeg, in: directory)
        let model = AppModel()
        model.add(urls: [input])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        #expect(!holdsIdleSleepAssertion())

        model.convert()
        try await waitUntil("encoding to start") { isConverting(model.items.first?.state) }
        #expect(holdsIdleSleepAssertion(), "nothing stops the Mac sleeping mid-run")

        await model.cancelAndWait()
        #expect(!holdsIdleSleepAssertion(), "the Mac is kept awake after the run")
    }

    func holdsIdleSleepAssertion() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
            let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        return (all[NSNumber(value: getpid())] ?? []).contains {
            $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep
        }
    }

    /// Closing the only window, or Quit, used to exit while ffmpeg carried on
    /// encoding by itself, with the rest of the queue silently dropped.
    @Test func quittingMidRunAsksThenStopsTheConversionBeforeExiting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try VideoFixtures.makeLong(ffmpeg: ffmpeg, in: directory)
        let delegate = AppDelegate()
        let model = delegate.model
        var asked = 0
        var reply: Bool?
        var stateAtReply: (converting: Bool, item: AppModel.Item.State?)?
        delegate.confirmQuit = { asked += 1; return true }
        delegate.replyToTerminate = {
            reply = $0
            stateAtReply = (model.isConverting, model.items.first?.state)
        }

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "idle quits at once")
        #expect(asked == 0, "nothing to ask about while idle")

        model.add(urls: [input])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        model.convert()
        try await waitUntil("encoding to start") { isConverting(model.items.first?.state) }

        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                "closing the window mid-run must not quit")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(asked == 1)
        try await waitUntil("the quit to be allowed") { reply != nil }

        #expect(reply == true)
        #expect(stateAtReply?.converting == false, "quit was allowed before the run had stopped")
        #expect(stateAtReply?.item == .cancelled)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func choosingToKeepConvertingCancelsTheQuit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try VideoFixtures.makeLong(ffmpeg: ffmpeg, in: directory)
        let delegate = AppDelegate()
        let model = delegate.model
        delegate.confirmQuit = { false }
        delegate.replyToTerminate = { _ in Issue.record("must not answer a cancelled quit") }

        model.add(urls: [input])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        model.convert()
        try await waitUntil("encoding to start") { isConverting(model.items.first?.state) }

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isConverting, "the run was stopped anyway")
        await model.cancelAndWait()
    }

    /// The row says the original was kept, the way it does for a PDF.
    @Test func aVideoThatWouldNotShrinkKeepsTheOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compact = try VideoFixtures.makeCompact(ffmpeg: ffmpeg, in: directory)
        let model = AppModel()
        model.settings = EncodeSettings(resolution: .original)

        model.add(urls: [compact])
        try await waitUntil("the video to be read") { model.items.first?.source != nil }
        model.convert()
        try await waitUntil("the run to finish") { !model.isConverting }

        guard case .skipped(let reason) = model.items.first?.state else {
            Issue.record("expected the original to be kept, got \(String(describing: model.items.first?.state))")
            return
        }
        #expect(reason.contains("kept the original"))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: model.settings.outputFileName(for: compact)).path))
    }
}
