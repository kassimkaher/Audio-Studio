import Foundation
import AVFoundation
import Combine
#if os(macOS)
import CoreAudio
#endif

/// Cross-platform audio I/O façade. On iOS it owns the `AVAudioSession`
/// (configuration, permission, interruptions, route changes). On macOS — where
/// there is no `AVAudioSession` — it manages device enumeration/selection via the
/// Core Audio HAL and mic permission via `AVCaptureDevice`. Both expose the same
/// API the engine calls, so the engine code is unchanged across platforms.
@MainActor
final class AudioSessionManager: ObservableObject {
    enum PermissionState { case undetermined, granted, denied }

    @Published private(set) var permission: PermissionState = .undetermined
    @Published private(set) var actualSampleRate: Double = AudioFormatConstants.sampleRate

    /// A selectable audio input/output (mic, headphones, interface, …).
    struct InputOption: Identifiable, Hashable {
        let id: String          // device/port UID
        let name: String
        let symbol: String      // SF Symbol
    }
    @Published private(set) var availableInputs: [InputOption] = []
    @Published private(set) var selectedInputUID: String?

    /// Fires when the engine must rebuild taps/connections (route/device change).
    let configurationChanged = PassthroughSubject<Void, Never>()
    /// Fires when playback/recording should pause (interruption / device lost).
    let shouldPause = PassthroughSubject<Void, Never>()
    /// Fires when an interruption ended and the system suggests resuming.
    let shouldResume = PassthroughSubject<Void, Never>()

    private var observers: [NSObjectProtocol] = []

    // ===================================================== Mobile mic link ===
    /// The synthetic UID for the "📱 iPhone (Wi-Fi)" virtual input.
    static let mobileInputUID = "mobile.wifi"
    /// True while a phone is linked over the local network (drives the picker).
    @Published private(set) var mobileLinkConnected = false
    /// True when the mobile-mic virtual input is the active capture source — read
    /// by `AudioEngineController.prepare` to tap the stream instead of hardware.
    private(set) var useMobileCapture = false

    /// Called by `MobileLinkService` when the phone connects/disconnects.
    func setMobileLinkConnected(_ connected: Bool) {
        mobileLinkConnected = connected
        if !connected, useMobileCapture {
            useMobileCapture = false
            selectedInputUID = availableInputs.first(where: { $0.id != Self.mobileInputUID })?.id
        }
        refreshInputs()
        configurationChanged.send(())
    }

    /// Prepends the mobile-mic entry to the input list while a phone is linked.
    private func injectMobileOption() {
        guard mobileLinkConnected else { return }
        guard !availableInputs.contains(where: { $0.id == Self.mobileInputUID }) else { return }
        availableInputs.insert(InputOption(id: Self.mobileInputUID,
                                           name: "📱 iPhone (Wi-Fi)",
                                           symbol: "wave.3.right"), at: 0)
    }

    // ============================================================== iOS ====
    #if os(iOS)
    private let session = AVAudioSession.sharedInstance()

    init() {
        refreshPermission()
        registerNotifications()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func refreshPermission() {
        switch session.recordPermission {
        case .granted: permission = .granted
        case .denied: permission = .denied
        default: permission = .undetermined
        }
    }

    func requestPermission() async -> Bool {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            session.requestRecordPermission { cont.resume(returning: $0) }
        }
        permission = granted ? .granted : .denied
        return granted
    }

