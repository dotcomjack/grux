import Foundation
import SwiftUI

// Observable state for the "iPhone mic" pipeline. The menu bar row + pairing
// window + any future debug view all bind to this.
@MainActor
final class PhoneReceiverState: ObservableObject {
    static let shared = PhoneReceiverState()

    // Is the NWListener up?
    @Published var isRunning: Bool = false
    // Is a phone currently authenticated and streaming?
    @Published var isConnected: Bool = false
    @Published var connectedDevice: String = ""
    // Frames received since launch - drives "waveform alive" indicator.
    @Published var audioFramesReceived: Int = 0
    @Published var lastFrameAt: Date = .distantPast
    // Latest decoded transcript, echoed back to the phone as partials.
    @Published var latestTranscript: String = ""
    @Published var lastError: String = ""
    // Listener port - exposed so the pairing UI can show / encode it. 0 until
    // the NWListener reports its actual bound port.
    @Published var listenerPort: UInt16 = 0

    // Rolling 15s byte counter for a rough "kbps" display.
    private var recentByteWindow: [(Date, Int)] = []

    var recentKilobytesPerSecond: Double {
        let cutoff = Date().addingTimeInterval(-15)
        let pruned = recentByteWindow.filter { $0.0 >= cutoff }
        let total = pruned.reduce(0) { $0 + $1.1 }
        guard !pruned.isEmpty else { return 0 }
        let span = max(1.0, Date().timeIntervalSince(pruned.first!.0))
        return Double(total) / span / 1024.0
    }

    func noteBytes(_ n: Int) {
        recentByteWindow.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-15)
        recentByteWindow.removeAll { $0.0 < cutoff }
    }

    private init() {}
}
