import Foundation
import GruxShellCore

/// How much the shell tool is trusted, and the one place that decides.
///
/// BEFORE THIS, THE MODEL DECIDED. `ShellTool.claudeTools()` publishes `mode` as
/// an ordinary tool argument with the enum `["trust", "guarded", "strict"]`, and
/// `ShellDispatcher` reads it as `(input["mode"] as? String) ?? "guarded"`. The
/// default only applies when the model OMITS the field. When it supplies one,
/// whatever it supplied is what the session ran under, for the whole life of
/// that session, because `ShellSession` stores the mode at start and every
/// later `shell_run` inherits it.
///
/// Measured 2026-08-26: no reference to the shell mode existed anywhere in
/// Settings or `AppState`. The user could not see the value, could not change
/// it, and had no ceiling on it. (The `ShellMode` that DOES appear in
/// `Shell/ShellStateBus.swift` is an unrelated type with the same name: it is
/// the orb's idle / listening / thinking state, it never reaches the shell tool,
/// and finding it is not evidence this setting existed.)
///
/// What the top of that dial actually buys is the point. `ShellSafety.evaluate`
/// only consults `detectNetworkOrExternalEffect` when `mode != .trust`, so
/// `trust` is not a convenience, it is the removal of the confirmation gate on
/// network sends, deploys and force pushes. And the model does not choose its
/// arguments in a vacuum: the text it is reasoning over includes files it just
/// read and pages it just fetched, so "start the shell session in trust mode"
/// is a sentence an attacker can write into a README and the model can be
/// talked into repeating.
///
/// This is the same shape as `SessionConcurrency`, and the argument there
/// applies unchanged: telling somebody to keep a setting conservative while the
/// setting is out of their hands is not advice, it is decoration. This makes it
/// theirs.
///
/// Stored in UserDefaults rather than `GruxConfig` for the reasons
/// `SessionConcurrency` gives: it needs no Codable migration on a struct every
/// install decodes at launch, and the failure mode of a missing or unparseable
/// key is the conservative default rather than a decode error. A security
/// setting whose absence throws is a security setting that gets caught and
/// ignored.
enum ShellTrustCeiling {

    /// Namespaced to match the `grux.sessions.` and `grux.step.` convention the
    /// rest of the app uses.
    static let defaultsKey = "grux.shell.trust_ceiling"

    /// What an install that never opens Settings gets.
    ///
    /// `guarded` rather than `strict`, and the choice is deliberate rather than
    /// split-the-difference. `strict` is an allowlist of common dev binaries, so
    /// it refuses ordinary work the moment a project uses a tool nobody put on
    /// the list, and a default that breaks the feature gets turned off entirely
    /// rather than turned down. `guarded` still runs any command; it only makes
    /// the ones that reach the outside world ask first. That is the strongest
    /// setting that does not make the feature feel broken, which is the bar a
    /// default has to clear to survive.
    ///
    /// It also matches the value `ShellDispatcher` already used when the model
    /// omitted the field, so an existing install sees no behaviour change until
    /// the model asks for something MORE than it used to get by default, which
    /// is exactly the case this type exists to refuse.
    static let conservativeDefault: GruxShellCore.ShellMode = .guarded

    /// Most restrictive first. This is the order a Settings picker should render
    /// and the order the ceiling reads as a dial: down is safer.
    ///
    /// Spelled out rather than derived from `CaseIterable`, because
    /// `GruxShellCore.ShellMode` does not conform to it and the declaration
    /// order of an enum is not a promise about the ordering of its meaning.
    static let selectableModes: [GruxShellCore.ShellMode] = [.strict, .guarded, .trust]

    /// The ordering property, as a total function, so `clamp` is a comparison
    /// rather than a switch full of pairs.
    ///
    /// Higher means MORE restrictive. `strict` is the allowlist plus the confirm
    /// gate plus containment, `guarded` drops the allowlist, `trust` drops the
    /// confirm gate as well. Containment and the shadow-git snapshot apply in
    /// all three and are not part of this dial.
    static func restrictiveness(_ mode: GruxShellCore.ShellMode) -> Int {
        switch mode {
        case .trust:   return 0
        case .guarded: return 1
        case .strict:  return 2
        }
    }

    /// The user's ceiling. A missing key, an unparseable value, or a value of
    /// the wrong type all resolve to `conservativeDefault`.
    ///
    /// Read through `object(forKey:) as? String` rather than `string(forKey:)`
    /// on purpose: the convenience accessor coerces a stored number into a
    /// string, and a corrupted or wrongly migrated key that arrives as `1`
    /// should land on the conservative default rather than on whatever a
    /// coerced string happens to parse as.
    static var ceiling: GruxShellCore.ShellMode {
        get {
            guard let raw = UserDefaults.standard.object(forKey: defaultsKey) as? String,
                  let mode = GruxShellCore.ShellMode(rawValue: raw) else {
                return conservativeDefault
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// Never raises what was asked for, only lowers it.
    ///
    /// "Lower" here means less trusted, so the result is always the MORE
    /// restrictive of the two. A model that asks for `strict` while the ceiling
    /// sits at `guarded` gets `strict`, because a caller asking for less
    /// authority than it is allowed knows something the ceiling does not, and
    /// silently promoting it to the ceiling would be the same defect running the
    /// other way.
    static func clamp(_ requested: GruxShellCore.ShellMode) -> GruxShellCore.ShellMode {
        let ceilingNow = ceiling
        return restrictiveness(requested) >= restrictiveness(ceilingNow) ? requested : ceilingNow
    }

    /// The clamp as it applies to a raw tool argument, which is the shape the
    /// call site actually holds.
    ///
    /// Returns `nil` when the string is present but does not parse. That is not
    /// the same as absent and must not be treated as such: `ShellDispatcher`
    /// answers an unknown mode with a specific error the model can act on, and
    /// coercing the typo to a valid value here would replace a clear refusal
    /// with a silent guess. Absent means the model expressed no preference, and
    /// the documented default is clamped in its place.
    static func clampRawMode(_ raw: String?) -> GruxShellCore.ShellMode? {
        guard let raw, !raw.isEmpty else { return clamp(conservativeDefault) }
        guard let requested = GruxShellCore.ShellMode(rawValue: raw) else { return nil }
        return clamp(requested)
    }
}
