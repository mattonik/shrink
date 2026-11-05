import AppKit
import Foundation
import Observation
import ShrinkCore

@MainActor
@Observable
final class AppModel {
    struct Item: Identifiable {
        enum Kind {
            case video
            case pdf
        }

        enum Source: Equatable {
            case video(VideoInfo)
            case pdf(PDFInfo)
        }

        enum State: Equatable {
            case ready
            case converting(Double)
            case done(output: URL, byteCount: Int64)
            /// Deliberately left alone; the original file is the result.
            case skipped(String)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let url: URL
        let kind: Kind
        var source: Source?
        var state: State = .ready
        /// Set when a conversion succeeded but needs a second look.
        var warning: String?

        var sourceByteCount: Int64? {
            switch source {
            case .video(let info): info.byteCount
            case .pdf(let info): info.byteCount
            case nil: nil
            }
        }

        var isPending: Bool {
            switch state {
            case .ready: true
            case .converting, .done, .skipped, .failed, .cancelled: false
            }
        }

        var isFinished: Bool {
            switch state {
            case .done, .skipped, .failed, .cancelled: true
            case .ready, .converting: false
            }
        }
    }

    var items: [Item] = []
    var settings = EncodeSettings()
    var pdfQuality: PDFQuality = .ebook
    var tools: ToolPaths? = ToolPaths.locate()
    var ghostscript: URL? = ToolPaths.locateGhostscript()
    var isConverting = false
    private(set) var runPosition: (index: Int, total: Int)?

    private var conversionTask: Task<Void, Never>?

    var hasAnyTool: Bool { tools != nil || ghostscript != nil }
    var hasVideos: Bool { items.contains { $0.kind == .video } }
    var hasPDFs: Bool { items.contains { $0.kind == .pdf } }

    var canConvert: Bool {
        !isConverting && items.contains { $0.isPending && $0.source != nil }
    }

    func recheckTools() {
        tools = ToolPaths.locate()
        ghostscript = ToolPaths.locateGhostscript()
    }

    /// Adds dropped or chosen files, skipping unsupported and duplicate
    /// entries, then reads each one's details in the background.
    func add(urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        let accepted = urls
            .map(\.standardizedFileURL)
            .filter { (isVideoFile($0) || isPDFFile($0)) && !existing.contains($0) }
        guard !accepted.isEmpty else { return }

        for url in accepted {
            let kind: Item.Kind = isPDFFile(url) ? .pdf : .video
            var item = Item(url: url, kind: kind)
            if let missing = missingToolMessage(for: kind) {
                item.state = .failed(missing)
            }
            items.append(item)
            if item.isPending {
                Task { await probe(url, kind: kind) }
            }
        }
    }

    private func missingToolMessage(for kind: Item.Kind) -> String? {
        switch kind {
        case .video where tools == nil: "Videos need ffmpeg: brew install ffmpeg"
        case .pdf where ghostscript == nil: "PDFs need Ghostscript: brew install ghostscript"
        default: nil
        }
    }

    private func probe(_ url: URL, kind: Item.Kind) async {
        do {
            switch kind {
            case .video:
                guard let tools else { return }
                let info = try await Transcoder(tools: tools).probe(url)
                update(url) { $0.source = .video(info) }
            case .pdf:
                // PDFKit parsing and the signature scan read the whole file,
                // so keep them off the main thread for large documents.
                let info = try await Task.detached { try PDFInspector.inspect(url) }.value
                update(url) { item in
                    item.source = .pdf(info)
                    if let reason = info.skipReason { item.state = .skipped(reason) }
                }
            }
        } catch {
            update(url) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
    }

    var hasFinishedItems: Bool {
        items.contains(where: \.isFinished)
    }

    func clearFinished() {
        items.removeAll(where: \.isFinished)
    }

    func convert() {
        guard !isConverting else { return }
        let pending = items.filter { $0.isPending && $0.source != nil }.map(\.id)
        guard !pending.isEmpty else { return }

        // Settings are fixed for the whole run; the panel is disabled anyway.
        let videoSettings = settings
        let pdfQuality = pdfQuality
        isConverting = true
        conversionTask = Task {
            defer {
                isConverting = false
                runPosition = nil
                conversionTask = nil
            }
            for (index, id) in pending.enumerated() {
                if Task.isCancelled {
                    update(id) { if $0.isPending { $0.state = .cancelled } }
                    continue
                }
                runPosition = (index + 1, pending.count)
                guard let item = items.first(where: { $0.id == id }) else { continue }
                switch item.source {
                case .video(let info):
                    if let tools { await convertVideo(item, info: info, settings: videoSettings, tools: tools) }
                case .pdf:
                    if let ghostscript { await compressPDF(item, quality: pdfQuality, ghostscript: ghostscript) }
                case nil:
                    break
                }
            }
        }
    }

    func cancel() {
        conversionTask?.cancel()
    }

    private func convertVideo(
        _ item: Item, info: VideoInfo, settings: EncodeSettings, tools: ToolPaths
    ) async {
        let id = item.id
        let output = item.url
            .deletingLastPathComponent()
            .appending(path: settings.outputFileName(for: item.url))

        update(id) { $0.state = .converting(0) }
        do {
            let stream = Transcoder(tools: tools).transcode(
                input: item.url,
                output: output,
                settings: settings,
                info: info
            )
            for try await fraction in stream {
                update(id) { $0.state = .converting(fraction) }
            }
            // A cancelled stream can end without throwing, so confirm before
            // reporting success — otherwise a half-written file looks finished.
            try Task.checkCancellation()

            let byteCount =
                (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init)
                ?? 0
            update(id) { $0.state = .done(output: output, byteCount: byteCount) }
        } catch is CancellationError {
            discardPartialVideo(at: output)
            update(id) { $0.state = .cancelled }
        } catch {
            discardPartialVideo(at: output)
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// No cleanup here on purpose: the compressor only writes to `output` once
    /// a result is kept, so on cancel or failure whatever is at that path was
    /// there before and belongs to the user.
    private func compressPDF(_ item: Item, quality: PDFQuality, ghostscript: URL) async {
        let id = item.id
        let output = item.url
            .deletingLastPathComponent()
            .appending(path: quality.outputFileName(for: item.url))

        update(id) { $0.state = .converting(0) }
        do {
            var outcome: PDFOutcome?
            let stream = PDFCompressor(ghostscript: ghostscript)
                .compress(input: item.url, output: output, quality: quality)
            for try await event in stream {
                switch event {
                case .progress(let fraction): update(id) { $0.state = .converting(fraction) }
                case .finished(let result): outcome = result
                }
            }
            try Task.checkCancellation()

            switch outcome {
            case .compressed(let url, let byteCount, let warning):
                update(id) {
                    $0.state = .done(output: url, byteCount: byteCount)
                    $0.warning = warning
                }
            case .keptOriginal(let reason):
                update(id) { $0.state = .skipped(reason) }
            case nil:
                update(id) { $0.state = .failed("Ghostscript stopped without a result") }
            }
        } catch is CancellationError {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// ffmpeg writes straight to its output and leaves a truncated MP4 behind
    /// when killed or failing; removing it keeps a broken file from looking
    /// like a real result.
    private func discardPartialVideo(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func update(_ id: UUID, _ mutate: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    private func update(_ url: URL, _ mutate: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        mutate(&items[index])
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose videos or PDFs to shrink"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
