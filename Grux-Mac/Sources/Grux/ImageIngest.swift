import AppKit
import UniformTypeIdentifiers

/// Images coming in from a drop or the clipboard, turned into PNG bytes. One
/// copy of the rules for every surface that takes an image: Chat's composer
/// and the Optimize card's Change it box.
enum ImageIngest {

    struct Failure: Error, Equatable {
        let message: String
    }

    static let cannotEncode = "Couldn't encode that image."

    static let acceptedDropTypes: [UTType] = [
        .image, .fileURL, .png, .jpeg, .gif, .webP, .heic, .tiff
    ]

    // Walk NSItemProvider candidates, preferring the NSImage loader because
    // that's the only path that reliably works across EVERY macOS drag source
    // (Safari, Photos, iMessage, Finder, Preview, Notes). Raw
    // loadDataRepresentation often returns nil/empty even when
    // hasItemConformingToTypeIdentifier says the type is available - the
    // provider resolves the bytes lazily through the object loader, not the
    // UTType data channel. Fall back to file URLs for Finder drops that
    // only expose themselves as file refs.
    //
    // `all: false` takes the first image a drop offers (Chat attaches one);
    // `all: true` takes one per provider (a work order takes several).
    // `deliver` runs on the main actor, once per image or failure. Returns
    // false when nothing in the drop could be an image.
    @discardableResult
    static func load(_ providers: [NSItemProvider], all: Bool = false,
                     deliver: @escaping @MainActor (Result<NSImage, Failure>) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        if !all {
            if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
                loadImage(provider, deliver: deliver)
                return true
            }
            if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
                loadFile(provider, deliver: deliver)
                return true
            }
            return false
        }
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                loadImage(provider, deliver: deliver)
                took = true
            } else if provider.canLoadObject(ofClass: URL.self) {
                loadFile(provider, deliver: deliver)
                took = true
            }
        }
        return took
    }

    private static func loadImage(_ provider: NSItemProvider,
                                  deliver: @escaping @MainActor (Result<NSImage, Failure>) -> Void) {
        _ = provider.loadObject(ofClass: NSImage.self) { object, err in
            let image = object as? NSImage
            let message = err.map { "Drop failed: \($0.localizedDescription)" } ?? "Couldn't read the dropped image."
            Task { @MainActor in
                deliver(image.map { .success($0) } ?? .failure(Failure(message: message)))
            }
        }
    }

    private static func loadFile(_ provider: NSItemProvider,
                                 deliver: @escaping @MainActor (Result<NSImage, Failure>) -> Void) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                guard let url else {
                    deliver(.failure(Failure(message: "Couldn't resolve the dropped file.")))
                    return
                }
                deliver(image(fromFile: url))
            }
        }
    }

    // Dropped-file path: read bytes off disk and decode them, so a file that
    // came in via a file-URL-only provider (some Finder drags) goes through
    // the same NSImage pipeline as an in-memory drop.
    static func image(fromFile url: URL) -> Result<NSImage, Failure> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(Failure(message: "Couldn't read \(url.lastPathComponent)."))
        }
        guard let image = NSImage(data: data) else {
            return .failure(Failure(message: "\(url.lastPathComponent) isn't a readable image."))
        }
        return .success(image)
    }

    // Universal ingest: re-encode whatever NSImage we got into PNG so the
    // Anthropic API gets a format it accepts (PNG/JPEG/GIF/WebP). NSImage
    // is normalized via TIFF, NSBitmapImageRep, then PNG; that round-trip also
    // strips any weird source-specific metadata that might confuse the API.
    static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              !png.isEmpty else { return nil }
        return png
    }

    /// The images on a pasteboard: image data first (a screenshot copied
    /// with Control-Shift-Command-4), then image files copied in Finder.
    /// Empty when the pasteboard holds none, so plain text paste is left to
    /// the text field.
    static func images(on pasteboard: NSPasteboard) -> [NSImage] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            return files.compactMap { try? image(fromFile: $0).get() }
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]) ?? []
    }
}
