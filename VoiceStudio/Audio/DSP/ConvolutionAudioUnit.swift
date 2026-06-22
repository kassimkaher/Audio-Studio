import Foundation
import AVFoundation
import Accelerate

/// Real-time, per-channel direct convolution of an input stream with an impulse
/// response, using `vDSP_conv` plus a carried input-history buffer. Correct for
/// any IR length; cost is O(frames · IRlength), so it's ideal for the short,
/// dense tails the signature acoustic preset uses. (FFT partitioning is a future
/// optimization for very long IRs.)
final class DirectConvolver {
    private var ir: [Float] = [0]            // reversed IR (for vDSP_conv → true convolution)
    private var irLength: Int = 1
    private var history: [Float] = []        // last (irLength-1) input samples
    private var work: [Float] = []           // history + current block scratch

    /// Sets the impulse response (natural order). Reverses it internally so
    /// `vDSP_conv` (which correlates) yields a true convolution.
    /// Max render block size to pre-size the work buffer for (avoids realloc on
    /// the audio thread).
    var maxFrames = 16_384

    /// Real-time cap on IR taps. Direct (time-domain) convolution costs
    /// `irLength` MACs *per output sample*, so a multi-second IR (100k+ taps) on
    /// several tracks overruns the render budget and glitches ("robotic"). Capping
    /// to ~0.25 s keeps the room character while staying real-time-safe when many
    /// tracks each run a convolution.
    /// Default real-time cap (~0.25 s @ 48 kHz). Offline export sets this to
    /// `.max` to keep the full-length, full-quality reverb tail.
    static let realtimeIRTaps = 12_000
    var maxIRTaps = DirectConvolver.realtimeIRTaps

    func setIR(_ samples: [Float]) {
        var normalized = samples.isEmpty ? [Float(0)] : samples
        if normalized.count > maxIRTaps {
            normalized = Array(normalized[0..<maxIRTaps])
            // Fade the truncated tail so the cut doesn't click.
            let fade = min(256, normalized.count)
            let start = normalized.count - fade
            for i in 0..<fade { normalized[start + i] *= Float(fade - i) / Float(fade) }
        }
        irLength = normalized.count
        ir = normalized.reversed()
        history = [Float](repeating: 0, count: max(0, irLength - 1))
        work = [Float](repeating: 0, count: history.count + maxFrames)
    }

    /// Convolves `count` input samples into `output` (wet signal only).
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, _ count: Int) {
        let h = irLength - 1
        let needed = h + count
        if work.count < needed { work = [Float](repeating: 0, count: needed) }   // safety net only

        work.withUnsafeMutableBufferPointer { w in
            // [ history(h) | input(count) ]
            for i in 0..<h { w[i] = history[i] }
            for i in 0..<count { w[h + i] = input[i] }

            ir.withUnsafeBufferPointer { f in
                // C[n] = Σ_p w[n+p]·fReversedIR[p] = Σ_q x[n-q]·ir[q]  → convolution.
                vDSP_conv(w.baseAddress!, 1, f.baseAddress!, 1, output, 1, vDSP_Length(count), vDSP_Length(irLength))
            }
            // Carry the last h input samples as history for the next block.
            if h > 0 {
                for i in 0..<h { history[i] = w[count + i] }
            }
        }
    }

    func reset() { for i in history.indices { history[i] = 0 } }
}

/// A custom in-process Audio Unit that applies IR convolution with a wet/dry mix,
/// hosted inside `AVAudioEngine` (there is no stock convolution AU in AVFoundation).
final class ConvolutionAudioUnit: AUAudioUnit {
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private var format: AVAudioFormat
    private var pcmBuffer: AVAudioPCMBuffer?

    private var convolvers: [DirectConvolver] = []
    private let kernelLock = NSLock()
    /// IR-tap cap applied to new convolvers. Real-time default; export sets `.max`.
    var capIRTaps: Int = DirectConvolver.realtimeIRTaps
    /// 0...1 wet/dry. Read on the render thread; written from the main thread.
    private var _mix: Float = 1.0
    var mix: Float {
        get { _mix }
        set { _mix = max(0, min(newValue, 1)) }
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                            busses: [try AUAudioUnitBus(format: format)])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                             busses: [try AUAudioUnitBus(format: format)])
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    /// Installs an IR (mono samples) applied to every channel. Built off the
    /// render thread; swapped under a lock.
    func setIR(_ samples: [Float]) {
        let channels = Int(format.channelCount)
        let mf = max(16_384, Int(maximumFramesToRender))
        let cap = capIRTaps
        let new = (0..<channels).map { _ -> DirectConvolver in
            let c = DirectConvolver(); c.maxFrames = mf; c.maxIRTaps = cap; c.setIR(samples); return c
        }
        kernelLock.lock(); convolvers = new; kernelLock.unlock()
    }

    override func allocateRenderResources() throws {
        format = outputBusArray[0].format
        try super.allocateRenderResources()
        pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFramesToRender))
        if convolvers.isEmpty {
            setIR([1])   // identity until an IR is loaded
        }
    }

    override func deallocateRenderResources() {
        pcmBuffer = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let lock = kernelLock
        return { [weak self] _, _, frameCount, _, outputData, _, pullInput in
            guard let self, let pull = pullInput else { return kAudioUnitErr_NoConnection }
            guard let pcm = self.pcmBuffer else { return kAudioUnitErr_Uninitialized }

            // Pull the upstream audio into our own buffer.
            let inputList = pcm.mutableAudioBufferList
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            let status = pull(&flags, &ts, frameCount, 0, inputList)
            if status != noErr { return status }

            let outList = UnsafeMutableAudioBufferListPointer(outputData)
            let inList = UnsafeMutableAudioBufferListPointer(inputList)
            let n = Int(frameCount)
            let mix = self._mix

            // Try to use the convolvers without blocking the render thread.
            let haveKernel = lock.try()
            defer { if haveKernel { lock.unlock() } }

            for ch in 0..<outList.count {
                guard ch < inList.count,
                      let outBuf = outList[ch].mData?.assumingMemoryBound(to: Float.self),
                      let inBuf = inList[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }

                if haveKernel, ch < self.convolvers.count, mix > 0 {
                    self.convolvers[ch].process(inBuf, outBuf, n)   // wet → outBuf
                    if mix < 1 {                                    // blend dry in-place (no alloc)
                        var wetGain = mix
                        var dryGain = 1 - mix
                        vDSP_vsmul(outBuf, 1, &wetGain, outBuf, 1, vDSP_Length(n))      // outBuf *= wet
                        vDSP_vsma(inBuf, 1, &dryGain, outBuf, 1, outBuf, 1, vDSP_Length(n)) // outBuf += in*dry
                    }
                } else {
                    // No kernel / fully dry / mid-swap: pass through.
                    memcpy(outBuf, inBuf, n * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
    }
}
