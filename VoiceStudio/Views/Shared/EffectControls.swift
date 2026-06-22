import SwiftUI

/// A labeled slider with a trailing value readout, used for wet/dry & intensity.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var format: (Float) -> String = { String(format: "%.0f%%", $0 * 100) }
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(format(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: range)
                .tint(tint)
        }
    }
}

/// Picker of preset categories + presets within the selected category.
struct PresetPickerView: View {
    @Binding var selectedPresetID: String
    /// The current chain — used by "Save as Mode".
    var currentChain: EffectChainSpec
    /// Applies the chosen chain (built-in preset or saved Mode).
    var onSelect: (EffectChainSpec) -> Void

    @EnvironmentObject private var presetStore: PresetStore
    @State private var category: PresetCategory = .anasheed
    @State private var showingModes = false
    @State private var showSaveDialog = false
    @State private var newModeName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Custom segmented control (a plain SwiftUI segmented Picker can crash
            // in NSSegmentedControl's sizing on macOS), and it scrolls when there
            // are many categories.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PresetCategory.allCases) { cat in
                        categoryChip(cat.rawValue, selected: !showingModes && category == cat) {
                            category = cat; showingModes = false
                        }
                    }
                    categoryChip("My Modes", selected: showingModes) { showingModes = true }
                }
                .padding(.horizontal, 1)
            }

            if showingModes {
                if presetStore.presets.isEmpty {
                    Text("No saved Modes yet. Tweak the filters below, then “Save as Mode”.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).padding(.vertical, 8)
                } else {
                    ForEach(presetStore.presets) { mode in modeRow(mode) }
                }
            } else {
                ForEach(PresetLibrary.presets(in: category)) { preset in presetRow(preset) }
            }

            Button { showSaveDialog = true } label: {
                Label("Save current settings as Mode", systemImage: "square.and.arrow.down.on.square")
                    .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Theme.surfaceElevated).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .onAppear {
            if let p = PresetLibrary.preset(id: selectedPresetID) { category = p.category }
        }
        .alert("Save Mode", isPresented: $showSaveDialog) {
            TextField("Mode name", text: $newModeName)
            Button("Save") {
                let saved = presetStore.add(name: newModeName, chain: currentChain)
                selectedPresetID = saved.id.uuidString
                newModeName = ""
                showingModes = true
            }
            Button("Cancel", role: .cancel) { newModeName = "" }
        } message: { Text("Save the current filters as a reusable Mode.") }
    }

    private func categoryChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.surfaceElevated)
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func presetRow(_ preset: VocalPreset) -> some View {
        row(id: preset.id, symbol: preset.symbol, name: preset.name, subtitle: preset.subtitle,
            tint: Theme.accentWarm) {
            selectedPresetID = preset.id
            onSelect(preset.chain)
        }
    }

    private func modeRow(_ mode: UserPreset) -> some View {
        row(id: mode.id.uuidString, symbol: "wand.and.stars", name: mode.name,
            subtitle: "\(mode.chain.stages.count) filters", tint: Theme.accent,
            onTap: { selectedPresetID = mode.id.uuidString; onSelect(mode.chain) },
            onDelete: { presetStore.delete(mode.id) })
    }

    private func row(id: String, symbol: String, name: String, subtitle: String, tint: Color,
                     onTap: @escaping () -> Void, onDelete: (() -> Void)? = nil) -> some View {
        let selected = selectedPresetID == id
        return HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 38, height: 38)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer()
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
        }
        .padding(12)
        .background(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .foregroundStyle(Theme.textPrimary)
    }
}

/// Live Audience / Majlis atmosphere controls (shared by the iOS & macOS record
/// panels): the master toggle plus crowd volume, ducking depth and sensitivity.
/// Binding-driven so it stays decoupled from any specific view model.
struct AudienceControlsView: View {
    @Binding var enabled: Bool
    @Binding var crowdVolume: Float
    @Binding var duckingAmountDb: Float
    @Binding var sensitivity: Float
    /// Routes the next approved take to the active track as a Raddah/crowd layer.
    @Binding var designateAsCrowdTake: Bool

    /// Crowd volume shown as dB (matches the Stitch "Crowd Vol  -6.0 dB").
    private var crowdDb: String {
        crowdVolume <= 0.001 ? "-∞ dB" : String(format: "%.1f dB", 20 * log10(crowdVolume))
    }
    /// Ducking depth 0…100% mapped onto the −3…−18 dB attenuation range.
    private var depthBinding: Binding<Float> {
        Binding(get: { (abs(duckingAmountDb) - 3) / 15 * 100 },
                set: { duckingAmountDb = -(3 + ($0 / 100) * 15) })
    }

