import Foundation
import Combine

/// One credit-backed key, as this install knows it. The same shape for every
/// provider (P-R-3), persisted in `credits.json` under `Persistence.supportDir`.
///
/// AN EPISODE runs from the first response that says the credit is out to the
/// next call that succeeds. The person is told once per episode, and only if a
/// call on that key had succeeded before: a keyless install makes no calls, and
/// a key that never worked was never relied on, so neither hears anything.
struct CreditState: Codable, Equatable {
    /// A call on this key has succeeded at least once on this install.
    var hasSucceeded = false
    /// When the provider's own response said the credit is out. Nil: not known
    /// to be out.
    var exhaustedAt: Date?
    /// The person has been told about the current episode.
    var toldThisEpisode = false

    var isExhausted: Bool { exhaustedAt != nil }

    /// What the Usage card and the notice are for: out, and relied on.
    var shouldShow: Bool { isExhausted && hasSucceeded }

    /// A call succeeded, so the credit is there: the episode, if any, is over,
    /// and a later exhaustion is a new one that is told again. Returns whether
    /// anything changed, so an unchanged state is never written or published.
    mutating func recordSuccess() -> Bool {
        let before = self
        hasSucceeded = true
        exhaustedAt = nil
        toldThisEpisode = false
        return self != before
    }

    /// The provider said the credit is out. Returns whether to tell the person
    /// now: the first time in this episode, and only after a prior success.
    mutating func recordExhausted(at date: Date) -> Bool {
        if exhaustedAt == nil { exhaustedAt = date }
        guard hasSucceeded, !toldThisEpisode else { return false }
        toldThisEpisode = true
        return true
    }
}

/// What the person is told when a credit runs out: what got worse, in plain
/// words, and where to refill. One notification and one Usage card line, both
/// from here, so the two can never describe the same outage differently.
struct CreditNotice: Equatable {
    let provider: CreditProvider
    let title: String
    let body: String

    /// The Usage card's one status line for this provider.
    var statusLine: String { "\(title). \(body)" }

    static func `for`(_ provider: CreditProvider) -> CreditNotice {
        switch provider {
        case .jev:
            // What on device actually does, from the code, not a summary of it:
            // LocalDecisionProvider scores an exact phrase 0.95 and word overlap
            // at most 0.6, under the 0.70 execute threshold; the voice router
            // only treats words as room talk when a provider that can judge is
            // sure (`providerSureItIsChatter`); and on device a noul is 0.5,
            // "cannot judge", so the mail needs-you pass and the notification
            // content judgment (P-R-5) leave everything to their keyword floors.
            return CreditNotice(
                provider: .jev,
                title: "Jev is out of credit",
                body: "Until you refill, Grux decides on this Mac: it acts only on exact phrases, "
                    + "is worse at telling room talk from requests, and stops judging which mail "
                    + "and notifications need you. Refill at https://console.typesafe.ai")
        case .openRouter:
            // ChatService has no fallback for a failed OpenRouter turn: the
            // turn fails with a Retry that fails again.
            return CreditNotice(
                provider: .openRouter,
                title: "OpenRouter is out of credit",
                body: "Chat on your OpenRouter model stops answering until you refill. "
                    + "Add credit at https://openrouter.ai/settings/credits")
        case .elevenLabs:
            // SpeechEngine.speak falls back to the system voice on a failed
            // fetch; the streamed path chat replies use drops the sentence.
            return CreditNotice(
                provider: .elevenLabs,
                title: "ElevenLabs is out of credit",
                body: "Until you refill, chat replies are not read aloud and everything else Grux "
                    + "says comes in the Mac's own voice. Add credit at https://elevenlabs.io/app/subscription")
        case .replicate:
            return CreditNotice(
                provider: .replicate,
                title: "Replicate is out of credit",
                body: "Media Studio cannot make new images on Replicate until you refill. "
                    + "Add credit at https://replicate.com/account/billing")
        case .anthropic:
            // Nothing that calls ClaudeClient has a fallback: a failed Claude
            // chat turn shows a banner and a Retry, and the paths pinned to
            // Anthropic whatever chat is routed to (FocusWatcher's vision
            // check, Compare's Claude contender, the Design Studio CritiqueGate
            // and the QualityGate diff review) simply fail. Chat is named
            // conditionally because it is often routed elsewhere.
            return CreditNotice(
                provider: .anthropic,
                title: "Anthropic is out of credit",
                body: "Until you refill, everything Grux asks Claude to do stops: chat when it runs on a "
                    + "Claude model, focus checks, Compare, Design Studio critiques and diff reviews. "
                    + "Add credit at https://platform.claude.com/settings/billing")
        }
    }
}

/// Every credit-backed key's state, read from the providers' own responses.
///
/// Callers report two things only: a call that succeeded, and a response that
/// did not. `recordFailure` hands the status and body to `CreditSignature`,
/// and ONLY a documented out of credit response marks anything. A timeout has
/// no response and is never reported. Nothing here retries, and nothing here
/// changes which provider a caller uses: each keeps the fallback it had.
@MainActor
final class CreditMonitor: ObservableObject {
    /// The app's monitor. Only this one posts a notification, and never under
    /// test: a monitor a test builds keeps the no-op `notify`, like
    /// `VoiceCommandRouter.banner`, and the shared one's file lives in the
    /// suite's temporary directory (`Persistence.supportDir`).
    static let shared: CreditMonitor = {
        let monitor = CreditMonitor(storeURL: Persistence.supportDir.appendingPathComponent("credits.json"))
        if !Persistence.isUnderTest {
            monitor.notify = { NotificationManager.shared.sendCreditNotice($0) }
        }
        return monitor
    }()

