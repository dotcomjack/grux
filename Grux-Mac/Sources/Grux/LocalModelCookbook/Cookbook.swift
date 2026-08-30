import Foundation

// Static, curated catalog of local models worth running through Ollama, plus
// the fit-scoring math that matches them to a HardwareProfile. Pure logic,
// no IO, fully testable with fabricated profiles.

// One entry in the cookbook. `id` is the exact Ollama tag passed to
// `ollama pull` / the chat API, so "Use this model" can write it straight
// into GruxConfig.offlineLLMModel.
struct CookbookModel: Identifiable, Codable, Equatable {
    let id: String              // Ollama tag, e.g. "llama3.1:8b"
    let displayName: String
    let parameterLabel: String  // "8B", "27B", ...
    let diskGB: Double          // download size on disk
    let estimatedMemoryGB: Double // resident working memory while serving (q4 class)
    let contextTokens: Int
    let strengths: String       // one-line pitch for the list row
    let supportsTools: Bool     // advertises tool calling through Ollama
}

// How well a model fits the machine. Ordering matters: the view sorts by
// fit first, then by capability.
enum ModelFit: String, Codable {
    case great   // headroom to spare, daily-driver safe
    case good    // fits comfortably alongside normal app load
    case tight   // runs, but expect swapping under memory pressure
    case tooBig  // do not bother

    var label: String {
        switch self {
        case .great:  return "Great fit"
        case .good:   return "Good fit"
        case .tight:  return "Tight"
        case .tooBig: return "Too big"
        }
    }
}

enum Cookbook {

