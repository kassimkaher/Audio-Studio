#if os(macOS)
import SwiftUI

/// Menu-bar commands. They post notifications that the focused views act on,
/// which keeps the command definitions decoupled from view state.
extension Notification.Name {
    static let vsNewProject  = Notification.Name("vs.newProject")
    static let vsRecord      = Notification.Name("vs.record")
    static let vsPlayStop    = Notification.Name("vs.playStop")
    static let vsAddTrack    = Notification.Name("vs.addTrack")
    static let vsImport      = Notification.Name("vs.import")
    static let vsExport      = Notification.Name("vs.export")
    static let vsDeleteClip  = Notification.Name("vs.deleteClip")
    static let vsCopy        = Notification.Name("vs.copy")
    static let vsPaste       = Notification.Name("vs.paste")
    static let vsDuplicate   = Notification.Name("vs.duplicate")
    static let vsUndo        = Notification.Name("vs.undo")
    static let vsRedo        = Notification.Name("vs.redo")
}

struct VoiceStudioCommands: Commands {
    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { post(.vsNewProject) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { post(.vsUndo) }.keyboardShortcut("z", modifiers: .command)
            Button("Redo") { post(.vsRedo) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // Copy / Paste / Duplicate for the selected clip or track.
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") { post(.vsCopy) }.keyboardShortcut("c", modifiers: .command)
            Button("Paste") { post(.vsPaste) }.keyboardShortcut("v", modifiers: .command)
            Button("Duplicate") { post(.vsDuplicate) }.keyboardShortcut("d", modifiers: .command)
        }
        CommandMenu("Studio") {
            Button("Record / Stop") { post(.vsRecord) }.keyboardShortcut("r", modifiers: .command)
            Button("Play / Pause (Space)") { post(.vsPlayStop) }
            Divider()
            Button("Add Track") { post(.vsAddTrack) }.keyboardShortcut("t", modifiers: .command)
            Button("Import Audio…") { post(.vsImport) }.keyboardShortcut("i", modifiers: .command)
            Button("Export Mixdown…") { post(.vsExport) }.keyboardShortcut("e", modifiers: .command)
            Divider()
            Button("Delete Selected Clip") { post(.vsDeleteClip) }.keyboardShortcut(.delete, modifiers: [])
        }
    }
}
#endif
