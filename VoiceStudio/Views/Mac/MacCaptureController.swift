#if os(macOS)
import SwiftUI

/// Inline capture (replaces the modal record panel): a banner that drops in below
/// the transport while recording onto the **armed/selected** lane. Reuses
/// `RecordSessionViewModel` verbatim (record, monitor, overdub latency comp,
/// crowd-designation) — only the presentation is inline. Recording starts on
/// appear; Stop → Approve/Discard commit to the capture-target track.
struct MacCaptureBar: View {
    @ObservedObject var editor: ProjectEditorViewModel
    @ObservedObject var vm: RecordSessionViewModel
    @EnvironmentObject private var recordingService: RecordingService
    var onClose: () -> Void

    @State private var levels: [Float] = []
    @State private var started = false
    @State private var clipping = false

    private var targetName: String {
        editor.project.tracks.first { $0.id == editor.captureTargetID }?.name ?? "New Track"
    }

    var body: some View {
        HStack(spacing: 14) {
            recordStop
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.hasTake ? "Take ready" : "Recording → \(targetName)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                WaveformView(levels: levels, color: vm.isRecording ? Theme.recordRed : Theme.accent)
                    .frame(height: 34).animation(.easeOut(duration: 0.05), value: levels)
            }
            Text(formatTimecode(recordingService.elapsedTime))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(vm.isRecording ? Theme.recordRed : Theme.textPrimary)

            if clipping {
                Text("CLIP — lower mic gain")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.recordRed).foregroundStyle(.white)
                    .clipShape(Capsule())
                    .help("Input is clipping at the source — lower In: gain or the mic/interface level")
            }

            if !vm.hasTake { monitorMenu }

            if vm.hasTake {
                Toggle("ردّة", isOn: Binding(get: { vm.isCrowdDesignatedTake },
                                            set: { vm.isCrowdDesignatedTake = $0 }))
                    .toggleStyle(.button).tint(Theme.accent)
                    .help("Designate as Crowd / Raddah take")
                Button { vm.togglePreview() } label: { Image(systemName: "play.fill") }.help("Listen")
                Button(role: .destructive) { vm.discardTake() } label: { Image(systemName: "trash") }.help("Discard")
                Button {
                    vm.approve(into: editor, trackID: editor.captureTargetID)
                    onClose()
                } label: { Label("Approve", systemImage: "checkmark.circle.fill") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            Button { vm.cancelAll(); onClose() } label: { Image(systemName: "xmark") }
                .help("Close capture")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.06)) }
        .onReceive(recordingService.waveform.$levels) { levels = $0 }
        .onReceive(recordingService.waveform.$isClipping) { clipping = $0 }
        .onAppear {
            vm.backingProvider = { editor.project }
            // Start monitoring, then begin capturing immediately on the armed lane.
            Task { await vm.appear(); if !started { started = true; await vm.toggleRecording() } }
        }
    }

    /// "Hear:" dropdown — choose which existing tracks play while recording.
    private var monitorMenu: some View {
        Menu {
            Button { vm.monitorScope = .all }  label: { row("All tracks", selected: vm.monitorScope == .all) }
            Button { vm.monitorScope = .none } label: { row("None (mic only)", selected: vm.monitorScope == .none) }
            if !vm.monitorTracks.isEmpty { Divider() }
            ForEach(vm.monitorTracks, id: \.id) { t in
                Button { vm.monitorScope = .track(t.id) } label: {
                    row(t.name, selected: isSelected(t.id))
                }
            }
        } label: {
            Label(monitorLabel, systemImage: "ear")
                .font(.caption).foregroundStyle(Theme.accent)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Choose which tracks you hear while recording")
    }

    @ViewBuilder private func row(_ text: String, selected: Bool) -> some View {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
    private func isSelected(_ id: UUID) -> Bool {
        if case .track(let sel) = vm.monitorScope { return sel == id }
        return false
    }
    private var monitorLabel: String {
        switch vm.monitorScope {
        case .all:  return "Hear: All"
        case .none: return "Hear: None"
        case .track(let id):
            return "Hear: " + (vm.monitorTracks.first { $0.id == id }?.name ?? "Track")
        }
    }

    private var recordStop: some View {
        Button { Task { await vm.toggleRecording() } } label: {
            ZStack {
                Circle().fill(Theme.surfaceElevated).frame(width: 40, height: 40)
                if vm.isRecording {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.recordRed).frame(width: 16, height: 16)
                } else {
                    Circle().fill(Theme.recordRed).frame(width: 18, height: 18)
                }
            }
            .overlay(Circle().stroke(Theme.recordRed.opacity(0.6), lineWidth: 1.5).frame(width: 40, height: 40))
        }
        .buttonStyle(.plain)
        .disabled(vm.hasTake)
        .help(vm.isRecording ? "Stop" : "Record")
    }
}
#endif
