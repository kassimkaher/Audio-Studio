#if os(macOS)
import SwiftUI

/// Zone 1 — the global transport & status bar: glossy media controls, a glowing
/// teal monospaced timecode, audio I/O device selectors, and Export. Recording
/// state is reflected by a pulsing red record button + red timecode (the window
/// border is drawn by `MacRootView`).
struct StudioTopBar: View {
    @ObservedObject var editor: ProjectEditorViewModel
    @EnvironmentObject private var playback: PlaybackService
    @EnvironmentObject private var session: AudioSessionManager
    @EnvironmentObject private var recordingService: RecordingService
    @EnvironmentObject private var mobileLink: MobileLinkService

    var onRecord: () -> Void
    var onExport: () -> Void

    @State private var pulse = false
    @State private var showLink = false

    private var isRecording: Bool { recordingService.isRecording }
    private var timecode: String { formatTimecode(Double(playback.currentFrame) / editor.sampleRate) }

    var body: some View {
        HStack(spacing: 16) {
            wordmark
            transport
            Spacer(minLength: 12)
            center
            Spacer(minLength: 12)
            rightControls
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private var wordmark: some View {
        HStack(spacing: 4) {
            Text("VOICE STUDIO").font(.system(size: 13, weight: .bold)).tracking(0.5)
                .foregroundStyle(Theme.accent).neonGlow(Theme.accent, radius: 4)
            Text("PRO").font(.system(size: 13, weight: .bold)).tracking(0.5)
                .foregroundStyle(Theme.accentWarm)
        }
    }

    // MARK: Transport (left)

    private var transport: some View {
        HStack(spacing: 10) {
            glossy("backward.end.fill", help: "Rewind to start") { editor.stopPlayback() }
            glossy(playback.isPlaying ? "pause.fill" : "play.fill",
                   tint: Theme.accent, help: "Play / Pause (Space)") { editor.togglePlay() }
            recordButton
        }
    }

    private var recordButton: some View {
        Button(action: onRecord) {
            ZStack {
                Circle().fill(Theme.surfaceElevated).frame(width: 34, height: 34)
                Circle().fill(Theme.recordRed)
                    .frame(width: isRecording ? 14 : 16, height: isRecording ? 14 : 16)
                    .opacity(isRecording && pulse ? 0.4 : 1)
            }
            .overlay(Circle().stroke(isRecording ? Theme.recordRed : .white.opacity(0.1), lineWidth: 1.5)
                .frame(width: 34, height: 34))
        }
        .buttonStyle(.plain)
        .help("Record on the armed track")
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } }
    }

    // MARK: Center (title + timecode)

    private var center: some View {
        VStack(spacing: 2) {
            Text(editor.project.name)
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timecode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .modifier(TimecodeStyle(recording: isRecording))
                Text("/ \(formatTimecode(editor.project.duration))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Right (I/O + export)

    private var rightControls: some View {
        HStack(spacing: 10) {
            DevicePicker(title: "In:", systemImage: "mic", options: session.availableInputs,
                         selected: session.selectedInputUID) { session.selectInput(uid: $0) }
                .help("Input device")
            if session.inputGain != nil {
                HStack(spacing: 4) {
                    Image(systemName: "dial.medium").font(.caption2).foregroundStyle(Theme.textSecondary)
                    Slider(value: Binding(get: { session.inputGain ?? 1 },
                                          set: { session.setInputGain($0) }), in: 0...1)
                        .frame(width: 64).controlSize(.mini).tint(Theme.accent)
                }
                .help("Mic input gain — lower this if recordings clip/distort")
            }
            DevicePicker(title: "Out:", systemImage: "hifispeaker", options: session.availableOutputs,
                         selected: session.selectedOutputUID) { session.selectOutput(uid: $0) }
                .help("Output device")
            linkMobileButton
            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(editor.project.totalFrames == 0)
            .help("Export Mixdown")
        }
    }

    // MARK: Link Mobile (Wi-Fi mic)

    private var linkMobileButton: some View {
        Button { showLink = true } label: {
            Label("Link Mobile", systemImage: mobileLink.isConnected ? "iphone.radiowaves.left.and.right" : "iphone")
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background((mobileLink.isConnected ? Theme.accentWarm : Theme.accent).opacity(0.16))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(mobileLink.isConnected ? Theme.accentWarm : Theme.accent)
        .help("Use your phone as a wireless mic")
        .popover(isPresented: $showLink, arrowEdge: .bottom) { linkPopover }
        .onAppear { mobileLink.start() }     // advertise on the network so the phone can find the Mac
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                Text("Link Mobile Device").font(.headline)
            }
            Divider().overlay(Theme.hairline)

            if mobileLink.isConnected {
                Label("iPhone connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentWarm)
                HStack(spacing: 6) {
                    Image(systemName: mobileLink.bufferedMs > 0 ? "waveform" : "waveform.slash")
                        .foregroundStyle(mobileLink.bufferedMs > 0 ? Theme.accent : Theme.recordRed)
                    Text(mobileLink.bufferedMs > 0
                         ? "Receiving audio · \(mobileLink.bufferedMs) ms buffered"
                         : "Connected, but no audio arriving")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Text("Select **📱 iPhone (Wi-Fi)** in the In: menu, arm a lane, and record.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text("On the same Wi-Fi, open **Voice Studio Mic** on your iPhone — it finds this Mac automatically.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let ep = mobileLink.endpoint {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi").foregroundStyle(Theme.accent)
                        Text(ep).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceElevated).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(mobileLink.isAdvertising ? "Waiting for your phone…" : "Starting…")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(16).frame(width: 300)
    }

    private func glossy(_ symbol: String, tint: Color = Theme.textPrimary,
                        help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceElevated)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Glowing-teal timecode normally; solid red while recording.
private struct TimecodeStyle: ViewModifier {
    let recording: Bool
    func body(content: Content) -> some View {
        if recording {
            content.foregroundStyle(Theme.recordRed)
                .shadow(color: Theme.recordRed.opacity(0.7), radius: 8)
        } else {
            content.tealGlow()
        }
    }
}
#endif
