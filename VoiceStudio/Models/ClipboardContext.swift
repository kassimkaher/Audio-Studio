import Foundation

/// Process-wide audio clipboard so ⌘C/⌘V work **across tracks and across
/// projects**. Holds the copied clip (or track) metadata plus the underlying
/// `AudioSource`(s) — the source file lives in the shared recordings directory,
/// so re-registering the source in the paste target makes the clip resolvable
/// even in a different project.
@MainActor
enum ClipboardContext {
    static var clip: Clip?
    static var clipSource: AudioSource?
    static var track: Track?
    static var trackSources: [AudioSource] = []
}