    // Curated catalog, smallest to largest.
    //
    // REFRESHED 2026-08-21, and the previous list is why this comment exists. It
    // recommended gemma3 and qwen3 while Ollama had shipped gemma4, qwen3.5 and
    // qwen3.6, so the app said "Recommended" about a model two generations old.
    // A hardcoded list of a moving target goes stale silently, which is exactly
    // what "Check for newer models" below exists to catch.
    //
    // PROVENANCE, so every number here can be rechecked rather than trusted:
    //   id and diskGB   ollama.com/library/<model>/tags, the published download size
    //   contextTokens   ollama.com/library/<model>, the stated context window
    //   supportsTools   the capability chips on that same page
    //   estimatedMemoryGB is the ONLY estimate: roughly 1.5x disk for a q4 class
    //   model while serving. It is a heuristic, it is named like one, and the fit
    //   scoring treats it as approximate.
    //
    // DELIBERATELY ABSENT: llama4. It exists in the registry at 67 GB, but its
    // context window is not stated anywhere I could read, and every other figure
    // in this table is sourced. A guessed context is worse than a missing model,
    // because the fit scoring would present the guess as fact. Add it the day the
    // number can be cited.
    //
    // THE FIRST VERSION OF THIS REFRESH WAS ITSELF STALE WITHIN THE HOUR. It
    // shipped qwen3.6 and no mistral-small3.2, because the library page is ordered
    // by popularity and qwen3.8 sits past the fortieth entry. "Check for newer
    // models" found it. That is the argument for the button in one sentence.
    static let catalog: [CookbookModel] = [
        // THE MODEL THE APP ALREADY SHIPPED AS ITS DEFAULT, and the reason this
        // entry exists at all. `GruxConfig.defaultLocalModel` has read
        // "llama3.2:3b" since qwen3:8b was measured returning empty content, and
        // every fit label, every headline recommendation and every "Great fit"
        // chip in this file was computed over a catalog that had never heard of
        // it. So the app scored thirteen models it did not use and could not
        // score the one it did, and the smallest thing it could see needed 5.0
        // GB, which on an 8 GB Mac is a "Tight" warning and nothing better.
        //
        // PROVENANCE, and for this one row it is not the tags page, because the
        // machine it was added from had no network. Every figure below was read
        // off a local Ollama install that already held the model, which serves
        // the same manifest the tags page renders:
        //   id             the tag Ollama reports for the pulled model
        //   diskGB         `ollama list` prints 2.0 GB and the model layer in the
        //                  manifest is 2,019,377,376 bytes, so 2.0 is the
        //                  published size and not a rounding of somebody's memory
        //   contextTokens  `ollama show` prints "context length 131072"
        //   supportsTools  `ollama show` lists "tools" under Capabilities
        //
        // estimatedMemoryGB IS THE ESTIMATE, and this is the row where the
        // table's 1.5x-disk rule is weakest, so the measurements behind it are
        // written down rather than left implied. Served through the local server
        // and read back from `/api/ps`: 2.55 GB resident at a 4096 token context,
        // 5.87 GB at 32768. That spread is the KV cache, which this model carries
        // heavily for its size. qwen3.5:4b, listed at 6.0 GB below, measured 3.14
        // and 4.23 GB at those same two contexts, so it is this model that is
        // unusual and not the method. Grux never sends `num_ctx`, so Ollama sizes
        // the window to the machine it is running on: the 32768 figure is a
        // property of a workstation with memory to spare, and a small Mac gets a
        // smaller window and a smaller footprint. 3.0 GB is the table's own rule
        // applied unchanged, and it sits above the small-context measurement
        // rather than below it. If one number in this table ever gets corrected
        // from a real 8 GB machine, it should be this one.
        //
        // KNOWN SIDE EFFECT, said out loud rather than found later:
        // ModelRegistryCheck compares FAMILIES, and llama3.3 already sits in this
        // catalog, so the staleness banner will report llama3.2 as having a newer
        // sibling from now on. That check states the limit itself, and it applies
        // exactly here: llama3.3 ships at 70B only, so for a 3B user there is no
        // upgrade behind that row.
        CookbookModel(
            id: "llama3.2:3b", displayName: "Llama 3.2", parameterLabel: "3B",
            diskGB: 2.0, estimatedMemoryGB: 3.0, contextTokens: 131_072,
            strengths: "Smallest model that answers well, comfortable on 8 GB",
            supportsTools: true),
        CookbookModel(
            id: "qwen3.5:2b", displayName: "Qwen 3.5", parameterLabel: "2B",
            diskGB: 2.7, estimatedMemoryGB: 5.0, contextTokens: 262_144,
            strengths: "Fastest useful local model, drafts and classification",
            supportsTools: true),
        CookbookModel(
            id: "qwen3-vl:4b", displayName: "Qwen 3 VL", parameterLabel: "4B",
            diskGB: 3.3, estimatedMemoryGB: 6.0, contextTokens: 262_144,
            strengths: "Reads screenshots and images, small enough for any Mac",
            supportsTools: true),
        CookbookModel(
            id: "qwen3.5:4b", displayName: "Qwen 3.5", parameterLabel: "4B",
            diskGB: 3.4, estimatedMemoryGB: 6.0, contextTokens: 262_144,
            strengths: "Small generalist with tool calling and a 256K window",
            supportsTools: true),
        CookbookModel(
            id: "qwen3.5:9b", displayName: "Qwen 3.5", parameterLabel: "9B",
            diskGB: 6.6, estimatedMemoryGB: 10.0, contextTokens: 262_144,
            strengths: "Best quality per gigabyte in the small class",
            supportsTools: true),
        CookbookModel(
            id: "gemma4:12b", displayName: "Gemma 4", parameterLabel: "12B",
            diskGB: 7.6, estimatedMemoryGB: 12.0, contextTokens: 131_072,
            strengths: "Strong open writing quality, now with tool calling",
            supportsTools: true),
        CookbookModel(
            id: "mistral-small3.2:24b", displayName: "Mistral Small 3.2", parameterLabel: "24B",
            diskGB: 15.0, estimatedMemoryGB: 22.0, contextTokens: 131_072,
            strengths: "Vision and tools, the strongest non-Qwen mid size",
            supportsTools: true),
        CookbookModel(
            id: "gpt-oss:20b", displayName: "GPT-OSS", parameterLabel: "20B",
            diskGB: 14.0, estimatedMemoryGB: 20.0, contextTokens: 131_072,
            strengths: "Open weight reasoning model, thinking mode",
            supportsTools: true),
        CookbookModel(
            id: "qwen3.8:27b", displayName: "Qwen 3.8", parameterLabel: "27B",
            diskGB: 18.0, estimatedMemoryGB: 26.0, contextTokens: 262_144,
            strengths: "Newest Qwen, thinking and vision at a 27B footprint",
            supportsTools: true),
        CookbookModel(
            id: "gemma4:26b", displayName: "Gemma 4", parameterLabel: "26B",
            diskGB: 18.0, estimatedMemoryGB: 26.0, contextTokens: 131_072,
            strengths: "Gemma at full size, vision and tools",
            supportsTools: true),
        CookbookModel(
            id: "qwen3-coder:30b", displayName: "Qwen 3 Coder", parameterLabel: "30B",
            diskGB: 19.0, estimatedMemoryGB: 28.0, contextTokens: 262_144,
            strengths: "Built for code, strong at long refactors",
            supportsTools: true),
        CookbookModel(
            id: "qwen3.5:35b", displayName: "Qwen 3.5", parameterLabel: "35B",
            diskGB: 24.0, estimatedMemoryGB: 35.0, contextTokens: 262_144,
            strengths: "The largest Qwen that is comfortable on 64 GB",
            supportsTools: true),
        CookbookModel(
            id: "llama3.3:70b", displayName: "Llama 3.3", parameterLabel: "70B",
            diskGB: 43.0, estimatedMemoryGB: 60.0, contextTokens: 131_072,
            strengths: "Meta's largest open release, needs real headroom",
            supportsTools: true),
        CookbookModel(
            id: "gpt-oss:120b", displayName: "GPT-OSS", parameterLabel: "120B",
            diskGB: 65.0, estimatedMemoryGB: 88.0, contextTokens: 131_072,
            strengths: "Frontier class locally, 96 GB and up only",
            supportsTools: true),
    ]

