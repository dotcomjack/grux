import Foundation
import UserNotifications
import AppKit

// Everything a triaged notification needs to either banner now (interrupt),
// fold into the hourly digest (batch), or leave only a timeline record
// (silent). Built by the send* helpers below, consumed by route(_:).
struct TriageEnvelope {
    var identifier: String
    var title: String
    var body: String
    var sound: Bool = true
    var categoryIdentifier: String? = nil
    var userInfo: [String: Any] = [:]
    // Spoken on interrupt when the category is in speakOnInterrupt.
    // Defaults to the title when nil.
    var speechText: String? = nil
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() {}

    // MARK: - Triage routing (blueprint section 03)

    // Every notification flows through here. The policy store resolves the
    // category's interrupt/batch/silent action (actionRequired upgrades
    // blockers; quiet hours downgrade interrupts), the log entry is the
    // timeline record, and only interrupts reach UNUserNotificationCenter.
    func route(_ category: TriageCategory, actionRequired: Bool = false, _ env: TriageEnvelope) {
        let action = TriagePolicyStore.shared.resolve(
            category: category, actionRequired: actionRequired, at: Date()
        )
        TriagePolicyStore.shared.logTriage(category: category, action: action, title: env.title)
        switch action {
        case .interrupt:
            post(env)
            if TriagePolicyStore.shared.speakOnInterrupt.contains(category) {
                SpeechEngine.shared.speak(env.speechText ?? env.title)
            }
        case .batch:
            TriageBatchQueue.shared.enqueue(category: category, title: env.title, body: env.body)
        case .silent:
            break // logTriage above is the delivery
        }
    }

