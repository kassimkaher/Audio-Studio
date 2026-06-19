import Foundation
import AVFoundation

// Generates synthetic impulse responses (mono 48k WAV) that emulate acoustic
// spaces: a direct impulse + early reflections + a band-shaped, exponentially
// decaying diffuse tail. Placeholders — swap in real field recordings later.

let sampleRate = 48_000.0

struct Space { let name: String; let decay: Double; let predelayMs: Double; let reflections: Int; let lowpass: Float }

let spaces = [
    Space(name: "Studio",       decay: 0.28, predelayMs: 6,  reflections: 6,  lowpass: 0.30),
    Space(name: "HussainiHall", decay: 0.95, predelayMs: 16, reflections: 12, lowpass: 0.22),
    Space(name: "GrandMosque",  decay: 2.6,  predelayMs: 32, reflections: 18, lowpass: 0.16),
]

func makeIR(_ s: Space) -> [Float] {
    let length = Int((s.decay * 1.2) * sampleRate)
    var ir = [Float](repeating: 0, count: max(1, length))

    // Direct sound.
    ir[0] = 1.0
    // Early reflections.
    let pre = Int(s.predelayMs / 1000.0 * sampleRate)
    for r in 0..<s.reflections {
        let t = pre + Int(Double.random(in: 0...(0.06)) * sampleRate) + r * Int(0.004 * sampleRate)
        if t < ir.count { ir[t] += Float.random(in: 0.2...0.6) * (r % 2 == 0 ? 1 : -1) }
    }
    // Diffuse decaying-noise tail (band-limited via a one-pole lowpass).
    var lp: Float = 0
    for n in pre..<ir.count {
        let env = Float(exp(-Double(n) / (s.decay * sampleRate / 6.0)))
        let noise = Float.random(in: -1...1) * env
        lp += s.lowpass * (noise - lp)
        ir[n] += lp
    }
    // Normalize peak.
    var peak: Float = 0
    for v in ir { peak = max(peak, abs(v)) }
    if peak > 0 { let g = 0.9 / peak; for i in ir.indices { ir[i] *= g } }
    return ir
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
for s in spaces {
    let samples = makeIR(s)
    let url = outDir.appendingPathComponent("\(s.name).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    for i in samples.indices { buf.floatChannelData![0][i] = samples[i] }
    try file.write(from: buf)
    print("wrote \(url.lastPathComponent) (\(samples.count) samples, \(String(format: "%.2f", Double(samples.count)/sampleRate))s)")
}
