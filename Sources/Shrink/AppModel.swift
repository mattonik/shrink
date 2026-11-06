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
        // Duplicates within one batch too: Open With can deliver a file twice,
        // and a second row for it would never be read.
        var seen = Set(items.map(\.url.standardizedFileURL))
        let accepted = urls
            .map(\.standardizedFileURL)
            .filter { (isVideoFile($0) || isPDFFile($0)) && seen.insert($0).inserted }
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
        // Without this, a Mac on battery idles to sleep halfway through a long
        // batch and the conversion just stops until someone wakes it.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "Converting files")
        conversionTask = Task {
            defer {
                ProcessInfo.processInfo.endActivity(activity)
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
                let folder = item.url.deletingLastPathComponent()
                switch item.source {
                case .video(let info):
                    guard let tools else { continue }
                    let output = folder.appending(path: videoSettings.outputFileName(for: item.url))
                    await run(id, Transcoder(tools: tools).transcode(
                        input: item.url, output: output, settings: videoSettings, info: info))
                case .pdf:
                    guard let ghostscript else { continue }
                    let output = folder.appending(path: pdfQuality.outputFileName(for: item.url))
                    await run(id, PDFCompressor(ghostscript: ghostscript).compress(
                        input: item.url, output: output, quality: pdfQuality))
                case nil:
                    break
                }
            }
        }
    }

    func cancel() {
        conversionTask?.cancel()
    }

    /// Cancels the run and returns once it has wound down, so quitting can
    /// wait for the tools to be stopped.
    func cancelAndWait() async {
        guard let task = conversionTask else { return }
        task.cancel()
        await task.value
    }

    /// Runs one conversion and records how it ended.
    ///
    /// No cleanup on cancel or failure, on purpose: ffmpeg and Ghostscript
    /// write into a scratch folder and only a finished result reaches the
    /// output path, so whatever is at that path then was there before and
    /// belongs to the user.
    private func run(_ id: UUID, _ events: AsyncThrowingStream<ConversionEvent, Error>) async {
        update(id) { $0.state = .converting(0) }
        do {
            var outcome: ConversionOutcome?
            for try await event in events {
                switch event {
                case .progress(let fraction): update(id) { $0.state = .converting(fraction) }
                case .finished(let result): outcome = result
                }
            }
            // A cancelled stream can end without throwing, so confirm before
            // reporting success — otherwise a cancelled file shows as done.
            try Task.checkCancellation()

            switch outcome {
            case .compressed(let output, let byteCount, let warning):
                update(id) {
                    $0.state = .done(output: output, byteCount: byteCount)
                    $0.warning = warning
                }
            case .keptOriginal(let reason):
                update(id) { $0.state = .skipped(reason) }
            case nil:
                update(id) { $0.state = .failed("The conversion stopped without a result") }
            }
        } catch is CancellationError {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
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
