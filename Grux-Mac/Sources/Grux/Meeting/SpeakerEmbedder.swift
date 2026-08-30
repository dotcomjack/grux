import Foundation
import Accelerate

// Pure-Accelerate voice embedder. Takes a [Float] 16 kHz mono PCM buffer and
// returns a fixed-length L2-normalized feature vector suitable for cosine-
// distance speaker clustering.
//
// v2 feature (52-dim): 13 MFCC means + 13 MFCC stds + 13 delta-MFCC means +
// 13 delta-MFCC stds. Statics capture spectral identity, deltas capture
// how the spectrum MOVES over time - a major boost for separating same-
// gender adult voices whose mean MFCCs overlap. 100% on-device, zero new
// deps, Apple Silicon-accelerated. Swap-in point for a neural embedder
// (CoreML x-vector / ECAPA-TDNN) is the `embed(samples:)` entry - keep the
// output dimensionality stable or the downstream cosine-threshold will need
// a re-tune.
//
// VAD: drops frames whose log-mel energy is more than `vadDropDB` below the
// chunk's peak. Silence-only chunks return nil.
enum SpeakerEmbedder {

    static let sampleRate: Float = 16_000
    static let frameSize: Int = 400              // 25 ms
    static let hopSize: Int = 160                // 10 ms
    static let fftSize: Int = 512                // next pow2 ≥ frameSize
    static let log2fft: vDSP_Length = 9
    static let melBands: Int = 40
    static let mfccDims: Int = 13                // drop the 0th? No - keep C0; it's useful.
    static let embeddingDims: Int = 52           // 13 means + 13 stds + 13 Δ means + 13 Δ stds
    static let vadDropDB: Float = 25.0           // ≥25 dB below peak → silent frame
    static let silenceRMSFloor: Float = 1e-4     // chunk-wide absolute silence gate

    // Result vector length is always `embeddingDims`. Nil when no voiced
    // frames pass VAD (pure silence / music with no speech-like spectrum).
    static func embed(samples: [Float]) -> [Float]? {
        guard samples.count >= frameSize else { return nil }
        // Absolute silence gate. Peak-relative VAD is useless on a
        // completely-zero chunk (every frame ties the peak), so check the
        // whole-chunk RMS here before framing.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms >= silenceRMSFloor else { return nil }

        let frames = framedMFCC(samples: samples)
        guard !frames.isEmpty else { return nil }

        // First-order delta MFCCs. Delta[t] = (MFCC[t+1] - MFCC[t-1]) / 2,
        // clamping at the edges. Captures how the spectrum evolves - a
        // robust speaker cue even when MFCC means cluster closely.
        let deltas: [[Float]] = computeDeltas(frames: frames)

        let (staticMean, staticStd) = meanAndStd(frames: frames)
        let (deltaMean, deltaStd) = meanAndStd(frames: deltas)

        var emb = staticMean + staticStd + deltaMean + deltaStd
        // L2 normalize so cosine sim = dot product.
        var mag: Float = 0
        vDSP_svesq(emb, 1, &mag, vDSP_Length(emb.count))
        let norm = sqrtf(max(1e-9, mag))
        var inv = 1.0 / norm
        vDSP_vsmul(emb, 1, &inv, &emb, 1, vDSP_Length(emb.count))
        return emb
    }

    private static func meanAndStd(frames: [[Float]]) -> (mean: [Float], std: [Float]) {
        guard let first = frames.first else {
            return (Array(repeating: 0, count: mfccDims), Array(repeating: 0, count: mfccDims))
        }
        let dims = first.count
        var means = [Float](repeating: 0, count: dims)
        var stds = [Float](repeating: 0, count: dims)
        for d in 0..<dims {
            var col = [Float](repeating: 0, count: frames.count)
            for (i, f) in frames.enumerated() { col[i] = f[d] }
            var m: Float = 0
            vDSP_meanv(col, 1, &m, vDSP_Length(col.count))
            means[d] = m
            var sq: Float = 0
            var zeroMean = col
            var neg = -m
            vDSP_vsadd(zeroMean, 1, &neg, &zeroMean, 1, vDSP_Length(zeroMean.count))
            vDSP_svesq(zeroMean, 1, &sq, vDSP_Length(zeroMean.count))
            stds[d] = sqrtf(sq / Float(max(1, col.count)))
        }
        return (means, stds)
    }

    private static func computeDeltas(frames: [[Float]]) -> [[Float]] {
        guard !frames.isEmpty else { return [] }
        let dims = frames[0].count
        var out: [[Float]] = Array(repeating: Array(repeating: 0, count: dims), count: frames.count)
        for t in 0..<frames.count {
            let prev = frames[max(0, t - 1)]
            let next = frames[min(frames.count - 1, t + 1)]
            for d in 0..<dims {
                out[t][d] = (next[d] - prev[d]) * 0.5
            }
        }
        return out
    }

    // MARK: - Frame → MFCC

    private static func framedMFCC(samples: [Float]) -> [[Float]] {
        guard let fft = try? vDSP.FFT(log2n: log2fft, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return []
        }

        let hamming: [Float] = {
            var w = [Float](repeating: 0, count: frameSize)
            vDSP_hamm_window(&w, vDSP_Length(frameSize), 0)
            return w
        }()

        let melFB = makeMelFilterbank()
        let dctMat = makeDCTMatrix(rows: mfccDims, cols: melBands)

        var mfccPerFrame: [[Float]] = []
        var logEnergies: [Float] = []

        // FFT scratch
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2 + 1)
        var melEnergies = [Float](repeating: 0, count: melBands)

