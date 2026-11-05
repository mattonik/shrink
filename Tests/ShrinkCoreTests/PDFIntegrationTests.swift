import Foundation
import PDFKit
import Testing

@testable import ShrinkCore
import ShrinkTestSupport

/// Runs real Ghostscript against generated PDFs. The unit tests pin the
/// argument strings; these prove what actually ends up on disk.
@Suite(.enabled(if: ToolPaths.locateGhostscript() != nil, "requires Ghostscript on this machine"))
struct PDFIntegrationTests {
    let compressor = PDFCompressor(ghostscript: ToolPaths.locateGhostscript()!)

    func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "shrink-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func compress(_ input: URL, quality: PDFQuality = .ebook) async throws -> (events: [PDFEvent], output: URL) {
        let output = input.deletingLastPathComponent().appending(path: quality.outputFileName(for: input))
        let compressor = compressor
        let events = try await { () async throws -> [PDFEvent] in
            var seen: [PDFEvent] = []
            for try await event in compressor.compress(input: input, output: output, quality: quality) {
                seen.append(event)
            }
            return seen
        }()
        return (events, output)
    }

    func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? -1
    }

    @Test func compressesAnImageHeavyPDF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "scan.pdf")
        try PDFFixtures.imageHeavy(at: input, pages: 3)
        let originalBytes = size(input)
        let originalData = try Data(contentsOf: input)

        let (events, output) = try await compress(input)

        guard case .finished(.compressed(let url, let bytes, let warning)) = events.last else {
            Issue.record("expected a compressed result, got \(String(describing: events.last))")
            return
        }
        #expect(url == output)
        #expect(bytes == size(output))
        #expect(Double(bytes) <= Double(originalBytes) * 0.9)
        #expect(warning == nil)
        #expect(PDFDocument(url: output)?.pageCount == 3)

        let fractions = events.compactMap { if case .progress(let f) = $0 { f } else { nil } }
        #expect(!fractions.isEmpty, "Ghostscript reported no page progress")
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)

        // The original is never modified.
        #expect(try Data(contentsOf: input) == originalData)
    }

    @Test func keepsTheOriginalWhenRecompressingGainsTooLittle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "scan.pdf")
        try PDFFixtures.imageHeavy(at: input)

        // Compressing an already-compressed file again gains next to nothing.
        let (_, firstPass) = try await compress(input, quality: .screen)
        let (events, secondPass) = try await compress(firstPass, quality: .screen)

        guard case .finished(.keptOriginal(let reason)) = events.last else {
            Issue.record("expected the original to be kept, got \(String(describing: events.last))")
            return
        }
        #expect(reason.contains("kept the original"))
        #expect(!FileManager.default.fileExists(atPath: secondPass.path))
    }

    @Test func leavesAnExistingFileAloneWhenTheResultIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "scan.pdf")
        try PDFFixtures.imageHeavy(at: input)
        let (_, compressed) = try await compress(input, quality: .screen)

        // Something already sits where the rejected result would have gone.
        let target = directory.appending(path: PDFQuality.screen.outputFileName(for: compressed))
        try Data("keep me".utf8).write(to: target)

        let (events, _) = try await compress(compressed, quality: .screen)

        guard case .finished(.keptOriginal) = events.last else {
            Issue.record("expected the result to be rejected")
            return
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
    }

    @Test func leavesSignedPDFsUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "contract.pdf")
        try PDFFixtures.signed(at: input)

        #expect(try PDFInspector.inspect(input).isSigned)
        let (events, output) = try await compress(input)

        // A single event and no progress: Ghostscript never ran.
        #expect(events.count == 1)
        guard case .finished(.keptOriginal(let reason)) = events.first else {
            Issue.record("expected the signed PDF to be skipped, got \(events)")
            return
        }
        #expect(reason.contains("signed"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func leavesPasswordProtectedPDFsUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "locked.pdf")
        try PDFFixtures.passwordProtected(at: input)

        let (events, output) = try await compress(input)

        #expect(events.count == 1)
        guard case .finished(.keptOriginal(let reason)) = events.first else {
            Issue.record("expected the locked PDF to be skipped, got \(events)")
            return
        }
        #expect(reason.contains("Password"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func leavesFormPDFsUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "intake-form.pdf")
        try PDFFixtures.withFormField(at: input)

        #expect(try PDFInspector.inspect(input).hasFormFields)
        let (events, output) = try await compress(input)

        #expect(events.count == 1)
        guard case .finished(.keptOriginal(let reason)) = events.first else {
            Issue.record("expected the form PDF to be skipped, got \(events)")
            return
        }
        #expect(reason.contains("form"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// End to end: `%` in both the input and the output name. Ghostscript only
    /// ever writes to a scratch file, so this passes on the temp-file design
    /// alone; the escaping itself (needed if the scratch volume's own path has
    /// a `%`) is pinned by `doublesPercentSignsInTheOutputPath`.
    @Test func handlesPercentSignsInFileNames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "Growth %d 25%.pdf")
        try PDFFixtures.imageHeavy(at: input, pages: 2, pixels: 1200)

        let (events, output) = try await compress(input)

        guard case .finished(.compressed) = events.last else {
            Issue.record("expected a compressed result, got \(String(describing: events.last))")
            return
        }
        #expect(output.lastPathComponent == "Growth %d 25%-ebook.pdf")
        #expect(PDFDocument(url: output)?.pageCount == 2, "both pages in one file, not split per page")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["Growth %d 25%-ebook.pdf", "Growth %d 25%.pdf"])
    }

    @Test func warnsWhenGhostscriptHadToRepairTheFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "damaged.pdf")
        try PDFFixtures.imageHeavy(at: input)
        try PDFFixtures.damageCrossReference(of: input)

        let (events, _) = try await compress(input)

        guard case .finished(.compressed(_, _, let warning)) = events.last else {
            Issue.record("expected a compressed result, got \(String(describing: events.last))")
            return
        }
        #expect(warning?.contains("repair") == true)
    }

    @Test func cancellingStopsGhostscriptAndWritesNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "long.pdf")
        try PDFFixtures.imageHeavy(at: input, pages: 24, pixels: 900)
        let output = directory.appending(path: PDFQuality.ebook.outputFileName(for: input))
        let compressor = compressor

        let progressBeforeCancel = try await { () async throws -> Int in
            var seen = 0
            for try await event in compressor.compress(input: input, output: output, quality: .ebook) {
                if case .progress = event {
                    seen += 1
                    break  // dropping the stream is how the app cancels
                }
            }
            return seen
        }()

        #expect(progressBeforeCancel == 1)
        #expect(await waitUntilNoProcess(matching: directory.lastPathComponent), "Ghostscript still running")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

/// True once no process command line mentions `pattern`, polling up to 2 s —
/// far longer than termination takes, far shorter than the jobs it watches.
func waitUntilNoProcess(matching pattern: String) async -> Bool {
    for _ in 0..<20 {
        let result = try? await runStreamingLines(
            executable: URL(filePath: "/usr/bin/pgrep"), arguments: ["-f", pattern]
        ) { _ in }
        if result?.status == 1 { return true }  // 1 = nothing matched
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}
