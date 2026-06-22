import Foundation
import Network

/// Best-effort local IPv4 address for showing the user where to point the phone.
enum LocalIP {
    static func address() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }   // IPv4 only
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }     // Wi-Fi / Ethernet
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
            }
        }
        return result
    }
}

/// Wi-Fi transport: advertises `_voicestudiomic._tcp` over Bonjour, accepts the
/// phone's TCP connection, and decodes length-prefixed `AudioFrame`s off the wire.
///
/// Wire framing: `[UInt32 big-endian payloadLength][AudioFrame.encoded()]`.
final class BonjourTransport: MobileLinkTransport {
    var onFrame: ((AudioFrame) -> Void)?
    var onState: ((LinkState) -> Void)?

    static let serviceType = MobileLink.serviceType
    static let port: UInt16 = MobileLink.port

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.voicestudio.mobilelink")
    private var buffer = Data()

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port) ?? .any)
            listener.service = NWListener.Service(name: hostName(), type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? Self.port
                    let ep = "\(LocalIP.address() ?? "this Mac"):\(port)"
                    self?.onState?(.advertising(ep))
                case .failed(let error):
                    self?.onState?(.failed("\(error)"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState?(.failed("\(error)"))
        }
    }

    func stop() {
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        buffer.removeAll()
        onState?(.idle)
    }

    private func hostName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Voice Studio"
        #else
        return "Voice Studio"
        #endif
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:   self?.onState?(.connected("iPhone (Wi-Fi)"))
            case .failed, .cancelled:
                if let ep = LocalIP.address() { self?.onState?(.advertising("\(ep):\(Self.port)")) }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error == nil && !isComplete { self.receive(on: conn) }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = Int(buffer.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard length > 0, buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let frame = AudioFrame.decode(payload) { onFrame?(frame) }
        }
    }
}