    var body: some View {
        Card(glow: Theme.accentWarm) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("LIVE AUDIENCE ENGINE")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accentWarm)
                            .neonGlow(Theme.accentWarm, radius: 4)
                        Text("محرك الجمهور الحي")
                            .font(.caption2).foregroundStyle(Theme.accentWarm.opacity(0.8))
                    }
                    Spacer()
                    Toggle("", isOn: $enabled).labelsHidden()
                        .toggleStyle(.switch).tint(Theme.accentWarm)
                }

                Divider().overlay(Theme.accentWarm.opacity(0.25))

                Button { designateAsCrowdTake.toggle() } label: {
                    HStack(spacing: 10) {
                        checkBox(designateAsCrowdTake, tint: Theme.accentWarm)
                        Text("Designate as Crowd Take (ردّة)")
                            .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)

                goldSlider("Crowd Vol", readout: crowdDb, value: $crowdVolume, range: 0...1)
                goldSlider("Ducking Depth", readout: "\(Int(depthBinding.wrappedValue))%",
                           value: depthBinding, range: 0...100)
            }
        }
    }

    private func checkBox(_ on: Bool, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(on ? tint : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? tint : Theme.hairline, lineWidth: 1.5))
            .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black).opacity(on ? 1 : 0))
            .frame(width: 18, height: 18)
    }

    private func goldSlider(_ title: String, readout: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(readout).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accentWarm)
            }
            Slider(value: value, in: range).tint(Theme.accentWarm).controlSize(.small)
        }
    }
}

/// The editable effect rack: each filter expands to reveal its parameter sliders,
/// can be enabled/bypassed and removed, and new filters can be added. Shared by
/// iOS and macOS. Structural edits (add/remove) take effect on the next
/// play/record build; parameter and enable changes apply live.
struct EffectRackView: View {
    @Binding var chain: EffectChainSpec
    var onChange: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach($chain.stages) { $stage in
                EffectStageRow(stage: $stage, onChange: onChange, onRemove: { remove(stage) })
            }
            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(EffectKind.userAddable, id: \.self) { kind in
                Button { add(kind) } label: { Label(kind.displayName, systemImage: kind.symbol) }
            }
        } label: {
            Label("Add Filter", systemImage: "plus.circle")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .tint(Theme.accent)
    }

    private func add(_ kind: EffectKind) {
        chain.stages.append(EffectStageSpec(kind: kind, params: kind.defaultParams))
        onChange()
    }

    private func remove(_ stage: EffectStageSpec) {
        chain.stages.removeAll { $0.id == stage.id }
        onChange()
    }
}

/// One expandable filter row: enable toggle + parameter sliders + remove.
private struct EffectStageRow: View {
    @Binding var stage: EffectStageSpec
    var onChange: () -> Void
    var onRemove: () -> Void
    @EnvironmentObject private var irLoader: IRLoader
    @State private var expanded = false

    private var isML: Bool { stage.kind == .mlVoiceConversion }
    private var isConv: Bool { stage.kind == .convolutionReverb }
    private var rowAccent: Color { isConv ? Theme.accentWarm : Theme.accent }

    var body: some View {
        let hasParams = !stage.kind.editableParams.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Enable checkbox (Stitch node-row style).
                Button { if !isML { stage.isEnabled.toggle(); onChange() } } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(stage.isEnabled ? rowAccent : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(stage.isEnabled ? rowAccent : Theme.hairline, lineWidth: 1.5))
                        .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black).opacity(stage.isEnabled ? 1 : 0))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).disabled(isML)

                Text(stage.kind.displayName)
                    .font(.system(size: 13, weight: isConv ? .semibold : .medium))
                    .foregroundStyle(isConv ? Theme.accentWarm : Theme.textPrimary)
                if isML {
                    Text("Phase 2").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accentWarm.opacity(0.25)).clipShape(Capsule())
                        .foregroundStyle(Theme.accentWarm)
                }
                Spacer()
                if hasParams {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "line.3.horizontal").font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))      // drag handle
                Menu {
                    Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary) }
                .menuStyle(.borderlessButton).fixedSize().disabled(isML)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { if hasParams { withAnimation { expanded.toggle() } } }

            if expanded {
                VStack(spacing: 10) {
                    if stage.kind == .convolutionReverb { irPicker }
                    ForEach(stage.kind.editableParams) { param in
                        LabeledSlider(
                            title: param.label,
                            value: Binding(
                                get: { stage.param(param.key, default: param.defaultValue) },
                                set: { stage.params[param.key] = $0; onChange() }),
                            range: param.range,
                            format: { param.format.string($0) })
                    }
                }
                .padding(.leading, 32).padding(.bottom, 8)
                .opacity(stage.isEnabled ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 10)
        .background(isConv ? Theme.accentWarm.opacity(0.08) : Theme.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isConv ? Theme.accentWarm.opacity(0.5) : Theme.hairline, lineWidth: 1))
    }

    /// Acoustic-space (IR) selector for the convolution filter.
    private var irPicker: some View {
        HStack {
            Text("Acoustic Space").font(.subheadline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Picker("", selection: Binding(
                get: { stage.stringParams?[ParamKeys.ir] ?? irLoader.available.first?.id ?? "" },
                set: { stage.stringParams = (stage.stringParams ?? [:]).merging([ParamKeys.ir: $0]) { _, b in b }; onChange() })) {
                ForEach(irLoader.available) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.accent)
        }
    }
}