    // The pre-triage posting path, byte-for-byte what the send* helpers used
    // to do inline. Only route(_:) calls this.
    private func post(_ env: TriageEnvelope) {
        let content = UNMutableNotificationContent()
        content.title = env.title
        content.body = env.body
        content.sound = env.sound ? .default : nil
        if let cat = env.categoryIdentifier { content.categoryIdentifier = cat }
        if !env.userInfo.isEmpty { content.userInfo = env.userInfo }
        let req = UNNotificationRequest(identifier: env.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        registerCategories()
    }

    private func registerCategories() {
        let stillOnIt = UNNotificationAction(identifier: "grux.stillOnIt", title: "Still on it", options: [])
        let switchTask = UNNotificationAction(identifier: "grux.switchTask", title: "Switch task", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "grux.snooze", title: "Snooze 15m", options: [])
        let focusDriftCat = UNNotificationCategory(identifier: "grux.focusDrift", actions: [stillOnIt, switchTask, snooze], intentIdentifiers: [], options: [])

        // Agent paused: auth limit hit. The action set mirrors the Resume
        // sheet: tapping the banner itself opens the Resume sheet for full
        // controls; the inline actions are quick paths.
        let resume = UNNotificationAction(identifier: "grux.agent.resume", title: "Switch account & resume", options: [.foreground])
        let snoozeHour = UNNotificationAction(identifier: "grux.agent.snooze1h", title: "Snooze 1h", options: [])
        let cancelJob = UNNotificationAction(identifier: "grux.agent.cancel", title: "Cancel job", options: [.destructive])
        let agentPausedCat = UNNotificationCategory(
            identifier: "grux.agentPaused",
            actions: [resume, snoozeHour, cancelJob],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([focusDriftCat, agentPausedCat])
    }

    func sendDriftNotification(currentTask: String, activeApp: String, rationale: String, suggested: String?, eventId: UUID, message: String? = nil) {
        // Prefer the model's punchy nudge copy; fall back to the old-style
        // "in <app> • <rationale>" body.
        let body: String
        if let message, !message.isEmpty {
            body = message
        } else {
            var parts: [String] = ["In \(activeApp)"]
            if let suggested { parts.append("Looks like: \(suggested)") }
            parts.append(rationale)
            body = parts.joined(separator: " • ")
        }
        route(.reminders, TriageEnvelope(
            identifier: "grux.drift.\(eventId.uuidString)",
            title: "Grux: drift from \"\(currentTask)\"",
            body: body,
            categoryIdentifier: "grux.focusDrift",
            userInfo: ["eventId": eventId.uuidString, "suggested": suggested ?? ""],
            speechText: body
        ))
    }

    // Quiet positive confirmation when the user returns to focus after drifting.
    // No sound, the green glow carries the signal; this just leaves a record
    // in Notification Center.
    func sendRefocusConfirmation(currentTask: String) {
        route(.reminders, TriageEnvelope(
            identifier: "grux.refocus.\(UUID().uuidString)",
            title: "Back on track",
            body: "Locked in on \"\(currentTask)\"",
            sound: false
        ))
    }

    // Notify the user that an agent job paused waiting for an account
    // switch. Tapping the banner posts gruxNotificationAction with
    // action=grux.agent.resume + jobId; GruxApp's handler opens the Agents
    // tab and pre-selects the paused job.
    func sendAgentPaused(jobId: String, title: String, accountLabel: String?) {
        let body: String
        if let acct = accountLabel, !acct.isEmpty {
            body = "Anthropic monthly limit hit on \(acct). Tap to switch accounts and resume."
        } else {
            body = "Anthropic monthly limit hit. Tap to switch accounts and resume."
        }
        // actionRequired: a paused swarm blocks until the user acts, so this
        // interrupts even when agentLifecycle's base policy is batch/silent
        // (quiet hours still fold it into the digest).
        route(.agentLifecycle, actionRequired: true, TriageEnvelope(
            identifier: "grux.agent.\(jobId).pausedForAuth",
            title: "Swarm paused: \(title)",
            body: body,
            categoryIdentifier: "grux.agentPaused",
            userInfo: ["jobId": jobId, "kind": "agentPaused"]
        ))
    }

    // Commands V2 milestone phase notification. Fired by
    // CommandV2PhaseNotifier when ship-ios-app crosses one of the
    // milestone phases (build, walkthrough, publish, decide-next).
    // The body deliberately stays generic, never includes ASC feedback
    // text, secrets, or run state, so glancing at the lock screen
    // doesn't leak production-sensitive data.
    func notifyAgentPhaseTransition(
        commandId: String,
        runId: String,
        phaseName: String,
        phaseIndex: Int,
        totalPhases: Int
    ) {
        // userInfo carries the same keys as the bridge envelope so the tap
        // handler in AppDelegate can deep-link straight to the run detail.
        route(.commandPhases, TriageEnvelope(
            identifier: "v2.\(commandId).\(runId).phase\(phaseIndex)",
            title: "Phase \(phaseIndex)/\(totalPhases): \(phaseName)",
            body: "ship-ios-app run is at the \(phaseName) milestone.",
            userInfo: [
                "kind": "v2PhaseTransition",
                "commandId": commandId,
                "runId": runId,
                "phaseName": phaseName,
                "phaseIndex": phaseIndex,
                "totalPhases": totalPhases
            ]
        ))
    }

    // Generic free-text entry point (domain expiry, ASC rejections, schedule
    // fires, API key checks, ...). Rule-based classification first; cached
    // Haiku verdicts second. Genuinely unknown text defaults to BATCH right
    // now (never a synchronous model call on the hot path) while the Haiku
    // escalation seam classifies it in the background for next time.
    func sendInfo(title: String, body: String) {
        let env = TriageEnvelope(
            identifier: "grux.info.\(UUID().uuidString)",
            title: title,
            body: body
        )
        if let verdict = TriageClassifier.shared.classify(kind: nil, title: title, body: body) {
            route(verdict.category, actionRequired: verdict.actionRequired, env)
            return
        }
        TriageClassifier.shared.scheduleEscalation(title: title, body: body)
        TriagePolicyStore.shared.logTriage(category: .system, action: .batch, title: title)
        TriageBatchQueue.shared.enqueue(category: .system, title: title, body: body)
    }

    // Category-explicit variant for call sites that know their bucket (and
    // for blockers that must interrupt regardless of the matrix).
    func sendCategorized(_ category: TriageCategory, actionRequired: Bool = false, title: String, body: String) {
        route(category, actionRequired: actionRequired, TriageEnvelope(
            identifier: "grux.\(category.rawValue).\(UUID().uuidString)",
            title: title,
            body: body
        ))
    }

    // Hourly support-triage sweep staged new drafts. Tapping the banner opens
    // the Support Drafts window (handled in AppDelegate.handleAction via the
    // kind == "supportDrafts" branch on the default tap action).
    func sendSupportDraftsReady(newCount: Int, totalWaiting: Int) {
        route(.emailTriage, TriageEnvelope(
            identifier: "grux.support.\(UUID().uuidString)",
            title: newCount == 1 ? "1 new support draft" : "\(newCount) new support drafts",
            body: "\(totalWaiting) waiting. Tap to review and send.",
            userInfo: ["kind": "supportDrafts"]
        ))
    }

    // Foreground presentation so notifications still appear when Grux is frontmost
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let ui = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        NotificationCenter.default.post(name: .gruxNotificationAction, object: nil, userInfo: [
            "action": action,
            "userInfo": ui
        ])
        completionHandler()
    }
}

extension Notification.Name {
    static let gruxNotificationAction = Notification.Name("GruxNotificationAction")
    static let gruxActiveTaskChanged = Notification.Name("GruxActiveTaskChanged")
    static let gruxTaskStackChanged = Notification.Name("GruxTaskStackChanged")
    static let gruxFocusEvent = Notification.Name("GruxFocusEvent")
    // Posted by the fire-test-expand-job CLI trigger; observed by
    // LaunchRootView (which has the SwiftUI openWindow environment value
    // in scope) to open the AgentJobWindow scene for verification.
    static let gruxOpenAgentJobWindow = Notification.Name("GruxOpenAgentJobWindow")
}
