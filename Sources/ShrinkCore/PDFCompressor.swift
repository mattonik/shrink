import Foundation
import PDFKit

public enum PDFQuality: String, CaseIterable, Identifiable, Sendable {
    case screen
    case ebook
    case printer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .screen: "Screen · 72 dpi"
        case .ebook: "Ebook · 150 dpi"
        case .printer: "Print · 300 dpi"
        }
    }

    /// Ghostscript's `-dPDFSETTINGS` preset; the dpi in the label is the
    /// resolution images are downsampled to.
    var ghostscriptPreset: String {
        switch self {
        case .screen: "/screen"
        case .ebook: "/ebook"
        case .printer: "/printer"
        }
    }

    var suffix: String {
        switch self {
        case .screen: "screen"
        case .ebook: "ebook"
        case .printer: "print"
        }
    }

    public func outputFileName(for input: URL) -> String {
        "\(input.deletingPathExtension().lastPathComponent)-\(suffix).pdf"
    }
}

public struct PDFInfo: Equatable, Sendable {
    public var pageCount: Int
    public var byteCount: Int64
    public var isEncrypted: Bool
    public var isSigned: Bool
    public var hasFormFields: Bool

    public init(
        pageCount: Int,
        byteCount: Int64,
        isEncrypted: Bool = false,
        isSigned: Bool = false,
        hasFormFields: Bool = false
    ) {
        self.pageCount = pageCount
        self.byteCount = byteCount
        self.isEncrypted = isEncrypted
        self.isSigned = isSigned
        self.hasFormFields = hasFormFields
    }

    /// Why this PDF must not be rewritten, or nil when it is safe to compress.
    /// Each of these is something Ghostscript would silently destroy: any
    /// rewrite invalidates a signature, it strips encryption from the copy, and
    /// it drops fillable form fields outright.
    public var skipReason: String? {
        if isSigned { return "Digitally signed — left untouched so the signature stays valid" }
        if isEncrypted { return "Password-protected — left untouched" }
        if hasFormFields { return "Has fillable form fields, which compressing would remove" }
        return nil
    }
}

public enum PDFOutcome: Equatable, Sendable {
    case compressed(output: URL, byteCount: Int64, warning: String?)
    /// Nothing was written; the reason says why the original is the answer.
    case keptOriginal(reason: String)
}

public enum PDFEvent: Equatable, Sendable {
    case progress(Double)
    case finished(PDFOutcome)
}

public enum PDFInspector {
    public static func inspect(_ url: URL) throws -> PDFInfo {
        let byteCount =
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        guard let document = PDFDocument(url: url) else {
            throw TranscodeError.failed("\(url.lastPathComponent) is not a readable PDF")
        }

        // A locked document hides its pages, so forms can't be checked — but
        // it is skipped as password-protected before that matters.
        let hasFormFields =
            !document.isLocked
            && (0..<document.pageCount).contains { index in
                document.page(at: index)?.annotations.contains { $0.type == "Widget" } ?? false
            }

        return PDFInfo(
            pageCount: document.pageCount,
            byteCount: byteCount,
            isEncrypted: document.isEncrypted,
            isSigned: containsSignature(url),
            hasFormFields: hasFormFields
        )
    }

    /// A signed PDF always carries a `/ByteRange` in its signature dictionary,
    /// stored uncompressed because the signature covers exact byte offsets — so
    /// a raw scan finds it even when the rest of the file is compressed.
    static func containsSignature(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return data.range(of: Data("/ByteRange".utf8)) != nil
    }
}

/// "Page 12" from Ghostscript's stdout, or nil for any other line.
public func parseGhostscriptPage(line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("Page ") else { return nil }
    return Int(trimmed.dropFirst(5))
}

public struct PDFCompressor: Sendable {
    public let ghostscript: URL

    /// Results saving less than this are thrown away. A Word export typically
    /// shrinks 1–2%, which is not worth a rewritten document that may have lost
    /// its accessibility tagging along the way.
    public static let minimumSavings = 0.10

    public init(ghostscript: URL) {
        self.ghostscript = ghostscript
    }

