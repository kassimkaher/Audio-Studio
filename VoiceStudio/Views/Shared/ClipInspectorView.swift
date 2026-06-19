import SwiftUI
import AVFoundation

/// Per-clip editor (Audition-style): rename, gain, fades, solo-listen, delete, and
/// the clip's own effect chain (preset + wet/dry + intensity + stage toggles).
struct ClipInspectorView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    let clipID: UUID
    @EnvironmentObject private var playback: PlaybackService
    @Environment(\.dismiss) private var dismiss

    @State private var clip: Clip?
    @State private var source: AudioSource?
    @State private var fxEnabled = false
    @State private var chain: EffectChainSpec = PresetLibrary.general.chain
    @State private var presetID = PresetLibrary.general.id

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.screenBackground.ignoresSafeArea()
                if clip != nil {
                    ScrollView {
                        VStack(spacing: 20) {
                            infoCard
                            effectsToggleCard
                            if fxEnabled {
                                presetCard
                                mixCard
                                rackCard
                            }
                            clipActions
                            deleteButton
                        }
                        .padding()
                    }
                } else {
                    Text("Clip not found").foregroundStyle(Theme.textSecondary)
                }
            }
            .navigationTitle("Edit Clip")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Done") { commit(); dismiss() } } }
        }
        .onAppear(perform: load)
        .onDisappear { playback.stop() }
    }

    private func load() {
        guard let found = editor.clip(clipID) else { return }
        clip = found.clip
        source = found.source
        if let c = found.clip.effectChain {
            fxEnabled = true
            chain = c
            presetID = PresetLibrary.all.first { $0.chain.stages.map(\.kind) == c.stages.map(\.kind) }?.id ?? ""
        }
    }

    // MARK: Cards

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Clip name", text: Binding(
                    get: { clip?.name ?? "" },
                    set: { clip?.name = $0 }))
                    .font(.headline).textFieldStyle(.roundedBorder)

                LabeledSlider(title: "Voice Volume",
                              value: Binding(get: { clip?.gain ?? 1 }, set: { clip?.gain = $0 }),
                              range: 0...2, format: { String(format: "%.0f%%", $0 * 100) })

                if editor.project.tracks.count > 1 {
                    HStack {
                        Text("Track").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { editor.trackID(ofClip: clipID) ?? editor.project.tracks.first!.id },
                            set: { moveToTrack($0) })) {
                            ForEach(editor.project.tracks) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().pickerStyle(.menu).tint(Theme.accent)
                    }
                }

                positionRow

                Button { soloListen() } label: {
                    Label(playback.isPlaying ? "Stop" : "Listen (solo)",
                          systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(Theme.accent)
            }
        }
    }

    private var effectsToggleCard: some View {
        Card {
            Toggle(isOn: Binding(get: { fxEnabled }, set: { setFXEnabled($0) })) {
                Label {
                    VStack(alignment: .leading) {
                        Text("Clip Effects")
                        Text("Apply filters to just this clip")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                } icon: { Image(systemName: "wand.and.stars") }
            }
            .tint(Theme.accent)
        }
    }

    private var presetCard: some View {
        Card {
            PresetPickerView(selectedPresetID: $presetID, currentChain: chain) { newChain in
                chain = newChain; commit()
            }
        }.sectionHeader("Preset")
    }

    private var mixCard: some View {
        Card {
            VStack(spacing: 16) {
                LabeledSlider(title: "Wet / Dry",
                              value: Binding(get: { chain.wetDryMix }, set: { chain.wetDryMix = $0; commit() }))
                LabeledSlider(title: "Intensity",
                              value: Binding(get: { chain.intensity }, set: { chain.intensity = $0; commit() }),
                              range: 0...1.5, tint: Theme.accentWarm)
            }
        }.sectionHeader("Mix")
    }

    private var rackCard: some View {
        Card { EffectRackView(chain: $chain) { commit() } }.sectionHeader("Effect Rack")
    }

    /// Gesture-free clip positioning (drag fights the scrolling timeline).
    private var positionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position").font(.caption).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                nudge("−1s", -1.0); nudge("−0.1s", -0.1)
                Button { editor.setClipStart(clipID, toFrame: playback.currentFrame) } label: {
                    Image(systemName: "arrow.right.to.line")
                }.buttonStyle(.bordered).tint(Theme.accent)
                nudge("+0.1s", 0.1); nudge("+1s", 1.0)
            }
        }
    }

    private func nudge(_ label: String, _ seconds: Double) -> some View {
        Button(label) {
            editor.nudgeClip(clipID, byFrames: AVAudioFramePosition(seconds * editor.sampleRate))
        }
        .buttonStyle(.bordered).tint(Theme.accent).font(.caption)
    }

    private var clipActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { editor.duplicateClip(clipID); dismiss() } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(Theme.accent)
                Button { splitAtPlayhead() } label: {
                    Label("Split", systemImage: "scissors").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(Theme.accent)
            }
            Button { editor.duplicateClipToNewTrack(clipID); dismiss() } label: {
                Label("Duplicate to New Track", systemImage: "rectangle.stack.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(Theme.accent)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            editor.deleteClipAnywhere(clipID); dismiss()
        } label: {
            Label("Delete Clip", systemImage: "trash").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(Theme.recordRed)
    }

    private func splitAtPlayhead() {
        if editor.splitClip(clipID, atFrame: playback.currentFrame) { dismiss() }
    }

    // MARK: Actions

    private func setFXEnabled(_ on: Bool) {
        fxEnabled = on
        if on && (clip?.effectChain == nil) {
            chain = PresetLibrary.general.chain
            presetID = PresetLibrary.general.id
        }
        commit()
    }

    private func commit() {
        guard var c = clip else { return }
        c.effectChain = fxEnabled ? chain : nil
        clip = c
        editor.commitClip(c)                       // live-updates if playing
        if !playback.isPlaying, let s = source {   // …else auto-play so edits are heard
            playback.previewClip(c, source: s, loop: true)
        }
    }

    private func moveToTrack(_ trackID: UUID) {
        guard let c = clip else { return }
        editor.moveClip(clipID, toTrack: trackID, atFrame: c.timelineStartFrame)
    }

    private func soloListen() {
        guard let c = clip, let s = source else { return }
        if playback.isPlaying { playback.stop() }
        else { playback.previewClip(c, source: s) }
    }
}
