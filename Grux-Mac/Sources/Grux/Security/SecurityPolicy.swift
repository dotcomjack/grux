import Foundation

// Persisted user policy for the Security module (items 30 + 31): prompt-scan
// toggle, URL guard toggle + user allow/deny host lists, and per-category
// Touch ID gate policies.
//
// Stored as JSON at ~/Library/Application Support/Grux/security-policy.json
// (same App Support/Grux directory FilesystemTool + Persistence already use).
// Reads are lock-protected and synchronous so URLGuard / PromptSecurity can
// consult the policy from any thread without an actor hop in the tool loop.

enum GatePolicy: String, Codable, CaseIterable, Identifiable {
    /// No biometric prompt for this category.
    case off
    /// Require Touch ID (password fallback) before the action runs.
    case require
    var id: String { rawValue }
    var label: String { self == .off ? "Off" : "Touch ID" }
}

enum SensitiveActionCategory: String, Codable, CaseIterable, Identifiable {
    /// File writes landing OUTSIDE the FilesystemTool allowlisted roots.
    /// The one category that defaults ON: an out-of-root write is the
    /// highest-blast-radius thing a future fs_write tool could do.
    case fsWriteOutsideRoots = "fs_write_outside_roots"
    /// Shell commands the ShellTool classifies as dangerous in guarded mode
    /// (network sends, deploys, force-push). Off by default; the ShellTool
    /// confirm flow already covers these, this adds biometric proof on top.
    case shellDangerous = "shell_dangerous"
    /// Outbound email sends (Resend / SMTP).
    case emailSend = "email_send"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fsWriteOutsideRoots: return "File writes outside project roots"
        case .shellDangerous:      return "Dangerous shell commands"
        case .emailSend:           return "Sending email"
        }
    }

    var defaultPolicy: GatePolicy {
        switch self {
        case .fsWriteOutsideRoots: return .require
        case .shellDangerous:      return .off
        case .emailSend:           return .off
        }
    }

    /// True when at least one tool call site actually consults the gate for
    /// this category. Only enforced categories surface a toggle in
    /// SecuritySettingsView: a visible toggle for an unenforced category
    /// advertises protection that does not exist.
    var isEnforced: Bool {
        switch self {
        // FilesystemTool is read-only today (fs_read / fs_list); there is no
        // fs_write tool to gate yet. Flip to true when one ships AND calls
        // SensitiveActionGate.authorize(.fsWriteOutsideRoots, ...).
        case .fsWriteOutsideRoots: return false
        // ShellTool.dispatch gates shell_run_confirmed.
        case .shellDangerous:      return true
        // EmailTool.composeEmail gates before ResendClient.send.
        case .emailSend:           return true
        }
    }
}

struct SecurityPolicy: Codable, Equatable {
    /// Master switch for PromptSecurity scanning of tool results + fetched web content.
    var promptScanEnabled: Bool = true
    /// Master switch for URLGuard checks on browser opens + research fetches.
    var urlGuardEnabled: Bool = true
    /// User-added hosts that are always allowed (entry matches the host and its subdomains).
    var urlAllowlist: [String] = []
    /// User-added hosts that are always denied. Denylist beats everything except the credential check.
    var urlDenylist: [String] = []
    /// Touch ID policy per category, keyed by SensitiveActionCategory rawValue.
    /// Missing keys fall back to the category default.
    var gatePolicies: [String: GatePolicy] = [:]

    func policy(for category: SensitiveActionCategory) -> GatePolicy {
        gatePolicies[category.rawValue] ?? category.defaultPolicy
    }
}

final class SecurityPolicyStore: @unchecked Sendable {
    static let shared = SecurityPolicyStore()

    private let lock = NSLock()
    private var cached: SecurityPolicy

    private static func fileURL() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base = appSupport else { return nil }
        let dir = base.appendingPathComponent("Grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("security-policy.json")
    }

    init() {
        if let url = Self.fileURL(),
           let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(SecurityPolicy.self, from: data) {
            cached = loaded
        } else {
            cached = SecurityPolicy()
        }
    }

    var policy: SecurityPolicy {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func update(_ mutate: (inout SecurityPolicy) -> Void) {
        lock.lock()
        var p = cached
        mutate(&p)
        cached = p
        lock.unlock()
        save(p)
    }

    func replace(_ policy: SecurityPolicy) {
        lock.lock()
        cached = policy
        lock.unlock()
        save(policy)
    }

    private func save(_ policy: SecurityPolicy) {
        guard let url = Self.fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(policy) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
