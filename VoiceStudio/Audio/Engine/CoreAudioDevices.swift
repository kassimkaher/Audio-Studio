#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox

/// Core Audio HAL helpers for enumerating and selecting input/output devices on
/// macOS (there is no `AVAudioSession`).
enum CoreAudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map {
            Device(id: $0, uid: uid(of: $0), name: name(of: $0),
                   hasInput: channelCount($0, scope: kAudioObjectPropertyScopeInput) > 0,
                   hasOutput: channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? { all().first { $0.uid == uid }?.id }

    /// Sets the system default input/output device — the reliable way to steer
    /// AVAudioEngine's I/O on macOS (the engine follows the default device).
    @discardableResult
    static func setDefaultDevice(_ id: AudioDeviceID, forInput input: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        return status == noErr
    }

    /// Sets the current hardware device on an AVAudioEngine I/O node's audio unit.
    static func setCurrentDevice(_ id: AudioDeviceID, onAudioUnit au: AudioUnit) {
        var dev = id
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: Property readers

    private static func name(of id: AudioDeviceID) -> String {
        stringProperty(id, kAudioObjectPropertyName) ?? "Audio Device"
    }
    private static func uid(of id: AudioDeviceID) -> String {
        stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "dev-\(id)"
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
