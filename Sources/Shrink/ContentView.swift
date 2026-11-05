import ShrinkCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.hasAnyTool {
                mainLayout
            } else {
                MissingToolsView(model: model)
            }
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            fileArea
            Divider()
            SettingsPanel(model: model)
                .disabled(model.isConverting)
            Divider()
            bottomBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var fileArea: some View {
        ZStack {
            if model.items.isEmpty {
                EmptyStateView()
            } else {
                List {
                    ForEach(model.items) { item in
                        ItemRow(item: item, model: model)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Add Files…") { model.chooseFiles() }
                .disabled(model.isConverting)

            if model.hasFinishedItems && !model.isConverting {
                Button("Clear Finished") { model.clearFinished() }
            }

            Spacer()

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if model.isConverting {
                Button("Cancel") { model.cancel() }
            } else {
                Button("Shrink") { model.convert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConvert)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var statusText: String {
        if model.isConverting, let position = model.runPosition {
            return "Converting \(position.index) of \(position.total)…"
        }
        let totals = model.items.reduce(into: (source: Int64(0), output: Int64(0))) { totals, item in
            if case .done(_, let byteCount) = item.state, let source = item.sourceByteCount {
                totals.source += source
                totals.output += byteCount
            }
        }
        if let percent = savingsPercent(source: totals.source, output: totals.output) {
            return "Saved \(formatBytes(totals.source - totals.output)) · \(percent)% smaller"
        }
        let pending = model.items.filter { $0.isPending && $0.source != nil }.count
        return pending > 0 ? "\(pending) file\(pending == 1 ? "" : "s") ready" : ""
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop videos or PDFs here")
                .font(.title3)
            Text("MP4, MOV, WebM, MKV and PDF")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ItemRow: View {
    let item: AppModel.Item
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .pdf ? "doc.richtext" : "film")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }

            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .skipped(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .converting(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
        case .done where item.warning != nil:
            Label(item.warning ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        default:
            Text(sourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var sourceSummary: String {
        switch item.source {
        case nil:
            return "Reading…"
        case .video(let info):
            var parts = [
                "\(info.displaySize.width)×\(info.displaySize.height)",
                formatDuration(info.durationSeconds),
                formatBytes(info.byteCount),
            ]
            if !info.hasAudio { parts.append("no sound") }
            return parts.joined(separator: " · ")
        case .pdf(let info):
            let pages = "\(info.pageCount) page\(info.pageCount == 1 ? "" : "s")"
            return "\(pages) · \(formatBytes(info.byteCount))"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .ready:
            Button {
                model.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .disabled(model.isConverting)

        case .converting(let fraction):
            Text("\(Int(fraction * 100))%")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

        case .done(let output, let byteCount):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(byteCount))
                        .font(.callout)
                        .monospacedDigit()
                    if let source = item.sourceByteCount,
                        let percent = savingsPercent(source: source, output: byteCount)
                    {
                        Text("−\(percent)%")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    }
                }
                Button {
                    model.reveal(output)
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }

        case .skipped:
            Text("Kept original")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

        case .cancelled:
            Text("Cancelled")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsPanel: View {
    @Bindable var model: AppModel

    /// Section labels only earn their space when both kinds are on screen.
    private var showsLabels: Bool { model.hasVideos && model.hasPDFs }
    private var showsVideo: Bool { model.hasVideos || !model.hasPDFs }

    /// One grid for both sections, so the picker labels right-align and the
    /// pickers share a left edge however long each label is.
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if showsVideo {
                GridRow {
                    if showsLabels { SectionLabel(title: "Video", systemImage: "film") }
                    Text("Resolution").gridColumnAlignment(.trailing)
                    Picker("Resolution", selection: $model.settings.resolution) {
                        ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170, alignment: .leading)
                    Toggle("Keep sound", isOn: $model.settings.keepAudio)
                        .padding(.leading, 12)
                }
                GridRow {
                    if showsLabels { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    Text("Quality")
                    Picker("Quality", selection: $model.settings.quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170, alignment: .leading)
                    Toggle("HEVC (smaller files)", isOn: $model.settings.useHEVC)
                        .help("H.265: roughly 30–50% smaller, but older players and some Windows PCs can't play it")
                        .padding(.leading, 12)
                }
            }
            if showsLabels {
                Divider().gridCellColumns(4).padding(.vertical, 2)
            }
            if model.hasPDFs {
                GridRow {
                    if showsLabels { SectionLabel(title: "PDF", systemImage: "doc.richtext") }
                    Text("Images")
                    Picker("Images", selection: $model.pdfQuality) {
                        ForEach(PDFQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170, alignment: .leading)
                    Text("Signed, password-protected and form PDFs are left untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct SectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .leading)
    }
}

private struct MissingToolsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("ffmpeg and Ghostscript not found")
                .font(.title3)
            Text("Shrink uses ffmpeg for videos and Ghostscript for PDFs. Install them, then check again:")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("brew install ffmpeg ghostscript")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            Button("Check Again") { model.recheckTools() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
