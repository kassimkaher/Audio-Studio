import SwiftUI
import UIKit

/// Full-screen capture flow: record with live, audible filter changes, then
/// Approve the take onto a track or Discard it.
struct RecordSessionView: View {
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
        NavigationStack {
            ZStack {
                Theme.screenBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        waveformCard
                        transport
                        if vm.hasTake { takeActions } else {
                            inputSourceCard
                            monitorRow
                            audienceCard
                        }
                        presetSection
                        mixSection
                        effectRackSection
                    }
                    .padding()
                }
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { vm.cancelAll(); dismiss() }
                }
            }
        }
        .onReceive(recordingService.waveform.$levels) { levels = $0 }
        .onReceive(recordingService.waveform.$currentLevel) { level = $0 }
        .onAppear {
            targetTrackID = editor.selectedTrackID ?? editor.project.tracks.first?.id
            vm.backingProvider = { editor.project }   // hear existing tracks while recording
            Task { await vm.appear() }
        }
        .onDisappear { vm.cancelAll() }
        .alert("Microphone Access Needed", isPresented: $vm.showPermissionDenied) {
            Button("Open Settings") { openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Enable microphone access in Settings to record.") }
        .alert("Recording Error",
               isPresented: Binding(get: { vm.errorMessage != nil },
                                    set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.errorMessage ?? "") }
    }

    // MARK: Sections

    private var waveformCard: some View {
        Card {
            VStack(spacing: 12) {
                ZStack {
                    if levels.allSatisfy({ $0 < 0.001 }) {
                        Text(vm.isRecording ? "Listening…" :
                                (vm.hasTake ? "Take ready" :
                                    (vm.isMonitoringLive ? "Speak to see your voice" : "Tap record to begin")))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    WaveformView(levels: levels, color: vm.isRecording ? Theme.recordRed : Theme.accent)
                        .animation(.easeOut(duration: 0.05), value: levels)
                }
                .frame(height: 130)
                Text(formatTime(recordingService.elapsedTime))
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
    }

    private var transport: some View {
        Button { Task { await vm.toggleRecording() } } label: {
            ZStack {
                // Live level halo — grows with the incoming voice.
                Circle()
                    .fill((vm.isRecording ? Theme.recordRed : Theme.accent).opacity(0.18))
                    .frame(width: 78, height: 78)
                    .scaleEffect(1 + CGFloat(min(level, 1)) * 0.7)
                    .animation(.easeOut(duration: 0.08), value: level)

                Circle().fill(vm.isRecording ? Theme.surfaceElevated : Theme.recordRed)
                    .frame(width: 78, height: 78)
                if vm.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.recordRed).frame(width: 28, height: 28)
                } else {
                    Circle().fill(.white).frame(width: 28, height: 28)
                }
            }
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 2).frame(width: 78, height: 78))
        }
        .accessibilityLabel(vm.isRecording ? "Stop recording" : "Start recording")
        .disabled(vm.hasTake)
        .opacity(vm.hasTake ? 0.4 : 1)
    }

    private var takeActions: some View {
        Card {
            VStack(spacing: 14) {
                if editor.project.tracks.count > 1 {
                    Picker("Add to track", selection: $targetTrackID) {
                        ForEach(editor.project.tracks) { t in Text(t.name).tag(Optional(t.id)) }
                    }
                    .pickerStyle(.menu).tint(Theme.accent)
                }
                if vm.isOverdubTake { syncTuner }
                Toggle(isOn: Binding(get: { vm.isCrowdDesignatedTake }, set: { vm.isCrowdDesignatedTake = $0 })) {
                    Label("Crowd / Raddah Take", systemImage: "person.2.wave.2.fill")
                }
                .tint(Theme.accent)
                HStack(spacing: 12) {
                    Button { vm.togglePreview() } label: {
                        Label(playback.isPlaying ? "Stop" : "Listen",
                              systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)

                    Button(role: .destructive) { vm.discardTake() } label: {
                        Label("Discard", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(Theme.recordRed)
                }
                Button {
                    vm.approve(into: editor, trackID: targetTrackID)
                    dismiss()
                } label: {
                    Label("Approve & Add to Track", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .sectionHeader("Your Take")
    }

    private var syncTuner: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    private var inputSourceCard: some View {
        Card {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text("Input Source")
                        Text("Choose which microphone to record from")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                } icon: { Image(systemName: "mic.and.signal.meter") }
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
                Label {
                    VStack(alignment: .leading) {
                        Text("Live Monitoring")
                        Text("Hear effects while recording (use headphones)")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                } icon: { Image(systemName: "headphones") }
            }
            .tint(Theme.accent)
        }
    }

    /// Live Audience / Majlis atmosphere: crowd bed + auto-ducking under the voice.
    private var audienceCard: some View {
        AudienceControlsView(
            enabled: Binding(get: { vm.audienceModeEnabled }, set: { vm.audienceModeEnabled = $0 }),
            crowdVolume: Binding(get: { vm.crowdVolume }, set: { vm.crowdVolume = $0 }),
            duckingAmountDb: Binding(get: { vm.duckingAmountDb }, set: { vm.duckingAmountDb = $0 }),
            sensitivity: Binding(get: { vm.duckingSensitivity }, set: { vm.duckingSensitivity = $0 }),
            designateAsCrowdTake: Binding(get: { vm.isCrowdDesignatedTake }, set: { vm.isCrowdDesignatedTake = $0 }))
    }

    private var presetSection: some View {
        Card {
            PresetPickerView(selectedPresetID: $vm.selectedPresetID, currentChain: vm.chain) { vm.applyChain($0) }
        }.sectionHeader("Voice Preset")
    }

    private var mixSection: some View {
        Card {
            VStack(spacing: 16) {
                LabeledSlider(title: "Wet / Dry",
                              value: Binding(get: { vm.wetDry }, set: { vm.wetDry = $0 }))
                LabeledSlider(title: "Intensity",
                              value: Binding(get: { vm.intensity }, set: { vm.intensity = $0 }),
                              range: 0...1.5, tint: Theme.accentWarm)
            }
        }.sectionHeader("Mix")
    }

    private var effectRackSection: some View {
        Card { EffectRackView(chain: $vm.chain) { vm.chainChanged() } }
            .sectionHeader("Effect Rack")
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
