import Foundation
import AppKit

// MARK: - TextExtract
//
// Single entry point for "give me the plain text of this file". Markdown and
// plain text pass straight through; RTF / RTFD / Word go via
// NSAttributedString's document readers (AppKit handles docx through the
// officeOpenXML document type); PDFs route to PDFSupport. Returns nil when
// nothing readable could be extracted.
enum TextExtract {

    static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch DocumentKind(fileExtension: ext) {
        case .markdown, .plainText:
            return try? String(contentsOf: url, encoding: .utf8)

        case .rtf:
            return attributedText(from: url, type: ext == "rtfd" ? .rtfd : .rtf)

        case .word:
            // .docx reads via officeOpenXML; legacy .doc via docFormat.
            if ext == "doc" {
                return attributedText(from: url, type: .docFormat)
            }
            return attributedText(from: url, type: .officeOpenXML)

        case .pdf:
            let text = PDFSupport.extractText(url: url)
            return text.isEmpty ? nil : text

        case .other:
            // Best effort: try UTF-8, then let AppKit sniff the format.
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                return utf8
            }
            return attributedText(from: url, type: nil)
        }
    }

    // NSAttributedString-based extraction. Passing nil lets AppKit detect the
    // document type from the bytes.
    private static func attributedText(from url: URL, type: NSAttributedString.DocumentType?) -> String? {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type {
            options[.documentType] = type
        }
        guard let attributed = try? NSAttributedString(url: url, options: options, documentAttributes: nil) else {
            return nil
        }
        let text = attributed.string
        return text.isEmpty ? nil : text
    }
}
