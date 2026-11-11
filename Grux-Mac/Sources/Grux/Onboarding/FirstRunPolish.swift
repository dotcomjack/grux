import Foundation

/// Small pure answers the first run needs, held outside the views so a test can
/// check them without building SwiftUI.
///
/// All three exist for the same reason, found by walking a first run on a wiped
/// Mac on 2026-09-22: the flow asked for things it could already answer, and
/// said nothing about what it had already found.

// MARK: - The name macOS already knows

@MainActor
enum Identity {

    /// The name to put in the field before the person types anything.
    ///
    /// **Only when it looks like a human name.** A prefill that is WRONG is
    /// worse than an empty field, because the person accepts it without reading
    /// it and Grux then calls them by their account's short name forever. So
    /// this takes the first word of the account's full name, and only when that
    /// full name carries a surname too, or the single word is capitalised the
    /// way a name is. "Ada Lovelace" and "Ada" both give "Ada"; "svcacct",
    /// "admin" and an address give nothing, and the field stays empty exactly
    /// as it did before.
    ///
    /// An address is rejected outright: macOS lets the full name be anything,
    /// and some managed Macs set it to the login email.
    nonisolated static func suggestedName(fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return "" }

        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = words.first.map(String.init), first.count >= 2 else { return "" }
        // A name is letters. "svc-2" and "501" are not.
        guard first.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return "" }

        let looksLikeAName = words.count > 1 || (first.first?.isUppercase ?? false)
        return looksLikeAName ? first : ""
    }

    /// The same answer for the Mac this is running on.
    nonisolated static var systemSuggestion: String {
        suggestedName(fullName: NSFullUserName())
    }
}

// MARK: - What the model gate found before it asked

@MainActor
enum ModelGate {

    /// Shown when a local server answered before the person pressed anything.
    ///
    /// The screen used to open with "Paste an Anthropic API key" whatever was
    /// true on the Mac, so somebody already running Ollama, which is the free
    /// path the README leads with, was asked for a key they had deliberately
    /// not got. Looking first costs one request to a loopback address.
    static let foundTitle = "There is already a model on this Mac"

    /// Under "Use a local model instead". The old line promised Grux fetches a
    /// model whatever is running, which is false with no Ollama (W4, 2026-10-13).
    /// "Your chats stay", not "nothing leaves": a weather ask sends a city
    /// name and the update check asks GitHub, whichever model chat uses.
    static let localLine = "Runs on this Mac. No key, no account, and your chats stay on it. "
        + "With Ollama running, Grux fetches the best model this Mac can run."
    static let ollamaLink = "Get Ollama, free, at ollama.com"
    /// Under a download that gave up: the same press again, which resumes.
    static let tryAgain = "Try again"

    /// The headline when it is a Grux Local, the one first run recommends.
    static func recommendedLocal(_ headline: CookbookModel?) -> CookbookModel? {
        headline.flatMap { $0.displayName == "Grux Local" ? $0 : nil }
    }

    /// The local button. It names Grux Local and its download, so the one
    /// press that fetches it is a choice made knowing what it costs.
    static func localButton(_ recommended: CookbookModel?, installed: Bool = false) -> String {
        guard let m = recommended else { return "Use a local model instead" }
        let what = "Use \(m.displayName) \(m.parameterLabel), recommended for this Mac"
        return installed ? what : what + String(format: " (%.1f GB download)", m.diskGB)
    }

    /// Under the local line: what Grux Local is, and that nothing downloads
    /// until the button is pressed.
    static func gruxLocalLine(_ m: CookbookModel) -> String {
        "\(m.displayName) is a model trained for Grux, and \(m.parameterLabel) is the size for this Mac's memory. "
            + "Nothing downloads until you press the button; it then comes through Ollama from gruxai.com "
            + "and runs only here."
    }
    static let ollamaURL = URL(string: "https://ollama.com")!

    /// "Get Ollama" only when no model was found here: it sat under "There is
    /// already a model on this Mac" (D135 item 2). None of the three choices
    /// below draws while the probe is still looking: each showed for a moment
    /// and vanished when it found a model (W45-P3 item 4).
    static func offersOllamaLink(_ probe: Probe) -> Bool { probe == .none }
    /// "Use a local model instead" and its line only when nothing was found:
    /// with a model found it ran the same `useLocalModel()` as "Use the model
    /// on this Mac", two buttons for one choice (D142 item 3).
    static func showsLocalPath(_ probe: Probe) -> Bool { probe == .none }
    /// The local button. With nothing found it is the local path above. With
    /// a model found it still offers the Grux Local made for this Mac when that
    /// is not on the Mac yet: a different choice from "Use the model on this
    /// Mac" (it downloads and switches chat to Grux Local), so not the
    /// duplicate D142 removed. Never while the probe looks (W45-P3 item 4).
    static func showsLocalButton(_ probe: Probe, recommended: CookbookModel?, recommendedInstalled: Bool) -> Bool {
        showsLocalPath(probe) || (probe.model != nil && recommended != nil && !recommendedInstalled)
    }
    /// Skip only when nothing was found. With a model found, Skip left chat
    /// on that model, the same as "Use the model on this Mac" beside it: two
    /// buttons for one outcome (D146 item 14). The pinned button is the way
    /// past without a key, so the screen is never a dead end; once using the
    /// found model has failed, Skip is back (W45-FIX).
    static func offersSkip(_ probe: Probe, localFailed: Bool) -> Bool {
        probe == .none || (probe.model != nil && localFailed)
    }

    /// The way past this step with no key and no local model. On a clean Mac
    /// Continue stayed disabled with nothing else to press (W4, 2026-10-13).
    /// Grux finishes setting up without a model; Now and Chat both say
    /// "Connect a model" and go to the same place.
    static let skip = "Skip for now"
    static let skipNote = "You can connect a model any time; Chat will ask for one."

    static func foundDetail(model: String) -> String {
        "Grux found \(model) running here. Use it and your chats stay on this Mac, "
            + "with no key and no account. You can add a key later in Settings, Models."
    }

    static let useFound = "Use the model on this Mac"
    /// While the probe looks, in place of the choices its answer may take away.
    static let lookingLine = "Looking for a model already on this Mac"

    /// The installed model the local route ends up on: what "Use the model on
    /// this Mac" leaves configured, and so the one the found line names. The
    /// line used to name Ollama's most recently pulled tag while the button
    /// kept another model (D111). Nil when nothing usable is installed.
    static func modelToUse(configured: String, installed: [String], headline: String?) -> String? {
        let usable = GruxConfig.usableLocalModels(installed)
        guard !usable.isEmpty else { return nil }
        // The model chat is set to when the server holds it, however the
        // server spells the tag: discovery may just have adopted an installed
        // Grux Local under its gruxai.com name, and naming another model beside
        // a chat on Grux Local would name the wrong one (3.2.0).
        // The configured spelling first, so a name chat already uses is never
        // rewritten to another spelling of the same model.
        if usable.contains(configured) { return configured }
        if let same = usable.first(where: { FileNamingRoute.sameTag($0, configured) }) { return same }
        return GruxConfig.installedModelToAdopt(configured: configured, installed: installed,
                                                headline: headline) ?? configured
    }

    /// What the probe concluded. `none` covers "no server" and "nothing usable"
    /// deliberately: neither is something to say out loud on this screen.
    /// `looking` until it has answered.
    enum Probe: Equatable {
        case none
        case looking
        case found(String)

        var model: String? {
            if case .found(let m) = self { return m }
            return nil
        }
    }
}
