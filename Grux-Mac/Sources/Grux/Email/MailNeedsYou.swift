import Foundation

/// How many messages actually want something from the person.
///
/// The rail showed 245, which is an inbox size. It is the same number whether
/// today is calm or on fire, so it tells nobody anything and it is the reason
/// the count reads as wallpaper.
///
/// Two layers. `needsYou` is the FLOOR: a conservative on-device heuristic, and
/// exactly what a keyless install counts. On top of it, a provider that can
/// judge reads each NEW message the floor counts, once, and may take it out of
/// the badge when it is confident nothing is asked of the person (P-R-5,
/// surface `mail.needsYou`). The answer is stored on the message, so the rail's
/// memo stays a synchronous read and nothing is judged per render.
///
/// Conservative in one direction on purpose: when in doubt it counts the
/// message. A missed message is worse than one extra in the badge.
enum MailNeedsYou {
    /// Addresses that exist to send and never to receive.
    static let bulkSenderMarkers = [
        "noreply", "no-reply", "donotreply", "do-not-reply", "notifications@",
        "newsletter", "mailer@", "mailer-daemon", "bounce", "updates@",
        "marketing@", "news@", "digest@", "alerts@", "automated"
    ]

    /// Phrases that only appear in mail sent to a list.
    static let bulkBodyMarkers = [
        "unsubscribe", "manage your preferences", "view in browser",
        "you are receiving this", "email preferences", "opt out"
    ]

    /// The floor. Unread, not from a send-only address, not list mail.
    static func needsYou(_ message: EmailMessage) -> Bool {
        // Something already read is something already dealt with.
        guard message.isUnread else { return false }
        let sender = message.fromEmail.lowercased()
        if bulkSenderMarkers.contains(where: { sender.contains($0) }) { return false }
        let body = (message.snippet + " " + message.bodyText).lowercased()
        if bulkBodyMarkers.contains(where: { body.contains($0) }) { return false }
        return true
    }

    /// What the badge counts: the floor, less what a provider that could judge
    /// was confident asks nothing of the person. An unjudged message, and one
    /// judged on device (stored as 0.5, "cannot judge"), counts as the floor
    /// says.
    static func counts(_ message: EmailMessage) -> Bool {
        guard needsYou(message) else { return false }
        guard let p = message.needsYouProbability else { return true }
        return p >= dropBelow
    }

    static func count(_ messages: [EmailMessage]) -> Int {
        messages.filter(counts).count
    }

    // MARK: - The judgment on the engine (P-R-5)

    static let surface = "mail.needsYou"

    /// Below this a message leaves the badge. Calibrated 2026-09-21 against the
    /// live provider over 14 invented messages: every one that asked something
    /// of the person answered 0.92 or higher, every receipt, notice, FYI and
    /// thank-you answered 0.09 or lower, and the one genuinely unclear case, a
    /// cold recruiter asking for a chat, answered 0.70 and so still counts.
    /// 0.3 sits in the empty band, nearer the "nothing asked" side, because a
    /// missed message costs more than an extra one.
    static let dropBelow = 0.3

    /// A NOUL, not a score. The badge is a yes or no count, and a noul is the
    /// one question type whose on-device answer, 0.5, already means "cannot
    /// judge"; a score answers 0 on device, which would read as "no action".
    static let instructions =
        "Does this email need a reply or an action from the person it was sent to? Answer high if someone is "
        + "asking them something, waiting on them, or needs a decision, an answer, a payment, a signature or a "
        + "review from them. Answer low for receipts, shipping and order updates, confirmations, calendar "
        + "responses, sign-in and security notices that need nothing unless something is wrong, newsletters, "
        + "promotions, automated alerts, cold outreach nobody asked for, and messages that only tell them something."

    static var questions: [String: DecisionQuestion] { ["needs": .noul(instructions: instructions)] }

    /// What the provider reads: who, what about, and the start of the body,
    /// with secrets scrubbed. The body is capped so one message stays near
    /// 400 input tokens.
    static func state(_ m: EmailMessage) -> String {
        let text = m.bodyText.isEmpty ? m.snippet : m.bodyText
        return SecretRedactor.redact("From: \(m.fromName) <\(m.fromEmail)>\nSubject: \(m.subject)\n\n"
                                     + String(text.prefix(1200)))
    }

    /// The probability to store. On device a noul is 0.5, which means "cannot
    /// judge", so a local answer is stored as exactly that: the message counts
    /// as the floor says and is never asked again.
    static func probability(from result: DecisionResult) -> Double {
        guard result.provider != .local, case .noul(let p)? = result.answers["needs"] else { return 0.5 }
        return p
    }

    /// The messages a judging pass should ask about: the floor counts them and
    /// nobody has judged them. Mail the floor already excludes (read, bulk,
    /// list) is never asked.
    static func awaitingJudgement(_ messages: [EmailMessage]) -> [EmailMessage] {
        messages.filter { needsYou($0) && $0.needsYouProbability == nil }
    }

    /// The most messages one pass asks about. A first pass over an existing
    /// mailbox judges its backlog (about 50 on the operator's 245), and new
    /// mail arrives 25 per account per sweep at most, so this bounds a runaway
    /// without leaving anything unjudged: the rest wait for the next pass.
    static let judgePassLimit = 60
}
