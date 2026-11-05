import ShrinkCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.tools == nil {
                MissingToolsView(model: model)
            } else {
                mainLayout
            }
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            fileArea
            Divider()
            SettingsPanel(settings: $model.settings)
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
            Button("Add Videos…") { model.chooseFiles() }
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
        let pending = model.items.filter(\.isPending).count
        if model.isConverting {
            let done = model.items.filter { if case .done = $0.state { true } else { false } }.count
            return "Converting \(done + 1) of \(done + 1 + pending)…"
        }
        let totalSaved = model.items.reduce(into: (source: Int64(0), output: Int64(0))) { totals, item in
            if case .done(_, let byteCount) = item.state, let info = item.info {
                totals.source += info.byteCount
                totals.output += byteCount
            }
        }
        if let percent = savingsPercent(source: totalSaved.source, output: totalSaved.output) {
            return "Saved \(formatBytes(totalSaved.source - totalSaved.output)) · \(percent)% smaller"
        }
        return pending > 0 ? "\(pending) video\(pending == 1 ? "" : "s") ready" : ""
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop videos here")
                .font(.title3)
            Text("MP4, MOV, WebM, MKV and friends")
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
        case .converting(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
        default:
            Text(sourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var sourceSummary: String {
        guard let info = item.info else { return "Reading…" }
        var parts = [
            "\(info.size.width)×\(info.size.height)",
            formatDuration(info.durationSeconds),
            formatBytes(info.byteCount),
        ]
        if !info.hasAudio { parts.append("no sound") }
        return parts.joined(separator: " · ")
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
                    if let info = item.info,
                        let percent = savingsPercent(source: info.byteCount, output: byteCount)
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
    @Binding var settings: EncodeSettings

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
            }
            .frame(maxWidth: 260)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep sound", isOn: $settings.keepAudio)
                Toggle("HEVC (smaller, needs a recent player)", isOn: $settings.useHEVC)
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct MissingToolsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("ffmpeg not found")
                .font(.title3)
            Text("Shrink uses ffmpeg to convert videos. Install it, then check again:")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("brew install ffmpeg")
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
