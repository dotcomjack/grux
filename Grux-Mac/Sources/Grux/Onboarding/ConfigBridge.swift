import Foundation

/// The contract keys Grux implements under a Swift name.
///
/// ## The problem this solves
///
/// `docs/contract.md` declares 56 config keys. Ten of them are read as literal `grux.*`
/// UserDefaults strings and `grux config` could already set those. The rest looked, to a
/// grep, like keys nothing implements, and they were once described that way in a handoff.
///
/// That was wrong, and measurably so. `grux.capture.excluded_bundle_ids` IS implemented: it
/// is `GruxConfig.captureExcludedBundleIds`, live in four files including the window-title
/// privacy gate. It was a NAMING MISMATCH, not a dead feature. The person reading the
/// contract sees a key, `grux config` says Grux does not read it, and both the key and the
/// feature are real.
///
/// So this is the missing half of the bridge: contract key on one side, the property that
/// already implements it on the other.
///
/// ## What is deliberately NOT here
///
/// **Credentials.** Eleven of the 56 carry `secret: yes`. None of them appear below and none
/// of them ever should: a secret handed over as a command argument is in the shell history,
/// in the process table for any local `ps`, and in whatever logs the invocation. `grux keys`
/// owns those and asks at a TTY with echo off.
///
/// **`grux.focus.cadence_seconds`.** It maps cleanly onto `captureIntervalSeconds` and is
/// left out on purpose, because that property is not read by anything: the focus watcher
/// schedules on the tier's cadence. Settings already renders it read-only and says so. A
/// setter for a value nothing consults is the exact defect this file exists to remove, and
/// adding one here would be committing it in a new place.
enum ConfigBridge {

    /// One contract key, and how to read and write the thing that implements it.
    ///
    /// Read and write are closures rather than a key path because the underlying types
    /// differ (Bool, Int, String, [String], and one enum-shaped pair of strings) and every
    /// value crossing the socket is a string either way.
    struct Entry {
        let key: String
        /// Human shape, shown in `grux config` so somebody knows what a valid value is.
        let shape: String
        let read: @MainActor () -> String
        /// Returns nil when the value does not parse, so the refusal can say what it wanted
        /// rather than writing a zero and reporting success.
        let write: @MainActor (String) -> String?
    }

    private static func str(_ key: String, _ shape: String,
                           _ get: @escaping @MainActor () -> String,
                           _ set: @escaping @MainActor (String) -> Void) -> Entry {
        Entry(key: key, shape: shape, read: get, write: { v in set(v); return v })
    }

    private static func bool(_ key: String,
                            _ get: @escaping @MainActor () -> Bool,
                            _ set: @escaping @MainActor (Bool) -> Void) -> Entry {
        Entry(key: key, shape: "true or false",
              read: { get() ? "true" : "false" },
              write: { v in
                  switch v.lowercased() {
                  case "true", "yes", "on", "1":   set(true);  return "true"
                  case "false", "no", "off", "0":  set(false); return "false"
                  default: return nil
                  }
              })
    }

    private static func int(_ key: String, _ shape: String, range: ClosedRange<Int>,
                           _ get: @escaping @MainActor () -> Int,
                           _ set: @escaping @MainActor (Int) -> Void) -> Entry {
        Entry(key: key, shape: shape,
              read: { String(get()) },
              write: { v in
                  // RANGE CHECKED, not clamped. Clamping "25" to 23 would report success for
                  // a value the person did not ask for, and they would find out from the
                  // behaviour rather than from the answer.
                  guard let n = Int(v.trimmingCharacters(in: .whitespaces)), range.contains(n)
                  else { return nil }
                  set(n); return String(n)
              })
    }

    private static func list(_ key: String,
                            _ get: @escaping @MainActor () -> [String],
                            _ set: @escaping @MainActor ([String]) -> Void) -> Entry {
        Entry(key: key, shape: "comma separated, empty clears the list",
              read: { get().joined(separator: ", ") },
              write: { v in
                  let entries = v.split(separator: ",")
                      .map { $0.trimmingCharacters(in: .whitespaces) }
                      .filter { !$0.isEmpty }
                  set(entries)
                  return entries.joined(separator: ", ")
              })
    }

