import Foundation
import Combine

/// Whether the listening microphone is actually delivering sound.
///
/// Measured 2026-09-21: ambient came up deaf three times running, stopped
/// retrying, and every surface went on reading ARMED, so the person talked to
/// a Grux that could not hear them and the orb tap they tried next MUTED it.
/// This is the fact those surfaces were missing.
///
/// It changes only on a transition, so a view that reads it redraws when
/// hearing starts or stops and never at audio rate. `AmbientState` publishes
/// the live level many times a second, which is why the rail must not
/// observe that (see `RootObservesOnlyWhatItReadsTests`).
@MainActor
final class MicHealth: ObservableObject {
    static let shared = MicHealth()

    @Published private(set) var notHearing = false

    func set(notHearing: Bool) {
        guard self.notHearing != notHearing else { return }
        self.notHearing = notHearing
    }
}