    // MARK: - Fit scoring

    // EVERY FUNCTION IN THIS SECTION COMES IN TWO SHAPES, and the pair is
    // deliberate rather than a migration left half finished.
    //
    // The two-argument form scores against the DEVICE, which is what a catalog
    // browser wants: "this Mac can run a 27B" is a fact about the hardware and it
    // does not stop being true because a video call is open. The form that takes
    // a headroom scores against what the machine can afford at this moment, which
    // is what a RECOMMENDATION wants, because a 16 GB Mac was told an 11 GB model
    // was a "Good fit" while most of that budget was already spent, and the user
    // met that verdict as swap rather than as a warning.
    //
    // The two-argument form is not deprecated and it is not a shim. It delegates
    // at `.full`, where `HardwareProfile.budgetFraction` is exactly 1.00 and
    // multiplying a Double by 1.00 is exact, so every existing caller and every
    // existing test reads the identical number it read before, bit for bit. That
    // matters more than tidiness here: this file is scored by tests that pin
    // thresholds to two decimal places, and a "harmless" rounding introduced by
    // routing an old caller through new arithmetic would surface as a fit label
    // changing on hardware nobody touched.

    // Fraction of the machine's model budget this model would consume.
    // Below 1.0 it fits at all; the rating thresholds add comfort margin.
    static func loadFactor(of model: CookbookModel, in profile: HardwareProfile) -> Double {
        loadFactor(of: model, in: profile, headroom: .full)
    }

    // The same fraction against the budget the machine can afford right now.
    // A zero budget still reports infinity rather than dividing by it, and that
    // covers the pressure path too: `.minimal` scales a zero device budget to
    // zero, so a machine with no Metal device and no RAM reading cannot produce
    // a loadFactor of NaN and score every model as "Great fit" by accident.
    static func loadFactor(of model: CookbookModel,
                           in profile: HardwareProfile,
                           headroom: MachineLoad.Headroom) -> Double {
        let budget = profile.modelBudgetGB(headroom: headroom)
        guard budget > 0 else { return .infinity }
        return model.estimatedMemoryGB / budget
    }

    static func fit(of model: CookbookModel, in profile: HardwareProfile) -> ModelFit {
        fit(of: model, in: profile, headroom: .full)
    }

    // The rating thresholds are the same numbers at every headroom. Only the
    // budget underneath them moves, which is the point: a model does not get
    // more comfortable because the machine got busier, so the shrinking budget
    // pushes the load factor up and the label down. Two knobs, one turned, and
    // a reader can predict the outcome without reading both.
    static func fit(of model: CookbookModel,
                    in profile: HardwareProfile,
                    headroom: MachineLoad.Headroom) -> ModelFit {
        switch loadFactor(of: model, in: profile, headroom: headroom) {
        case ..<0.50:        return .great
        case 0.50..<0.75:    return .good
        case 0.75..<0.95:    return .tight
        default:             return .tooBig
        }
    }

    // Ranking score: higher is better. Rewards capability (memory footprint
    // is the best simple proxy for quality within the catalog) but only
    // among models that actually fit; penalizes tight fits so the headline
    // recommendation is something the machine can live with day to day.
    static func fitScore(of model: CookbookModel, in profile: HardwareProfile) -> Double {
        fitScore(of: model, in: profile, headroom: .full)
    }