    @Published private(set) var states: [CreditProvider: CreditState] = [:]

    /// Tells the person. Called at most once per episode per provider.
    var notify: @MainActor (CreditNotice) -> Void = { _ in }

    private let storeURL: URL?
    private let now: () -> Date
    private let isExhaustedResponse: (CreditProvider, Int, Data) -> Bool

    init(storeURL: URL?,
         now: @escaping () -> Date = Date.init,
         isExhaustedResponse: @escaping (CreditProvider, Int, Data) -> Bool = CreditSignature.isExhausted) {
        self.storeURL = storeURL
        self.now = now
        self.isExhaustedResponse = isExhaustedResponse
        if let storeURL {
            let saved = Persistence.load([String: CreditState].self, from: storeURL, fallback: [:])
            states = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                CreditProvider(rawValue: key).map { ($0, value) }
            })
        }
    }

    func state(_ provider: CreditProvider) -> CreditState { states[provider] ?? CreditState() }

    /// A call on this key succeeded. Cheap on the hot path: after the first
    /// success, an unexhausted key changes nothing, so nothing is written or
    /// published.
    func recordSuccess(_ provider: CreditProvider) {
        var s = state(provider)
        let wasExhausted = s.isExhausted
        guard s.recordSuccess() else { return }
        states[provider] = s
        save()
        if wasExhausted { WakeLog.shared.log("credits: \(provider.rawValue) answered again, the episode is over") }
    }

    /// A response that was not a success. Marks the credit out only when the
    /// provider's documented out of credit response says so, and tells the
    /// person once per episode. Returns whether it was that response.
    @discardableResult
    func recordFailure(_ provider: CreditProvider, status: Int, body: Data) -> Bool {
        guard isExhaustedResponse(provider, status, body) else {
            logUnrecognised(provider, status: status, body: body)
            return false
        }
        var s = state(provider)
        let before = s
        // Whole seconds, which is what the ISO 8601 file keeps, so the state
        // in memory is the state a relaunch reads back.
        let at = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let tell = s.recordExhausted(at: at)
        if s != before {
            states[provider] = s
            save()
            WakeLog.shared.log("credits: \(provider.rawValue) is out of credit (HTTP \(status))"
                               + (tell ? ", telling the person" : s.hasSucceeded ? "" : ", never used here, so silent"))
        }
        if tell { notify(CreditNotice.for(provider)) }
        return true
    }

    /// THE Usage card's status line: every credit that is out and was relied
    /// on, in one line. Nil when there is none, so the card holds no space.
    var statusLine: String? {
        let lines = CreditProvider.allCases.filter { state($0).shouldShow }.map { CreditNotice.for($0).statusLine }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Provider and status pairs already logged this run.
    private var loggedFailures: Set<String> = []

    /// HOW AN UNDOCUMENTED SHAPE GETS OBSERVED. Jev and Replicate document no
    /// out of credit response, so their detectors are off; the day one of
    /// them refuses for money, this line in WakeLog is the evidence that turns
    /// the detector on. The first failure of each provider and status per run
    /// only, so an outage writes one line, not one per decision. The body is
    /// cut short and redacted.
    private func logUnrecognised(_ provider: CreditProvider, status: Int, body: Data) {
        guard loggedFailures.insert("\(provider.rawValue) \(status)").inserted else { return }
        let text = SecretRedactor.redact(String(decoding: body.prefix(240), as: UTF8.self))
        WakeLog.shared.log("credits: \(provider.rawValue) answered HTTP \(status), "
                           + "not a documented out of credit response: \(text)")
    }

    private func save() {
        guard let storeURL else { return }
        Persistence.save(Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) }), to: storeURL)
    }
}

extension CreditMonitor {
    /// Reports one provider response from any context (an actor, a background
    /// task): a 2xx is a success on the key, anything else is read for what it
    /// says about the credit. Only a call that actually reached the provider
    /// and spends its credit belongs here.
    nonisolated static func observe(_ provider: CreditProvider, status: Int, body: Data,
                                    on monitor: CreditMonitor? = nil) async {
        await MainActor.run {
            let target = monitor ?? CreditMonitor.shared
            if (200..<300).contains(status) {
                target.recordSuccess(provider)
            } else {
                target.recordFailure(provider, status: status, body: body)
            }
        }
    }
}

extension NotificationManager {
    /// A credit ran out. Categorized rather than `sendInfo`, for two reasons:
    /// `sendInfo` has no once guard (the episode rule in `CreditState` is the
    /// guard), and with a decision key it first asks Jev whether the notice
    /// matters, which for a Jev notice is a round trip to the provider that
    /// just said it has no credit. `.system` with action required interrupts
    /// once, and quiet hours still fold it into the digest.
    func sendCreditNotice(_ notice: CreditNotice) {
        sendCategorized(.system, actionRequired: true, title: notice.title, body: notice.body)
    }
}
