import SwiftUI

/// Companion mic app: one screen that connects to the Mac and streams the mic.
struct MicContentView: View {
    @StateObject private var streamer = MicStreamer()

    private var statusText: String {
        switch streamer.status {
        case .idle:        return "Tap Connect to find your Mac"
        case .searching:   return "Searching for Voice Studio…"
        case .connecting:  return "Connecting…"
        case .streaming:   return "Streaming to \(streamer.hostName ?? "Mac")"
        case .denied:      return "Microphone access denied — enable it in Settings"
        case .error(let m): return "Error: \(m)"
        }
    }

    private var isStreaming: Bool { streamer.status == .streaming }

    var body: some View {
        ZStack {
            Color(red: 0.047, green: 0.055, blue: 0.067).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text("Voice Studio")
                    .font(.title2.weight(.bold)).foregroundColor(Color(red: 0, green: 0.96, blue: 0.83))
                + Text(" Mic").font(.title2.weight(.bold)).foregroundColor(Color(red: 0.98, green: 0.71, blue: 0))

                ZStack {
                    Circle()
                        .fill(isStreaming ? Color(red: 0, green: 0.96, blue: 0.83).opacity(0.18) : Color.white.opacity(0.06))
                        .frame(width: 180, height: 180)
                    Image(systemName: isStreaming ? "waveform" : "mic.fill")
                        .font(.system(size: 64))
                        .foregroundColor(isStreaming ? Color(red: 0, green: 0.96, blue: 0.83) : .white.opacity(0.7))
                }

                Text(statusText)
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)

                Spacer()

                if isStreaming {
                    Button { streamer.muted.toggle() } label: {
                        Label(streamer.muted ? "Muted" : "Live",
                              systemImage: streamer.muted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity).padding()
                            .background((streamer.muted ? Color.red : Color(red: 0, green: 0.96, blue: 0.83)).opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .tint(streamer.muted ? .red : Color(red: 0, green: 0.96, blue: 0.83))
                }

                Button(isStreaming || streamer.status == .searching || streamer.status == .connecting
                       ? "Disconnect" : "Connect") {
                    if streamer.status == .idle { streamer.start() } else { streamer.stop() }
                }
                .font(.headline).frame(maxWidth: .infinity).padding()
                .background(Color(red: 0, green: 0.96, blue: 0.83).opacity(0.9))
                .foregroundStyle(.black).clipShape(Capsule())
                .padding(.horizontal, 32).padding(.bottom, 24)
            }
        }
    }
}
