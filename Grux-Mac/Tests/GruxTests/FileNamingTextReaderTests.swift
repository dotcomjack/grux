import XCTest
import CoreGraphics
import ImageIO
@testable import Grux

/// WHAT THE READER HANDS ON. Two of its rules decide whether a file reaches
/// the model at all: the letter floor that leaves a file with too little text
/// alone, and the content check that keeps a file still being written from
/// being named from its first half. Both are pure or read only a temporary
/// file of the test's own.
final class FileNamingTextReaderTests: XCTestCase {

    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = fm.temporaryDirectory.appendingPathComponent("file-naming-reader-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - The letter floor

    /// ONE SHORT WORD IS STILL TOO LITTLE TEXT. The largest-text line is a
    /// label plus a copy of body lines, and counted toward the floor it let
    /// any one word of 3 letters through: a sign reading SALE went to the
    /// model (review 2026-10-28).
    func testOneShortWordIsStillTooLittleTextWithTheLabel() {
        let label = FileTextReader.largestTextLabel
        XCTAssertEqual(FileTextReader.prepared(label + "SALE\nSALE"), "", "the label's letters counted toward the floor")
        XCTAssertEqual(FileTextReader.prepared(label + "Hello\nHello"), "")
        XCTAssertEqual(FileTextReader.prepared("SALE"), "", "control: the word alone is too little")
        let invoice = label + "Northwind Studio\nNorthwind Studio\nInvoice 2041"
        XCTAssertEqual(FileTextReader.prepared(invoice), invoice, "control: enough text in the body passes")
    }

    func testTheBodyIsTheTextAfterTheLabelLine() {
        let label = FileTextReader.largestTextLabel
        XCTAssertEqual(FileTextReader.body(of: label + "Northwind | Acme\nNorthwind\nAcme"), "Northwind\nAcme")
        XCTAssertEqual(FileTextReader.body(of: "Northwind\nAcme"), "Northwind\nAcme", "no label, nothing removed")
        XCTAssertEqual(FileTextReader.body(of: label + "Northwind"), "", "a label line with no body is no body")
        XCTAssertTrue(label.hasPrefix("Largest text"), "control: this is the label the reader writes")
    }

    // MARK: - Whole content

    /// A small PNG, written by ImageIO.
    private func png() throws -> Data { try encoded("public.png") }

    /// A small image in `type`, written by ImageIO.
    private func encoded(_ type: String) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 20, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A one page PDF, written by Core Graphics.
    private func pdf() throws -> Data {
        let url = dir.appendingPathComponent("made.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A DOWNLOAD CUT SHORT IS NOT WHOLE. Two equal sizes alone named a file
    /// written straight to its final name from its first half during a stall
    /// in the network. ImageIO reads a PNG cut short from a file as complete
    /// (measured 2026-10-28, review round 3), so only the format's own end
    /// can tell: with the ImageIO status alone, every cut below reads whole
    /// and this goes red.
    func testAnImageCutShortIsNotWhole() throws {
        let whole = try png()
        XCTAssertTrue(FileTextReader.isComplete(try write(whole, "whole.png"), kind: .image),
                      "control: a whole PNG reads as not whole, so the feature would name nothing")
        for percent in [90, 50, 10] {
            let cut = whole.prefix(whole.count * percent / 100)
            XCTAssertFalse(FileTextReader.isComplete(try write(Data(cut), "cut\(percent).png"), kind: .image),
                           "a PNG cut to \(percent) percent reads as whole")
        }
        XCTAssertFalse(FileTextReader.isComplete(try write(Data("not an image".utf8), "text.png"), kind: .image))
    }

    /// A JPEG ends in FF D9, with at most 32 zero bytes of padding after it.
    func testAJPEGCutShortIsNotWhole() throws {
        let whole = try encoded("public.jpeg")
        XCTAssertEqual(Array(whole.suffix(2)), [0xFF, 0xD9], "control: ImageIO's JPEG does not end in its marker")
        XCTAssertTrue(FileTextReader.isComplete(try write(whole, "whole.jpg"), kind: .image),
                      "control: a whole JPEG reads as not whole")
        XCTAssertTrue(FileTextReader.isComplete(try write(whole + Data(count: 16), "padded.jpg"), kind: .image),
                      "zero padding after the end marker reads as not whole")
        XCTAssertFalse(FileTextReader.isComplete(try write(whole + Data(count: 40), "overpadded.jpg"), kind: .image),
                       "more zeros than padding allows read as whole")
        for percent in [90, 50, 10] {
            let cut = whole.prefix(whole.count * percent / 100)
            XCTAssertFalse(FileTextReader.isComplete(try write(Data(cut), "cut\(percent).jpg"), kind: .image),
                           "a JPEG cut to \(percent) percent reads as whole")
        }
    }

    /// A MOTION PHOTO IS WHOLE. Pixel and Samsung phones put an MP4 after the
    /// picture's FF D9, so the file never ends in it, and every motion photo
    /// waited out the timeout unnamed (review 2026-10-28).
    func testAMotionPhotoIsWhole() throws {
        let picture = try encoded("public.jpeg")
        var movie = Data([0x00, 0x00, 0x00, 0x18])
        movie.append(Data("ftypisom".utf8))
        movie.append(Data(repeating: 0x11, count: 300))
        XCTAssertTrue(FileTextReader.isComplete(try write(picture + movie, "PXL_20261028_123456789.MP.jpg"), kind: .image),
                      "a motion photo reads as not whole")
        XCTAssertFalse(FileTextReader.isComplete(try write(picture + Data(repeating: 0x11, count: 300), "trailing.jpg"),
                                                 kind: .image),
                       "control: bytes after the end that are not a movie still read as whole")
        let cut = picture.prefix(picture.count / 2)
        XCTAssertFalse(FileTextReader.isComplete(try write(Data(cut), "cut.jpg"), kind: .image),
                       "control: a JPEG cut short reads as whole")
    }

    /// A GIF ends in its 0x3B trailer.
    func testAGIFCutShortIsNotWhole() throws {
        let whole = try encoded("com.compuserve.gif")
        XCTAssertEqual(whole.last, 0x3B, "control: ImageIO's GIF does not end in its trailer")
        XCTAssertTrue(FileTextReader.isComplete(try write(whole, "whole.gif"), kind: .image))
        XCTAssertFalse(FileTextReader.isComplete(try write(Data(whole.dropLast()), "cut.gif"), kind: .image),
                       "a GIF missing its trailer reads as whole")
    }

    func testAPDFWithoutItsEndIsNotWhole() throws {
        let whole = try pdf()
        XCTAssertTrue(FileTextReader.isComplete(try write(whole, "whole.pdf"), kind: .pdf),
                      "control: a whole PDF reads as not whole, so the feature would name nothing")
        let end = try XCTUnwrap(whole.range(of: Data("%%EOF".utf8), options: .backwards), "control: the PDF has no end marker")
        let cut = whole.prefix(upTo: end.lowerBound)
        XCTAssertFalse(FileTextReader.isComplete(try write(Data(cut), "cut.pdf"), kind: .pdf),
                       "a PDF missing its end reads as whole")
        XCTAssertFalse(FileTextReader.isComplete(try write(Data("%PDF-fixture %%EOF".utf8), "fake.pdf"), kind: .pdf),
                       "bytes that only end like a PDF read as whole")
    }
}
