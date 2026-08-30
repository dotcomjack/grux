import Foundation

// Durable user choices for the Cookbook tab: which model the user picked, which
// models were pulled through Grux, whether to auto-serve Ollama at launch,
// and the last detected hardware profile (so the hardware card renders
// instantly on next open, then refreshes live). JSON on disk in the Grux
// Application Support dir, debounced scheduleSave like SemanticMemoryStore.
struct CookbookState: Codable, Equatable {
    var selectedModelId: String? = nil
    var pulledModelIds: [String] = []
    var autoServeOnLaunch: Bool = false
    var lastProfile: HardwareProfile? = nil

    static let empty = CookbookState()

    init() {}

    // decodeIfPresent everywhere (GruxConfig migration style) so an older or
    // partial cookbook.json never throws and never resets the user's choices.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedModelId = try c.decodeIfPresent(String.self, forKey: .selectedModelId)
        pulledModelIds = try c.decodeIfPresent([String].self, forKey: .pulledModelIds) ?? []
        autoServeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoServeOnLaunch) ?? false
        lastProfile = try c.decodeIfPresent(HardwareProfile.self, forKey: .lastProfile)
    }
}

@MainActor
final class CookbookStore: ObservableObject {
    static let shared = CookbookStore()

    @Published private(set) var state: CookbookState = .empty
    private var loaded = false
    private var pendingSave: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "grux.cookbook.save", qos: .utility)

    // Own URL computed locally (InboxStore pattern) so this module never
    // touches the shared Persistence.swift file.
    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("cookbook.json") }

    private init() {}

    func load() {
        guard !loaded else { return }
        loaded = true
        state = Persistence.load(CookbookState.self, from: jsonURL, fallback: .empty)
    }

    // MARK: - Mutations

    func select(modelId: String?) {
        load()
        guard state.selectedModelId != modelId else { return }
        state.selectedModelId = modelId
        scheduleSave()
    }

    func notePulled(_ modelId: String) {
        load()
        guard !state.pulledModelIds.contains(modelId) else { return }
        state.pulledModelIds.append(modelId)
        scheduleSave()
    }

    func setAutoServe(_ on: Bool) {
        load()
        guard state.autoServeOnLaunch != on else { return }
        state.autoServeOnLaunch = on
        scheduleSave()
    }

    func noteProfile(_ profile: HardwareProfile) {
        load()
        guard state.lastProfile != profile else { return }
        state.lastProfile = profile
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        pendingSave = work
        writeQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveNow() {
        Persistence.save(state, to: jsonURL)
    }
}