    static func fitScore(of model: CookbookModel,
                         in profile: HardwareProfile,
                         headroom: MachineLoad.Headroom) -> Double {
        let capability = model.estimatedMemoryGB
        switch fit(of: model, in: profile, headroom: headroom) {
        case .great:  return capability * 1.00
        case .good:   return capability * 0.85
        case .tight:  return capability * 0.40
        case .tooBig: return 0
        }
    }

    // Catalog filtered to models that run at all, best score first. Ties
    // break toward the smaller model (faster tokens for the same rating).
    static func recommended(for profile: HardwareProfile) -> [CookbookModel] {
        recommended(for: profile, headroom: .full)
    }

    static func recommended(for profile: HardwareProfile,
                            headroom: MachineLoad.Headroom) -> [CookbookModel] {
        catalog
            .filter { fit(of: $0, in: profile, headroom: headroom) != .tooBig }
            .sorted {
                let a = fitScore(of: $0, in: profile, headroom: headroom)
                let b = fitScore(of: $1, in: profile, headroom: headroom)
                if a != b { return a > b }
                if $0.estimatedMemoryGB != $1.estimatedMemoryGB {
                    return $0.estimatedMemoryGB < $1.estimatedMemoryGB
                }
                // LAST RESORT, AND NOT DECORATION. Two entries can tie on score
                // AND on footprint: qwen3-vl:4b and qwen3.5:4b are both estimated
                // at 6.0 GB, so on a 16 GB Mac they produce identical scores and
                // the tie-break above cannot separate them either. `sorted`
                // promises an ordering, never a STABLE one, so with no total
                // order the headline pick for that machine is whatever the sort
                // implementation happened to do that day. That was survivable
                // while the headline was only a label. It stopped being
                // survivable the moment `defaultModelID` below started writing
                // the headline into a config file, because the default a user
                // gets would then change with a toolchain upgrade rather than
                // with a decision anybody made. Comparing ids is arbitrary, but
                // it is arbitrary ONCE and it is written down.
                return $0.id < $1.id
            }
    }

    // The single headline pick for this machine, nil only on absurdly small
    // budgets (every catalog entry too big).
    static func headline(for profile: HardwareProfile) -> CookbookModel? {
        recommended(for: profile).first
    }

    static func headline(for profile: HardwareProfile,
                         headroom: MachineLoad.Headroom) -> CookbookModel? {
        recommended(for: profile, headroom: headroom).first
    }

    // MARK: - The pane, scored once

    // WHAT THE USER ACTUALLY SEES, and the reason the headroom overloads above
    // stopped being a capability nothing called.
    //
    // The pressure-aware half of this file shipped as pure functions with tests
    // and zero production callers. Measured across `Sources/`: every fit badge,
    // every "Recommended" line and every "Too big" section was still computed by
    // the two-argument device forms, so a 16 GB Mac with a browser, an IDE and a
    // video call open read exactly what an idle one read. That is the swap the
    // whole exercise exists to prevent, and it was unmitigated on every surface a
    // user can reach. A built capability nobody calls is worse than a missing
    // one, because it reads as done.
    //
    // ONE FUNCTION RATHER THAN THREE CALL SITES, because the view scored the
    // catalog three separate times: `recommended` for the top section, a filter
    // over `fit` for the bottom one, then `fit` again per row for the badge.
    // Nothing made those three agree about the budget, so threading a headroom
    // through them would have been three chances to miss one and ship a list
    // whose sections disagreed with their own badges. This scores once, keeps the
    // budget it used, and hands back everything the pane renders.
    struct Listing {
        // The budget every rating below was computed against, still carrying the
        // device number it was discounted from. The pane prints it, so a fit
        // label becomes a claim a reader can hold against Activity Monitor
        // rather than an opinion they can only be told again.
        let budget: ModelBudget

        // Runs at all, best first.
        let fitting: [CookbookModel]

        // Does not, in catalog order.
        let tooBig: [CookbookModel]

        let headline: CookbookModel?

        fileprivate let ratings: [String: ModelFit]

        // A model with no rating here is not in the catalog, so it cannot have
        // come from either list above and the pane never renders it. `.tooBig`
        // is the conservative answer for a question that should not be asked:
        // it hides a PULL button rather than offering one for something nothing
        // scored.
        func fit(of model: CookbookModel) -> ModelFit { ratings[model.id] ?? .tooBig }
    }

