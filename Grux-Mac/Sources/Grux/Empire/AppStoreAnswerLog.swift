import Foundation

/// Apple's answers already announced, per app, shared by the two places that
/// announce one: the App Store Connect sweep (ASCStateMonitor) and a ship run
/// reaching decide-next (CommandV2PhaseNotifier). Whichever sees an answer
/// first claims it and announces; the other stays quiet, so one rejection is
/// one banner and one spoken line, not two.
///
/// No time window. A claim stands until a successful read shows the app in a
/// different state (`observe`), so rejected Monday, waiting for review
/// Tuesday, rejected again Thursday announces twice, and the same rejection
/// read again a week later announces nothing. A new version is a new answer:
/// 1.0 approved, then 1.0.1 approved, celebrates twice.
///
/// Apps are keyed by bundle id (else App Store Connect id), which the sweep
/// reads from Apple and a run records at check-status, so the two agree
/// whatever each calls the app.
@MainActor
final class AppStoreAnswerLog {
    static let shared = AppStoreAnswerLog(url: Persistence.supportDir.appendingPathComponent("app-store-answers.json"))

    private struct Answer: Codable {
        let state: String
        let version: String?
    }

    private let url: URL?
    private var said: [String: Answer]

    /// `url` nil keeps the log in memory only (tests).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Answer].self, from: data) {
            said = saved
        } else {
            said = [:]
        }
    }

    /// The key for an app: its bundle id, else its App Store Connect id; nil
    /// when neither is known.
    static func appKey(bundleId: String?, ascAppId: String?) -> String? {
        if let b = bundleId?.trimmingCharacters(in: .whitespaces), !b.isEmpty { return "bundle:" + b.lowercased() }
        if let a = ascAppId?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return "asc:" + a }
        return nil
    }

    /// A successful read saw `app` in `state`. A claim for any other state is
    /// released: whatever Apple says next is a new answer.
    func observe(app: String, state: String) {
        guard let answer = said[app], answer.state != state.uppercased() else { return }
        said[app] = nil
        save()
    }

    /// True when `state` (at `version`, when known) is a new answer for
    /// `app`, recording it; false when it was already announced and the app
    /// has not been seen in another state since.
    func claim(app: String, state: String, version: String? = nil) -> Bool {
        let state = state.uppercased()
        let version = version?.isEmpty == false ? version : nil
        if let answer = said[app], answer.state == state,
           version == nil || answer.version == nil || answer.version == version {
            return false
        }
        said[app] = Answer(state: state, version: version)
        save()
        return true
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(said) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
