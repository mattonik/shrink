import AppKit
import Foundation
import Observation
import ShrinkCore

@MainActor
@Observable
final class AppModel {
    struct Item: Identifiable {
        enum State: Equatable {
            case ready
            case converting(Double)
            case done(output: URL, byteCount: Int64)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let url: URL
        var info: VideoInfo?
        var state: State = .ready

        var isPending: Bool {
            switch state {
            case .ready: true
            case .converting, .done, .failed, .cancelled: false
            }
        }

        var isFinished: Bool {
            switch state {
            case .done, .failed, .cancelled: true
            case .ready, .converting: false
            }
        }
    }

    var items: [Item] = []
    var settings = EncodeSettings()
    var tools: ToolPaths? = ToolPaths.locate()
    var isConverting = false

    private var conversionTask: Task<Void, Never>?

    var canConvert: Bool {
        tools != nil && !isConverting && items.contains { $0.isPending && $0.info != nil }
    }

    func recheckTools() {
        tools = ToolPaths.locate()
    }

    /// Adds dropped or chosen files, skipping non-video and duplicate entries,
    /// then fills in each file's resolution and duration from ffprobe.
    func add(urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        let accepted = urls
            .map(\.standardizedFileURL)
            .filter { isVideoFile($0) && !existing.contains($0) }
        guard !accepted.isEmpty else { return }

        items.append(contentsOf: accepted.map { Item(url: $0) })
        for url in accepted {
            Task { await probe(url) }
        }
    }

    private func probe(_ url: URL) async {
        guard let tools else { return }
        do {
            let info = try await Transcoder(tools: tools).probe(url)
            update(url) { $0.info = info }
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
        guard let tools, !isConverting else { return }
        let pending = items.filter { $0.isPending && $0.info != nil }.map(\.id)
        guard !pending.isEmpty else { return }

        isConverting = true
        conversionTask = Task {
            defer {
                isConverting = false
                conversionTask = nil
            }
            for id in pending {
                if Task.isCancelled {
                    update(id) { if $0.isPending { $0.state = .cancelled } }
                    continue
                }
                await convertItem(id, using: tools)
            }
        }
    }

    func cancel() {
        conversionTask?.cancel()
    }

    private func convertItem(_ id: UUID, using tools: ToolPaths) async {
        guard let item = items.first(where: { $0.id == id }), let info = item.info else { return }
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
            discardPartialFile(at: output)
            update(id) { $0.state = .cancelled }
        } catch {
            discardPartialFile(at: output)
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// ffmpeg leaves a truncated MP4 behind when it is killed or errors out;
    /// removing it keeps a broken file from looking like a real result.
    private func discardPartialFile(at url: URL) {
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
        panel.message = "Choose videos to shrink"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
