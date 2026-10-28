import Foundation
import AppKit
import ImageIO
import PDFKit
import Vision
import GruxGuardrails

/// Reads the text a file shows, on this Mac, off the main actor.
///
/// The two OCR helpers the app already had (`ScreenCapturer.performOCR`,
/// `ScreenPrescreen.ocrText`) are private and run Vision on the main actor.
/// This one decodes the file with `CGImageSource`, which is cheaper than an
/// `NSImage`, and runs in a detached task so a large scan never stalls the UI.
/// `VisionTool` is not used: it is a cloud call that captures the screen.
enum FileTextReader {

    /// The most text the model reads. Enough for a name, and short enough that
    /// a person's chat turn waits behind at most one quick call.
    static let maxCharacters = 3_000

    /// Fewer letters than this is too little to name a file from.
    static let minimumLetters = 12

    /// The PDF pages read for text, from the first.
    static let pdfPages = 3

    /// The text of `url`, capped and with secrets redacted, or "" when there is
    /// too little to name from. Never throws: an unreadable file has no text.
    static func text(of url: URL, kind: FileNamingKind) async -> String {
        let raw = await Task.detached(priority: .utility) { () -> String in
            switch kind {
            case .image: return FileTextReader.ocrImage(at: url)
            case .pdf: return FileTextReader.pdfText(at: url)
            }
        }.value
        return prepared(raw)
    }

    /// Cap, redact, and apply the letter floor. Pure. The floor counts the
    /// text the file shows, never the largest-text line: that line is a label
    /// of 11 letters plus a copy of lines already in the body, so with it
    /// counted any one word of 3 letters cleared the floor and a photo of a
    /// sign reading SALE went to the model (review 2026-10-28, which counted 5
    /// of the eval's 15 no-text items lost that way).
    static func prepared(_ raw: String) -> String {
        let collapsed = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let capped = String(collapsed.prefix(maxCharacters))
        let redacted = SecretRedactor.redact(capped, passes: .evidenceOnly)
        guard body(of: redacted).filter(\.isLetter).count >= minimumLetters else { return "" }
        return redacted
    }

    /// The start of the line `withLargestText` puts first. One constant, read
    /// by the reader that writes the line and by `FileNamePrompt.clean`, which
    /// must never ground a name on the label's own words.
    static let largestTextLabel = "Largest text: "

