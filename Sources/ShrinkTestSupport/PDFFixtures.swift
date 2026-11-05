import CoreGraphics
import Foundation
import PDFKit

/// Builds real PDF files for the integration tests, each standing in for a
/// kind of document Shrink has to treat differently.
public enum PDFFixtures {
    public struct FixtureError: Error {}

    /// Pages that each hold a distinct high-resolution noise image: about
    /// 246 dpi on the page, so every preset downsamples it, and different on
    /// every page so Ghostscript cannot deduplicate its way through the file.
    public static func imageHeavy(at url: URL, pages: Int = 1, pixels: Int = 1600) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError()
        }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.draw(try noise(side: pixels), in: CGRect(x: 72, y: 200, width: 468, height: 468))
            context.endPDFPage()
        }
        context.closePDF()
    }

    public static func withFormField(at url: URL) throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let field = PDFAnnotation(
            bounds: CGRect(x: 72, y: 600, width: 200, height: 24), forType: .widget,
            withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "client_name"
        field.widgetStringValue = "Jane Doe"
        page.addAnnotation(field)
        guard document.write(to: url) else { throw FixtureError() }
    }

    public static func passwordProtected(at url: URL) throws {
        try imageHeavy(at: url, pixels: 200)
        guard let document = PDFDocument(url: url),
            document.write(
                to: url,
                withOptions: [.userPasswordOption: "open-sesame", .ownerPasswordOption: "owner"])
        else { throw FixtureError() }
    }

    /// A one-page document with a filled signature field. The signature value
    /// is a placeholder — detection only cares that a signature dictionary with
    /// a `/ByteRange` exists, which is what every real signature carries.
    public static func signed(at url: URL) throws {
        try handBuilt(
            at: url,
            objects: [
                "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
                "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [0 0 0 0] /V 5 0 R /P 3 0 R >>",
                "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 100 200 300] /Contents <00> >>",
            ])
    }

    /// Writes a PDF from raw object bodies with a correct cross-reference table.
    public static func handBuilt(at url: URL, objects: [String]) throws {
        var body = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        try Data(body.utf8).write(to: url)
    }

    /// Breaks the trailer pointer so a reader has to rebuild the xref table by
    /// scanning — recoverable damage of the kind Ghostscript quietly repairs.
    public static func damageCrossReference(of url: URL) throws {
        var data = try Data(contentsOf: url)
        guard let marker = data.range(of: Data("startxref".utf8), options: .backwards) else {
            throw FixtureError()
        }
        data.replaceSubrange(marker.upperBound..<data.endIndex, with: Data("\n999999999\n%%EOF\n".utf8))
        try data.write(to: url)
    }

    private static func noise(side: Int) throws -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var words = [UInt64](repeating: 0, count: side * side / 2)  // 4 bytes/pixel, 8 per word
        for index in words.indices { words[index] = generator.next() }
        let data = words.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw FixtureError() }
        return image
    }
}
