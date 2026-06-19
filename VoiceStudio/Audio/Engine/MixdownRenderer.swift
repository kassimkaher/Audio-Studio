import Foundation
import AVFoundation
import Combine

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav = "WAV"
    case m4a = "M4A"
    var id: String { rawValue }
    var fileExtension: String { self == .wav ? "wav" : "m4a" }
    var subtitle: String { self == .wav ? "Lossless · 24-bit/48k" : "Compressed AAC · smaller file" }
}

/// Renders the dual-track montage to a single file by running the *exact* live
/// effect graph in `AVAudioEngine` offline (manual rendering) mode.
///
/// `AVAssetExportSession`/`AVAudioMix` can only do volume ramps and taps — they
/// cannot host arbitrary `AVAudioUnit` chains — so manual rendering is the
/// correct path for baking effects into the export. Extra tail frames are
/// rendered so long reverb decays are not cut off.
@MainActor
final class MixdownRenderer: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isRendering = false

    /// Seconds of extra audio rendered past the last clip to capture reverb tails.
    private let tailSeconds: Double = 6.0

    func render(project: Project, format: ExportFormat) async throws -> URL {
        guard project.totalFrames > 0 else { throw MixdownError.empty }
        isRendering = true
        progress = 0
        defer { isRendering = false }

        let sampleRate = project.sampleRate
        let tailFrames = AVAudioFramePosition(tailSeconds * sampleRate)
        let totalFrames = project.totalFrames + tailFrames

        let outName = "\(project.name)-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
            .replacingOccurrences(of: " ", with: "_")
        let outURL = AppPaths.exportsDirectory.appendingPathComponent(outName)
        try? FileManager.default.removeItem(at: outURL)

        // Hop to a background task; report progress back on the main actor.
        try await Task.detached(priority: .userInitiated) {
            try Self.performRender(project: project,
                                   format: format,
                                   outURL: outURL,
                                   totalFrames: totalFrames,
                                   progress: { p in Task { @MainActor in self.progress = p } })
        }.value

        progress = 1
        return outURL
    }

    private nonisolated static func performRender(project: Project,
                                                  format: ExportFormat,
                                                  outURL: URL,
                                                  totalFrames: AVAudioFramePosition,
                                                  progress: @escaping (Double) -> Void) throws {
        let engine = AVAudioEngine()
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: project.sampleRate,
                                         channels: AudioFormatConstants.mixdownChannelCount)!

        var players: [AVAudioPlayerNode] = []
        var chains: [ProcessingChain] = []
        var openFiles: [UUID: AVAudioFile] = [:]

        func openFile(_ sourceID: UUID) -> AVAudioFile? {
            if let f = openFiles[sourceID] { return f }
            guard let source = project.source(for: sourceID),
                  let f = try? AVAudioFile(forReading: source.url) else { return nil }
            openFiles[sourceID] = f
            return f
        }

        // Per-clip routing (mirrors PlaybackService): each clip → optional clip
        // chain → track sum mixer → track master chain → track gain → main.
        for track in project.tracks where project.isAudible(track) {
            let sumMixer = AVAudioMixerNode()
            let gainMixer = AVAudioMixerNode()
            engine.attach(sumMixer)
            engine.attach(gainMixer)

            for clip in track.clips {
                guard let file = openFile(clip.sourceID), clip.frameLength > 0 else { continue }
                let fileFormat = file.processingFormat
                let player = AVAudioPlayerNode()
                engine.attach(player)

                if let clipSpec = clip.effectChain {
                    let proc = AVAudioFormat(standardFormatWithSampleRate: fileFormat.sampleRate,
                                             channels: AudioFormatConstants.mixdownChannelCount) ?? fileFormat
                    let clipChain = ProcessingChain(spec: clipSpec)
                    let out = clipChain.install(into: engine, source: player,
                                                sourceFormat: fileFormat, processingFormat: proc)
                    engine.connect(out, to: sumMixer, format: proc)
                    chains.append(clipChain)
                } else {
                    engine.connect(player, to: sumMixer, format: fileFormat)
                }

                let when = AVAudioTime(sampleTime: clip.timelineStartFrame, atRate: fileFormat.sampleRate)
                player.scheduleSegment(file,
                                       startingFrame: clip.sourceInFrame,
                                       frameCount: AVAudioFrameCount(clip.frameLength),
                                       at: when)
                players.append(player)
            }

            let masterChain = ProcessingChain(spec: track.effectChain)
            let out = masterChain.install(into: engine, source: sumMixer,
                                          sourceFormat: renderFormat, processingFormat: renderFormat)
            engine.connect(out, to: gainMixer, format: renderFormat)
            engine.connect(gainMixer, to: engine.mainMixerNode, format: renderFormat)
            gainMixer.outputVolume = track.volume
            chains.append(masterChain)
        }

        guard !players.isEmpty else { throw MixdownError.empty }

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        try engine.start()
        players.forEach { $0.play() }

        let outFile = try makeOutputFile(url: outURL, format: format, renderFormat: renderFormat, project: project)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw MixdownError.bufferAllocation
        }

        var rendered: AVAudioFramePosition = 0
        while rendered < totalFrames {
            let remaining = totalFrames - rendered
            let toRender = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), remaining))
            let status = try engine.renderOffline(toRender, to: buffer)
            switch status {
            case .success:
                try outFile.write(from: buffer)
                rendered += AVAudioFramePosition(buffer.frameLength)
                progress(Double(rendered) / Double(totalFrames))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw MixdownError.renderFailed
            @unknown default:
                throw MixdownError.renderFailed
            }
        }

        engine.stop()
        players.forEach { $0.stop() }
        _ = chains   // retained until here
    }

    private nonisolated static func makeOutputFile(url: URL,
                                                   format: ExportFormat,
                                                   renderFormat: AVAudioFormat,
                                                   project: Project) throws -> AVAudioFile {
        switch format {
        case .wav:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: project.sampleRate,
                AVNumberOfChannelsKey: AudioFormatConstants.mixdownChannelCount,
                AVLinearPCMBitDepthKey: AudioFormatConstants.bitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        case .m4a:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: project.sampleRate,
                AVNumberOfChannelsKey: AudioFormatConstants.mixdownChannelCount,
                AVEncoderBitRateKey: 192_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }
}

enum MixdownError: LocalizedError {
    case empty, bufferAllocation, renderFailed
    var errorDescription: String? {
        switch self {
        case .empty: return "There is nothing to export yet. Record or add audio first."
        case .bufferAllocation: return "Could not allocate the render buffer."
        case .renderFailed: return "The mixdown failed while rendering."
        }
    }
}
