import Foundation

// Shared vocabulary for the Design Studio subsystem. Pure data, Foundation only.
// Every campaign workstream compiles against these types; do not add engine or UI
// dependencies here. Persisted structs follow the house rule: hand-written
// init(from:) with decodeIfPresent + defaults so old JSON on disk never breaks.

enum DesignArtifactKind: String, Codable, CaseIterable, Sendable {
    case prototype
    case deck
    case dashboard
    case image
    case motion

    var displayName: String {
        switch self {
        case .prototype: return "Prototype"
        case .deck: return "Deck"
        case .dashboard: return "Live Dashboard"
        case .image: return "Image"
        case .motion: return "Motion"
        }
    }

    var iconName: String {
        switch self {
        case .prototype: return "macwindow"
        case .deck: return "rectangle.on.rectangle"
        case .dashboard: return "chart.bar.xaxis"
        case .image: return "photo"
        case .motion: return "film"
        }
    }
}

struct DesignVersion: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let savedAt: Date
    let label: String
    let byteCount: Int
}

struct DesignProject: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var slug: String
    var title: String
    var kind: DesignArtifactKind
    var brandSlug: String?
    var designSystemFile: String?
    var tags: [String]
    var starred: Bool
    var createdAt: Date
    var updatedAt: Date
    var preview: String?

    init(
        id: UUID = UUID(),
        slug: String,
        title: String,
        kind: DesignArtifactKind = .prototype,
        brandSlug: String? = nil,
        designSystemFile: String? = nil,
        tags: [String] = [],
        starred: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        preview: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.kind = kind
        self.brandSlug = brandSlug
        self.designSystemFile = designSystemFile
        self.tags = tags
        self.starred = starred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        kind = (try? c.decode(DesignArtifactKind.self, forKey: .kind)) ?? .prototype
        brandSlug = try? c.decodeIfPresent(String.self, forKey: .brandSlug)
        designSystemFile = try? c.decodeIfPresent(String.self, forKey: .designSystemFile)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        starred = (try? c.decode(Bool.self, forKey: .starred)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
    }
}

struct DesignProjectIndexEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var slug: String
    var title: String
    var kind: DesignArtifactKind
    var brandSlug: String?
    var starred: Bool
    var updatedAt: Date
}

// How a generative run is executed and billed. The route is the campaign's
// usage pitch: the same run can ride the metered API, the Claude Code
// subscription CLI, or a free local model, and the picker prices each.
enum ExecutionRoute: String, Codable, CaseIterable, Sendable {
    case api
    case subscriptionCLI
    case localModel

    var displayName: String {
        switch self {
        case .api: return "API key"
        case .subscriptionCLI: return "Claude Code subscription"
        case .localModel: return "Local model"
        }
    }

    // Provider string understood by ModelRegistry.resolvedRouting.
    var providerString: String? {
        switch self {
        case .api: return "anthropic"
        case .subscriptionCLI: return nil
        case .localModel: return "local"
        }
    }
}

struct DesignRunConfig: Codable, Hashable, Sendable {
    var route: ExecutionRoute
    var modelId: String?
    var brandSlug: String?
    var draftMode: Bool
    var temperature: Double?

    init(
        route: ExecutionRoute = .api,
        modelId: String? = nil,
        brandSlug: String? = nil,
        draftMode: Bool = false,
        temperature: Double? = nil
    ) {
        self.route = route
        self.modelId = modelId
        self.brandSlug = brandSlug
        self.draftMode = draftMode
        self.temperature = temperature
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = (try? c.decode(ExecutionRoute.self, forKey: .route)) ?? .api
        modelId = try? c.decodeIfPresent(String.self, forKey: .modelId)
        brandSlug = try? c.decodeIfPresent(String.self, forKey: .brandSlug)
        draftMode = (try? c.decode(Bool.self, forKey: .draftMode)) ?? false
        temperature = try? c.decodeIfPresent(Double.self, forKey: .temperature)
    }
}

// A pre-run cost estimate. All figures are estimates and every user-facing
// rendering must carry the word "estimated" per the Foundry labeling rule.
struct DesignRouteCost: Codable, Hashable, Sendable {
    let route: ExecutionRoute
    let modelId: String
    let estimatedUSD: Double?
    let label: String
}

struct DesignRunEstimate: Codable, Hashable, Sendable {
    let inputTokens: Int
    let maxOutputTokens: Int
    let primary: DesignRouteCost
    let alternatives: [DesignRouteCost]
    let generatedAt: Date

    init(
        inputTokens: Int,
        maxOutputTokens: Int,
        primary: DesignRouteCost,
        alternatives: [DesignRouteCost] = [],
        generatedAt: Date = Date()
    ) {
        self.inputTokens = inputTokens
        self.maxOutputTokens = maxOutputTokens
        self.primary = primary
        self.alternatives = alternatives
        self.generatedAt = generatedAt
    }
}

extension Notification.Name {
    static let gruxDesignArtifactsUpdated = Notification.Name("gruxDesignArtifactsUpdated")
    static let gruxDesignRunStateChanged = Notification.Name("gruxDesignRunStateChanged")
}
