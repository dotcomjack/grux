import Foundation
import os

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
    // Score on Grux's own local-model jobs, 0 to 1, and where it was measured.
    // Nil for a model nobody has measured, which ranks by footprint instead
    // (see `fitScore`).
    var measuredQuality: Double? = nil
    var qualitySource: String? = nil
    // The ONE model a download too slow on this Mac falls back to
    // (LocalModelSpeedCheck). Marked here, in the catalog, rather than named
    // as a default anywhere else.
    var speedFallback: Bool = false
    // The oldest Ollama that runs this model, as the model's own registry
    // config states it (`requires`); nil when the config states none. D25: a
    // model the person's Ollama is too old for is never recommended or offered
    // for Pull (see `Cookbook.runs`).
    var minimumOllama: String? = nil
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
    //   estimatedMemoryGB is an estimate unless marked measured: roughly 1.5x
    //   disk for a q4 class model while serving. It is a heuristic, it is named
    //   like one, and the fit scoring treats it as approximate.
    //   measuredQuality   the S1 eval, below
    //
    // MEASURED FOOTPRINTS (2026-10-22). Six rows carry a measured
    // estimatedMemoryGB in place of the 1.5x rule: Ollama serving at a 16K window,
    // one request at a time, resident size read back. qwen3.5:2b 2.6,
    // qwen3.5:4b 4.4 (read on a 16 GB Mac), qwen3.5:9b 6.2, gemma4:12b 9.4,
    // gemma4:26b 19.2, qwen3.8:27b 17.4. The rule had them 1.3 to 2 times too
    // big, which hid the 4B from 8 GB Macs and the 26B from 32 GB ones.
    //
    // MEASURED QUALITY (`measuredQuality`, source `s1`). The S1 eval sent 273
    // synthetic cases over 11 of Grux's own local-model jobs (chat with tools,
    // thread titles, notification and support triage, meeting summaries,
    // dictation repair and others) exactly as this code sends them, with
    // `"think": false`, and scored each model 0 to 1. Its finding is why the
    // ranking below stopped using footprint as the quality proxy: size is not
    // quality. gemma4:26b scored 0.945 and llama3.3:70b 0.668, and qwen3-vl:4b,
    // the old 16 GB headline, scored 0.490 because it returned empty on every
    // triage, title and summary call. The full table is
    // `docs/factory/local-model-eval.md` on the eval branch.
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
    static let s1 = "S1 2026-10-22"

    // GRUX LOCAL (2026-10-23), Grux's own trained model, the three tags gruxai.com
    // serves to `ollama pull` with no Ollama account (card and files:
    // github.com/dotcomjack/grux-local). Its quality is the S2 sweep's score on
    // the same S1 jobs and weights, on a GPU with `"think": false`; its footprints
    // were MEASURED on a 16 GB Mac mini (Ollama /api/ps, MLX nvfp4), not
    // estimated. The pitch says TRAINED to ignore hidden instructions, because it
    // is not perfect at it: 65 of 70 (4B) and 66 of 70 (2B) on the held out set.
    static let s2 = "S2 sweep 2026-10-23 (S1 jobs and weights, GPU, think false)"
    static let gruxLocalStrengths = "Trained on Grux's own jobs, and to ignore instructions hidden in pasted text"

    // THE OLLAMA EACH ONE NEEDS (`minimumOllama`, D25), read 2026-10-29 from each
    // model's own registry config (the `requires` field of the manifest's config
    // blob at registry.ollama.ai, or gruxai.com for Grux Local). Most of the list
    // needs 0.30 or newer, and a Mac a few months behind gets an error on Pull,
    // so the ranking skips what the local server cannot run (`Cookbook.runs`).
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
        // heavily for its size. qwen3.5:4b, listed at 4.4 GB below, measured 3.14
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
            supportsTools: true,
            measuredQuality: 0.637, qualitySource: Cookbook.s1),
        CookbookModel(
            id: "qwen3.5:2b", displayName: "Qwen 3.5", parameterLabel: "2B",
            // estimatedMemoryGB measured, see MEASURED FOOTPRINTS above the catalog
            diskGB: 2.7, estimatedMemoryGB: 2.6, contextTokens: 262_144,
            strengths: "Fastest useful local model, drafts and classification",
            supportsTools: true,
            measuredQuality: 0.752, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.0"),
        CookbookModel(
            id: "gruxai.com/grux/grux-local:2b", displayName: "Grux Local", parameterLabel: "2B",
            // estimatedMemoryGB measured, see GRUX LOCAL above the catalog
            diskGB: 2.6, estimatedMemoryGB: 2.65, contextTokens: 262_144,
            strengths: Cookbook.gruxLocalStrengths,
            supportsTools: true,
            measuredQuality: 0.939, qualitySource: Cookbook.s2,
            minimumOllama: "0.19.0"),
        CookbookModel(
            id: "qwen3-vl:4b", displayName: "Qwen 3 VL", parameterLabel: "4B",
            diskGB: 3.3, estimatedMemoryGB: 6.0, contextTokens: 262_144,
            strengths: "Reads screenshots and images, small enough for any Mac",
            supportsTools: true,
            measuredQuality: 0.490, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.0"),
        CookbookModel(
            id: "qwen3.5:4b", displayName: "Qwen 3.5", parameterLabel: "4B",
            // estimatedMemoryGB measured, see MEASURED FOOTPRINTS above the catalog
            diskGB: 3.4, estimatedMemoryGB: 4.4, contextTokens: 262_144,
            strengths: "Small generalist with tool calling and a 256K window",
            supportsTools: true,
            measuredQuality: 0.868, qualitySource: Cookbook.s1,
            // Measured on a 16 GB Mac mini, 2026-10-22, think false: 0.58 s
            // p50 dictation repair, 1.28 s chat turn with tools.
            speedFallback: true,
            minimumOllama: "0.30.0"),
        CookbookModel(
            id: "gruxai.com/grux/grux-local:4b", displayName: "Grux Local", parameterLabel: "4B",
            // estimatedMemoryGB measured, see GRUX LOCAL above the catalog
            diskGB: 4.3, estimatedMemoryGB: 4.44, contextTokens: 262_144,
            strengths: Cookbook.gruxLocalStrengths,
            supportsTools: true,
            measuredQuality: 0.975, qualitySource: Cookbook.s2,
            minimumOllama: "0.19.0"),
        CookbookModel(
            id: "gruxai.com/grux/grux-local:9b", displayName: "Grux Local", parameterLabel: "9B",
            // Grux 3.2: the 9B, made for 24 GB Macs and up, so the 32 GB class
            // and up lead with it. Disk is the gruxai.com manifest's layers
            // (7,152,645,636 bytes, digest 357e4bd4 as grux-local results/v1.json
            // names it), memory v1.json's measured fresh load (7.25 GB at num_ctx
            // 16384 on the 16 GB test Mac), quality the S2 score of this model's own run
            // (m3-9b, 2026-10-23, S1 jobs and weights, GPU, think false: 270 of
            // 273, weighted 0.988), and `requires` 0.19.0 from its registry config.
            diskGB: 7.2, estimatedMemoryGB: 7.25, contextTokens: 262_144,
            strengths: Cookbook.gruxLocalStrengths,
            supportsTools: true,
            measuredQuality: 0.988, qualitySource: Cookbook.s2,
            minimumOllama: "0.19.0"),
        CookbookModel(
            id: "qwen3.5:9b", displayName: "Qwen 3.5", parameterLabel: "9B",
            // estimatedMemoryGB measured, see MEASURED FOOTPRINTS above the catalog
            diskGB: 6.6, estimatedMemoryGB: 6.2, contextTokens: 262_144,
            strengths: "Best quality per gigabyte in the small class",
            supportsTools: true,
            measuredQuality: 0.853, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.0"),
        CookbookModel(
            id: "gemma4:12b", displayName: "Gemma 4", parameterLabel: "12B",
            // estimatedMemoryGB measured, see MEASURED FOOTPRINTS above the catalog
            diskGB: 7.6, estimatedMemoryGB: 9.4, contextTokens: 131_072,
            strengths: "Strong open writing quality, now with tool calling",
            supportsTools: true,
            measuredQuality: 0.927, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.9"),
        CookbookModel(
            id: "mistral-small3.2:24b", displayName: "Mistral Small 3.2", parameterLabel: "24B",
            diskGB: 15.0, estimatedMemoryGB: 22.0, contextTokens: 131_072,
            strengths: "Vision and tools, the strongest non-Qwen mid size",
            supportsTools: true,
            measuredQuality: 0.781, qualitySource: Cookbook.s1),
        CookbookModel(
            id: "gpt-oss:20b", displayName: "GPT-OSS", parameterLabel: "20B",
            diskGB: 14.0, estimatedMemoryGB: 20.0, contextTokens: 131_072,
            strengths: "Open weight reasoning model, thinking mode",
            supportsTools: true,
            measuredQuality: 0.786, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.0"),
        CookbookModel(
            id: "qwen3.8:27b", displayName: "Qwen 3.8", parameterLabel: "27B",
            // estimatedMemoryGB measured, see MEASURED FOOTPRINTS above the catalog
            diskGB: 18.0, estimatedMemoryGB: 17.4, contextTokens: 262_144,
            strengths: "Newest Qwen, thinking and vision at a 27B footprint",
            supportsTools: true,
            measuredQuality: 0.927, qualitySource: Cookbook.s1,
            minimumOllama: "0.32.12"),
        CookbookModel(
            id: "gemma4:26b", displayName: "Gemma 4", parameterLabel: "26B",
            // estimatedMemoryGB measured, see MEASURED FOOTPRINTS above the catalog
            diskGB: 18.0, estimatedMemoryGB: 19.2, contextTokens: 131_072,
            strengths: "Gemma at full size, vision and tools",
            supportsTools: true,
            measuredQuality: 0.945, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.9"),
        CookbookModel(
            id: "qwen3-coder:30b", displayName: "Qwen 3 Coder", parameterLabel: "30B",
            diskGB: 19.0, estimatedMemoryGB: 28.0, contextTokens: 262_144,
            strengths: "Built for code, strong at long refactors",
            supportsTools: true,
            measuredQuality: 0.829, qualitySource: Cookbook.s1),
        CookbookModel(
            id: "qwen3.5:35b", displayName: "Qwen 3.5", parameterLabel: "35B",
            diskGB: 24.0, estimatedMemoryGB: 35.0, contextTokens: 262_144,
            strengths: "The largest Qwen that is comfortable on 64 GB",
            supportsTools: true,
            measuredQuality: 0.840, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.0"),
        CookbookModel(
            id: "llama3.3:70b", displayName: "Llama 3.3", parameterLabel: "70B",
            diskGB: 43.0, estimatedMemoryGB: 60.0, contextTokens: 131_072,
            strengths: "Meta's largest open release, needs real headroom",
            supportsTools: true,
            measuredQuality: 0.668, qualitySource: Cookbook.s1),
        CookbookModel(
            id: "gpt-oss:120b", displayName: "GPT-OSS", parameterLabel: "120B",
            diskGB: 65.0, estimatedMemoryGB: 88.0, contextTokens: 131_072,
            strengths: "Frontier class locally, 96 GB and up only",
            supportsTools: true,
            measuredQuality: 0.856, qualitySource: Cookbook.s1,
            minimumOllama: "0.30.0"),
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

    // Ranking score: higher is better. Rewards quality, but only among models
    // that actually fit; penalizes tight fits so the headline recommendation is
    // something the machine can live with day to day.
    //
    // Quality is the measured score on Grux's own jobs (see MEASURED QUALITY
    // above the catalog). This used to be the memory footprint, on the theory
    // that bigger is better within a catalog, and the S1 eval measured that it
    // is not: it put a 64 GB Mac on qwen3.5:35b (0.840) over gemma4:26b (0.945).
    // A model nobody has measured falls back to its footprint over 100, which
    // keeps the old bigger-first order among unmeasured models and puts every
    // one of them below a measured model of equal fit (no catalog model needs
    // 100 GB, so the fallback never reaches 1.0).
    static func quality(of model: CookbookModel) -> Double {
        model.measuredQuality ?? model.estimatedMemoryGB / 100
    }

    static func fitScore(of model: CookbookModel, in profile: HardwareProfile) -> Double {
        fitScore(of: model, in: profile, headroom: .full)
    }

    static func fitScore(of model: CookbookModel,
                         in profile: HardwareProfile,
                         headroom: MachineLoad.Headroom) -> Double {
        let capability = quality(of: model)
        switch fit(of: model, in: profile, headroom: headroom) {
        case .great:  return capability * 1.00
        case .good:   return capability * 0.85
        case .tight:  return capability * 0.40
        case .tooBig: return 0
        }
    }

    // Catalog filtered to models that run at all, best score first. Ties
    // break toward the smaller model (faster tokens for the same rating).
    static func recommended(for profile: HardwareProfile,
                            ollamaVersion: String? = Cookbook.knownOllamaVersion) -> [CookbookModel] {
        recommended(for: profile, headroom: .full, ollamaVersion: ollamaVersion)
    }

    static func recommended(for profile: HardwareProfile,
                            headroom: MachineLoad.Headroom,
                            ollamaVersion: String? = Cookbook.knownOllamaVersion) -> [CookbookModel] {
        ranked(catalog, for: profile, headroom: headroom, ollamaVersion: ollamaVersion)
    }

    // The ordering itself, over any list, so the tie-breaks can be tested on
    // fabricated models rather than on whichever ties the catalog holds today.
    static func ranked(_ models: [CookbookModel],
                       for profile: HardwareProfile,
                       headroom: MachineLoad.Headroom,
                       ollamaVersion: String? = nil) -> [CookbookModel] {
        models
            .filter { fit(of: $0, in: profile, headroom: headroom) != .tooBig }
            .filter { runs($0, onOllama: ollamaVersion) }
            .sorted {
                let a = fitScore(of: $0, in: profile, headroom: headroom)
                let b = fitScore(of: $1, in: profile, headroom: headroom)
                if a != b { return a > b }
                if $0.estimatedMemoryGB != $1.estimatedMemoryGB {
                    return $0.estimatedMemoryGB < $1.estimatedMemoryGB
                }
                // LAST RESORT, AND NOT DECORATION. Two entries can tie on score
                // AND on footprint: until the measured figures, qwen3-vl:4b and
                // qwen3.5:4b were both estimated at 6.0 GB, so on a 16 GB Mac they
                // produced identical scores and the tie-break above could not
                // separate them either. (gemma4:12b and qwen3.8:27b now tie on
                // measured quality and are separated by footprint.) `sorted`
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
    static func headline(for profile: HardwareProfile,
                         ollamaVersion: String? = Cookbook.knownOllamaVersion) -> CookbookModel? {
        recommended(for: profile, ollamaVersion: ollamaVersion).first
    }

    static func headline(for profile: HardwareProfile,
                         headroom: MachineLoad.Headroom,
                         ollamaVersion: String? = Cookbook.knownOllamaVersion) -> CookbookModel? {
        recommended(for: profile, headroom: headroom, ollamaVersion: ollamaVersion).first
    }

    // MARK: - The Ollama it needs (D25)

    /// The version the local Ollama server reported at `/api/version`, recorded by
    /// `OllamaManager` whenever it asks. Nil until a server has answered.
    nonisolated static var knownOllamaVersion: String? {
        get { ollamaVersionBox.withLock { $0 } }
        set { ollamaVersionBox.withLock { $0 = newValue } }
    }
    private static let ollamaVersionBox = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Whether an Ollama at `version` runs `model`.
    ///
    /// What Grux cannot read hides nothing: no answer yet, an unreadable version,
    /// and 0.0.0 (what an Ollama built from source reports) all count as runs, so
    /// an unknown never empties the list. A prerelease of a version counts as that
    /// version (`0.30.0-rc1` runs a model that needs 0.30.0).
    static func runs(_ model: CookbookModel, onOllama version: String?) -> Bool {
        guard let needed = model.minimumOllama.flatMap(versionParts),
              let have = version.flatMap(versionParts),
              have.contains(where: { $0 != 0 }) else { return true }
        for i in 0..<max(needed.count, have.count) {
            let h = i < have.count ? have[i] : 0
            let n = i < needed.count ? needed[i] : 0
            if h != n { return h > n }
        }
        return true
    }

    /// `0.30.10` as [0, 30, 10]: dot-separated numbers, compared as numbers, with
    /// anything after a `-` or `+` dropped. Nil when it does not read as one.
    static func versionParts(_ text: String) -> [Int]? {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") { core.removeFirst() }
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// The row's line for a model this Mac's Ollama is too old for.
    static func needsNewerOllamaLine(_ model: CookbookModel, have version: String?) -> String {
        let needed = "Needs Ollama \(model.minimumOllama ?? "a newer version") or newer"
        guard let version, !version.isEmpty else { return needed + "." }
        return needed + "; this Mac has \(version)."
    }

    /// Under the section that lists them.
    static let needsNewerOllamaNote =
        "Update Ollama to use these: download it again from ollama.com, or run brew upgrade ollama if Homebrew installed it."


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

        // Would fit, but the Ollama on this Mac is too old to run them (D25),
        // in catalog order.
        var needsNewerOllama: [CookbookModel] = []

        // The server version the lists were scored against; nil when unknown.
        var ollamaVersion: String? = nil

        fileprivate let ratings: [String: ModelFit]

        // A model with no rating here is not in the catalog, so it cannot have
        // come from either list above and the pane never renders it. `.tooBig`
        // is the conservative answer for a question that should not be asked:
        // it hides a PULL button rather than offering one for something nothing
        // scored.
        func fit(of model: CookbookModel) -> ModelFit { ratings[model.id] ?? .tooBig }
    }

    static func listing(for profile: HardwareProfile,
                        headroom: MachineLoad.Headroom,
                        ollamaVersion: String? = Cookbook.knownOllamaVersion) -> Listing {
        var ratings: [String: ModelFit] = [:]
        for model in catalog {
            ratings[model.id] = fit(of: model, in: profile, headroom: headroom)
        }
        let fitting = recommended(for: profile, headroom: headroom, ollamaVersion: ollamaVersion)
        return Listing(budget: profile.modelBudget(headroom: headroom),
                       fitting: fitting,
                       tooBig: catalog.filter { ratings[$0.id] == .tooBig },
                       headline: fitting.first,
                       needsNewerOllama: catalog.filter {
                           ratings[$0.id] != .tooBig && !runs($0, onOllama: ollamaVersion)
                       },
                       ollamaVersion: ollamaVersion,
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
                               current: String,
                               ollamaVersion: String? = Cookbook.knownOllamaVersion) -> String {
        guard !userHasChosen else { return current }
        return headline(for: profile, ollamaVersion: ollamaVersion)?.id ?? current
    }
}
