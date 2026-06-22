import Foundation
import AVFoundation

// Generates the two synthetic assets for the Live Audience / Majlis engine:
//  • IRs/LiveMajlis.wav  — a crowd-absorptive convolution IR (dark, wide early
//    reflections, medium decay) so the voice sits in a packed hall.
//  • Audio/MajlisCrowd.wav — a loopable stereo ambience bed (low murmur + slow
//    talking modulation + periodic soft latm pulses) for the crowd lane.
// Placeholders — swap in real field recordings later (same filenames).

let sr = 48_000.0
let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func writeWav(_ samples: [[Float]], to url: URL) throws {
    let channels = AVAudioChannelCount(samples.count)
    let frames = AVAudioFrameCount(samples[0].count)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: channels, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for c in 0..<Int(channels) { for i in 0..<Int(frames) { buf.floatChannelData![c][i] = samples[c][i] } }
    try file.write(from: buf)
}

func normalize(_ s: inout [Float], peak target: Float) {
    var mx: Float = 0; for v in s { mx = max(mx, abs(v)) }
    if mx > 0 { let g = target / mx; for i in s.indices { s[i] *= g } }
}

// MARK: Live Majlis IR — crowd absorption
func makeLiveMajlisIR() -> [Float] {
    let decay = 0.75
    let length = Int(decay * 1.2 * sr)
    var ir = [Float](repeating: 0, count: length)
    ir[0] = 1.0
    // Wide early reflections (a packed hall scatters sound) in the first ~45 ms.
    let pre = Int(0.012 * sr)
    for r in 0..<16 {
        let t = pre + Int(Double.random(in: 0...0.045) * sr) + r * Int(0.003 * sr)
        if t < ir.count { ir[t] += Float.random(in: 0.25...0.55) * (r % 2 == 0 ? 1 : -1) }
    }
    // Heavily low-passed decaying tail = high-frequency absorption by the crowd.
    var lp: Float = 0
    let cutoff: Float = 0.10   // darker than an empty hall
    for n in pre..<ir.count {
        let env = Float(exp(-Double(n) / (decay * sr / 6.0)))
        lp += cutoff * (Float.random(in: -1...1) * env - lp)
        ir[n] += lp
    }
    normalize(&ir, peak: 0.9)
    return ir
}

// MARK: Majlis crowd ambience bed (loopable, stereo)
func makeCrowdBed() -> [[Float]] {
    let seconds = 10.0
    let n = Int(seconds * sr)
    func channel(seed: Float) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        // Low murmur: low-passed noise.
        var lp: Float = 0
        // Mid talking: band-ish noise with slow amplitude modulation.
        var bp: Float = 0, bpPrev: Float = 0
        for i in 0..<n {
            let t = Double(i) / sr
            let noise = Float.random(in: -1...1)
            lp += 0.04 * (noise - lp)                                  // ~rumble
            let mid = (noise - bpPrev); bpPrev = noise
            bp += 0.20 * (mid - bp)                                    // crude band-pass
            let talkMod = Float(0.5 + 0.5 * sin(2 * .pi * (0.15 + Double(seed) * 0.03) * t))
            out[i] = lp * 0.6 + bp * 0.25 * talkMod
        }
        // Periodic soft latm pulses (chest-beating) ~ every 0.55 s, humanized.
        var t = 0.30
        while t < seconds {
            let start = Int(t * sr)
            let dur = Int(0.10 * sr)
            for k in 0..<dur where start + k < n {
                let env = Float(exp(-Double(k) / (0.02 * sr)))         // fast decay thump
                out[start + k] += Float.random(in: -1...1) * env * 0.5
            }
            t += Double.random(in: 0.48...0.62)
        }
        return out
    }
    var left = channel(seed: 0)
    var right = channel(seed: 1)
    // Seamless loop: crossfade the last 0.5 s into the head.
    let xf = Int(0.5 * sr)
    func crossfade(_ s: inout [Float]) {
        for k in 0..<xf {
            let a = Float(k) / Float(xf)
            let tail = n - xf + k
            s[k] = s[k] * a + s[tail] * (1 - a)
        }
    }
    crossfade(&left); crossfade(&right)
    normalize(&left, peak: 0.6); normalize(&right, peak: 0.6)
    return [left, right]
}

let ir = makeLiveMajlisIR()
try writeWav([ir], to: resources.appendingPathComponent("IRs/LiveMajlis.wav"))
print("wrote IRs/LiveMajlis.wav (\(ir.count) samples)")

let bed = makeCrowdBed()
try writeWav(bed, to: resources.appendingPathComponent("Audio/MajlisCrowd.wav"))
print("wrote Audio/MajlisCrowd.wav (\(bed[0].count) frames, stereo)")
