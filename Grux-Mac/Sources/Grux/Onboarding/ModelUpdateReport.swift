import Foundation

/// What Grux knows about the models available on THIS machine, right now.
///
/// The update phase that runs at the end of onboarding renders this, and
/// Settings can ask for it again later. It is a pure value computed from
/// injected inputs rather than something that reaches out and measures on its
/// own, which is what makes the machine-specific claims testable: a Mac Studio
/// and an 8GB Air can both be fabricated in a test without owning either.
///
/// The honest warning is the point of the whole screen. A local model is a real
/// option and Grux should say so, but somebody who switches to one because it is
/// free and then finds Grux markedly worse has been misled by omission. So the
/// wording is specific about the tradeoff and specific about this machine, and
/// it refuses to recommend a local model as a replacement for a frontier one.
struct ModelUpdateReport: Equatable {

    /// The best local model this machine can comfortably run, if any.
    let headline: CookbookModel?
    /// Everything from the catalog that runs at all here, best first.
    let runnable: [CookbookModel]
    /// How the headline model sits against this machine's memory budget.
    let headlineFit: ModelFit?
    let profile: HardwareProfile

    /// Whether a frontier key is configured. Changes the advice completely: with
    /// no cloud model a local one is the only way Grux works at all, and with
    /// one it is a fallback that costs quality.
    let hasCloudModel: Bool

    /// Whether chat ACTUALLY routes to the cloud right now.
    ///
    /// Separate from `hasCloudModel` because they stopped being the same fact.
    /// A key can be present while the route is local: the model gate's "Use a
    /// local model instead" writes the route outright, and no-key-plus-a-local-
    /// model now falls forward to local as well. Reading key presence as though
    /// it were the route made the LAST screen of setup announce "Grux uses it by
    /// default" to somebody who had just chosen local two screens earlier.
    let routesToCloud: Bool
    /// Whether an Ollama server is actually reachable.
    let localServerRunning: Bool
    /// Model tags already pulled on this machine.
    let installedTags: [String]

    // MARK: - Derived copy

    /// One line naming the machine, so a reader can tell this was measured
    /// rather than templated.
    var machineSummary: String {
        let gb = Int(profile.physicalMemoryGB.rounded())
        let budget = Int(profile.modelBudgetGB.rounded())
        return "\(profile.chipName), \(gb)GB memory, about \(budget)GB usable for a model."
    }

    /// Whether a cloud key is configured, in one line.
    var cloudSummary: String {
        switch (hasCloudModel, routesToCloud) {
        case (true, true):  return "Configured. Grux uses it by default."
        case (true, false): return "Configured, and not in use: chat is routed to a local model."
        case (false, _):    return "Not set yet. You can add a key in Settings at any time."
        }
    }

    /// The state of the local model server, in one line.
    ///
    /// Reads `hasCloudModel` because it once did not, and the screen
    /// contradicted itself. The not-running line was hardcoded as "Ollama is not
    /// running. Grux can still use your cloud model", which rendered directly
    /// under "Cloud model: Not set yet" for anybody who had neither. A
    /// screenshot of an 8GB Mac with no key caught it. Sentences that depend on
    /// state belong where the state is, not in the view.
    var localServerSummary: String {
        if localServerRunning {
            return "Ollama is running, \(installedTags.count) model(s) installed."
        }
        return hasCloudModel
            ? "Ollama is not running. Grux can still use your cloud model."
            : "Ollama is not running, and no cloud key is set."
    }

    /// What this machine can do locally, in one sentence.
    var capabilitySummary: String {
        guard let headline, let headlineFit else {
            return "No local model in the catalog fits in this machine's memory budget."
        }
        let count = runnable.count
        let others = count == 1 ? "" : ", and \(count - 1) more"
        return "\(headline.displayName) \(headline.parameterLabel) runs here"
            + " (\(headlineFit.label.lowercased()))\(others)."
    }

    /// The honest warning, matched to what is actually true on this machine.
    ///
    /// Four different situations, four different truths. Collapsing them into
    /// one sentence is how a warning becomes noise: telling somebody with no API
    /// key that local models are a downgrade is useless, because for them it is
    /// that or nothing.
    var qualityWarning: String {
        // Keyed on the ROUTE, not on key presence, or this contradicts the line
        // directly above it for anybody who chose local while holding a key.
        switch (routesToCloud, headline) {
        case (true, .some):
            return "A local model runs on your Mac and costs nothing per use, and it is "
                + "noticeably worse than the cloud model at anything hard: longer reasoning, "
                + "code, and following detailed instructions. It is a good fallback for "
                + "offline work and for anything you would rather not send anywhere. Grux "
                + "keeps using your cloud model by default."
        case (true, .none):
            return "This machine does not have the memory to run a local model well, so Grux "
                + "will use your cloud model. Nothing is missing: that is the better of the "
                + "two options anyway."
        case (false, .some) where hasCloudModel:
            // ROUTED LOCAL WITH A KEY ON FILE, which is exactly what choosing
            // "Use a local model instead" leaves behind. Keying this paragraph
            // on the route alone made it open "With no cloud key" directly under
            // a line that had just said the key was configured. Two sentences,
            // one screen, flatly contradicting each other.
            return "Grux is routed to a local model, and your key is still on file. A local "
                + "model costs nothing per use and is meaningfully weaker at code and long "
                + "reasoning, so expect shorter and simpler answers. Settings, then Models, "
                + "switches back whenever you want."
        case (false, .some):
            return "With no cloud key, a local model is what Grux will use. It works, and it "
                + "is meaningfully weaker than a frontier model at code and long reasoning, "
                + "so expect shorter and simpler answers until you add a key."
        case (false, .none):
            return "There is no cloud key and no local model this machine can run, so Grux "
                + "cannot think yet. Adding a key is the one thing that changes that."
        }
    }

    /// Whether the screen has anything worth saying about local models at all.
    var offersLocalOption: Bool { headline != nil }

    // MARK: - Assembly

    /// Builds the report from the detectors that already exist.
    ///
    /// Deliberately takes its inputs rather than calling the singletons itself.
    /// `OllamaManager` is a live @MainActor object with a health loop, and a
    /// report that reached into it could not be constructed in a test without
    /// starting one.
    static func build(profile: HardwareProfile,
                      hasCloudModel: Bool,
                      routesToCloud: Bool? = nil,
                      localServerRunning: Bool,
                      installedTags: [String]) -> ModelUpdateReport {
        let runnable = Cookbook.recommended(for: profile)
        let headline = runnable.first
        return ModelUpdateReport(
            headline: headline,
            runnable: runnable,
            headlineFit: headline.map { Cookbook.fit(of: $0, in: profile) },
            profile: profile,
            hasCloudModel: hasCloudModel,
            // Defaults to the old behaviour when a caller has nothing better to
            // say, so existing tests keep describing the case they were written
            // for rather than silently changing meaning.
            routesToCloud: routesToCloud ?? hasCloudModel,
            localServerRunning: localServerRunning,
            installedTags: installedTags)
    }
}
