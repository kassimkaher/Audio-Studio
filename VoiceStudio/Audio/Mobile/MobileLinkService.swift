import Foundation
import Combine

/// Owns the mobile-mic link: a `MobileLinkTransport` (Wi-Fi by default) feeding a
/// `StreamInputNode` (the virtual capture source). Publishes connection state for
/// the UI and exposes the stream node for `AudioEngineController` to capture from.
@MainActor
final class MobileLinkService: ObservableObject {
    @Published private(set) var state: LinkState = .idle
    @Published private(set) var endpoint: String?       // IP:port to point the phone at
    @Published private(set) var isConnected = false
    @Published private(set) var isAdvertising = false
    /// Live jitter-buffer depth (ms) — non-zero confirms frames are arriving.
    @Published private(set) var bufferedMs = 0
    private var meterTimer: Timer?
    private var tcpConnected = false
    private var lastReceived = 0
    private var stalledTicks = 0

    /// The virtual input the DAW captures from when the mobile mic is selected.
    let streamInput = StreamInputNode(sampleRate: 48_000, jitterSeconds: 1.0)
    private let transport: MobileLinkTransport

    init(transport: MobileLinkTransport = BonjourTransport()) {
        self.transport = transport
        streamInput.bind(to: transport)                 // frames → ring buffer
        transport.onState = { [weak self] st in
            Task { @MainActor in self?.apply(st) }
        }
    }

    /// Begin advertising over the local network so the phone can find the Mac.
    func start() {
        streamInput.reset()
        transport.start()
    }

    func stop() { transport.stop() }

    private func apply(_ st: LinkState) {
        state = st
        switch st {
        case .idle:
            tcpConnected = false; isAdvertising = false; isConnected = false; stopMeter()
        case .advertising(let ep):
            endpoint = ep; tcpConnected = false; isAdvertising = true; isConnected = false; stopMeter()
        case .connected:
            tcpConnected = true; isAdvertising = true; startMeter()
        case .failed:
            tcpConnected = false; isAdvertising = false; isConnected = false; stopMeter()
        }
    }

    /// `isConnected` reflects *real frame flow*, not just an open socket — so a
    /// locked/suspended phone (socket lingers, frames stop) shows as disconnected.
    private func startMeter() {
        guard meterTimer == nil else { return }
        lastReceived = streamInput.receivedSamples
        stalledTicks = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let received = self.streamInput.receivedSamples
                let flowing = received > self.lastReceived
                self.lastReceived = received
                self.stalledTicks = flowing ? 0 : self.stalledTicks + 1
                self.bufferedMs = Int(self.streamInput.bufferedSeconds * 1000)
                // ~1.5s without new frames ⇒ treat as disconnected.
                self.isConnected = self.tcpConnected && self.stalledTicks < 5
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate(); meterTimer = nil; bufferedMs = 0; stalledTicks = 0
    }
}
