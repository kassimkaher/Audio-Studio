import SwiftUI

/// Edits a track's **master** effect chain (applied to all clips on the track,
/// after each clip's own effects). Changes apply live to playback.
struct TrackEffectsSheet: View {
    @ObservedObject var editor: ProjectEditorViewModel
    let trackID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var chain: EffectChainSpec = .empty
    @State private var presetID: String = ""

    private var track: Track? { editor.track(trackID) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.screenBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        Card {
                            LabeledSlider(title: "Track Volume", value: Binding(
                                get: { editor.track(trackID)?.volume ?? 1 },
                                set: { editor.setVolume($0, forTrack: trackID) }), range: 0...1.5)
                        }.sectionHeader("Volume")

                        Card {
                            PresetPickerView(selectedPresetID: $presetID, currentChain: chain) { newChain in
                                chain = newChain
                                editor.updateTrackChain(newChain, forTrack: trackID)
                            }
                        }.sectionHeader("Track Preset")

                        Card {
                            VStack(spacing: 16) {
                                LabeledSlider(title: "Wet / Dry",
                                              value: Binding(get: { chain.wetDryMix },
                                                             set: { chain.wetDryMix = $0; commit() }))
                                LabeledSlider(title: "Intensity",
                                              value: Binding(get: { chain.intensity },
                                                             set: { chain.intensity = $0; commit() }),
                                              range: 0...1.5, tint: Theme.accentWarm)
                            }
                        }.sectionHeader("Mix")

                        Card { EffectRackView(chain: $chain) { commit() } }
                            .sectionHeader("Track Effect Rack")
                    }
                    .padding()
                }
            }
            .navigationTitle(track?.name ?? "Effects")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            if let track { chain = track.effectChain; presetID = matchingPresetID(track.effectChain) }
        }
        .onDisappear { editor.playback.stop() }
    }

    private func commit() {
        editor.updateTrackChain(chain, forTrack: trackID)
        if !editor.playback.isPlaying, editor.project.totalFrames > 0 {
            editor.playback.play(project: editor.project, from: 0, loop: true)
        }
    }

    private func matchingPresetID(_ chain: EffectChainSpec) -> String {
        PresetLibrary.all.first { $0.chain.stages.map(\.kind) == chain.stages.map(\.kind) }?.id ?? ""
    }
}