    public static func arguments(input: URL, output: URL, quality: PDFQuality) -> [String] {
        [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            "-dPDFSETTINGS=\(quality.ghostscriptPreset)",
            // pdfwrite otherwise turns pages to match their dominant text
            // direction, which can flip a landscape table onto its side.
            "-dAutoRotatePages=/None",
            "-dNOPAUSE", "-dBATCH", "-dSAFER",
            "-sOutputFile=\(escapedOutputPath(output.path))",
            input.path,
        ]
    }

    /// Ghostscript reads `%d` in an output path as a page-number template and
    /// writes one file per page, so a literal `%` has to be doubled.
    static func escapedOutputPath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%%")
    }

    /// Ghostscript exits 0 even after repairing a damaged file, reporting the
    /// damage only on stderr. Returns a warning for the user when it did.
    static func repairWarning(fromStandardError text: String) -> String? {
        guard text.contains("errors were encountered") || text.contains("**** Error")
            || text.contains("ERROR:")
        else { return nil }

        let detail = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("The following") && !$0.hasPrefix("****") }
        return "Ghostscript had to repair this PDF (\(detail ?? "damaged file")) — check the result"
    }

    static func shouldKeep(outputBytes: Int64, originalBytes: Int64) -> Bool {
        outputBytes > 0 && Double(outputBytes) <= Double(originalBytes) * (1 - minimumSavings)
    }

    /// Compresses `input` into `output`, streaming page progress.
    ///
    /// Ghostscript writes to a temporary file first, and the result only
    /// replaces `output` once it has proved worth keeping — so a rejected,
    /// failed or cancelled run never touches a file already at that path.
    public func compress(
        input: URL,
        output: URL,
        quality: PDFQuality
    ) -> AsyncThrowingStream<PDFEvent, Error> {
        let ghostscript = ghostscript

        return AsyncThrowingStream { continuation in
            let task = Task {
                let fileManager = FileManager.default
                var scratch: URL?
                defer { if let scratch { try? fileManager.removeItem(at: scratch) } }

                do {
                    let info = try PDFInspector.inspect(input)
                    if let reason = info.skipReason {
                        continuation.yield(.finished(.keptOriginal(reason: reason)))
                        continuation.finish()
                        return
                    }

                    // Same volume as the destination where possible, so the
                    // final move is a rename rather than a copy.
                    let directory =
                        (try? fileManager.url(
                            for: .itemReplacementDirectory, in: .userDomainMask,
                            appropriateFor: output, create: true))
                        ?? fileManager.temporaryDirectory.appending(path: "shrink-\(UUID().uuidString)")
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    scratch = directory
                    let temporary = directory.appending(path: "compressed.pdf")

                    let pages = max(1, info.pageCount)
                    let result = try await runStreamingLines(
                        executable: ghostscript,
                        arguments: Self.arguments(input: input, output: temporary, quality: quality)
                    ) { line in
                        if let page = parseGhostscriptPage(line: line) {
                            continuation.yield(.progress(min(1, Double(page) / Double(pages))))
                        }
                    }
                    guard result.status == 0 else {
                        throw TranscodeError.failed(result.failureMessage(tool: "Ghostscript"))
                    }

                    let outputBytes =
                        (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap(Int64.init) ?? 0
                    guard Self.shouldKeep(outputBytes: outputBytes, originalBytes: info.byteCount)
                    else {
                        let saved = savingsPercent(source: info.byteCount, output: outputBytes)
                        continuation.yield(
                            .finished(
                                .keptOriginal(
                                    reason: saved.map { "Only \($0)% smaller — kept the original" }
                                        ?? "Already compact — kept the original")))
                        continuation.finish()
                        return
                    }

                    if fileManager.fileExists(atPath: output.path) {
                        _ = try fileManager.replaceItemAt(output, withItemAt: temporary)
                    } else {
                        try fileManager.moveItem(at: temporary, to: output)
                    }
                    continuation.yield(.progress(1))
                    continuation.yield(
                        .finished(
                            .compressed(
                                output: output,
                                byteCount: outputBytes,
                                warning: Self.repairWarning(fromStandardError: result.standardError))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
