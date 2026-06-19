#if os(macOS)
import SwiftUI

/// macOS record panel (sheet): live metering, presets, real-time filters,
/// monitoring, input-source selection, and Approve/Discard onto a track.
struct MacRecordPanel: View {
    @ObservedObject var editor: ProjectEditorViewModel
    @StateObject private var vm: RecordSessionViewModel
    @EnvironmentObject private var recordingService: RecordingService
    @EnvironmentObject private var playback: PlaybackService
    @EnvironmentObject private var session: AudioSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var levels: [Float] = []
    @State private var level: Float = 0
    @State private var targetTrackID: UUID?

    init(editor: ProjectEditorViewModel) {
        self.editor = editor
        _vm = StateObject(wrappedValue: RecordSessionViewModel(env: editor.env))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Record").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { vm.cancelAll(); dismiss() }
            }
            .padding()
            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(spacing: 18) {
                    waveformCard
                    transport
                    if vm.hasTake { takeActions } else {
                        inputRow
                        monitorRow
                    }
                    presetSection
                    mixSection
                    Card { EffectRackView(chain: $vm.chain) { vm.chainChanged() } }.sectionHeader("Effect Rack")
                }
                .padding()
            }
        }
        .frame(width: 520, height: 720)
        .background(Theme.background)
        .onReceive(recordingService.waveform.$levels) { levels = $0 }
        .onReceive(recordingService.waveform.$currentLevel) { level = $0 }
        .onAppear {
            targetTrackID = editor.selectedTrackID ?? editor.project.tracks.first?.id
            vm.backingProvider = { editor.project }   // hear existing tracks while recording
            Task { await vm.appear() }
        }
        .onDisappear { vm.cancelAll() }
    }

    private var waveformCard: some View {
        Card {
            VStack(spacing: 10) {
                ZStack {
                    if levels.allSatisfy({ $0 < 0.001 }) {
                        Text(vm.isRecording ? "Listening…" : (vm.hasTake ? "Take ready" : "Speak to see your voice"))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    WaveformView(levels: levels, color: vm.isRecording ? Theme.recordRed : Theme.accent)
                        .animation(.easeOut(duration: 0.05), value: levels)
                }
                .frame(height: 120)
                Text(formatTime(recordingService.elapsedTime))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
    }

    private var transport: some View {
        Button { Task { await vm.toggleRecording() } } label: {
            ZStack {
                Circle().fill((vm.isRecording ? Theme.recordRed : Theme.accent).opacity(0.18))
                    .frame(width: 72, height: 72)
                    .scaleEffect(1 + CGFloat(min(level, 1)) * 0.7)
                    .animation(.easeOut(duration: 0.08), value: level)
                Circle().fill(vm.isRecording ? Theme.surfaceElevated : Theme.recordRed).frame(width: 72, height: 72)
                if vm.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.recordRed).frame(width: 26, height: 26)
                } else { Circle().fill(.white).frame(width: 26, height: 26) }
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.hasTake).opacity(vm.hasTake ? 0.4 : 1)
        .accessibilityLabel(vm.isRecording ? "Stop recording" : "Start recording")
    }

    private var inputRow: some View {
        Card {
            HStack {
                Label("Input Source", systemImage: "mic.and.signal.meter")
                Spacer()
                DevicePicker(title: "Input", systemImage: "mic",
                             options: session.availableInputs,
                             selected: session.selectedInputUID) { session.selectInput(uid: $0) }
                    .tint(Theme.accent)
            }
        }
    }

    private var monitorRow: some View {
        Card {
            Toggle(isOn: Binding(get: { vm.monitorEnabled }, set: { vm.setMonitoring($0) })) {
                Label("Live Monitoring (use headphones)", systemImage: "headphones")
            }.tint(Theme.accent)
        }
    }

    private var takeActions: some View {
        Card {
            VStack(spacing: 12) {
                if editor.project.tracks.count > 1 {
                    Picker("Add to track", selection: $targetTrackID) {
                        ForEach(editor.project.tracks) { Text($0.name).tag(Optional($0.id)) }
                    }.tint(Theme.accent)
                }
                if vm.isOverdubTake {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Backing Sync").font(.subheadline)
                            Spacer()
                            Text("\(Int(vm.syncOffsetMs)) ms").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Slider(value: $vm.syncOffsetMs, in: -100...400, step: 5).tint(Theme.accent)
                        Text("If your take sounds late vs the music, slide right. Re-approve to apply.")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { vm.togglePreview() } label: {
                        Label(playback.isPlaying ? "Stop" : "Listen",
                              systemImage: playback.isPlaying ? "stop.fill" : "play.fill").frame(maxWidth: .infinity)
                    }.tint(Theme.accent)
                    Button(role: .destructive) { vm.discardTake() } label: {
                        Label("Discard", systemImage: "trash").frame(maxWidth: .infinity)
                    }.tint(Theme.recordRed)
                }
                Button { vm.approve(into: editor, trackID: targetTrackID); dismiss() } label: {
                    Label("Approve & Add to Track", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }.sectionHeader("Your Take")
    }

    private var presetSection: some View {
        Card { PresetPickerView(selectedPresetID: $vm.selectedPresetID, currentChain: vm.chain) { vm.applyChain($0) } }
            .sectionHeader("Voice Preset")
    }

    private var mixSection: some View {
        Card {
            VStack(spacing: 14) {
                LabeledSlider(title: "Wet / Dry", value: Binding(get: { vm.wetDry }, set: { vm.wetDry = $0 }))
                LabeledSlider(title: "Intensity", value: Binding(get: { vm.intensity }, set: { vm.intensity = $0 }),
                              range: 0...1.5, tint: Theme.accentWarm)
            }
        }.sectionHeader("Mix")
    }
}
#endif
