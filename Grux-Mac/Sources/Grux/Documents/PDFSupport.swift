import Foundation
import PDFKit
import AppKit

// MARK: - PDFSupport
//
// Thin PDFKit wrapper for the document library: page thumbnails for cards,
// full-text extraction for previews + AI context, and AcroForm read/fill so
// the pdf_form_fill chat tool can complete real forms. No third-party deps,
// PDFKit ships with macOS.
enum PDFSupport {

    // MARK: - Reading

    static func pageCount(url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    // Rendered thumbnail of one page, scaled so the longest side equals
    // maxDimension. Returns nil for missing files / out-of-range pages.
    static func thumbnail(url: URL, page pageIndex: Int = 0, maxDimension: CGFloat = 220) -> NSImage? {
        guard let doc = PDFDocument(url: url),
              pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex)
        else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    // Plain text of every page, joined with blank lines. Pages with no text
    // layer (scanned images) contribute nothing, callers can fall back to
    // VisionTool for OCR on those.
    static func extractText(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - AcroForm fields

    // Lists every interactive form widget: text fields and checkboxes get
    // first-class types; radio groups / combo boxes / signatures report as
    // "other" with their current string value where available.
    static func listFormFields(url: URL) -> [PDFFormFieldInfo] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var fields: [PDFFormFieldInfo] = []
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.isWidgetAnnotation {
                let name = annotation.fieldName ?? ""
                guard !name.isEmpty else { continue }
                let type: String
                let value: String
                switch annotation.widgetFieldType {
                case .text:
                    type = "text"
                    value = annotation.widgetStringValue ?? ""
                case .button:
                    type = "checkbox"
                    value = annotation.buttonWidgetState == .onState ? "true" : "false"
                default:
                    type = "other"
                    value = annotation.widgetStringValue ?? ""
                }
                fields.append(PDFFormFieldInfo(name: name, type: type, value: value, pageIndex: pageIndex))
            }
        }
        return fields
    }

    // Fills text + checkbox fields by name and writes a filled COPY to
    // outputURL (the source PDF is never mutated, same reversibility posture
    // as DocumentStore's version snapshots). Checkbox truthy values:
    // "true" / "yes" / "on" / "1" / "checked" (case-insensitive).
    // Returns the names of fields actually filled.
    @discardableResult
    static func fillForm(at url: URL, values: [String: String], outputURL: URL) throws -> [String] {
        guard let doc = PDFDocument(url: url) else {
            throw PDFSupportError.cannotOpen(url.lastPathComponent)
        }
        var filled: [String] = []
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.isWidgetAnnotation {
                guard let name = annotation.fieldName, let newValue = values[name] else { continue }
                switch annotation.widgetFieldType {
                case .text:
                    annotation.widgetStringValue = newValue
                    filled.append(name)
                case .button:
                    annotation.buttonWidgetState = isTruthy(newValue) ? .onState : .offState
                    filled.append(name)
                default:
                    // Combo / list / radio groups: best-effort string set.
                    annotation.widgetStringValue = newValue
                    filled.append(name)
                }
            }
        }
        guard doc.write(to: outputURL) else {
            throw PDFSupportError.cannotWrite(outputURL.lastPathComponent)
        }
        return filled
    }

    private static func isTruthy(_ raw: String) -> Bool {
        ["true", "yes", "on", "1", "checked"].contains(raw.lowercased())
    }
}

private extension PDFAnnotation {
    // PDFKit marks form widgets with type "Widget"; PDFAnnotation exposes no
    // direct boolean, so compare the raw type string.
    var isWidgetAnnotation: Bool {
        type == "Widget" || type == "'Widget'"
    }
}

enum PDFSupportError: Error, LocalizedError {
    case cannotOpen(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "Could not open PDF '\(name)'"
        case .cannotWrite(let name): return "Could not write filled PDF '\(name)'"
        }
    }
}