    /// `text` without a leading largest-text line: what the file shows.
    static func body(of text: String) -> String {
        guard text.hasPrefix(largestTextLabel) else { return text }
        guard let end = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: end)...])
    }

    // MARK: - Images

    /// The longest side an image is decoded at. A download can be a
    /// 30,000 by 10,000 PNG, about 1.2 GB once fully decoded, before Vision
    /// allocates its own buffers on top (review 2026-10-28). The thumbnail
    /// path decodes straight to this size, and text large enough to name a
    /// file from survives it.
    static let maxPixelSize = 4096

    static func ocrImage(at url: URL) -> String {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return "" }
        return recognize(image)
    }

    /// Vision's accurate recognizer with language correction and automatic
    /// language detection, lines in reading order: top to bottom by row, then
    /// left to right.
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let observations = request.results ?? []
        let lines: [(row: Int, x: CGFloat, text: String)] = observations.compactMap { (obs: VNRecognizedTextObservation) -> (row: Int, x: CGFloat, text: String)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            // Vision's origin is the bottom left. Rows of 2% of the height
            // keep words on one visual line together.
            return (Int((1 - box.midY) * 50), box.minX, text)
        }
        let body = lines.sorted { ($0.row, $0.x) < ($1.row, $1.x) }.map(\.text).joined(separator: "\n")
        return withLargestText(observations, body: body)
    }

    /// The largest text on screen is the title of what is shown: the settings
    /// page, the headline, the email's subject. Row order interleaves a sidebar
    /// with the page beside it, so without this line every settings screenshot
    /// in the eval came back "System Settings". Measured 2026-10-28 on the
    /// tuning set: grux-local:4b 119 to 127 of 135 useful, 2b 93 to 105.
    static func withLargestText(_ observations: [VNRecognizedTextObservation], body: String) -> String {
        let sized = observations.compactMap { (obs: VNRecognizedTextObservation) -> (height: CGFloat, text: String)? in
            guard let text = obs.topCandidates(1).first?.string, text.filter(\.isLetter).count >= 3 else { return nil }
            return (obs.boundingBox.height, text)
        }.sorted { $0.height > $1.height }
        var heads: [String] = []
        for item in sized where !heads.contains(item.text) {
            heads.append(item.text)
            if heads.count == 3 { break }
        }
        return heads.isEmpty ? body : largestTextLabel + heads.joined(separator: " | ") + "\n" + body
    }

    // MARK: - Complete

    /// Whether the file's content is whole, so a download written straight to
    /// its final name (curl, wget) is not named from its first half during a
    /// stall in the network. Read by the end of the file, because ImageIO
    /// reads a file cut short as complete: measured 2026-10-28, half a PNG,
    /// and a PNG, a JPEG and a HEIC cut to 90, 50 and 10 percent, all read
    /// `statusComplete` at the source and at index 0 (review 2026-10-28).
    ///   - PNG: the last 12 bytes are the IEND chunk.
    ///   - JPEG: the file ends in FF D9, after at most 32 zero bytes of padding.
    ///   - GIF: the last byte is the 0x3B trailer.
    ///   - Any other image (HEIC, TIFF, WebP): ImageIO's status at index 0,
    ///     the best there is for a container with no fixed end.
    ///   - PDF: `%%EOF` within the last 1,024 bytes, read first because it is
    ///     cheap, then the document must open.
    /// Reads the disk, so off the main actor.
    static func isComplete(_ url: URL, kind: FileNamingKind) -> Bool {
        switch kind {
        case .image:
            guard let head = bytes(of: url, fromEnd: false, count: 8),
                  let tail = bytes(of: url, fromEnd: true, count: 64) else { return false }
            if head.starts(with: pngSignature) { return tail.suffix(12).elementsEqual(pngEnd) }
            if head.starts(with: [0xFF, 0xD8, 0xFF]) {
                var end = tail[...]
                var padding = 0
                while end.last == 0x00 && padding < 32 { end = end.dropLast(); padding += 1 }
                return end.suffix(2).elementsEqual([0xFF, 0xD9])
            }
            if head.starts(with: Array("GIF8".utf8)) { return tail.last == 0x3B }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        case .pdf:
            guard let tail = bytes(of: url, fromEnd: true, count: 1_024),
                  tail.range(of: Data("%%EOF".utf8)) != nil else { return false }
            return PDFDocument(url: url) != nil
        }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The IEND chunk: an empty length, the type, and its fixed CRC.
    private static let pngEnd: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    /// Up to `count` bytes from the start or the end of the file.
    private static func bytes(of url: URL, fromEnd: Bool, count: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if fromEnd {
            guard let size = try? handle.seekToEnd() else { return nil }
            guard (try? handle.seek(toOffset: size > count ? size - count : 0)) != nil else { return nil }
            return try? handle.readToEnd() ?? Data()
        }
        return try? handle.read(upToCount: Int(count)) ?? Data()
    }

    // MARK: - PDFs

    /// The text layer of the first pages. A scan has none, so page 1 is
    /// rendered at 2,000 px and read with Vision.
    static func pdfText(at url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        for i in 0..<min(doc.pageCount, pdfPages) {
            if let text = doc.page(at: i)?.string, !text.isEmpty { parts.append(text) }
        }
        let text = parts.joined(separator: "\n\n")
        if text.contains(where: \.isLetter) { return text }
        guard let page = PDFSupport.thumbnail(url: url, page: 0, maxDimension: 2000),
              let image = page.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return recognize(image)
    }
}
