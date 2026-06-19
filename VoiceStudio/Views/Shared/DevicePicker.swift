import SwiftUI

/// A menu picker for audio input/output devices that clearly shows the current
/// selection (the picker displays the selected value and checkmarks it).
struct DevicePicker: View {
    let title: String
    let systemImage: String
    let options: [AudioSessionManager.InputOption]
    let selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        Picker(selection: Binding(
            get: { selected ?? options.first?.id ?? "" },
            set: { if !$0.isEmpty { onSelect($0) } }
        )) {
            if options.isEmpty {
                Text("No devices").tag("")
            }
            ForEach(options) { option in
                Label(option.name, systemImage: option.symbol).tag(option.id)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .pickerStyle(.menu)
        .disabled(options.isEmpty)
    }
}
