import Foundation
import Vision
import CoreGraphics
import AppKit
import NaturalLanguage

// Local-first screen prescreen. Runs every cadence tick and decides whether
// the cloud vision model needs to look at this frame.
//
// Pipeline:
//   1. Image-feature-print diff (Apple Vision) - pHash on steroids. Sub-100ms,
//      catches "screen is essentially the same as last tick".
//   2. OCR - Apple Vision text recognition (already a dependency).
//   3. Window-title diff vs last analyzed frame.
//   4. NLEmbedding cosine-similarity diff on OCR text vs last frame.
//   5. Heuristic floor: if it's been > maxSilenceSeconds since the last cloud
//      check, ALWAYS escalate (keepalive - confirms on-task states stay fresh).
//
// Output drives FocusWatcher's decision to fire a cloud Haiku call.
@MainActor
final class ScreenPrescreen {
    static let shared = ScreenPrescreen()

    struct Result {
        let shouldEscalate: Bool
        let reason: String
        let imageChange: Double      // 0.0 = identical, 1.0 = totally different
        let textChange: Double       // 1.0 - cosine similarity of OCR embeddings
        let ocrText: String
        let windowChanged: Bool
    }

    // Tuning thresholds. Empirically: VNFeaturePrintObservation distances
    // on the same frame run 0.0-0.05; even a tiny scroll bumps to 0.10-0.15;
    // an app switch jumps to 0.5+. We escalate at >= 0.18 to be conservative.
    private let imageChangeThreshold: Double = 0.18
    private let textChangeThreshold: Double = 0.20

    private var lastFeaturePrint: VNFeaturePrintObservation?
    private var lastOcrText: String = ""
    private var lastEmbedding: [Double]?
    private var lastBundleId: String = ""
    private var lastWindowTitle: String = ""

    // Cached NLEmbedding - first load takes ~500ms, subsequent calls reuse.
    // English-only for now; the OCR layer normalizes everything to
    // mostly-English text anyway.
    private lazy var sentenceEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    func evaluate(image: CGImage, bundleId: String, windowTitle: String, secondsSinceLastCloud: TimeInterval, maxSilenceSeconds: Int) async -> Result {
        // Run the two independent Vision requests concurrently. Both only READ
        // the CGImage; the state writes below are sequenced after both complete,
        // so there's no race. Saves ~50-100ms per ambient tick.
        async let printTask = featurePrint(for: image)
        async let ocrTask = ocrText(for: image)
        let (print, ocr) = await (printTask, ocrTask)

        // 1. Image diff vs last frame
        var imageChange: Double = 1.0
        if let last = lastFeaturePrint, let p = print {
            var dist: Float = 0
            do {
                try p.computeDistance(&dist, to: last)
                imageChange = Double(dist)
            } catch {
                imageChange = 1.0
            }
        }

        // 2. OCR text diff via sentence embeddings (falls back to Jaccard).
        let embedding = embed(text: ocr)
        var textChange: Double = 1.0
        if let last = lastEmbedding, let cur = embedding, last.count == cur.count, !last.isEmpty {
            textChange = max(0.0, 1.0 - cosineSimilarity(last, cur))
        } else if !lastOcrText.isEmpty || !ocr.isEmpty {
            textChange = 1.0 - jaccardSimilarity(lastOcrText, ocr)
        }

        // 3. Window/app switch
        let windowChanged = (bundleId != lastBundleId) || (windowTitle != lastWindowTitle)

        // 4. Decision
        var shouldEscalate = false
        var reason = "no change"
        if windowChanged {
            shouldEscalate = true
            reason = "window/app switch"
        } else if imageChange >= imageChangeThreshold {
            shouldEscalate = true
            reason = String(format: "image diff %.2f >= %.2f", imageChange, imageChangeThreshold)
        } else if textChange >= textChangeThreshold {
            shouldEscalate = true
            reason = String(format: "text diff %.2f >= %.2f", textChange, textChangeThreshold)
        } else if secondsSinceLastCloud >= TimeInterval(maxSilenceSeconds) {
            shouldEscalate = true
            reason = "keepalive (\(Int(secondsSinceLastCloud))s since last cloud check)"
        }

        // 5. Update state - only after we've used the previous values for diff.
        if let p = print { lastFeaturePrint = p }
        lastOcrText = ocr
        if let e = embedding { lastEmbedding = e }
        lastBundleId = bundleId
        lastWindowTitle = windowTitle

        return Result(
            shouldEscalate: shouldEscalate,
            reason: reason,
            imageChange: imageChange,
            textChange: textChange,
            ocrText: ocr,
            windowChanged: windowChanged
        )
    }

    // MARK: - Apple Vision plumbing

    private func featurePrint(for image: CGImage) async -> VNFeaturePrintObservation? {
        await withCheckedContinuation { (cont: CheckedContinuation<VNFeaturePrintObservation?, Never>) in
            let req = VNGenerateImageFeaturePrintRequest { req, _ in
                let obs = (req.results as? [VNFeaturePrintObservation])?.first
                cont.resume(returning: obs)
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([req])
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    private func ocrText(for image: CGImage) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let req = VNRecognizeTextRequest { req, _ in
                let obs = req.results as? [VNRecognizedTextObservation] ?? []
                let lines = obs.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            req.recognitionLevel = .fast    // prescreen wants speed, accurate is overkill
            req.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([req])
            } catch {
                cont.resume(returning: "")
            }
        }
    }

    // MARK: - Embeddings

    private func embed(text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model = sentenceEmbedding else { return nil }
        // Truncate to avoid hammering NLEmbedding on multi-thousand-line OCR
        // dumps. The first ~600 chars of an OCR pass are dominated by the
        // visible foreground content - that's what we want.
        let snippet = String(trimmed.prefix(600))
        guard let vec = model.vector(for: snippet) else {
            // sentenceEmbedding can't find a vector for unusual inputs (e.g.
            // pure code) - try splitting on lines and averaging.
            return averagedLineVector(text: snippet, model: model)
        }
        return vec
    }

    private func averagedLineVector(text: String, model: NLEmbedding) -> [Double]? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return nil }
        var acc: [Double]?
        var count = 0
        for line in lines.prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 4, let v = model.vector(for: trimmed) else { continue }
            if acc == nil {
                acc = v
            } else {
                for i in 0..<min(acc!.count, v.count) { acc![i] += v[i] }
            }
            count += 1
        }
        guard var out = acc, count > 0 else { return nil }
        for i in 0..<out.count { out[i] /= Double(count) }
        return out
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        let setB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        guard !setA.isEmpty || !setB.isEmpty else { return 1.0 }
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union == 0 ? 1.0 : Double(inter) / Double(union)
    }

    // For tests / "force a fresh next-tick" after settings changes.
    func reset() {
        lastFeaturePrint = nil
        lastOcrText = ""
        lastEmbedding = nil
        lastBundleId = ""
        lastWindowTitle = ""
    }
}
