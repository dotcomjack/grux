import Foundation
import LocalAuthentication

// Item 31: Touch ID gating for sensitive tool actions.
//
// Policy is per SensitiveActionCategory (SecurityPolicy.swift) and defaults
// OFF for everything except fsWriteOutsideRoots: a file write landing outside
// the FilesystemTool allowlisted roots is the documented default-on case.
//
// Mechanics:
//   - LAPolicy.deviceOwnerAuthentication: Touch ID when available, with the
//     account password as the graceful system fallback. No custom password UI.
//   - A success is cached per category for 5 minutes so a burst of writes
//     does not prompt repeatedly.
//   - Fail-closed: if the policy says .require and authentication is
//     unavailable or refused, the action is denied.
//   - Every decision (granted / refused / cache hit) writes an audit line.
//
// Call shape for tool call sites:
//   guard await SensitiveActionGate.shared.authorize(.fsWriteOutsideRoots,
//       reason: "write \(path) outside project roots") else {
//       return "error: blocked, Touch ID authorization refused"
//   }

actor SensitiveActionGate {
    static let shared = SensitiveActionGate()

    private var lastSuccess: [SensitiveActionCategory: Date] = [:]
    private let cacheSeconds: TimeInterval = 300 // 5 minutes

    // Injectable evaluator so tests can run without real biometrics.
    // Defaults to the LAContext path.
    private let evaluator: @Sendable (String) async -> Bool

    init(evaluator: (@Sendable (String) async -> Bool)? = nil) {
        self.evaluator = evaluator ?? SensitiveActionGate.systemEvaluate
    }

    /// Returns true when the action may proceed.
    /// reason: short human sentence shown in the macOS auth dialog. Keep it
    /// specific ("write ~/Desktop/report.md outside project roots"), never
    /// include secrets or full file contents.
    func authorize(_ category: SensitiveActionCategory, reason: String) async -> Bool {
        let policy = SecurityPolicyStore.shared.policy.policy(for: category)
        guard policy == .require else { return true }

        if let last = lastSuccess[category], Date().timeIntervalSince(last) < cacheSeconds {
            await SecurityAuditLog.shared.record(
                kind: "action_gate", source: category.rawValue,
                verdict: "granted", tags: ["CACHE_HIT"],
                detail: "cached success within \(Int(cacheSeconds))s")
            return true
        }

        let ok = await evaluator(reason)
        if ok { lastSuccess[category] = Date() }
        await SecurityAuditLog.shared.record(
            kind: "action_gate", source: category.rawValue,
            verdict: ok ? "granted" : "refused", tags: [ok ? "AUTH_OK" : "AUTH_FAIL"],
            detail: "reason=\(reason.prefix(120))")
        return ok
    }

    /// Drop the cached success (e.g. when the user toggles a policy in Settings).
    func resetCache() {
        lastSuccess.removeAll()
    }

    // MARK: - System evaluator

    private static let systemEvaluate: @Sendable (String) async -> Bool = { reason in
        let context = LAContext()
        context.localizedCancelTitle = "Deny"
        var error: NSError?
        // deviceOwnerAuthentication = Touch ID first, password fallback baked
        // into the system sheet. If neither is available (headless / locked
        // out), fail closed.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
