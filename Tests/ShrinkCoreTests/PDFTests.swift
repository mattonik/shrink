import Foundation
import Testing

@testable import ShrinkCore

@Test func buildsGhostscriptArgumentsForAPreset() {
    let args = PDFCompressor.arguments(
        input: URL(filePath: "/docs/report.pdf"),
        output: URL(filePath: "/docs/report-ebook.pdf"),
        quality: .ebook
    )

    #expect(args.contains("-sDEVICE=pdfwrite"))
    #expect(args.contains("-dPDFSETTINGS=/ebook"))
    #expect(args.contains("-dSAFER"))
    // Without this, pdfwrite rotates pages to match their text direction.
    #expect(args.contains("-dAutoRotatePages=/None"))
    #expect(args.contains("-sOutputFile=/docs/report-ebook.pdf"))
    #expect(args.last == "/docs/report.pdf")
}

@Test func doublesPercentSignsInTheOutputPath() {
    // Ghostscript reads a bare % in the output path as a page-number template.
    #expect(PDFCompressor.escapedOutputPath("/docs/Growth 25%-ebook.pdf") == "/docs/Growth 25%%-ebook.pdf")
    #expect(PDFCompressor.escapedOutputPath("/docs/plain.pdf") == "/docs/plain.pdf")

    let args = PDFCompressor.arguments(
        input: URL(filePath: "/docs/100%.pdf"),
        output: URL(filePath: "/docs/100%-screen.pdf"),
        quality: .screen
    )
    #expect(args.contains("-sOutputFile=/docs/100%%-screen.pdf"))
    // Input paths are not templated, so they stay as they are.
    #expect(args.last == "/docs/100%.pdf")
}

@Test func namesPDFOutputAfterThePreset() {
    let input = URL(filePath: "/docs/Annual Report.PDF")
    #expect(PDFQuality.screen.outputFileName(for: input) == "Annual Report-screen.pdf")
    #expect(PDFQuality.ebook.outputFileName(for: input) == "Annual Report-ebook.pdf")
    #expect(PDFQuality.printer.outputFileName(for: input) == "Annual Report-print.pdf")
}

@Test func readsPageProgressFromGhostscriptOutput() {
    #expect(parseGhostscriptPage(line: "Page 12") == 12)
    #expect(parseGhostscriptPage(line: "Page 1") == 1)
    #expect(parseGhostscriptPage(line: "Processing pages 1 through 18.") == nil)
    #expect(parseGhostscriptPage(line: "GPL Ghostscript 10.08.0 (2026-09-08)") == nil)
    #expect(parseGhostscriptPage(line: "Page") == nil)
}

@Test func warnsWhenGhostscriptReportsRepairs() throws {
    // Verbatim stderr from Ghostscript 10.08 on a damaged file it exited 0 for.
    let repaired = """

        The following errors were encountered at least once while processing this file:
        \tno startxref token found
        \txref table was repaired

        """
    let warning = try #require(PDFCompressor.repairWarning(fromStandardError: repaired))
    #expect(warning.contains("repair"))
    #expect(warning.contains("no startxref token found"))

    #expect(PDFCompressor.repairWarning(fromStandardError: "") == nil)
    #expect(PDFCompressor.repairWarning(fromStandardError: "Warning: font substituted\n") == nil)
}

@Test func keepsOnlyResultsThatSaveAtLeastTenPercent() {
    #expect(Savings.worthKeeping(outputBytes: 900, originalBytes: 1000))
    #expect(!Savings.worthKeeping(outputBytes: 901, originalBytes: 1000))
    #expect(!Savings.worthKeeping(outputBytes: 1200, originalBytes: 1000))
    #expect(!Savings.worthKeeping(outputBytes: 0, originalBytes: 1000))
}

@Test func skipsDocumentsCompressionWouldDamage() {
    #expect(PDFInfo(pageCount: 1, byteCount: 1).skipReason == nil)
    #expect(PDFInfo(pageCount: 1, byteCount: 1, hasFormFields: true).skipReason?.contains("form") == true)
    #expect(PDFInfo(pageCount: 1, byteCount: 1, isEncrypted: true, hasFormFields: true).skipReason?.contains("Password") == true)
    // A signature is the most important thing to protect, so it wins.
    #expect(
        PDFInfo(pageCount: 1, byteCount: 1, isEncrypted: true, isSigned: true, hasFormFields: true)
            .skipReason?.contains("signed") == true)
}

@Test func recognisesPDFFilesByExtension() {
    #expect(isPDFFile(URL(filePath: "/d/a.pdf")))
    #expect(isPDFFile(URL(filePath: "/d/a.PDF")))
    #expect(!isPDFFile(URL(filePath: "/d/a.mp4")))
    #expect(!isVideoFile(URL(filePath: "/d/a.pdf")))
}

@Test(.enabled(if: ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"].contains {
    FileManager.default.isExecutableFile(atPath: $0)
}))
func locatesGhostscriptWithoutPath() {
    #expect(ToolPaths.locateGhostscript(environment: [:]) != nil)
}