        var pos = 0
        while pos + frameSize <= samples.count {
            var frame = [Float](repeating: 0, count: fftSize)
            // Copy + apply window
            for i in 0..<frameSize {
                frame[i] = samples[pos + i] * hamming[i]
            }

            // Interleave into split complex for vDSP FFT
            frame.withUnsafeBufferPointer { fp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                        fft.forward(input: split, output: &split)
                    }
                }
            }

            // Power spectrum |X|^2 (length fftSize/2 + 1; we approximate with
            // fftSize/2 since DC and Nyquist are combined in vDSP split-complex.
            // Good enough for MFCC.)
            for k in 0..<(fftSize / 2) {
                let re = real[k]
                let im = imag[k]
                power[k] = re * re + im * im
            }
            power[fftSize / 2] = 0  // Nyquist bin unused

            // Mel filterbank energies
            for (b, filt) in melFB.enumerated() {
                var e: Float = 0
                for (k, w) in filt where k < power.count {
                    e += w * power[k]
                }
                melEnergies[b] = logf(max(1e-10, e))
            }

            // Per-frame energy for VAD
            var frameE: Float = 0
            vDSP_meanv(melEnergies, 1, &frameE, vDSP_Length(melEnergies.count))
            logEnergies.append(frameE)

            // DCT to get MFCCs
            var mfcc = [Float](repeating: 0, count: mfccDims)
            for d in 0..<mfccDims {
                var acc: Float = 0
                let row = dctMat[d]
                vDSP_dotpr(row, 1, melEnergies, 1, &acc, vDSP_Length(melBands))
                mfcc[d] = acc
            }
            mfccPerFrame.append(mfcc)

            pos += hopSize
        }

        // Voice activity: keep frames whose log-mel energy is within
        // `vadDropDB` of the chunk's peak. Converts dB gap → loge gap.
        guard let peak = logEnergies.max() else { return [] }
        let cutoff = peak - (vadDropDB / 10.0 * logf(10.0))
        var voiced: [[Float]] = []
        for (i, e) in logEnergies.enumerated() where e >= cutoff {
            voiced.append(mfccPerFrame[i])
        }
        return voiced
    }

    // MARK: - Filterbank + DCT (precomputed per call; cheap, no need to cache)

    // Triangular mel filterbank over the 0..sampleRate/2 band, mapped onto
    // `fftSize/2` linear-freq power bins.
    private static func makeMelFilterbank() -> [[(Int, Float)]] {
        let fMin: Float = 20
        let fMax: Float = sampleRate / 2
        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)
        var melPoints = [Float](repeating: 0, count: melBands + 2)
        for i in 0...(melBands + 1) {
            melPoints[i] = melMin + (melMax - melMin) * Float(i) / Float(melBands + 1)
        }
        let hzPoints = melPoints.map { melToHz($0) }
        // Map each mel edge to its nearest power-spectrum bin.
        let bins = hzPoints.map { Int((Float(fftSize) * $0 / sampleRate).rounded()) }

        var fb: [[(Int, Float)]] = []
        for b in 1...melBands {
            let left = bins[b - 1]
            let center = bins[b]
            let right = bins[b + 1]
            var sparse: [(Int, Float)] = []
            if center > left {
                for k in left..<center {
                    let w = Float(k - left) / Float(center - left)
                    if w > 0 { sparse.append((k, w)) }
                }
            }
            if right > center {
                for k in center..<right {
                    let w = Float(right - k) / Float(right - center)
                    if w > 0 { sparse.append((k, w)) }
                }
            }
            fb.append(sparse)
        }
        return fb
    }

    private static func hzToMel(_ hz: Float) -> Float { 2595 * log10f(1 + hz / 700) }
    private static func melToHz(_ mel: Float) -> Float { 700 * (powf(10, mel / 2595) - 1) }

    // Orthonormal DCT-II matrix, `rows` x `cols`.
    private static func makeDCTMatrix(rows: Int, cols: Int) -> [[Float]] {
        var m = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        let n = Float(cols)
        for k in 0..<rows {
            let scale = k == 0 ? sqrtf(1.0 / n) : sqrtf(2.0 / n)
            for i in 0..<cols {
                m[k][i] = scale * cosf(Float.pi * Float(k) * (2 * Float(i) + 1) / (2 * n))
            }
        }
        return m
    }

    // Cosine similarity of two equal-length embeddings (assumes L2-normalized).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "cosineSimilarity: length mismatch")
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    // Exponential moving average blend: c = (1 - α) * c + α * e.
    // Caller should re-normalize afterward.
    static func blendCentroid(_ c: [Float], with e: [Float], alpha: Float) -> [Float] {
        precondition(c.count == e.count, "blendCentroid: length mismatch")
        var result = [Float](repeating: 0, count: c.count)
        let oneMinusAlpha = 1 - alpha
        for i in 0..<c.count {
            result[i] = oneMinusAlpha * c[i] + alpha * e[i]
        }
        // L2 renormalize
        var mag: Float = 0
        vDSP_svesq(result, 1, &mag, vDSP_Length(result.count))
        let norm = sqrtf(max(1e-9, mag))
        var inv = 1.0 / norm
        vDSP_vsmul(result, 1, &inv, &result, 1, vDSP_Length(result.count))
        return result
    }
}