    func configureForRecording() throws {
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetoothA2DP, .allowBluetooth])
        try session.setPreferredSampleRate(AudioFormatConstants.sampleRate)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        actualSampleRate = session.sampleRate
        if let uid = selectedInputUID,
           let port = session.availableInputs?.first(where: { $0.uid == uid }) {
            try? session.setPreferredInput(port)
        }
    }

    func configureForPlayback() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        actualSampleRate = session.sampleRate
    }

    /// Round-trip I/O latency (output → ears + mic → file + buffer). Used to
    /// time-align overdub takes against the backing they were recorded over.
    /// Includes large Bluetooth output latency when applicable.
    var ioLatencySeconds: Double {
        session.outputLatency + session.inputLatency + session.ioBufferDuration
    }

    func deactivate() { try? session.setActive(false, options: .notifyOthersOnDeactivation) }

    func prepareForInputSelection() {
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.allowBluetoothA2DP, .allowBluetooth])
        try? session.setActive(true)
        refreshInputs()
    }

    func refreshInputs() {
        availableInputs = (session.availableInputs ?? []).map {
            InputOption(id: $0.uid, name: $0.portName, symbol: Self.symbol(forPort: $0.portType))
        }
        selectedInputUID = session.preferredInput?.uid
            ?? session.currentRoute.inputs.first?.uid
            ?? availableInputs.first?.id
        injectMobileOption()
    }

    func selectInput(uid: String) {
        if uid == Self.mobileInputUID {
            useMobileCapture = true; selectedInputUID = uid; configurationChanged.send(()); return
        }
        useMobileCapture = false
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(port)
        selectedInputUID = uid
    }

    private static func symbol(forPort type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: return "mic"
        case .bluetoothHFP, .bluetoothLE: return "headphones"
        case .headsetMic, .headphones: return "headphones"
        case .usbAudio: return "cable.connector"
        case .carAudio: return "car"
        default: return "waveform"
        }
    }

    private func registerNotifications() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] n in self?.handleInterruption(n) })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { [weak self] n in self?.handleRouteChange(n) })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: nil, queue: .main) { [weak self] _ in self?.configurationChanged.send(()) })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began: shouldPause.send(())
        case .ended:
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                try? session.setActive(true); shouldResume.send(())
            }
        @unknown default: break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        refreshInputs()
        switch reason {
        case .oldDeviceUnavailable: shouldPause.send(())
        case .newDeviceAvailable, .categoryChange, .override:
            actualSampleRate = session.sampleRate; configurationChanged.send(())
        default: break
        }
    }

    // ============================================================ macOS ====
    #elseif os(macOS)
    /// Output devices (macOS lets us pick output as well as input).
    @Published private(set) var availableOutputs: [InputOption] = []
    @Published private(set) var selectedOutputUID: String?

    /// Resolved hardware device IDs the engine applies to its I/O units.
    private(set) var selectedInputDeviceID: AudioDeviceID?
    private(set) var selectedOutputDeviceID: AudioDeviceID?

    // HAL property selectors we observe: device list changes (plug/unplug, an
    // iPhone Continuity mic appearing) and default-device changes.
    private var halSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice
    ]

    init() {
        refreshPermission()
        refreshInputs()
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                self?.refreshInputs(); self?.configurationChanged.send(())
            })
        // Live HAL listeners: refresh the In/Out pickers the instant a device is
        // connected/disconnected or the system default changes — without
        // interrupting the active audio context.
        for selector in halSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
                    Task { @MainActor in self?.refreshInputs() }
                }
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func refreshPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .denied, .restricted: permission = .denied
        default: permission = .undetermined
        }
    }

    func requestPermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permission = granted ? .granted : .denied
        return granted
    }

    // No AVAudioSession on macOS — the engine uses the selected devices directly.
    func configureForRecording() throws {}
    func configureForPlayback() throws {}
    func deactivate() {}

    /// macOS has no session latency API here; the engine's IO presentation
    /// latency is queried separately. Return 0 so the engine value is used.
    var ioLatencySeconds: Double { 0 }

    func prepareForInputSelection() { refreshInputs() }

    func refreshInputs() {
        let devices = CoreAudioDevices.all()
        availableInputs = devices.filter(\.hasInput).map {
            InputOption(id: $0.uid, name: $0.name, symbol: Self.symbol(forName: $0.name))
        }
        availableOutputs = devices.filter(\.hasOutput).map {
            InputOption(id: $0.uid, name: $0.name, symbol: "hifispeaker")
        }
        if selectedInputUID == nil { selectedInputUID = availableInputs.first?.id }
        if selectedOutputUID == nil { selectedOutputUID = availableOutputs.first?.id }
        selectedInputDeviceID = selectedInputUID.flatMap { CoreAudioDevices.deviceID(forUID: $0) }
        selectedOutputDeviceID = selectedOutputUID.flatMap { CoreAudioDevices.deviceID(forUID: $0) }
        injectMobileOption()
        refreshInputGain()
    }

    /// Hardware input gain (0…1) of the selected input device, nil if the device
    /// doesn't expose one. Lower it to stop a too-hot mic from clipping.
    @Published private(set) var inputGain: Float?

    func refreshInputGain() {
        inputGain = selectedInputDeviceID.flatMap { CoreAudioDevices.inputVolume($0) }
    }

    func setInputGain(_ value: Float) {
        guard let id = selectedInputDeviceID else { return }
        CoreAudioDevices.setInputVolume(value, id)
        inputGain = CoreAudioDevices.inputVolume(id) ?? value
    }

    func selectInput(uid: String) {
        if uid == Self.mobileInputUID {
            useMobileCapture = true; selectedInputUID = uid; configurationChanged.send(()); return
        }
        useMobileCapture = false
        selectedInputUID = uid
        selectedInputDeviceID = CoreAudioDevices.deviceID(forUID: uid)
        // Steer the engine via the system default input (reliable on macOS).
        if let id = selectedInputDeviceID { CoreAudioDevices.setDefaultDevice(id, forInput: true) }
        configurationChanged.send(())
    }

    func selectOutput(uid: String) {
        selectedOutputUID = uid
        selectedOutputDeviceID = CoreAudioDevices.deviceID(forUID: uid)
        if let id = selectedOutputDeviceID { CoreAudioDevices.setDefaultDevice(id, forInput: false) }
        configurationChanged.send(())
    }

    private static func symbol(forName name: String) -> String {
        let n = name.lowercased()
        if n.contains("bluetooth") || n.contains("airpod") || n.contains("headphone") { return "headphones" }
        if n.contains("usb") || n.contains("interface") { return "cable.connector" }
        if n.contains("built-in") || n.contains("macbook") || n.contains("imac") { return "mic" }
        return "waveform"
    }
    #endif
}
