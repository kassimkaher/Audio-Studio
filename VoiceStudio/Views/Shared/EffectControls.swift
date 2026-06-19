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

    var body: some View {
        let hasParams = !stage.kind.editableParams.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: stage.kind.symbol).frame(width: 22).foregroundStyle(Theme.accent)
                Text(stage.kind.displayName).foregroundStyle(Theme.textPrimary)
                if isML {
                    Text("Phase 2").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accentWarm.opacity(0.25)).clipShape(Capsule())
                        .foregroundStyle(Theme.accentWarm)
                } else if hasParams {
                    Text("\(stage.kind.editableParams.count) settings")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if hasParams {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Toggle("", isOn: Binding(get: { stage.isEnabled },
                                         set: { stage.isEnabled = $0; onChange() }))
                    .labelsHidden().tint(Theme.accent).disabled(isML)
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
        .background(Theme.surfaceElevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
