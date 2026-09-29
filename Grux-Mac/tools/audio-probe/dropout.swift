import Foundation
import AVFoundation

// Play a continuous 1 kHz tone for 8s and report per-100ms RMS of what the mic
// hears. A VPIO engine starting mid-way shows up as a gap or a step in the
// envelope. Run with a holder scheduled to start ~3s in.
let dur = 8.0, sr = 48000.0
let out = AVAudioEngine(); let player = AVAudioPlayerNode(); out.attach(player)
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
out.connect(player, to: out.mainMixerNode, format: fmt)
let n = AVAudioFrameCount(sr * dur)
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
for ch in 0..<2 { let p = buf.floatChannelData![ch]
    for i in 0..<Int(n) { p[i] = Float(0.2 * sin(2 * .pi * 1000.0 * Double(i)/sr)) } }

let mic = AVAudioEngine(); let input = mic.inputNode
let inFmt = input.outputFormat(forBus: 0); let nch = Int(inFmt.channelCount)
var bins = [(t: Double, rms: Double, ch: Int)]()
let lock = NSLock(); let t0 = Date()
input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { b, _ in
    guard let d = b.floatChannelData, b.frameLength > 0 else { return }
    var best = 0.0; var bestCh = 0
    for c in 0..<nch {
        var s = 0.0
        for i in 0..<Int(b.frameLength) { let v = Double(d[c][i]); s += v*v }
        let r = (s / Double(b.frameLength)).squareRoot()
        if r > best { best = r; bestCh = c }
    }
    lock.lock(); bins.append((Date().timeIntervalSince(t0), best, bestCh)); lock.unlock()
}
do { try mic.start(); try out.start() } catch { print("fail \(error)"); exit(1) }
player.scheduleBuffer(buf, at: nil, options: []); player.play()
Thread.sleep(forTimeInterval: dur + 0.3)
player.stop(); out.stop(); mic.stop()
lock.lock(); let b = bins; lock.unlock()
print("start format: \(nch)ch @\(Int(inFmt.sampleRate))Hz   buffers=\(b.count)")
// bucket into 250ms
var bucket = [Int: (sum: Double, n: Int, ch: Int)]()
for e in b { let k = Int(e.t / 0.25)
    var v = bucket[k] ?? (0,0,e.ch); v.sum += e.rms; v.n += 1; v.ch = e.ch; bucket[k] = v }
for k in bucket.keys.sorted() {
    let v = bucket[k]!; let avg = v.sum / Double(v.n)
    let db = 20 * log10(max(avg, 1e-12))
    let bar = String(repeating: "#", count: max(0, min(50, Int((db + 80) / 1.6))))
    print(String(format: "  t=%4.2fs ch%d rms=%9.6f %6.1fdB %@", Double(k)*0.25, v.ch, avg, db, bar))
}