    @MainActor
    static let entries: [Entry] = [
        str("grux.model.chat_id", "a model id",
            { AppState.shared.config.model },
            { AppState.shared.config.model = $0; AppState.shared.saveConfig() }),
        str("grux.model.vision_id", "a model id",
            { AppState.shared.config.focusVisionModel },
            { AppState.shared.config.focusVisionModel = $0; AppState.shared.saveConfig() }),

        bool("grux.focus.enabled",
             { AppState.shared.config.screenAnalysisEnabled },
             { AppState.shared.config.screenAnalysisEnabled = $0; AppState.shared.saveConfig() }),
        int("grux.focus.nudge_after_strikes", "1 to 20", range: 1...20,
            { AppState.shared.config.driftThreshold },
            { AppState.shared.config.driftThreshold = $0; AppState.shared.saveConfig() }),
        int("grux.focus.active_hours_start", "hour, 0 to 23", range: 0...23,
            { AppState.shared.config.activeHoursStart },
            { AppState.shared.config.activeHoursStart = $0; AppState.shared.saveConfig() }),
        int("grux.focus.active_hours_end", "hour, 0 to 23", range: 0...23,
            { AppState.shared.config.activeHoursEnd },
            { AppState.shared.config.activeHoursEnd = $0; AppState.shared.saveConfig() }),

        // The two the audit turned up, and the reason this file exists at all: the window
        // title privacy gate reads these on every capture and there was no way to set them
        // from outside the app.
        list("grux.capture.excluded_bundle_ids",
             { AppState.shared.config.captureExcludedBundleIds },
             { AppState.shared.config.captureExcludedBundleIds = $0; AppState.shared.saveConfig() }),
        list("grux.capture.excluded_window_titles",
             { AppState.shared.config.captureExcludedTitlePatterns },
             { AppState.shared.config.captureExcludedTitlePatterns = $0; AppState.shared.saveConfig() }),

        Entry(key: "grux.voice.tts_provider", shape: "system or elevenlabs",
              read: { AppState.shared.config.useElevenLabs ? "elevenlabs" : "system" },
              write: { v in
                  switch v.lowercased() {
                  case "elevenlabs": AppState.shared.config.useElevenLabs = true
                  case "system":     AppState.shared.config.useElevenLabs = false
                  default: return nil
                  }
                  AppState.shared.saveConfig()
                  return v.lowercased()
              }),

        str("grux.identity.user_name", "what Grux calls you",
            { AppState.shared.config.userName },
            { AppState.shared.config.userName = $0; AppState.shared.saveConfig() }),
        str("grux.identity.assistant_name", "what it calls itself",
            { AppState.shared.config.assistantName },
            { AppState.shared.config.assistantName = $0; AppState.shared.saveConfig() }),

        str("grux.developer.bundle_prefix", "reverse DNS root, e.g. com.example",
            { AppState.shared.config.developerBundlePrefix },
            { AppState.shared.config.developerBundlePrefix = $0; AppState.shared.saveConfig() }),
        str("grux.developer.team_id", "Apple Developer team id",
            { AppState.shared.config.developerTeamId },
            { AppState.shared.config.developerTeamId = $0; AppState.shared.saveConfig() }),

        // Implemented in this same wave, which is why it moved out of the "not implemented"
        // block in the contract: the key was declared "off by default" the whole time and
        // the governor ran on every launch regardless.
        bool("grux.foundry.enabled",
             { AppState.shared.config.foundryEnabled },
             { AppState.shared.config.foundryEnabled = $0; AppState.shared.saveConfig() }),

        // The listener's on switch. `grux.webhook.inbox_port` was already settable and the
        // flag that decides whether anything listens on it was not, so the port could be set
        // by somebody who then found nothing answering there.
        bool("grux.webhook.enabled",
             { AppState.shared.config.prInboxEnabled },
             { AppState.shared.config.prInboxEnabled = $0; AppState.shared.saveConfig() }),

        // Not a GruxConfig property: this one lives in UserDefaults under its own name,
        // written by the Settings toggle added with the first-run audit. Bridged all the same,
        // because from the contract's side it is the same kind of thing.
        bool("grux.workday.enabled",
             { WorkdayLogStore.isEnabled },
             { UserDefaults.standard.set($0, forKey: WorkdayLogStore.enabledKey) }),
    ]

    @MainActor
    static func entry(for key: String) -> Entry? { entries.first { $0.key == key } }

    @MainActor
    static var keys: [String] { entries.map(\.key) }
}
