import Foundation

/// Applies `ListeningMicPolicy` around a listening session and puts the
/// person's own choice back afterwards.
///
/// Restoring matters as much as moving: Grux changing the system default
/// input and leaving it changed would quietly take over a setting it does
/// not own. The restore is skipped if the default is no longer the device
/// Grux set, because then the person (or another app) has chosen since, and
/// their choice wins.
@MainActor
final class ListeningMicGuard {
    static let shared = ListeningMicGuard()

    private(set) var movedTo: String?
    private var restoreTo: String?
    private var holders: Set<String> = []

    /// Seams for tests. Defaults reach CoreAudio.
    var candidates: () -> [ListeningMicPolicy.Candidate] = { MicDevices.listeningCandidates() }
    var currentUID: () -> String? = { MicDevices.systemDefaultInputUID() }
    var setDefault: (String) -> Bool = { MicDevices.setSystemDefaultInput(toUID: $0) }
    var preferredUID: () -> String? = { MicWhitelist.preferredInputUID }
    var enabled: () -> Bool = { AppState.shared.config.listenOnTheMacsOwnMic }
    var log: (String) -> Void = { WakeLog.shared.log($0) }

    private init() {}

    /// Call as a listener starts. `holder` names the listener so two of them
    /// starting and stopping cannot restore the device out from under each
    /// other.
    func claim(_ holder: String) {
        holders.insert(holder)
        let devices = candidates()
        let now = currentUID()
        let current = devices.first(where: { $0.uid == now })
        guard let target = ListeningMicPolicy.inputToUse(
            current: current, devices: devices, preferredUID: preferredUID(), enabled: enabled())
        else { return }
        guard target != now else { return }
        guard let to = devices.first(where: { $0.uid == target }), let from = current else { return }
        guard setDefault(target) else {
            log("listening mic: could not move off \(from.name), staying on it")
            return
        }
        if restoreTo == nil { restoreTo = from.uid }
        movedTo = target
        log("listening mic: " + ListeningMicPolicy.explanation(movedFrom: from, to: to))
    }

    /// Call as a listener stops. The device goes back once the last listener
    /// has let go.
    func release(_ holder: String) {
        holders.remove(holder)
        guard holders.isEmpty, let back = restoreTo, let moved = movedTo else { return }
        restoreTo = nil
        movedTo = nil
        guard currentUID() == moved else {
            log("listening mic: input changed while listening, leaving it alone")
            return
        }
        let name = candidates().first(where: { $0.uid == back })?.name ?? back
        if setDefault(back) {
            log("listening mic: put the input back to \(name)")
        } else {
            log("listening mic: \(name) is gone, leaving the input where it is")
        }
    }
}
