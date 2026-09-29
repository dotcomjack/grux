import XCTest
import AppKit
@testable import Grux

/// Screenshots on a work order: dropped or pasted on the Change it box, kept
/// as PNGs in the order's own folder, and listed by path in work-order.md so
/// the agent can open them. Nothing leaves the Mac.
@MainActor
final class WorkOrderImagesTests: XCTestCase {

    private func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wo-images-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func context(_ orderDir: URL) -> WorkOrderContext {
        WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "8",
                         installed: .release(olderSource: nil),
                         supportDir: "/support/Grux", orderDir: orderDir.path)
    }

    private func square(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    func test_theHelperTurnsAnImageIntoPNGBytes() throws {
        let png = try XCTUnwrap(ImageIngest.png(from: square(.red)))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG")
        XCTAssertNotNil(NSImage(data: png), "the PNG does not read back")
    }

    func test_imagesAreWrittenBesideTheOrder_andListedByPath() throws {
        let store = WorkOrderStore(root: temp())
        let red = try XCTUnwrap(ImageIngest.png(from: square(.red)))
        let blue = try XCTUnwrap(ImageIngest.png(from: square(.blue)))
        let order = try XCTUnwrap(store.create(request: "the send button is cut off", images: [red, blue],
                                               context: context))
        let first = order.dir.appendingPathComponent("image-1.png")
        let second = order.dir.appendingPathComponent("image-2.png")
        XCTAssertEqual(try Data(contentsOf: first), red)
        XCTAssertEqual(try Data(contentsOf: second), blue)

        let text = try XCTUnwrap(store.workOrderText(order))
        let one = try XCTUnwrap(text.range(of: "- `\(first.path)`"), "image-1 is not listed by path")
        let two = try XCTUnwrap(text.range(of: "- `\(second.path)`"), "image-2 is not listed by path")
        XCTAssertLessThan(one.lowerBound, two.lowerBound)
        // After the request, before the line.
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "> the send button is cut off")).lowerBound, one.lowerBound)
        XCTAssertLessThan(two.lowerBound, try XCTUnwrap(text.range(of: "You are this person's coding agent.")).lowerBound)
    }

    func test_noImagesLeavesTheWorkOrderExactlyAsItWas() throws {
        let store = WorkOrderStore(root: temp())
        let order = try XCTUnwrap(store.create(request: "make the accent red", context: context))
        let text = try XCTUnwrap(store.workOrderText(order))
        XCTAssertEqual(text, WorkOrderPrompt.build(id: order.id, request: "make the accent red",
                                                   context: context(order.dir)))
        XCTAssertFalse(text.contains("Screenshots"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: order.dir.appendingPathComponent("image-1.png").path))
    }

    func test_anImageThatCannotBeWrittenLeavesNoFolderBehind() throws {
        let root = temp()
        let store = WorkOrderStore(root: root)
        XCTAssertNil(store.create(request: "the send button is cut off",
                                  images: [Data("not an image".utf8)], context: context))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path)
                        .filter { $0.hasPrefix("wo-") }, [],
                       "a half written order was left behind")
    }

    func test_aRewrittenOrderKeepsItsScreenshots() throws {
        let store = WorkOrderStore(root: temp())
        let red = try XCTUnwrap(ImageIngest.png(from: square(.red)))
        let order = try XCTUnwrap(store.create(request: "the send button is cut off", images: [red],
                                               context: context))
        try FileManager.default.removeItem(at: order.workOrderFile)
        let text = try XCTUnwrap(store.rewriteWorkOrder(order, detail: nil))
        XCTAssertTrue(text.contains("- `\(order.dir.appendingPathComponent("image-1.png").path)`"))
    }
}
