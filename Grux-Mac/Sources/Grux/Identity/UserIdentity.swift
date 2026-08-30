import Foundation

/// Who is using this copy of Grux, and what this copy of Grux is called.
///
/// Grux was written for one person and had his name compiled into it in 692
/// places: greetings, system prompts, speech-recognition biasing, tool
/// descriptions. That is not a cosmetic problem. A name inside a prompt changes
/// what the model believes about who it is talking to, and a name inside the
/// Whisper vocabulary changes what the microphone is willing to hear.
///
/// The fix has two halves, and only the first half needs this type:
///
/// 1. **Display** reads `name` and renders nothing when it is empty. A greeting
///    with no name is a correct greeting; a greeting with somebody else's name
///    is not.
/// 2. **Prompts** were rewritten into second person and do NOT interpolate
///    anything from here. "You" needs no configuration, stays cache-stable, and
///    cannot go stale. The single exception is ``systemPromptLine()``, which
///    states the user's name once, in one place, when they have set one.
///
/// Contract: `grux.identity.user_name` (no default, empty renders a greeting
/// with no name) and `grux.identity.assistant_name` (default `Grux`), both
/// under CR-19 in `docs/contract.md` section 2.5.
@MainActor
enum UserIdentity {

    /// What to call the person using Grux. Empty until they say, which is the
    /// honest default: Grux does not know a new user's name and should not
    /// pretend it does.
    static var name: String {
        AppState.shared.config.userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the assistant calls itself, which is NOT the app's name. The app is
    /// Grux; the assistant it runs is Jax by default. Configurable because the
    /// source is MIT and a rename is the user's right.
    ///
    /// Read by `JaxProfile.persona`, which is the one place the assistant asserts
    /// its own identity to the model. Until 2026-08-17 nothing read this at all
    /// and the persona hardcoded the name twice, so the setting was a config key
    /// with no effect.
    ///
    /// The default is `Jax` rather than `Grux` deliberately: that is the name the
    /// shipped persona already used, so wiring this up changes NOTHING about what
    /// an existing install says. Making the setting work should not quietly
    /// rename somebody's assistant. Contract section 2.5 was amended to match
    /// (CR-30); it had recorded `Grux`, which no code path ever produced.
    static var assistantName: String {
        let n = AppState.shared.config.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Jax" : n
    }

    /// True once the user has told Grux who they are. The onboarding gate reads
    /// this rather than a separate "did they finish" flag, so the two can never
    /// disagree.
    static var hasName: Bool { !name.isEmpty }

    /// The one place a name enters a prompt. Empty string when unset, so the
    /// prompt simply does not mention a name rather than naming a placeholder.
    ///
    /// Deliberately one line in one block. Interpolating a name at each of the
    /// hundreds of prompt sites would reintroduce exactly the problem this type
    /// exists to remove, one call site at a time.
    static func systemPromptLine() -> String {
        guard hasName else { return "" }
        return "The user's name is \(name). Use it when you address them directly."
    }

    /// Greeting subject. Empty renders "Good morning" rather than "Good
    /// morning, " with a dangling comma, which is why this returns the whole
    /// suffix and not just the name.
    static func greetingSuffix() -> String {
        hasName ? ", \(name)" : ""
    }
}