    static func listing(for profile: HardwareProfile,
                        headroom: MachineLoad.Headroom) -> Listing {
        var ratings: [String: ModelFit] = [:]
        for model in catalog {
            ratings[model.id] = fit(of: model, in: profile, headroom: headroom)
        }
        let fitting = recommended(for: profile, headroom: headroom)
        return Listing(budget: profile.modelBudget(headroom: headroom),
                       fitting: fitting,
                       tooBig: catalog.filter { ratings[$0.id] == .tooBig },
                       headline: fitting.first,
                       ratings: ratings)
    }

    // MARK: - The default model

    // THE CATALOG TOLD AND NEVER ACTED. The screenshot caption in the README
    // promises that Grux reads your hardware and says which local models actually
    // fit it, and `headline(for:)` above has computed exactly that from the day
    // this file was written. Nothing called it to decide anything. The shipped
    // default was one hardcoded tag for an 8 GB laptop and a 128 GB workstation
    // alike, so the machine that most needed a small model and the machine that
    // could run a 70B were handed the same 3B, and the fit scoring the app is
    // named for was a read-only opinion column next to it.

    /// Whether a stored local model id represents somebody's DECISION.
    ///
    /// Anything other than the shipped default counts as chosen and is never
    /// touched. That deliberately includes a value this file wrote on an earlier
    /// launch: the hardware pick runs once, on a config still sitting on the
    /// value it was assigned, and every launch after that leaves the field alone.
    /// Re-deciding on every launch would be a different feature, and a worse one,
    /// because a user who edited the field would watch it revert.
    ///
    /// An empty string is NOT a choice. `LocalLLM` and `SettingsView` both read
    /// an empty model as `GruxConfig.defaultLocalModel`, so an empty field is the
    /// default wearing different clothes and is eligible for the pick.
    static func userHasChosenModel(_ stored: String) -> Bool {
        !stored.isEmpty && stored != GruxConfig.defaultLocalModel
    }

    /// The local model id a machine should end up on, as a pure function.
    ///
    /// Pure because the decision and the writing of it belong to different
    /// owners: this file can be driven through an 8 GB laptop, a loaded 16 GB
    /// laptop and a 128 GB workstation inside one test process, while the caller
    /// that assigns the result touches `AppState` and a config file on disk. The
    /// same split is why `HardwareProfile.detect()` is the only thing in that
    /// file that reads sysctl.
    ///
    /// THE FAILURE THIS MUST NOT REPEAT, from the other direction.
    /// `GruxConfig.migratingLocalModel` exists because changing the default alone
    /// helped nobody who already had Grux: config.json stores the value
    /// explicitly, so an install that predated the change kept the broken model
    /// and a local "hi" still took the better part of a minute. The lesson people
    /// usually take from that is "be more willing to overwrite stored values",
    /// and applied here that would be the same bug pointing the other way: this
    /// runs on every successful local discovery, so a version of it that ignored
    /// `userHasChosen` would quietly replace a model the user typed by hand,
    /// every launch, forever. `migratingLocalModel` undoes an ASSIGNMENT and only
    /// one exact string. This function is held to the same bar.
    ///
    /// AND IT TAKES NO HEADROOM, WHICH IS DELIBERATE. `listing(for:headroom:)`
    /// above now scores every label against what the machine can afford this
    /// minute, so a loaded Mac shows a shorter list and a smaller headline, and
    /// both climb back when the pressure clears. This function must not move with
    /// them. It is the value that gets WRITTEN to config.json, and memory
    /// pressure is a weather report: a video call at the wrong moment would
    /// otherwise pin a stranger's install to the smallest model in the catalog
    /// long after the machine went quiet, and `userHasChosenModel` would then
    /// read that assignment back as a decision and refuse to revisit it, so one
    /// transient spike would be permanent. A LABEL is allowed to be about this
    /// minute. A STORED SETTING is not.
    ///
    /// Returns `current` unchanged when nothing in the catalog fits the machine,
    /// which is the honest answer for a Mac too small for any local model: the
    /// caller keeps whatever it had rather than being handed an empty tag, and
    /// the "no local model" copy in `ModelUpdateReport` is what tells the user.
    static func defaultModelID(for profile: HardwareProfile,
                               userHasChosen: Bool,
                               current: String) -> String {
        guard !userHasChosen else { return current }
        return headline(for: profile)?.id ?? current
    }
}
