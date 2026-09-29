import Foundation
import AVFoundation
import Accelerate

// Plays 1 kHz + 12 kHz through the DEFAULT OUTPUT and records what the
// microphone actually hears, with NO voice processing in this process.
// A narrow-band ("communications") output path kills the 12 kHz component
// while leaving 1 kHz intact, so the 12k/1k ratio is the measurement.
let label = CommandLine.arguments.dropFirst().first ?? "run"
let lowHz = 1000.0, highHz = 12000.0, dur = 3.0
let mode = CommandLine.arguments.first(where: { $0.hasPrefix("--tone=") })?
    .replacingOccurrences(of: "--tone=", with: "") ?? "both"
let playLow = (mode == "both" || mode == "low")
let playHigh = (mode == "both" || mode == "high")

let out = AVAudioEngine()
let player = AVAudioPlayerNode()
out.attach(player)
let sr = 48000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
out.connect(player, to: out.mainMixerNode, format: fmt)
let n = AVAudioFrameCount(sr * dur)
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
buf.frameLength = n
for ch in 0..<2 {
    let p = buf.floatChannelData![ch]
    for i in 0..<Int(n) {
        let t = Double(i) / sr
        p[i] = Float((playLow ? 0.16 * sin(2 * .pi * lowHz * t) : 0)
                   + (playHigh ? 0.16 * sin(2 * .pi * highHz * t) : 0))
    }
}

let mic = AVAudioEngine()
let input = mic.inputNode
let inFmt = input.outputFormat(forBus: 0)
let nch = Int(inFmt.channelCount)
var perCh = [[Float]](repeating: [], count: nch)
let lock = NSLock()
input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { b, _ in
    guard let d = b.floatChannelData else { return }
    lock.lock()
    for c in 0..<nch { for i in 0..<Int(b.frameLength) { perCh[c].append(d[c][i]) } }
    lock.unlock()
}
do { try mic.start(); try out.start() } catch { print("engine failed: \(error)"); exit(1) }
player.scheduleBuffer(buf, at: nil, options: [])
player.play()
Thread.sleep(forTimeInterval: dur + 0.4)
player.stop(); out.stop(); mic.stop()

lock.lock(); let chans = perCh; lock.unlock()
// Pick the highest-energy channel, exactly as AmbientListener.downmixAndResample
// does: a multichannel device routes the real mic to ONE channel and leaves the
// rest silent, so a naive channel-0 read measures silence and reports a bug.
var bestCh = 0, bestEnergy = 0.0
for (c, x) in chans.enumerated() {
    let e = x.reduce(0.0) { $0 + abs(Double($1)) }
    if e > bestEnergy { bestEnergy = e; bestCh = c }
}
let samples = chans.isEmpty ? [] : chans[bestCh]
let rate = inFmt.sampleRate
// Goertzel power at one frequency.
func power(_ x: [Float], _ f: Double, _ sr: Double) -> Double {
    guard x.count > 16 else { return 0 }
    let k = 2 * cos(2 * .pi * f / sr)
    var s0 = 0.0, s1 = 0.0, s2 = 0.0
    for v in x { s0 = Double(v) + k * s1 - s2; s2 = s1; s1 = s0 }
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(x.count)
}
// Skip the first 0.5s (playback ramp-up) and use the middle of the capture.
let skip = min(samples.count, Int(rate * 0.6))
let body = Array(samples[skip...])
let pl = power(body, lowHz, rate), ph = power(body, highHz, rate)
let db = { (p: Double) in 10 * log10(max(p, 1e-20)) }
print(String(format: "%-14@  n=%6d @%.0fHz %dch(used ch%d)  1kHz=%7.1fdB  12kHz=%7.1fdB  ratio(12k-1k)=%7.1fdB",
             ("\(label)[\(mode)]") as NSString, body.count, rate, inFmt.channelCount, bestCh, db(pl), db(ph), db(ph) - db(pl)))
