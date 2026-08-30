import Foundation
import GruxMCPCore

// MARK: - grux_model

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// A surface, the config field behind it, and what that surface IS in a person's words.
    ///
    /// EVERY FIELD LISTED HERE WAS CONFIRMED TO BE READ before it was listed, one call site
    /// each: `model` in `ChatService.send` and `ModelRegistry.modelId()`, `focusVisionModel`
    /// in `FocusWatcher.judgeVision`, `offlineLLMModel` in `ModelRegistry.modelId()`,
    /// `localLLMModel` in `AmbientLLM.completeTagged`, `elevenLabsModelId` in
    /// `SpeechEngine.fetchAndSchedule`. A sixth field that nothing consumes would be the
    /// defect `grux_config` documents at length: a control that moves and changes nothing.
    private struct ModelSurface {
        let id: String
        /// The heading. `id` is what you type, this is what it is called.
        let label: String
        /// A fragment that follows the id on one line. Lower case and no period on purpose:
        /// it is a caption under a row, not a sentence.
        let used: String
        /// The longer answer to "where does this actually get sent".
        let site: String
        let field: WritableKeyPath<GruxConfig, String>
        /// What runs when the field is empty, on the one surface where anything does. `nil`
        /// means an empty value is sent as an empty model id and the call fails, so a write
        /// that would empty it is refused rather than quietly breaking the surface.
        let emptyFallback: String?
    }

    private static let modelSurfaces: [ModelSurface] = [
        ModelSurface(
            id: "chat",
            label: "Chat",
            used: "what Grux answers you with when you type or talk to it",
            site: "Every chat turn that goes to Anthropic. Web research summaries, dictation "
                + "cleanup and the gather half of deep research all resolve to the same id, "
                + "so most of what Grux spends goes through this one name.",
            field: \.model,
            emptyFallback: nil),
        ModelSurface(
            id: "local",
            label: "Ambient brain",
            used: "the local model behind Grux's background thinking",
            site: "Hourly ambient summaries, the workday log, email triage and memory "
                + "extraction, while the local brain switch is on and a local endpoint is "
                + "set. Without both of those the same work goes to Anthropic instead.",
            field: \.localLLMModel,
            emptyFallback: GruxConfig.defaultLocalModel),
        ModelSurface(
            id: "offline",
            label: "Offline chat",
            used: "what answers chat when the route is not Anthropic",
            site: "Chat, whenever it is routed off Anthropic: a local server Grux "
                + "discovered, or a custom OpenAI compatible endpoint you added.",
            field: \.offlineLLMModel,
            emptyFallback: nil),
        ModelSurface(
            id: "vision",
            label: "Focus vision",
            used: "what Focus mode reads from your screen",
            site: "Focus mode's judgement of each screenshot it takes. This is the one "
                + "surface with a real fallback: left empty, Focus borrows the chat model.",
            field: \.focusVisionModel,
            emptyFallback: "the chat model"),
        ModelSurface(
            id: "voice",
            label: "Spoken replies",
            used: "the ElevenLabs model that reads replies out loud",
            site: "Every sentence the speech engine fetches from ElevenLabs. The on-device "
                + "system voice does not use it, and neither does anything Grux hears.",
            field: \.elevenLabsModelId,
            emptyFallback: nil),
    ]

    /// The prefix `Commands/Model.swift` matches on to draw the real list instead of
    /// printing this sentence by itself. Both ends of that coupling are in the two files
    /// this handler ships with, so neither can move without the other being read.
    private static let noSuchSurface = "No surface called "

    static func model(surface: String?, name: String?) -> [String: Any] {
        // CASE INSENSITIVE, like every other list a person reads and types back. Somebody
        // sees `vision` on screen and types `Vision`, and refusing that teaches them the
        // schema in exchange for a second attempt.
        let all = modelSurfaces.sorted { $0.id.lowercased() < $1.id.lowercased() }
        let wanted = (surface ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !wanted.isEmpty else {
            return MCPWire.textResult(jsonText(["surfaces": all.map { modelRow($0) }]))
        }

        guard let s = all.first(where: { $0.id.lowercased() == wanted.lowercased() }) else {
            return MCPWire.textFailure(noSuchSurface + "\(wanted). The surfaces are "
                + modelSentence(all.map(\.id)) + ".")
        }

        guard let name else {
            return MCPWire.textResult(jsonText(["surface": modelRow(s)]))
        }

        let now = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !now.isEmpty || s.emptyFallback != nil else {
            return MCPWire.textFailure(
                "Nothing runs on an empty name here. The id goes straight to the model "
                + "server, which answers an error rather than picking something for you. "
                + "Set a model name instead: grux model \(s.id) <name>.")
        }

        let was = AppState.shared.config[keyPath: s.field]
        // THE PROPERTY, THEN THE APP'S OWN SAVE. `AppState.load()` is the only place
        // config.json is ever read and there is no watcher on it, so a file written
        // underneath the running app is clobbered by the next save the app makes. This is
        // the same two lines every picker in Settings runs.
        AppState.shared.config[keyPath: s.field] = now
        AppState.shared.saveConfig()

        var reply: [String: Any] = [
            // REBUILT AFTER THE WRITE, so the row is a report of what is true rather than
            // an echo of what was asked for.
            "surface": modelRow(s),
            "was": was,
            "now": now,
            "changed": was != now,
            "inUse": modelNamesInUse(besides: s),
        ]
        if s.id == "offline" && now == GruxConfig.defaultLocalModel {
            // MEASURED IN ModelRegistry.discoverLocal: `Cookbook.userHasChosenModel` reads
            // the shipped default as nobody having chosen, so discovery may overwrite it
            // once with a model sized for this Mac. Somebody who set it deliberately and
            // then found it changed would have no way to know why.
            reply["caveat"] = "That is the model Grux ships with, which it reads as nobody "
                + "having chosen one. The next time it finds a local server it may upgrade "
                + "this once to a model that fits this Mac. Any other name it leaves alone."
        }
        return MCPWire.textResult(jsonText(reply))
    }

    private static func modelRow(_ s: ModelSurface) -> [String: Any] {
        let value = AppState.shared.config[keyPath: s.field]
        var notes: [String] = []
        if value.isEmpty, let fallback = s.emptyFallback {
            notes.append("Nothing is set, so \(fallback) is used instead.")
        }
        if let routing = modelRouting(s.id) { notes.append(routing) }
        return [
            "id": s.id,
            "label": s.label,
            "used": s.used,
            "site": s.site,
            "value": value,
            "set": !value.isEmpty,
            "fallsBack": s.emptyFallback != nil,
            "note": notes.joined(separator: " "),
        ]
    }

    /// Whether this surface is the one in play right now.
    ///
    /// A model name printed beside a switch that is off reads as the answer to "what will
    /// run", and it is not: it is the answer to "what would run". Saying which costs one
    /// sentence, and the two are opposite answers to the question somebody ran this to ask.
    private static func modelRouting(_ id: String) -> String? {
        let cfg = AppState.shared.config
        switch id {
        case "chat":
            return ModelRegistry.shared.offlineReady
                ? "Chat is routed off Anthropic right now, so the offline model is what "
                  + "actually answers."
                : nil
        case "offline":
            return ModelRegistry.shared.offlineReady
                ? nil
                : "Chat is on Anthropic right now, so this is what would answer if the "
                  + "route changed."
        case "vision":
            return cfg.screenAnalysisEnabled
                ? nil
                : "Screen analysis is off, so nothing is calling this yet."
        case "local":
            if !cfg.useLocalQwenForAmbient {
                return "The local brain switch is off, so this work goes to Anthropic."
            }
            return cfg.localLLMEndpoint.isEmpty
                ? "No local endpoint is set, so this work goes to Anthropic."
                : nil
        case "voice":
            // THE SHARED GATE, not a hand written copy of it. `VoiceEngineLogic` exists
            // precisely so a readout cannot drift from what `SpeechEngine.speak` does, and
            // it already knows the two reasons ElevenLabs silently does not run.
            switch VoiceEngineLogic.effectiveTTS(
                useElevenLabs: cfg.useElevenLabs,
                hasKey: !AppState.shared.elevenLabsKey.isEmpty,
                offline: AppState.shared.offlineMode) {
            case .elevenLabs:
                return cfg.speakRepliesAloud
                    ? nil
                    : "Grux is not speaking replies aloud, so nothing is calling this yet."
            case .system(let reason):
                guard let reason else {
                    return "ElevenLabs is off, so the system voice speaks and nothing calls "
                         + "this."
                }
                return "Replies are spoken by the system voice (\(reason)), so nothing is "
                     + "calling this."
            }
        default:
            return nil
        }
    }

    /// Every model name already set on this Mac, and which surfaces use it.
    ///
    /// The CLI compares a name it just wrote against these by edit distance. Nothing here
    /// asks a vendor whether a model exists, so a near miss on a name that IS in use is the
    /// only typo evidence this machine can honestly produce.
    private static func modelNamesInUse(besides: ModelSurface) -> [[String: Any]] {
        let cfg = AppState.shared.config
        var owners: [String: [String]] = [:]
        for s in modelSurfaces where s.id != besides.id {
            let value = cfg[keyPath: s.field]
            guard !value.isEmpty else { continue }
            owners[value, default: []].append(s.id)
        }
        return owners.keys.sorted { $0.lowercased() < $1.lowercased() }
            .map { name -> [String: Any] in
                let used = (owners[name] ?? []).sorted { $0.lowercased() < $1.lowercased() }
                // THE COUNT TRAVELS WITH THE SENTENCE. The reader writes "which <surfaces>
                // uses", and `used` can be several, so "which chat and vision uses" came out
                // the other end. A joined string cannot be counted at the far end without
                // parsing English back out of it.
                return ["name": name, "surfaces": modelSentence(used), "count": used.count]
            }
    }

    /// "chat, vision and voice". A sentence, not a comma join, because these strings land
    /// in the middle of one.
    private static func modelSentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
