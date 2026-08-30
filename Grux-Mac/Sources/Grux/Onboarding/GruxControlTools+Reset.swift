import Foundation
import GruxMCPCore

// MARK: - grux_reset

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// Put one scope back to never-asked.
    ///
    /// ## Never-asked is not off, and `features` is where that bites
    ///
    /// `FeatureSelection.clear()` removes the stored selection, and absence means everything
    /// is ON: the doc comment on that file calls it the most important line in it. So this
    /// turns all of them back on and makes first run ask again. The plain English reading of
    /// "reset features" is the exact opposite, so every reply here says which one happened
    /// rather than leaving the caller to guess from the word.
    ///
    /// ## What it cannot do, and does not pretend to
    ///
    /// It revokes no macOS permission. Microphone, screen recording and the rest are held by
    /// TCC, only System Settings can take one back, and a reply that implied otherwise would
    /// leave somebody believing the microphone had been released when it had not. It deletes
    /// no content either: notes, meetings and transcripts are untouched.
    static func reset(scope: String) -> [String: Any] {
        // The four in the order a person reads them, three specific then the aggregate. NOT
        // sorted: `all` is a superset of the other three, and filing it first would read as
        // the first choice rather than the last resort.
        let scopes = ["features", "brand", "consent", "all"]
        let wanted = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard scopes.contains(wanted) else {
            // A REFUSAL, NOT A GUESS. A scope this does not recognise cannot be narrowed to
            // one the caller meant, and picking the nearest would forget something nobody
            // asked to forget.
            let list = "features, brand, consent or all"
            return MCPWire.textFailure(wanted.isEmpty
                ? "grux_reset needs a scope and will not pick one: \(list)."
                : "No scope called \(scope). There are four: \(list).")
        }

        var done: [[String: Any]] = []
        if wanted == "features" || wanted == "all" { done.append(resetFeatureSelection()) }
        if wanted == "brand" || wanted == "all" { done.append(resetCurrentBrand()) }
        if wanted == "consent" || wanted == "all" { done.append(contentsOf: resetConsent()) }

        // `all` returns its members ONE BY ONE rather than a count. "Reset 5 things" is the
        // summary a caller has to expand before it can be checked, and the one shape of
        // reply that can be true in total while being wrong about a part of it.
        return MCPWire.textResult(jsonText([
            "scope": wanted,
            "reset": done,
            "never": "No macOS permission was revoked: only System Settings can do that, "
                   + "under Privacy & Security. Nothing you wrote was deleted either, so "
                   + "notes, meetings and transcripts are exactly where they were.",
        ]))
    }

    /// Forget which features were chosen.
    ///
    /// Read before the write, because "12 of 39 were chosen" and "no choice was ever stored"
    /// are different answers and the second one means this call changed nothing at all.
    private static func resetFeatureSelection() -> [String: Any] {
        let known = FeatureRegistry.rows.count
        let before = FeatureSelection.stored()
        FeatureSelection.clear()
        return [
            "id": "features",
            "label": "Feature selection",
            "changed": before != nil,
            "was": before.map { "\($0.count) of \(known) were chosen" }
                ?? "no choice was stored",
            "note": "All \(known) features are on again and first run asks which ones you "
                  + "want. That is the opposite of choosing none.",
        ]
    }

    private static func resetCurrentBrand() -> [String: Any] {
        let before = UserDefaults.standard.string(forKey: currentBrandKey)
        UserDefaults.standard.removeObject(forKey: currentBrandKey)
        return [
            "id": "brand",
            "label": "Current brand",
            "changed": before != nil,
            "was": before.map { "\($0) was current" } ?? "none was set",
            "note": "No brand is current. grux use <brand> sets one again.",
        ]
    }

    /// Three answers, not one, and every case of `MicConsent.Feature` by name.
    ///
    /// That enum is not `CaseIterable`, so a third listening feature added to it would keep
    /// its acknowledgement through `grux reset consent` until somebody added a line here.
    /// It is the one thing in this file the compiler cannot catch, which is why it is
    /// written down rather than left to be noticed.
    private static func resetConsent() -> [[String: Any]] {
        let recordingWas = AppState.shared.config.recordingConsentAcknowledged
        RecordingConsent.reset()

        let ambientWas = MicConsent.isAcknowledged(.ambient)
        let wakeWordWas = MicConsent.isAcknowledged(.wakeWord)
        MicConsent.reset(.ambient)
        MicConsent.reset(.wakeWord)

        func was(_ acknowledged: Bool) -> String {
            acknowledged ? "was acknowledged" : "was never answered"
        }

        return [
            ["id": "consent.recording",
             "label": "Meeting recording",
             "changed": recordingWas,
             "was": was(recordingWas),
             "note": "The next meeting recording asks before it starts."],
            ["id": "consent.microphone.ambient",
             "label": "Ambient listening",
             "changed": ambientWas,
             "was": was(ambientWas),
             "note": "Turning ambient listening on asks before it takes the microphone."],
            ["id": "consent.microphone.wake-word",
             "label": "Wake word",
             "changed": wakeWordWas,
             "was": was(wakeWordWas),
             "note": "Turning the wake word on asks before it takes the microphone."],
        ]
    }
}
