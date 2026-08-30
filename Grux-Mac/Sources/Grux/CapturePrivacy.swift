import Foundation
import ScreenCaptureKit

// Capture privacy. The thing that decides what Grux is not allowed to look at.
//
// Grux photographs the screen on a timer and sends the frame to a vision model.
// Before this existed there was exactly one exclusion in the whole app, a check
// that skipped ANALYSIS when Grux itself was frontmost, and nothing at all that
// stopped a frame containing an open password manager from being encoded to JPEG
// and posted to an API. On one machine belonging to one person who knew what he
// had built, that was a risk he was carrying knowingly. Shipped to a stranger it
// is a credential exfiltration path with a timer on it.
//
// Two layers, because they fail differently:
//
//   1. WINDOW EXCLUSION, the real one. Excluded windows are removed from the
//      SCContentFilter, so ScreenCaptureKit composites the frame without them.
//      The pixels never exist. This works even when the excluded app is not
//      frontmost, which matters: a password manager sitting visible on a second
//      monitor or beside the editor is exactly the case a frontmost-only check
//      misses, and it is not an unusual way to use one.
//
//   2. FRONTMOST SUPPRESSION, the blunt one. If the excluded app is frontmost,
//      skip the capture entirely rather than returning a frame with a hole in
//      it. Cheaper, and it means no timing signal is recorded either.
//
// Both are driven by the same lists, both are user-editable, and the defaults
// are deliberately narrow: credential holders only. Blocking anything a user
// might reasonably want watched, editors, browsers, chat apps, would train them
// to empty the list, and an emptied list protects nothing.
enum CapturePrivacy {

    // Password managers, the system keychain, and authenticator apps. Bundle ids
    // verified against the shipping macOS applications rather than guessed from
    // the vendor name, because a wrong id fails silently and looks identical to
    // a working one: the app is simply never in the list, so it is never excluded.
    static let defaultExcludedBundleIds: [String] = [
        "com.1password.1password",              // 1Password 8
        "com.agilebits.onepassword7",           // 1Password 7
        "com.agilebits.onepassword-osx",        // 1Password 6 and earlier
        "com.bitwarden.desktop",                // Bitwarden
        "org.keepassxc.keepassxc",              // KeePassXC
        "com.dashlane.Dashlane",                // Dashlane
        "com.lastpass.LastPass",                // LastPass
        "in.sinew.Enpass-Desktop",              // Enpass
        "com.markmcguill.strongbox.mac",        // Strongbox
        "com.nordpass.macos",                   // NordPass
        "me.proton.pass.electron",              // Proton Pass
        "com.apple.keychainaccess",             // Keychain Access
        "com.apple.Passwords",                  // Passwords (macOS 15+)
        "com.maxgoedjen.Secretive.Host",        // Secretive (SSH keys in the Secure Enclave)
        "com.authy.authy-mac",                  // Authy
    ]

    // Window-title patterns, matched case-insensitively as substrings. This is
    // the net under the bundle list, and it is what covers the case the bundle
    // list structurally cannot: a credential shown inside an app that is not a
    // credential app. A bank in a browser tab, a recovery phrase in a text
    // editor, an SSH key in a terminal. None of those have a bundle id worth
    // blocking wholesale, and all of them put the word on the title bar.
    //
    // Erring toward not capturing is the correct direction of error here. A
    // missed frame costs one tick of context. A captured one cannot be recalled.
    static let defaultExcludedTitlePatterns: [String] = [
        "password", "passphrase", "seed phrase", "recovery phrase",
        "recovery key", "private key", "secret key", "api key",
        "one-time code", "verification code", "authenticator",
        "credit card", "card number", "social security", "bank",
    ]

    /// Should this window be cut out of the frame?
    static func shouldExclude(_ window: SCWindow,
                              bundleIds: [String],
                              titlePatterns: [String],
                              selfBundleId: String) -> Bool {
        let owner = window.owningApplication?.bundleIdentifier ?? ""
        // Grux excludes itself from every frame. Previously it only declined to
        // ANALYSE its own window, which is a different thing: its own chat
        // transcript, holding whatever the user just pasted, was still in the
        // pixels of every frame captured while any other app was frontmost.
        if !owner.isEmpty, owner == selfBundleId { return true }
        if bundleIds.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) { return true }
        let title = (window.title ?? "").lowercased()
        guard !title.isEmpty else { return false }
        return titlePatterns.contains { matches($0, title) }
    }

    /// One pattern against one already-lowercased title.
    ///
    /// The trim is the whole point. A pattern of a single space is not empty, so
    /// an is-it-empty check waves it through, and " " is a substring of very
    /// nearly every window title in existence: one stray space in the settings
    /// editor would silently switch off all screen capture, and the only symptom
    /// would be Grux quietly going blind. Swift's own `contains("")` is false,
    /// so the truly empty case was never the risk. This one was.
    static func matches(_ pattern: String, _ lowercasedTitle: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return false }
        return lowercasedTitle.contains(p)
    }

    /// Is the app in front of the user right now one we refuse to photograph?
    /// Returns the reason to show, or nil when capture may proceed.
    static func frontmostBlockReason(bundleId: String,
                                     windowTitle: String,
                                     bundleIds: [String],
                                     titlePatterns: [String]) -> String? {
        if bundleIds.contains(where: { $0.caseInsensitiveCompare(bundleId) == .orderedSame }) {
            return "excluded app"
        }
        let title = windowTitle.lowercased()
        if !title.isEmpty,
           let hit = titlePatterns.first(where: { matches($0, title) }) {
            return "window title matched \"\(hit.trimmingCharacters(in: .whitespacesAndNewlines))\""
        }
        return nil
    }
}

/// Thrown by the capturer when privacy rules forbid the frame. Distinct from a
/// capture failure on purpose: a caller must be able to tell "I am not allowed
/// to look" from "looking broke", and report the first as normal operation
/// rather than as an error the user should try to fix.
struct CaptureBlocked: LocalizedError {
    let appName: String
    let reason: String
    var errorDescription: String? {
        "Screen capture is off for \(appName) (\(reason))."
    }
}
