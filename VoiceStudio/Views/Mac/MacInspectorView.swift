#if os(macOS)
import SwiftUI
import AVFoundation

/// Right-hand inspector: edits the selected clip's per-clip effects, or the
/// selected track's master chain. Reuses the shared effect controls.
struct MacInspectorView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    /// The capture session VM — owns the Live Audience / Majlis engine settings,
    /// surfaced here as a persistent project property (Zone 4, Card 3).
    @ObservedObject var audience: RecordSessionViewModel
    @EnvironmentObject private var playback: PlaybackService

    @State private var clip: Clip?
    @State private var source: AudioSource?
    @State private var fxEnabled = false
    @State private var clipChain = PresetLibrary.general.chain
    @State private var clipPreset = PresetLibrary.general.id

    @State private var trackPreset = ""

    /// Binds the effect rack directly to the selected track's stored chain — no
    /// cached copy, so each track always edits its own (independent) config.
    private func trackBinding(_ id: UUID) -> Binding<EffectChainSpec> {
        Binding(get: { editor.track(id)?.effectChain ?? .empty },
                set: { editor.updateTrackChain($0, forTrack: id) })
    }

    private func auditionTrack() {
        if !playback.isPlaying, editor.project.totalFrames > 0 {
            playback.play(project: editor.project, from: 0, loop: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Properties & Atmosphere")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                if clip != nil {
                    clipPropsCard            // Card 1 — Clip
                    clipEffectsCard          // Card 2 — Effects Rack
                    audienceCard             // Card 3 — Live Audience
                } else if let tid = editor.selectedTrackID, let track = editor.track(tid) {
                    trackPropsCard(track)    // Card 1 — Track
                    trackEffectsCard(track)  // Card 2 — Effects Rack
                    audienceCard             // Card 3 — Live Audience
                } else {
                    hint
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .overlay(alignment: .leading) { Divider().overlay(Theme.hairline) }
        .onAppear(perform: sync)
        .onChange(of: editor.selectedClipID) { _ in sync() }
        .onChange(of: editor.selectedTrackID) { _ in sync() }
    }

    /// Card 3 — the Live Audience / Majlis engine as a persistent project property.
    private var audienceCard: some View {
        AudienceControlsView(
            enabled: Binding(get: { audience.audienceModeEnabled }, set: { audience.audienceModeEnabled = $0 }),
            crowdVolume: Binding(get: { audience.crowdVolume }, set: { audience.crowdVolume = $0 }),
            duckingAmountDb: Binding(get: { audience.duckingAmountDb }, set: { audience.duckingAmountDb = $0 }),
            sensitivity: Binding(get: { audience.duckingSensitivity }, set: { audience.duckingSensitivity = $0 }),
            designateAsCrowdTake: Binding(get: { audience.isCrowdDesignatedTake }, set: { audience.isCrowdDesignatedTake = $0 }))
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text("Select a clip or track to edit its effects")
                .font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: Clip

    private var clipPropsCard: some View {
        Card { VStack(alignment: .leading, spacing: 16) {
            Text("Clip").font(.title3.weight(.semibold))
            TextField("Name", text: Binding(get: { clip?.name ?? "" }, set: { clip?.name = $0; commitClip() }))
                .textFieldStyle(.roundedBorder)
            LabeledSlider(title: "Voice Volume", value: Binding(get: { clip?.gain ?? 1 },
                          set: { clip?.gain = $0; commitClip() }), range: 0...2)
            if editor.project.tracks.count > 1, let c = clip {
                HStack {
                    Text("Track").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { editor.trackID(ofClip: c.id) ?? editor.project.tracks.first!.id },
                        set: { editor.moveClip(c.id, toTrack: $0, atFrame: c.timelineStartFrame); sync() })) {
                        ForEach(editor.project.tracks) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(Theme.accent)
                }
            }
            HStack {
                Button { soloListen() } label: {
                    Label(playback.isPlaying ? "Stop" : "Solo Listen",
                          systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                }.tint(Theme.accent)
                Spacer()
                Button(role: .destructive) {
                    if let id = clip?.id { editor.deleteClipAnywhere(id) }
                } label: { Label("Delete", systemImage: "trash") }.tint(Theme.recordRed)
            }
            HStack {
                Button { if let id = clip?.id { editor.duplicateClip(id) } } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }.tint(Theme.accent)
                Button { if let id = clip?.id { editor.duplicateClipToNewTrack(id) } } label: {
                    Label("To New Track", systemImage: "rectangle.stack.badge.plus")
                }.tint(Theme.accent)
                Button { if let id = clip?.id { _ = editor.splitClip(id, atFrame: playback.currentFrame) } } label: {
                    Label("Split", systemImage: "scissors")
                }.tint(Theme.accent)
            }
            // Gesture-free positioning (drag fights timeline scrolling).
            VStack(alignment: .leading, spacing: 4) {
                Text("Position").font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    macNudge("−1s", -1.0); macNudge("−0.1s", -0.1)
                    Button { if let id = clip?.id { editor.setClipStart(id, toFrame: playback.currentFrame) } } label: {
                        Image(systemName: "arrow.right.to.line")
                    }.tint(Theme.accent).help("Move to playhead")
                    macNudge("+0.1s", 0.1); macNudge("+1s", 1.0)
                }
                HStack(spacing: 6) {                       // fine 50 ms / 10 ms nudges
                    macNudge("−0.05s", -0.05); macNudge("+0.05s", 0.05)
                    macNudge("−0.01s", -0.01); macNudge("+0.01s", 0.01)
                }
            }
        } }
    }

    private var clipEffectsCard: some View {
        Card { VStack(alignment: .leading, spacing: 14) {
            Toggle("Clip Effects", isOn: Binding(get: { fxEnabled }, set: { setFX($0) })).tint(Theme.accent)
            if fxEnabled {
                PresetPickerView(selectedPresetID: $clipPreset, currentChain: clipChain) { clipChain = $0; commitClip() }
                LabeledSlider(title: "Wet / Dry", value: Binding(get: { clipChain.wetDryMix },
                              set: { clipChain.wetDryMix = $0; commitClip() }))
                LabeledSlider(title: "Intensity", value: Binding(get: { clipChain.intensity },
                              set: { clipChain.intensity = $0; commitClip() }), range: 0...1.5, tint: Theme.accentWarm)
                EffectRackView(chain: $clipChain) { commitClip() }
            }
        } }.sectionHeader("Effects Rack")
    }

    private func macNudge(_ label: String, _ seconds: Double) -> some View {
        Button(label) {
            if let id = clip?.id { editor.nudgeClip(id, byFrames: AVAudioFramePosition(seconds * editor.sampleRate)) }
        }.tint(Theme.accent).font(.caption)
    }

    // MARK: Track

    private func trackPropsCard(_ track: Track) -> some View {
        Card { VStack(alignment: .leading, spacing: 12) {
            Text("Track · \(track.name)").font(.title3.weight(.semibold))
            Text("Master chain (applied after each clip's effects)")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            LabeledSlider(title: "Track Volume", value: Binding(
                get: { editor.track(track.id)?.volume ?? 1 },
                set: { editor.setVolume($0, forTrack: track.id) }), range: 0...1.5)
        } }
    }

    private func trackEffectsCard(_ track: Track) -> some View {
        let chain = trackBinding(track.id)
        return Card { VStack(alignment: .leading, spacing: 14) {
            PresetPickerView(selectedPresetID: $trackPreset, currentChain: chain.wrappedValue) { newChain in
                editor.updateTrackChain(newChain, forTrack: track.id)
                trackPreset = PresetLibrary.all.first { $0.chain.stages.map(\.kind) == newChain.stages.map(\.kind) }?.id ?? ""
                auditionTrack()
            }
            LabeledSlider(title: "Wet / Dry", value: chain.wetDryMix)
            LabeledSlider(title: "Intensity", value: chain.intensity, range: 0...1.5, tint: Theme.accentWarm)
            EffectRackView(chain: chain) { auditionTrack() }
        } }.sectionHeader("Effects Rack")
    }

    // MARK: Sync & commit

    private func sync() {
        if let id = editor.selectedClipID, let found = editor.clip(id) {
            clip = found.clip; source = found.source
            if let c = found.clip.effectChain {
                fxEnabled = true; clipChain = c
                clipPreset = PresetLibrary.all.first { $0.chain.stages.map(\.kind) == c.stages.map(\.kind) }?.id ?? ""
            } else { fxEnabled = false }
        } else {
            clip = nil; source = nil
            if let tid = editor.selectedTrackID, let t = editor.track(tid) {
                trackPreset = PresetLibrary.all.first { $0.chain.stages.map(\.kind) == t.effectChain.stages.map(\.kind) }?.id ?? ""
            }
        }
    }

    private func setFX(_ on: Bool) {
        fxEnabled = on
        if on, clip?.effectChain == nil { clipChain = PresetLibrary.general.chain; clipPreset = PresetLibrary.general.id }
        commitClip()
    }

    private func commitClip() {
        guard var c = clip else { return }
        c.effectChain = fxEnabled ? clipChain : nil
        clip = c
        editor.commitClip(c)                 // live-updates if already playing
        autoPreview(c)                       // …otherwise auto-start so the edit is heard
    }

    /// Auto-plays (loops) the clip so filter edits are heard without pressing play.
    /// Only starts when nothing is playing; live updates handle the rest.
    private func autoPreview(_ c: Clip) {
        guard !playback.isPlaying, let s = source else { return }
        playback.previewClip(c, source: s, loop: true)
    }

    private func soloListen() {
        guard let c = clip, let s = source else { return }
        if playback.isPlaying { playback.stop() } else { playback.previewClip(c, source: s, loop: true) }
    }
}
#endif
