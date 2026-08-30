import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision
import AppKit

struct ScreenSnapshot {
    let image: CGImage
    let ocrText: String
    let capturedAt: Date
    // Frontmost app bundle id at capture time. Lets cachedOrCapture()
    // self-invalidate when the user switched apps since the snapshot was taken,
    // even if no explicit invalidateCache() fired. nil if unknown.
    var frontBundleId: String? = nil
}

@MainActor
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    private var lastCapture: Date?

    // Most-recent raw snapshot, retained so back-to-back screen questions can
    // reuse one capture instead of re-rendering + re-encoding every time. We
    // cache the raw CGImage (NOT encoded JPEG) so each caller can still encode
    // at its own dimension/quality. FocusWatcher's per-tick captureOnly() warms
    // this for free.
    private var cachedSnapshot: ScreenSnapshot?

    // How long a cached snapshot is considered fresh. Short enough that a stale
    // frame is rarely served, long enough to coalesce a quick "what's that /
    // read it again" pair. Context switches invalidate it early via
    // invalidateCache() (FocusWatcher) and the bundleId self-check below.
    nonisolated static let cacheTTL: TimeInterval = 4.0

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // Drop the cached snapshot so the next cachedOrCapture() recaptures. Called
    // on any app/window switch (FocusWatcher) so a freshness-sensitive read
    // never sees a frame from a different context.
    func invalidateCache() {
        cachedSnapshot = nil
    }

    func captureAndOCR() async throws -> ScreenSnapshot {
        let image = try await captureMainDisplay()
        let text = try await performOCR(on: image)
        lastCapture = Date()
        let snap = ScreenSnapshot(image: image, ocrText: text, capturedAt: Date(), frontBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        cachedSnapshot = snap
        return snap
    }

    // Vision-path: capture without OCR. Caller gets the raw CGImage and can
    // encode it to JPEG for Claude. Cheaper than captureAndOCR since it skips
    // the Vision request.
    func captureOnly() async throws -> ScreenSnapshot {
        let image = try await captureMainDisplay()
        lastCapture = Date()
        let snap = ScreenSnapshot(image: image, ocrText: "", capturedAt: Date(), frontBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        cachedSnapshot = snap
        return snap
    }

    // Reuse the cached snapshot when it's still fresh, else capture a new one.
    // Returns (snapshot, wasCached). `forceFresh` bypasses the cache for an
    // explicit rescan; the cache also self-invalidates if the frontmost app
    // changed since the snapshot was taken (belt-and-suspenders for when the
    // FocusWatcher isn't running to fire invalidateCache()).
    func cachedOrCapture(maxAge: TimeInterval = ScreenCapturer.cacheTTL, forceFresh: Bool = false) async throws -> (snapshot: ScreenSnapshot, wasCached: Bool) {
        if !forceFresh,
           let snap = cachedSnapshot,
           Date().timeIntervalSince(snap.capturedAt) <= maxAge,
           snap.frontBundleId == NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            return (snap, true)
        }
        let fresh = try await captureOnly()
        return (fresh, false)
    }

    // Compressed JPEG. Quality 0.55 + an internal downscale target of ~1280px
    // keeps payloads ~100KB while staying readable to vision models.
    static func jpegData(from image: CGImage, maxDimension: CGFloat = 1280, quality: CGFloat = 0.55) -> Data? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(1.0, maxDimension / max(w, h))
        let resized: CGImage
        if scale < 1.0 {
            let targetW = Int(w * scale)
            let targetH = Int(h * scale)
            let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: targetW,
                height: targetH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            guard let out = ctx.makeImage() else { return nil }
            resized = out
        } else {
            resized = image
        }
        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func captureMainDisplay() async throws -> CGImage {
        // Privacy gate. Deliberately here, in the one private function every
        // public capture path funnels through, rather than in FocusWatcher where
        // the ambient loop lives. FocusWatcher is only one of the callers: the
        // read_screen tool, the vision tool and the cache warmer all reach the
        // screen too, and a guard placed in the loop would have left those three
        // wide open while looking like the feature was done.
        let cfg = AppState.shared.config
        let bundleIds = cfg.captureExcludedBundleIds
        let titlePatterns = cfg.captureExcludedTitlePatterns
        let selfBundleId = Bundle.main.bundleIdentifier ?? "com.gruxai.grux"

        let front = ActiveApp.current()
        if front.bundleId != selfBundleId,
           let reason = CapturePrivacy.frontmostBlockReason(
                bundleId: front.bundleId,
                windowTitle: front.windowTitle,
                bundleIds: bundleIds,
                titlePatterns: titlePatterns) {
            AppState.shared.noteCaptureBlocked(app: front.name, reason: reason)
            throw CaptureBlocked(appName: front.name, reason: reason)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Grux", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display"])
        }
        // The real exclusion. These windows are removed from the content filter,
        // so the compositor never draws them into the frame and the pixels do
        // not exist to be encoded. A password manager visible on a second
        // monitor while the editor is frontmost is the case a frontmost-only
        // check misses entirely, and it is an ordinary way to use one.
        let excludedWindows = content.windows.filter {
            CapturePrivacy.shouldExclude($0,
                                         bundleIds: bundleIds,
                                         titlePatterns: titlePatterns,
                                         selfBundleId: selfBundleId)
        }
        if !excludedWindows.isEmpty {
            AppState.shared.lastCaptureExcludedWindowCount = excludedWindows.count
        } else {
            AppState.shared.lastCaptureExcludedWindowCount = 0
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.width = Int(Double(display.width) * 0.5)
        config.height = Int(Double(display.height) * 0.5)
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return image
    }

    private func performOCR(on image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err = err { cont.resume(throwing: err); return }
                let obs = req.results as? [VNRecognizedTextObservation] ?? []
                let lines = obs.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([req]) } catch { cont.resume(throwing: error) }
        }
    }

    func saveScreenshot(_ image: CGImage, label: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let url = Persistence.screenshotsDir.appendingPathComponent("\(ts)-\(label).jpg")
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) {
            try? data.write(to: url)
        }
    }
}
