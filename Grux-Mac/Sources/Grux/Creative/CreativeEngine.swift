import Foundation
import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import GruxShellCore

// CreativeEngine
//
// Voice-triggered creative pipeline. Routes spoken briefs through whichever
// creative services the user has configured:
//
//   1. Image-only path     : voice mentions "hero shot" / "image" / "render"
//                            POST <image service>/api/images/render
//                            (see imageBaseURLs: empty until configured)
//
//   2. Full-bundle path    : voice mentions "creative brief" / "ad" / "copy"
//                            POST http://127.0.0.1:3850/api/creative/brief
//                            wraps a Mac-local Node content-studio service.
//                            Falls back to image-only, then to direct Claude
//                            when the Node wrapper is unreachable.
//
// Brand cue from the utterance ("for <brand>") is matched against the brands
// discovered in the project registry. Nothing is compiled in, so an install
// with no registry simply produces untagged work.
//
// Every result is persisted to ~/.grux/creative/<brand>/<timestamp>.json
// (with the image bytes as a sibling .png when one was rendered) and
// surfaced in CreativeStudioView.

// MARK: - Domain

enum CreativeIntent: String, Codable, Sendable {
    case imageOnly
    case fullBundle
}

// CreativeBrand identifies which brand voice + visual identity a generation
// belongs to. Two families:
//
//   - Untagged: explicit "no brand". Brand voice comes from the brief alone.
//     Useful for one-off work, and the honest default on a fresh install.
//   - Registry(slug): a project discovered in the projects index, with a
//     deterministic accent color from a slug hash. Brands appear as the
//     registry learns about them; no roster is compiled in.
//
// Wire format: single string slug, which is what makes this safe to change:
// a bundle written by an older build decodes its slug into .registry and
// re-encodes byte-identically. The "untagged" sentinel decodes to .untagged.
enum CreativeBrand: Hashable, Sendable {
    case untagged
    case registry(slug: String)

    var slug: String {
        switch self {
        case .untagged: return "untagged"
        case .registry(let s): return s
        }
    }

    var rawValue: String { slug }

    init(slug: String) {
        switch slug.lowercased() {
        case "untagged", "", "no-brand", "none": self = .untagged
        default: self = .registry(slug: slug.lowercased())
        }
    }

    // Brand cue from an utterance, matched against the slugs the registry
    // actually knows about. Pure on purpose: the roster is passed in rather
    // than reached for, so this stays testable and non-isolated. An empty
    // roster answers .untagged, which is correct rather than a failure.
    static func parse(from utterance: String, known: [String]) -> CreativeBrand {
        let lower = utterance.lowercased()
        for slug in known where slug.count >= 3 {
            let spaced = slug.replacingOccurrences(of: "-", with: " ")
            if lower.contains(slug) || lower.contains(spaced) {
                return .registry(slug: slug)
            }
        }
        return .untagged
    }

    var displayName: String {
        switch self {
        case .untagged: return "No brand"
        case .registry(let s):
            return s.split(separator: "-").map { String($0).capitalized }.joined(separator: " ")
        }
    }

    var shortName: String {
        switch self {
        case .untagged: return "None"
        case .registry(let s):
            let head = s.split(separator: "-").first.map(String.init) ?? s
            return String(head.prefix(8)).capitalized
        }
    }

    // Brand accent color. Untagged is muted. Registry brands derive a
    // deterministic hue from a slug hash so the same brand gets the same
    // color across launches.
    var accentColor: Color {
        switch self {
        case .untagged: return GruxTheme.textTertiary
        case .registry(let s):
            return CreativeBrand.deterministicHue(for: s)
        }
    }

    var accentSoft: Color { accentColor.opacity(0.16) }

    private static func deterministicHue(for slug: String) -> Color {
        // Simple djb2 hash → hue in 0..360. Saturation + brightness kept
        // restrained so brand chips stay quiet next to the app's own accent
        // instead of competing with it.
        var hash: UInt64 = 5381
        for b in slug.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.42, brightness: 0.78)
    }
}

extension CreativeBrand: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let slug = try c.decode(String.self)
        self.init(slug: slug)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(slug)
    }
}

// MARK: - Workflows

// What a studio generation produces. Image and video focused only. Text
// outputs (copy, ad-copy, scripts as standalone, threads posts, emails)
// belong in Chat, not here.
enum CreativeWorkflow: String, Codable, Sendable, CaseIterable, Identifiable {
    case image         // single hero image, brand-aware
    case platformPack  // image set sized for Meta (1:1) and TikTok (9:16)
    case videoDraft    // structured video script (hook/body/payoff) + one storyboard frame

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .platformPack: return "Platform pack"
        case .videoDraft: return "Video draft"
        }
    }

    var subline: String {
        switch self {
        case .image: return "One hero render"
        case .platformPack: return "Meta 1:1, TikTok 9:16"
        case .videoDraft: return "Script + storyboard frame"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo.fill"
        case .platformPack: return "square.grid.2x2.fill"
        case .videoDraft: return "video.fill"
        }
    }
}

// MARK: - Brand registry

// Loads the Untagged sentinel plus every project in the projects registry.
// Cached in-memory for the session; refreshed in the background on app launch
// and on demand. No brand roster is compiled in: an install whose registry
// answers nothing shows the Untagged chip alone, which is a working state.
@MainActor
final class CreativeBrandRegistry: ObservableObject {

    static let shared = CreativeBrandRegistry()

    // Published list, ordered for the chip strip:
    //   1. Untagged (No brand)
    //   2. Registry brands, alphabetical
    @Published private(set) var brands: [CreativeBrand] = [.untagged]

    // slug -> the registry project's real, proper-cased name. The chip strip
    // renders these verbatim so a brand never shows a mangled or truncated
    // label.
    @Published private(set) var registryNames: [String: String] = [:]

    @Published private(set) var lastRegistryFetch: Date? = nil
    @Published private(set) var registryReachable: Bool = false

    // Convenience for the view. The warning ribbon should only fire when
    // there are literally no registry brands available, not when the source
    // happens to be the on-disk cache. A cached registry is still useful.
    var registryHasBrands: Bool {
        brands.contains { if case .registry = $0 { return true } else { return false } }
    }

    // Slugs of every brand the registry knows about, in chip order. This is
    // the roster CreativeBrand.parse matches an utterance against, and it is
    // empty until a registry answers.
    var registrySlugs: [String] {
        brands.compactMap { brand -> String? in
            if case .registry(let s) = brand { return s }
            return nil
        }
    }

    // The label a chip should show for a brand. Untagged uses its own
    // displayName; registry brands prefer the live project name and fall
    // back to the slug-derived title only when the registry has not loaded.
    func displayName(for brand: CreativeBrand) -> String {
        if case .registry(let slug) = brand {
            return registryNames[slug] ?? brand.displayName
        }
        return brand.displayName
    }

    private init() {
        // Kick off a background fetch shortly after init. Failure is silent;
        // the Untagged chip still renders fine without a registry.
        Task { await self.refresh() }
    }

    func refresh() async {
        let result = await ProjectRegistryClient.fetchProjects()
        var seen = Set<String>()
        let projects: [RemoteProject] = result.projects
            .filter { $0.status == "active" }
            .compactMap { proj -> RemoteProject? in
                let s = proj.slug.lowercased()
                // Dedupe case-insensitively by slug.
                guard seen.insert(s).inserted else { return nil }
                return proj
            }
            .sorted { $0.slug.lowercased() < $1.slug.lowercased() }
        let registryBrands: [CreativeBrand] = projects.map { .registry(slug: $0.slug.lowercased()) }
        var names: [String: String] = [:]
        for proj in projects {
            let s = proj.slug.lowercased()
            let n = proj.name.trimmingCharacters(in: .whitespacesAndNewlines)
            names[s] = n.isEmpty ? CreativeBrand(slug: s).displayName : n
        }
        self.registryNames = names
        self.brands = [.untagged] + registryBrands
        self.lastRegistryFetch = Date()
        self.registryReachable = (result.source == .macMini || result.source == .localhost)
    }
}

// One-line quick-start prompts shown on the empty-state hero so a brand new
// user can fire a bundle with one click instead of guessing the voice phrase.
struct CreativeQuickPrompt: Identifiable {
    let id = UUID()
    let label: String
    let utterance: String
    let brand: CreativeBrand
    let intent: CreativeIntent
}

extension CreativeQuickPrompt {
    // Deliberately brand-free. These are shape examples, not a portfolio, so
    // they work on a fresh install with nothing configured.
    static let seeded: [CreativeQuickPrompt] = [
        .init(
            label: "Hero shot",
            utterance: "Render a hero shot of a ceramic mug on a warm marble counter beside a citrus slice.",
            brand: .untagged,
            intent: .imageOnly
        ),
        .init(
            label: "Creative brief",
            utterance: "Draft a creative brief for a small product launch. Focus on one clear promise and who it is for.",
            brand: .untagged,
            intent: .fullBundle
        ),
        .init(
            label: "Social post",
            utterance: "Draft a short social post announcing a new feature, plain language, no hype.",
            brand: .untagged,
            intent: .fullBundle
        )
    ]
}

struct CreativeBundle: Codable, Identifiable, Sendable {
    let id: String              // timestamp + brand-slug + nonce
    let createdAt: Date
    let brand: CreativeBrand
    let intent: CreativeIntent
    let utterance: String
    let imageURL: String?       // remote URL from :3847 if rendered
    let localImagePath: String? // sibling .png on disk if downloaded
    let copy: CreativeCopy?
    let imageBrief: CreativeImageBrief?
    let adVariants: [CreativeAdVariant]
    let script: CreativeScript?
    let providerPath: String    // "3850" | "3847-only" | "claude-direct"
    let degraded: Bool
    let notes: String?

    // Optional: present on bundles created through the Studio's typed
    // composer. Voice-triggered bundles created before this field existed
    // decode with workflow == nil; the studio view falls back to .image.
    let workflow: CreativeWorkflow?

    // Dynamic Studio fields (Phase 1+). All have safe defaults so older bundles
    // and the existing render paths decode and construct unchanged.
    let images: [String]          // local paths of all rendered siblings (batch); localImagePath == images.first
    let remoteImages: [String]    // pipeline-relative paths on the render service, index-aligned with images
    let directive: String?        // the compiled qwen-style directive actually sent to /render-dynamic
    let aspect: String?           // "1:1" | "4:5" | "9:16" | "16:9"
    let recipeId: String?         // the recipe this bundle was generated from, if any
    let batchID: String?          // groups sibling variations from one generate call
    var approval: ApprovalState   // draft | approved | rejected (library workflow)
    var tags: [String]            // free-form tags for search
    var videoPath: String?        // local .mp4 once a still is animated (Phase 6)
    let imageModel: String?       // model that produced the still (e.g. qwen-image-edit-plus)
    var videoModel: String?       // model that produced the clip (e.g. wan2.6-i2v), once animated
    var rating: AssetRating       // self-learning feedback: up / down / none
    var feedbackNote: String?     // optional freeform note attached to the rating
    let parentAssetId: String?    // C2PA-style lineage: the asset this was derived from (e.g. an aspect export)

    enum CodingKeys: String, CodingKey {
        case id, createdAt, brand, intent, utterance, imageURL, localImagePath,
             copy, imageBrief, adVariants, script, providerPath, degraded, notes, workflow,
             images, remoteImages, directive, aspect, recipeId, batchID, approval, tags, videoPath,
             imageModel, videoModel, rating, feedbackNote, parentAssetId
    }

    init(id: String, createdAt: Date, brand: CreativeBrand, intent: CreativeIntent,
         utterance: String, imageURL: String?, localImagePath: String?,
         copy: CreativeCopy?, imageBrief: CreativeImageBrief?,
         adVariants: [CreativeAdVariant], script: CreativeScript?,
         providerPath: String, degraded: Bool, notes: String?,
         workflow: CreativeWorkflow? = nil,
         images: [String] = [], remoteImages: [String] = [], directive: String? = nil, aspect: String? = nil,
         recipeId: String? = nil, batchID: String? = nil,
         approval: ApprovalState = .draft, tags: [String] = [], videoPath: String? = nil,
         imageModel: String? = nil, videoModel: String? = nil,
         rating: AssetRating = .none, feedbackNote: String? = nil, parentAssetId: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.brand = brand
        self.intent = intent
        self.utterance = utterance
        self.imageURL = imageURL
        self.localImagePath = localImagePath
        self.copy = copy
        self.imageBrief = imageBrief
        self.adVariants = adVariants
        self.script = script
        self.providerPath = providerPath
        self.degraded = degraded
        self.notes = notes
        self.workflow = workflow
        self.images = images
        self.remoteImages = remoteImages
        self.directive = directive
        self.aspect = aspect
        self.recipeId = recipeId
        self.batchID = batchID
        self.approval = approval
        self.tags = tags
        self.videoPath = videoPath
        self.imageModel = imageModel
        self.videoModel = videoModel
        self.rating = rating
        self.feedbackNote = feedbackNote
        self.parentAssetId = parentAssetId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.brand = try c.decode(CreativeBrand.self, forKey: .brand)
        self.intent = try c.decode(CreativeIntent.self, forKey: .intent)
        self.utterance = try c.decode(String.self, forKey: .utterance)
        self.imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        self.localImagePath = try c.decodeIfPresent(String.self, forKey: .localImagePath)
        self.copy = try c.decodeIfPresent(CreativeCopy.self, forKey: .copy)
        self.imageBrief = try c.decodeIfPresent(CreativeImageBrief.self, forKey: .imageBrief)
        self.adVariants = (try? c.decode([CreativeAdVariant].self, forKey: .adVariants)) ?? []
        self.script = try c.decodeIfPresent(CreativeScript.self, forKey: .script)
        self.providerPath = (try? c.decode(String.self, forKey: .providerPath)) ?? ""
        self.degraded = (try? c.decode(Bool.self, forKey: .degraded)) ?? false
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.workflow = try c.decodeIfPresent(CreativeWorkflow.self, forKey: .workflow)
        self.images = (try? c.decode([String].self, forKey: .images)) ?? []
        self.remoteImages = (try? c.decode([String].self, forKey: .remoteImages)) ?? []
        self.directive = try c.decodeIfPresent(String.self, forKey: .directive)
        self.aspect = try c.decodeIfPresent(String.self, forKey: .aspect)
        self.recipeId = try c.decodeIfPresent(String.self, forKey: .recipeId)
        self.batchID = try c.decodeIfPresent(String.self, forKey: .batchID)
        self.approval = (try? c.decode(ApprovalState.self, forKey: .approval)) ?? .draft
        self.tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        self.videoPath = try c.decodeIfPresent(String.self, forKey: .videoPath)
        self.imageModel = try c.decodeIfPresent(String.self, forKey: .imageModel)
        self.videoModel = try c.decodeIfPresent(String.self, forKey: .videoModel)
        self.rating = (try? c.decode(AssetRating.self, forKey: .rating)) ?? .none
        self.feedbackNote = try c.decodeIfPresent(String.self, forKey: .feedbackNote)
        self.parentAssetId = try c.decodeIfPresent(String.self, forKey: .parentAssetId)
    }
}

/// Library approval state for a rendered bundle.
enum ApprovalState: String, Codable, Sendable {
    case draft
    case approved
    case rejected
}

struct CreativeCopy: Codable, Sendable, Hashable {
    let headline: String
    let body: String
    let cta: String
}

struct CreativeImageBrief: Codable, Sendable, Hashable {
    let scene: String
    let prompt: String
}

struct CreativeAdVariant: Codable, Sendable, Hashable, Identifiable {
    var id: String { "\(platform)-\(hook.prefix(20))" }
    let platform: String
    let hook: String
    let body: String
    let cta: String
}

struct CreativeScript: Codable, Sendable, Hashable {
    let hook: String
    let body: String
    let payoff: String
}

// MARK: - Engine

@MainActor
final class CreativeEngine: ObservableObject {

    static let shared = CreativeEngine()

    @Published private(set) var inbox: [CreativeBundle] = []
    @Published private(set) var isWorking: Bool = false
    // Reference count so concurrent async ops (e.g. animate while a render runs)
    // don't clear the busy state early and let the UI fire a second job.
    private var workingCount: Int = 0 { didSet { isWorking = workingCount > 0 } }
    private func beginWork() { workingCount += 1 }
    private func endWork() { workingCount = max(0, workingCount - 1) }
    @Published var lastError: String? {
        // EVERY write drops the absence flag: the nil clears, the technical
        // messages, and the writes the studio view makes directly. The ONE
        // absence write, in renderImageNow, sets it back immediately after.
        // A didSet rather than a paired flag write beside each of the
        // fifteen sites, because the sixteenth site would forget the pair
        // and ship a technical fault wearing the absence card.
        didSet { lastErrorIsAbsence = false }
    }
    /// True exactly while `lastError` holds the media-service absence notice,
    /// so the studio can give it the notice treatment instead of an error
    /// line: absence is a normal state to explain, never a fault to report.
    @Published private(set) var lastErrorIsAbsence = false

    private let session: URLSession
    // The composing wrapper, on loopback. A companion service the user runs, so
    // it is absent on every install but the one it was written on. That is NOT a
    // dead end here: runFullBundle degrades to image-only and then to a direct
    // model call, so the surface still produces something. The reader-facing
    // sentence for when it produces nothing lives in one place,
    // PrivateServiceNotice.mediaService. Do not write a second one.
    private let creativeBriefURL = URL(string: "http://127.0.0.1:3850/api/creative/brief")!
    private let creativeHealthURL = URL(string: "http://127.0.0.1:3850/healthz")!

    // Base URLs of the image-generation service, tried in order. EMPTY by
    // default: this is a service the user runs on their own machine, and a
    // fresh install has no idea where it lives. Configure it as a comma
    // separated list, e.g.
    //
    //   defaults write com.gruxai.grux grux.creative.imageServiceBaseURLs \
    //     "http://your-host.local:3847,http://localhost:3847"
    //
    // Empty already means "not configured" at every call site: the POST and
    // GET helpers below iterate this list, so an empty list simply finds no
    // reachable path and the caller reports the failure. Each entry is fast
    // to fail when its prerequisite (VPN, tunnel, LAN) is not present.
    // Internal rather than private because PrivateServiceNotice.mediaService
    // answers the same question from the same key and reads it through this
    // one parser (the SocialOpsService.configuredHosts precedent: one reader
    // per config source). Nonisolated so the notice's @Sendable closures can
    // call it; it reads only UserDefaults.
    nonisolated static var imageBaseURLs: [String] {
        (UserDefaults.standard.string(forKey: "grux.creative.imageServiceBaseURLs") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Every configured base joined to one route, in precedence order.
    //
    // THE JOIN RULE HAS ONE HOME, `PrivateServiceFetch.join`, and this is how
    // the render service reaches it. These bases are PASTED BY A PERSON into
    // a defaults key, so a trailing slash is an ordinary thing to find in
    // one, and the naive concat every site used produced
    // "http://host//api/images/render". Strict routers 404 that path, which
    // turned a healthy service into a total failure of render, mini-list,
    // approve and draft-from-image, and left the mediaService probe counting
    // the 404 as proof the service was listening and well.
    //
    // A base that will not parse as a URL is dropped rather than passed
    // through: it could never have been reached anyway, and dropping it here
    // keeps the failure at the one place that knows why.
    nonisolated static func imageServiceURLs(_ path: String) -> [String] {
        imageBaseURLs.compactMap { base in
            guard let url = URL(string: base) else { return nil }
            return PrivateServiceFetch.join(url, path: path)?.absoluteString
        }
    }

    // scp target holding the render pipeline's output tree, as
    // "user@host:/absolute/path". EMPTY by default for the same reason as
    // imageBaseURLs. Empty means no file is copied back, so a bundle simply
    // arrives without local bytes rather than failing.
    private var imageServiceScpRoot: String {
        (UserDefaults.standard.string(forKey: "grux.creative.imageServiceScpRoot") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: cfg)
        loadInboxFromDisk()
    }

    // MARK: - Public entry points

    // Voice path: parse utterance to intent + brand, dispatch.
    func handleVoice(_ utterance: String) {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let brand = CreativeBrand.parse(from: trimmed,
                                        known: CreativeBrandRegistry.shared.registrySlugs)
        let intent = inferIntent(from: trimmed)
        Task { await self.run(utterance: trimmed, brand: brand, intent: intent) }
    }

    /// THE ONE MEDIA-SERVICE ABSENCE GATE for every user-facing render entry
    /// point. Returns true when it has answered, and the caller must return.
    ///
    /// It was copied into renderImageNow and then renderDynamic, and the two
    /// entry points that were NOT under the cursor on either occasion,
    /// `run(utterance:)` and `generate(brief:)`, kept answering an
    /// unconfigured install with "creative engine: all upstream paths failed"
    /// in amber: the opaque wrong-cause message the guard exists to delete.
    /// A rule copied per call site is a rule that misses call sites.
    ///
    /// The sweep, counted rather than assumed. Six entry points reach the
    /// image service: renderImageNow, renderDynamic, run(utterance:) and
    /// generate() all take this gate; animate() cannot be reached on an
    /// unconfigured install because it requires remoteImages from a render
    /// that already succeeded; setApproval and draftToSocial are
    /// fire-and-forget background writes with no user-visible verdict.
    ///
    /// - Parameter resultPath: the fire-image CLI verdict file, written here
    ///   because this early return is otherwise the one exit that skips the
    ///   contract, which once left a harness reading a previous run's PASS.
    private func answeredWithMediaServiceAbsence(resultPath: String? = nil) -> Bool {
        guard Self.imageBaseURLs.isEmpty else { return false }
        self.lastError = PrivateServiceNotice.mediaService.explanation
        self.lastErrorIsAbsence = true
        if let resultPath {
            let line = "fire-image @ \(ISO8601DateFormatter().string(from: Date()))\n"
                + "VERDICT: FAIL\nerror: \(PrivateServiceNotice.mediaService.explanation)\n"
            try? line.write(toFile: resultPath, atomically: true, encoding: .utf8)
        }
        return true
    }

    // Direct programmatic path (used by the smoke test).
    func run(utterance: String, brand: CreativeBrand, intent: CreativeIntent) async {
        // The fault channel is cleared on ENTRY here, matching
        // renderDynamic. engineStatus is the first reader this wave
        // gave a write-only channel, which turned "never cleared" from
        // invisible into an amber banner that outlived the failure it
        // described: a failed render followed by a successful one still
        // read "render service unreachable" until dismissed by hand.
        self.lastError = nil
        if answeredWithMediaServiceAbsence() { return }
        beginWork()
        defer { endWork() }
        do {
            let bundle: CreativeBundle
            switch intent {
            case .imageOnly:
                bundle = try await runImageOnly(utterance: utterance, brand: brand)
            case .fullBundle:
                bundle = try await runFullBundle(utterance: utterance, brand: brand)
            }
            persist(bundle)
            self.inbox.insert(bundle, at: 0)
            WakeLog.shared.log("creative: bundle saved id=\(bundle.id.prefix(20)) brand=\(brand.rawValue) intent=\(intent.rawValue) path=\(bundle.providerPath)")
        } catch {
            self.lastError = "creative engine: \(error.localizedDescription)"
            WakeLog.shared.log("creative: failed, \(error.localizedDescription)")
        }
    }

    // MARK: - Intent inference

    private func inferIntent(from utterance: String) -> CreativeIntent {
        let l = utterance.lowercased()
        let imageCues = ["hero shot", "render", "image of", "picture of", "photo of"]
        let bundleCues = ["creative brief", "draft", "ad", "copy", "campaign", "post for"]
        let hasImage = imageCues.contains(where: { l.contains($0) })
        let hasBundle = bundleCues.contains(where: { l.contains($0) })
        // If both cues fire, the richer bundle wins. Image-only is a subset
        // of what the wrapper service produces.
        if hasBundle { return .fullBundle }
        if hasImage { return .imageOnly }
        return .fullBundle
    }

    // MARK: - Image-only path

    private func runImageOnly(utterance: String, brand: CreativeBrand) async throws -> CreativeBundle {
        guard let (scene, sku) = await pickMiniSceneAndSku(for: brand) else {
            throw CreativeError.allPathsFailed
        }
        let payload: [String: Any] = [
            "brand": brand.rawValue,
            "scene": scene,
            "sku": sku
        ]
        let (rendered, baseUsed) = try await postFirstReachable(
            paths: Self.imageServiceURLs("/api/images/render"),
            body: payload,
            perRequestTimeoutSec: 90
        )
        let imageURL = renderResponseURL(rendered, baseUsed: baseUsed)
        var downloadedImagePath: String? = nil
        if let outputPath = rendered["outputPath"] as? String, !outputPath.isEmpty {
            downloadedImagePath = await fetchRenderedImage(outputPath: outputPath, brand: brand)
        } else if let url = imageURL {
            downloadedImagePath = await downloadImageBytes(url: url, brand: brand)
        }

        let bundleId = bundleID(brand: brand)
        return CreativeBundle(
            id: bundleId,
            createdAt: Date(),
            brand: brand,
            intent: .imageOnly,
            utterance: utterance,
            imageURL: imageURL,
            localImagePath: downloadedImagePath,
            copy: nil,
            imageBrief: CreativeImageBrief(scene: utterance, prompt: utterance),
            adVariants: [],
            script: nil,
            providerPath: {
                if baseUsed.contains("localhost") || baseUsed.contains("127.0.0.1") {
                    return "3847-localhost"
                }
                return "3847-remote"
            }(),
            degraded: false,
            notes: nil
        )
    }

    // MARK: - Full-bundle path

    private func runFullBundle(utterance: String, brand: CreativeBrand) async throws -> CreativeBundle {
        // 1. Try the :3850 wrapper first.
        if let bundle = try? await fetchFromWrapper(utterance: utterance, brand: brand) {
            return bundle
        }

        // 2. Wrapper unreachable. Try the on-demand spawn (best effort).
        spawnWrapperIfPossible()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let bundle = try? await fetchFromWrapper(utterance: utterance, brand: brand) {
            return bundle
        }

        // 3. Wrapper still down. Degrade to image-only.
        if let imageOnly = try? await runImageOnly(utterance: utterance, brand: brand) {
            var degraded = imageOnly
            degraded = CreativeBundle(
                id: imageOnly.id,
                createdAt: imageOnly.createdAt,
                brand: imageOnly.brand,
                intent: .fullBundle,
                utterance: imageOnly.utterance,
                imageURL: imageOnly.imageURL,
                localImagePath: imageOnly.localImagePath,
                copy: nil,
                imageBrief: imageOnly.imageBrief,
                adVariants: [],
                script: nil,
                providerPath: "3847-only (degraded)",
                degraded: true,
                notes: "Wrapper :3850 unreachable. Image-only output."
            )
            return degraded
        }

        // 4. Both companion service paths down. Last resort: direct Claude call.
        return try await fetchFromClaudeDirect(utterance: utterance, brand: brand)
    }

    private func fetchFromWrapper(utterance: String, brand: CreativeBrand) async throws -> CreativeBundle {
        let payload: [String: Any] = [
            "brand": brand.rawValue,
            "intent": utterance
        ]
        var req = URLRequest(url: creativeBriefURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CreativeError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = try parseWrapperPayload(data: data)

        // Render an image via :3847 so the bundle ships with a visual.
        // The companion service's API contract: scene must be a discrete label from
        // /api/images/scenes?brand=X (e.g. "A"), sku must be a real product
        // slug from /api/images/skus?brand=X. Free-form prose 400s. So we
        // discover the valid set per brand (cached in-process), pick scene
        // "A" plus the first listed sku, and call. If the brand has no
        // configured scenes/skus on the render service (untagged, registry brands),
        // we skip the render and the bundle ships text-only.
        var imageURL: String? = nil
        var localImagePath: String? = nil
        if parsed.imageBrief != nil,
           let (scene, sku) = await pickMiniSceneAndSku(for: brand),
           let (rendered, baseUsed) = try? await postFirstReachable(
            paths: Self.imageServiceURLs("/api/images/render"),
            body: ["brand": brand.rawValue, "scene": scene, "sku": sku],
            perRequestTimeoutSec: 90
           ) {
            imageURL = renderResponseURL(rendered, baseUsed: baseUsed)
            if let outputPath = rendered["outputPath"] as? String, !outputPath.isEmpty {
                localImagePath = await fetchRenderedImage(outputPath: outputPath, brand: brand)
            } else if let url = imageURL {
                localImagePath = await downloadImageBytes(url: url, brand: brand)
            }
        }
        let providerPath: String = (localImagePath == nil) ? "3850 (no-img)" : "3850+3847"

        let bundleId = bundleID(brand: brand)

        // POST grounding: brand copy must not assert a product fact off the catalog.
        let copyText = [parsed.copy?.headline, parsed.copy?.body, parsed.copy?.cta]
            .compactMap { $0 }.joined(separator: " ")
            + " " + parsed.adVariants.map { "\($0.hook) \($0.body) \($0.cta)" }.joined(separator: " ")
        let verdict = await MainActor.run { GroundingGate.vet(draft: copyText, brief: "\(brand.rawValue) \(utterance)") }
        if !verdict.surfaceable {
            WakeLog.shared.log("creative: blocked ungrounded fact in \(brand.rawValue) bundle. \(verdict.refusalLine)")
            // Fail safe: do not ship invented copy. Return a degraded bundle naming
            // the issue so the caller regenerates or a human fixes it; never the fact.
            return CreativeBundle(id: bundleId, createdAt: Date(), brand: brand, intent: .fullBundle, utterance: utterance, imageURL: imageURL, localImagePath: localImagePath, copy: parsed.copy, imageBrief: parsed.imageBrief, adVariants: parsed.adVariants, script: parsed.script, providerPath: providerPath, degraded: true, notes: verdict.refusalLine)
        }

        return CreativeBundle(
            id: bundleId,
            createdAt: Date(),
            brand: brand,
            intent: .fullBundle,
            utterance: utterance,
            imageURL: imageURL,
            localImagePath: localImagePath,
            copy: parsed.copy,
            imageBrief: parsed.imageBrief,
            adVariants: parsed.adVariants,
            script: parsed.script,
            providerPath: providerPath,
            degraded: false,
            notes: nil
        )
    }

    private func fetchFromClaudeDirect(utterance: String, brand: CreativeBrand) async throws -> CreativeBundle {
        // ROUTED, AND THE ROUTE PICKS THE MODEL. This built its own ClaudeClient
        // and gated on AppState.anthropicKey, so the copy-only rescue path (both
        // render service ports unreachable) threw missingClaudeKey for a
        // local-only or custom-endpoint user and the bundle came back empty.
        //
        // The first cut of that fix pinned "claude-sonnet-4-6" as the override
        // to hold the tier, and resolvedRouting returned that id AFTER the
        // backend had resolved, so on a local route this last resort POSTed an
        // Anthropic model id to Ollama and the bundle came back empty anyway,
        // just with a 404 instead of a missing key. A rescue path that still
        // fails is not a rescue, so the override is now only ever honoured on a
        // route that can serve it, and the routed model is used everywhere else.
        //
        // Resolved ONCE, before the prompt is built.
        // THE TIER IS RESTORED, and it is safe now for a reason that did not
        // exist when it was dropped. resolvedRouting refuses an Anthropic model
        // id on a route that cannot serve it, so this override holds on the
        // Anthropic route and falls back to the routed model on a local or
        // custom one. Dropping it entirely also fixed the 404, and it fixed it
        // by quietly downgrading a paying user from Sonnet to Haiku on a
        // feature nobody had asked to change. A preference honoured only where
        // it can be honoured costs nothing and keeps the behaviour that shipped.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: "claude-sonnet-4-6")
        guard !routing.apiKey.isEmpty else { throw CreativeError.missingClaudeKey }
        let brandBlock = directClaudeBrandBlock(for: brand)
        let user = """
        \(brandBlock)

        CREATIVE BRIEF:
        Brand: \(brand.rawValue)
        Intent: \(utterance)

        Produce a complete creative bundle in valid JSON with this schema:
        {
          "copy": {"headline": "...", "body": "...", "cta": "..."},
          "image_brief": {"scene": "...", "prompt": "..."},
          "ad_variants": [{"platform":"meta","hook":"...","body":"...","cta":"..."}],
          "script": {"hook":"...","body":"...","payoff":"..."}
        }
        Return ONLY the JSON object. No markdown fence. No commentary.
        """
        let reply = try await routing.backend.complete(
            apiKey: routing.apiKey,
            model: routing.modelId,
            system: nil,
            messages: [ClaudeMessage(role: "user", content: user)],
            maxTokens: 2000,
            temperature: 0.4,
            spanName: "creative.full_bundle.claude_direct",
            feature: "creative_engine"
        )
        let parsed = try parseDirectClaudeReply(reply)
        let bundleId = bundleID(brand: brand)

        // POST grounding: brand copy must not assert a product fact off the catalog.
        let copyText = [parsed.copy?.headline, parsed.copy?.body, parsed.copy?.cta]
            .compactMap { $0 }.joined(separator: " ")
            + " " + parsed.adVariants.map { "\($0.hook) \($0.body) \($0.cta)" }.joined(separator: " ")
        let verdict = await MainActor.run { GroundingGate.vet(draft: copyText, brief: "\(brand.rawValue) \(utterance)") }
        if !verdict.surfaceable {
            WakeLog.shared.log("creative: blocked ungrounded fact in \(brand.rawValue) bundle. \(verdict.refusalLine)")
            // Fail safe: do not ship invented copy. Return a degraded bundle that names
            // the issue so the caller regenerates or a human fixes it; never surface the fact.
            return CreativeBundle(id: bundleId, createdAt: Date(), brand: brand, intent: .fullBundle, utterance: utterance, imageURL: nil, localImagePath: nil, copy: parsed.copy, imageBrief: parsed.imageBrief, adVariants: parsed.adVariants, script: parsed.script, providerPath: "claude-direct (degraded)", degraded: true, notes: verdict.refusalLine)
        }

        return CreativeBundle(
            id: bundleId,
            createdAt: Date(),
            brand: brand,
            intent: .fullBundle,
            utterance: utterance,
            imageURL: nil,
            localImagePath: nil,
            copy: parsed.copy,
            imageBrief: parsed.imageBrief,
            adVariants: parsed.adVariants,
            script: parsed.script,
            providerPath: "claude-direct (degraded)",
            degraded: true,
            notes: "Both render service ports unreachable. Copy-only output from Claude direct."
        )
    }

    // MARK: - HTTP helpers

    // THE FIRST ANSWERED OUTCOME WINS THE RIGHT TO SPEAK, which is
    // `PrivateServiceFetch.run`'s documented rule and this loop now holds it
    // too. One `lastErr` slot held both kinds, so a host that ANSWERED (a 500,
    // a body that would not parse) was overwritten by a later host that
    // simply refused the connection, and the caller reported "connection
    // refused" for a service that had just told it what was wrong. Paths are
    // in precedence order, so the highest-precedence host that actually
    // replied is the authoritative account; transport silence only speaks
    // when nothing replied at all.
    private func postFirstReachable(paths: [String], body: [String: Any], perRequestTimeoutSec: TimeInterval = 30) async throws -> ([String: Any], String) {
        var answered: Error?
        var transportErr: Error?
        for path in paths {
            guard let url = URL(string: path) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = perRequestTimeoutSec
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    if answered == nil {
                        answered = CreativeError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
                    }
                    continue
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return (json, path)
                }
                if answered == nil {
                    answered = CreativeError.decoding("non-JSON response from \(path)")
                }
            } catch {
                // FIRST, not last, matching the `answered` rule three lines
                // up: bases are in precedence order, so the highest-precedence
                // host's reason is the authoritative one. Overwriting meant
                // a first base refusing with a useful reason was reported as
                // the second base's timeout.
                if transportErr == nil { transportErr = error }
                continue
            }
        }
        throw answered ?? transportErr ?? CreativeError.allPathsFailed
    }

    private func downloadImageBytes(url: String, brand: CreativeBrand) async -> String? {
        guard let u = URL(string: url) else { return nil }
        let dir = self.creativeDir(brand: brand)
        var req = URLRequest(url: u)
        req.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let filename = "img-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).png"
            let dest = dir.appendingPathComponent(filename)
            try data.write(to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    // Best-effort spawn of the local :3850 wrapper. The Node script that
    // serves it belongs to the user, so its location is configuration rather
    // than a constant:
    //
    //   defaults write com.gruxai.grux grux.creative.wrapperScriptPath \
    //     "/path/to/creative-service.js"
    //
    // Empty means "no local wrapper", and the full-bundle path degrades to
    // image-only then to direct Claude exactly as it does when the service is
    // simply not running.
    private func spawnWrapperIfPossible() {
        let script = (UserDefaults.standard.string(forKey: "grux.creative.wrapperScriptPath") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            WakeLog.shared.log("creative: no wrapper script configured; skipping spawn")
            return
        }
        guard FileManager.default.fileExists(atPath: script) else {
            WakeLog.shared.log("creative: wrapper script not present at \(script); skipping spawn")
            return
        }
        let dir = (script as NSString).deletingLastPathComponent
        let file = (script as NSString).lastPathComponent
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-lc", "cd \"\(dir)\" && nohup node \"\(file)\" > /tmp/grux-creative-service.log 2>&1 &"]
        do {
            try task.run()
            WakeLog.shared.log("creative: spawned :3850 wrapper from \(script)")
        } catch {
            WakeLog.shared.log("creative: spawn failed, \(error.localizedDescription)")
        }
    }

    // MARK: - Companion scene/sku discovery

    // The companion service's /api/images/render endpoint validates scene as a discrete
    // label (e.g. "A", "B") from /api/images/scenes?brand=X, and sku as a
    // real product slug from /api/images/skus?brand=X. The wrapper at :3850
    // produces free-form scene prose; we ignore it for the API call and
    // instead pick scene "A" plus the first available sku per brand.
    // Cached in-process so we hit the discovery endpoints once per brand
    // per session.
    private var miniBrandCache: [String: (scenes: [String], skus: [String])] = [:]

    fileprivate func pickMiniSceneAndSku(for brand: CreativeBrand) async -> (scene: String, sku: String)? {
        let slug = brand.slug
        if let cached = miniBrandCache[slug],
           let firstScene = cached.scenes.first, let firstSku = cached.skus.first {
            return (firstScene, firstSku)
        }
        let scenes = await fetchMiniList(path: "/api/images/scenes?brand=\(slug)", key: "scenes") ?? []
        let skus = await fetchMiniList(path: "/api/images/skus?brand=\(slug)", key: "skus") ?? []
        guard !scenes.isEmpty, !skus.isEmpty else {
            // Don't cache empty results: a transient companion outage would
            // otherwise tombstone this brand for the whole session.
            return nil
        }
        miniBrandCache[slug] = (scenes, skus)
        return (scenes[0], skus[0])
    }

    private func fetchMiniList(path: String, key: String) async -> [String]? {
        for joined in Self.imageServiceURLs(path) {
            guard let url = URL(string: joined) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json[key] as? [String] {
                return list
            }
        }
        return nil
    }

    // Build a fetchable URL from the render response. The image service's HTTP
    // server doesn't expose the brand output dirs statically
    // (everything outside /api falls through to the SPA index.html), so a
    // plain GET of the constructed URL returns HTML. We still store the
    // synthesized URL on the bundle for display, but the actual bytes get
    // downloaded over Tailscale SSH (see fetchRenderedImage).
    fileprivate func renderResponseURL(_ rendered: [String: Any], baseUsed: String) -> String? {
        if let direct = (rendered["url"] as? String) ?? (rendered["image_url"] as? String), !direct.isEmpty {
            return direct
        }
        if let outputPath = rendered["outputPath"] as? String, !outputPath.isEmpty {
            if let u = URL(string: baseUsed),
               let scheme = u.scheme, let host = u.host {
                let portPart = (u.port.map { ":\($0)" }) ?? ""
                let base = "\(scheme)://\(host)\(portPart)"
                let path = outputPath.hasPrefix("/") ? outputPath : "/\(outputPath)"
                return base + path
            }
        }
        return nil
    }

    // Pull the rendered jpg off the image service host over SSH (scp). The
    // server returns a relative outputPath like
    // "brands/<slug>/output/sceneA.jpg"; the real file lives under the
    // configured scp root (see imageServiceScpRoot).
    // Stores the file under ~/.grux/creative/<brand>/img-<ts>.jpg and
    // returns the absolute local path on success.
    fileprivate func fetchRenderedImage(outputPath: String, brand: CreativeBrand) async -> String? {
        // UUID nonce so batch siblings pulled within the same wall-clock second
        // (and re-renders of the same sku/scene) get distinct local files
        // instead of silently overwriting one another.
        let filename = "img-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jpg"
        return await scpFromMini(outputPath: outputPath, filename: filename, brand: brand)
    }

    /// Pull any rendered file (still or .mp4 clip) off the image service host
    /// by its pipeline-relative path, preserving the extension.
    fileprivate func fetchRenderedFile(outputPath: String, brand: CreativeBrand, ext: String) async -> String? {
        let filename = "vid-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(ext)"
        return await scpFromMini(outputPath: outputPath, filename: filename, brand: brand)
    }

    private func scpFromMini(outputPath: String, filename: String, brand: CreativeBrand) async -> String? {
        let root = imageServiceScpRoot
        // Nothing configured means nothing to copy from. Callers already treat
        // nil as "no local bytes for this render".
        guard !root.isEmpty else { return nil }
        let dir = creativeDir(brand: brand)
        let dest = dir.appendingPathComponent(filename)
        let remote = root.hasSuffix("/") ? root + outputPath : root + "/" + outputPath
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let p = Process()
            let keyPath = NSHomeDirectory() + "/.ssh/id_ed25519"
            p.launchPath = "/usr/bin/scp"
            p.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new",
                // Force traditional SSH pubkey auth via the installed
                // ed25519 key. Without this, scp falls into Tailscale SSH's
                // periodic interactive re-auth dance and hangs indefinitely
                // inside @MainActor.
                "-o", "PreferredAuthentications=publickey",
                "-o", "IdentitiesOnly=yes",
                "-i", keyPath,
                remote, dest.path
            ]
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) {
                    continuation.resume(returning: dest.path)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            do { try p.run() } catch { continuation.resume(returning: nil) }
        }
    }

    // MARK: - Persistence

    private func bundleID(brand: CreativeBrand) -> String {
        // Append an 8-char UUID nonce so two voice triggers fired in the same
        // wall-clock second produce distinct IDs. Without this, ForEach in
        // CreativeStudioView (Identifiable on id) gets duplicate keys and the
        // on-disk persist call silently overwrites the older bundle.
        let ts = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(brand.rawValue)-\(ts)-\(nonce)"
    }

    private func creativeDir(brand: CreativeBrand) -> URL {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("creative", isDirectory: true)
            .appendingPathComponent(brand.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func persist(_ bundle: CreativeBundle) {
        let dir = creativeDir(brand: bundle.brand)
        let dest = dir.appendingPathComponent("\(bundle.id).json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(bundle) {
            try? data.write(to: dest)
        }
    }

    private func loadInboxFromDisk() {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("creative", isDirectory: true)
        guard let brandDirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        var all: [CreativeBundle] = []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for bd in brandDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: bd, includingPropertiesForKeys: nil) else { continue }
            // Only decode bundle files (<id>.json). Exclude compound-extension
            // sidecars like <image>.prov.json that now live in the same dir.
            for f in files where f.pathExtension == "json" && f.deletingPathExtension().pathExtension.isEmpty {
                if let data = try? Data(contentsOf: f),
                   let bundle = try? dec.decode(CreativeBundle.self, from: data) {
                    all.append(bundle)
                }
            }
        }
        self.inbox = all.sorted(by: { $0.createdAt > $1.createdAt })
    }

    // MARK: - Parsing

    private struct WrapperParse {
        let copy: CreativeCopy?
        let imageBrief: CreativeImageBrief?
        let adVariants: [CreativeAdVariant]
        let script: CreativeScript?
    }

    private func parseWrapperPayload(data: Data) throws -> WrapperParse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreativeError.decoding("wrapper returned non-JSON")
        }
        return WrapperParse(
            copy: Self.decodeCopy(obj["copy"]),
            imageBrief: decodeImageBrief(obj["image_brief"]),
            adVariants: decodeAdVariants(obj["ad_variants"]),
            script: decodeScript(obj["script"])
        )
    }

    private func parseDirectClaudeReply(_ reply: String) throws -> WrapperParse {
        // Strip ```json ... ``` (and bare ``` ... ```) fences first, then
        // attempt to parse progressively from each candidate `{` so a leading
        // prose sentence containing a stray `{` does not break extraction.
        // Falls through to a final "decoding failed" error only when every
        // candidate slice fails JSON parsing.
        let stripped = reply
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastClose = stripped.lastIndex(of: "}") else {
            throw CreativeError.decoding("direct Claude reply lacked a closing brace")
        }
        var cursor = stripped.startIndex
        while let openIdx = stripped[cursor...].firstIndex(of: "{") {
            let slice = String(stripped[openIdx...lastClose])
            if let data = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return WrapperParse(
                    copy: Self.decodeCopy(obj["copy"]),
                    imageBrief: decodeImageBrief(obj["image_brief"]),
                    adVariants: decodeAdVariants(obj["ad_variants"]),
                    script: decodeScript(obj["script"])
                )
            }
            cursor = stripped.index(after: openIdx)
            if cursor >= lastClose { break }
        }
        throw CreativeError.decoding("direct Claude reply JSON parse failed")
    }

    // The one place model JSON becomes CreativeCopy, so the one place to enforce
    // the house no-dash rule on it.
    //
    // The brief already tells the model "No em or en dashes" (see the VOICE
    // lines below), and that is instruction-only enforcement, which is exactly
    // what DashSanitizer exists because of: "the LLM drafters are also told to
    // avoid them in their system prompts, but models slip".
    //
    // Cleaned at CREATION rather than at a render boundary because this copy is
    // not merely displayed. Every bundle is persisted to
    // ~/.grux/creative/<brand>/<timestamp>.json, and a headline or CTA written
    // there is ad copy that can end up in front of customers. A dash that lands
    // in the file is already past us.
    //
    // stripDashesOnly rather than clean(): body can carry deliberate line breaks
    // and clean() collapses runs of whitespace.
    //
    // nonisolated static so the real decode path is testable without booting the
    // @MainActor engine.
    nonisolated static func decodeCopy(_ raw: Any?) -> CreativeCopy? {
        guard let d = raw as? [String: Any] else { return nil }
        func field(_ key: String) -> String {
            DashSanitizer.stripDashesOnly((d[key] as? String) ?? "")
        }
        return CreativeCopy(headline: field("headline"), body: field("body"), cta: field("cta"))
    }
    private func decodeImageBrief(_ raw: Any?) -> CreativeImageBrief? {
        guard let d = raw as? [String: Any] else { return nil }
        return CreativeImageBrief(
            scene: (d["scene"] as? String) ?? "",
            prompt: (d["prompt"] as? String) ?? ""
        )
    }
    private func decodeAdVariants(_ raw: Any?) -> [CreativeAdVariant] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            CreativeAdVariant(
                platform: (d["platform"] as? String) ?? "",
                hook: (d["hook"] as? String) ?? "",
                body: (d["body"] as? String) ?? "",
                cta: (d["cta"] as? String) ?? ""
            )
        }
    }
    private func decodeScript(_ raw: Any?) -> CreativeScript? {
        guard let d = raw as? [String: Any] else { return nil }
        return CreativeScript(
            hook: (d["hook"] as? String) ?? "",
            body: (d["body"] as? String) ?? "",
            payoff: (d["payoff"] as? String) ?? ""
        )
    }

    // MARK: - Direct-Claude brand prompt (mirrors :3850 wrapper)

    private func directClaudeBrandBlock(for brand: CreativeBrand) -> String {
        switch brand {
        case .untagged:
            return "VOICE: clean, direct, observational. No buzzwords. No em or en dashes. Stay specific to whatever the brief describes."
        case .registry(let slug):
            return "BRAND: \(brand.displayName) (slug: \(slug)). VOICE: clean, direct, brand-appropriate. No em or en dashes. No medical, manufacturing, or ownership claims. Stay specific."
        }
    }

    // MARK: - Inbox actions (UI surface)

    // Remove a bundle from memory + on-disk JSON + sibling image (if any).
    // Idempotent: re-deleting a missing bundle is a silent no-op.
    func delete(_ bundle: CreativeBundle) {
        self.inbox.removeAll { $0.id == bundle.id }
        let dir = creativeDir(brand: bundle.brand)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(bundle.id).json"))
        // Remove every batch sibling image plus its provenance sidecar, the
        // single localImagePath, and the clip, so nothing is orphaned on disk.
        var paths = Set(bundle.images)
        if let p = bundle.localImagePath { paths.insert(p) }
        for p in paths {
            try? FileManager.default.removeItem(atPath: p)
            try? FileManager.default.removeItem(atPath: (p as NSString).deletingPathExtension + ".prov.json")
        }
        if let v = bundle.videoPath {
            try? FileManager.default.removeItem(atPath: v)
        }
        WakeLog.shared.log("creative: deleted \(bundle.id)")
    }

    // Re-run the original brief, producing a fresh bundle (new ID, new
    // timestamp). The old bundle stays in the inbox so the user can compare
    // variations.
    func regenerate(_ bundle: CreativeBundle) {
        Task { await self.run(utterance: bundle.utterance, brand: bundle.brand, intent: bundle.intent) }
    }

    // Try to attach an image to a bundle that shipped without one (companion
    // service unreachable at first generation, etc.). Uses the existing image_brief
    // scene as the prompt. Updates the bundle in place + on disk on success.
    func renderImageNow(for bundle: CreativeBundle) async {
        // The fault channel is cleared on ENTRY here, matching
        // renderDynamic. engineStatus is the first reader this wave
        // gave a write-only channel, which turned "never cleared" from
        // invisible into an amber banner that outlived the failure it
        // described: a failed render followed by a successful one still
        // read "render service unreachable" until dismissed by hand.
        self.lastError = nil
        // WITH NO IMAGE SERVICE CONFIGURED, WHICH IS EVERY FRESH INSTALL, both
        // guards below fail and both used to report an internal component as
        // broken: "has no scenes or skus on the render service" and "render
        // service unreachable". Neither names a thing the reader has, and the
        // second reads as a fault when the honest answer is that this install
        // was never pointed at a service and almost nobody runs one. So absence
        // is answered with the notice, once, before either technical message can
        // fire, and the technical messages are kept for the case they were
        // written for: a service that IS configured and did not behave.
        if answeredWithMediaServiceAbsence() { return }
        guard let (scene, sku) = await pickMiniSceneAndSku(for: bundle.brand) else {
            self.lastError = "image render unavailable: brand \(bundle.brand.displayName) has no scenes or skus on the render service"
            return
        }
        guard let (rendered, baseUsed) = try? await postFirstReachable(
            paths: Self.imageServiceURLs("/api/images/render"),
            body: ["brand": bundle.brand.rawValue, "scene": scene, "sku": sku],
            perRequestTimeoutSec: 90
        ) else {
            self.lastError = "image render failed: \(bundle.brand.displayName) render service unreachable"
            return
        }
        let imageURL = renderResponseURL(rendered, baseUsed: baseUsed)
        var localImagePath: String? = nil
        if let outputPath = rendered["outputPath"] as? String, !outputPath.isEmpty {
            localImagePath = await fetchRenderedImage(outputPath: outputPath, brand: bundle.brand)
        } else if let url = imageURL {
            localImagePath = await downloadImageBytes(url: url, brand: bundle.brand)
        }
        let updated = CreativeBundle(
            id: bundle.id,
            createdAt: bundle.createdAt,
            brand: bundle.brand,
            intent: bundle.intent,
            utterance: bundle.utterance,
            imageURL: imageURL,
            localImagePath: localImagePath,
            copy: bundle.copy,
            imageBrief: bundle.imageBrief,
            adVariants: bundle.adVariants,
            script: bundle.script,
            providerPath: bundle.providerPath + " + img-retry",
            degraded: bundle.degraded,
            notes: bundle.notes
        )
        if let idx = self.inbox.firstIndex(where: { $0.id == bundle.id }) {
            self.inbox[idx] = updated
        }
        persist(updated)
    }

    // Fire a quick-prompt from the empty state. Just delegates to run().
    func runQuickPrompt(_ qp: CreativeQuickPrompt) {
        Task { await self.run(utterance: qp.utterance, brand: qp.brand, intent: qp.intent) }
    }

    // MARK: - Studio entry point (typed composer)

    // The Studio composer calls this directly. Caller passes an explicit
    // brief + brand + workflow (no parsing, no inference). Each workflow
    // routes to a distinct pipeline; the resulting bundle is stamped with
    // its workflow so the gallery can group / filter / re-run cleanly.
    //
    // Workflows map to the underlying engine like so:
    //   .image         → fetchFromWrapper (which embeds an :3847 image render)
    //                    or :3847-only when wrapper down; degrades to claude
    //                    direct on full outage. Same path as voice .fullBundle.
    //   .platformPack  → fires .image, then issues a second :3847 render with
    //                    a "9:16 vertical" prompt hint and appends the
    //                    second URL into the bundle's notes for v1.
    //                    (TODO: multi-image support on CreativeBundle for v2.)
    //   .videoDraft    → fires .image; uses the wrapper's script field as the
    //                    primary surface. Image becomes the storyboard frame.
    func generate(brief: String, brand: CreativeBrand, workflow: CreativeWorkflow) {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await self.runStudioGenerate(brief: trimmed, brand: brand, workflow: workflow) }
    }

    private func runStudioGenerate(brief: String, brand: CreativeBrand, workflow: CreativeWorkflow) async {
        // The fault channel is cleared on ENTRY here, matching
        // renderDynamic. engineStatus is the first reader this wave
        // gave a write-only channel, which turned "never cleared" from
        // invisible into an amber banner that outlived the failure it
        // described: a failed render followed by a successful one still
        // read "render service unreachable" until dismissed by hand.
        self.lastError = nil
        if answeredWithMediaServiceAbsence() { return }
        beginWork()
        defer { endWork() }

        // All three workflows share the .fullBundle base path (image + brief +
        // ad variants + script). We then post-process to fit the workflow.
        do {
            var bundle = try await runFullBundle(utterance: brief, brand: brand)

            // Stamp the workflow onto the bundle (immutable replace).
            bundle = CreativeBundle(
                id: bundle.id,
                createdAt: bundle.createdAt,
                brand: bundle.brand,
                intent: bundle.intent,
                utterance: bundle.utterance,
                imageURL: bundle.imageURL,
                localImagePath: bundle.localImagePath,
                copy: bundle.copy,
                imageBrief: bundle.imageBrief,
                adVariants: bundle.adVariants,
                script: bundle.script,
                providerPath: bundle.providerPath + " (\(workflow.rawValue))",
                degraded: bundle.degraded,
                notes: bundle.notes,
                workflow: workflow
            )

            // Platform pack: kick off a second render with a different scene
            // label (B vs the default A) so the TikTok variant differs from
            // the Meta hero. v1 limitation: bundle model is single-image;
            // the second URL gets stashed in notes for the detail sheet.
            if workflow == .platformPack, let (_, sku) = await pickMiniSceneAndSku(for: brand) {
                if let (rendered, baseUsed) = try? await postFirstReachable(
                    paths: Self.imageServiceURLs("/api/images/render"),
                    body: ["brand": brand.rawValue, "scene": "B", "sku": sku],
                    perRequestTimeoutSec: 90
                ), let url = renderResponseURL(rendered, baseUsed: baseUsed) {
                    let extraNote = "Platform pack: tiktok variant at \(url)"
                    bundle = CreativeBundle(
                        id: bundle.id, createdAt: bundle.createdAt, brand: bundle.brand, intent: bundle.intent,
                        utterance: bundle.utterance, imageURL: bundle.imageURL, localImagePath: bundle.localImagePath,
                        copy: bundle.copy, imageBrief: bundle.imageBrief, adVariants: bundle.adVariants,
                        script: bundle.script, providerPath: bundle.providerPath, degraded: bundle.degraded,
                        notes: [bundle.notes, extraNote].compactMap { $0 }.joined(separator: " | "),
                        workflow: workflow
                    )
                }
            }

            persist(bundle)
            self.inbox.insert(bundle, at: 0)
            WakeLog.shared.log("creative: studio bundle id=\(bundle.id.prefix(24)) brand=\(brand.slug) workflow=\(workflow.rawValue) path=\(bundle.providerPath)")
        } catch {
            self.lastError = "studio generate: \(error.localizedDescription)"
            WakeLog.shared.log("creative: studio generate failed, \(error.localizedDescription)")
        }
    }

    // MARK: - Dynamic Studio

    /// Render from a compiled freeform directive via POST /api/images/render-dynamic.
    /// Produces ONE bundle that holds every batch sibling (images), with the
    /// first as localImagePath. Drives both the Studio composer and the
    /// ~/.grux/fire-image CLI trigger, so there is one code path with two front
    /// doors. Manages isWorking + inbox the same way runStudioGenerate does.
    func renderDynamic(
        brand: CreativeBrand,
        directive: String,
        sku: String?,
        aspect: AspectPreset,
        count: Int,
        recipeId: String? = nil,
        reference: String? = nil,
        resultPath: String? = nil
    ) async {
        beginWork()
        defer { endWork() }
        self.lastError = nil
        // The same absence gate renderImageNow holds, on the path Media
        // Studio's GENERATE button and the ~/.grux/fire-image trigger both
        // take. Without it an unconfigured install got
        // "dynamic render: all upstream paths failed" in amber, an opaque
        // fault where the sibling path names the notice: the same wrong-cause
        // defect, one entry point over.
        if answeredWithMediaServiceAbsence(resultPath: resultPath) { return }
        do {
            let bundle = try await runDynamic(
                brand: brand, directive: directive, sku: sku,
                aspect: aspect, count: count, recipeId: recipeId, reference: reference
            )
            persist(bundle)
            self.inbox.insert(bundle, at: 0)
            WakeLog.shared.log("creative: dynamic bundle id=\(bundle.id.prefix(24)) brand=\(brand.slug) aspect=\(aspect.rawValue) imgs=\(bundle.images.count)")
            if let resultPath { writeDynamicResult(bundle, to: resultPath) }
        } catch {
            self.lastError = "dynamic render: \(error.localizedDescription)"
            WakeLog.shared.log("creative: dynamic render failed, \(error.localizedDescription)")
            if let resultPath {
                let line = "fire-image @ \(ISO8601DateFormatter().string(from: Date()))\nVERDICT: FAIL\nerror: \(error.localizedDescription)\n"
                try? line.write(toFile: resultPath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// String-typed convenience for the fire-image file-watcher trigger, which
    /// reads a JSON payload of plain strings.
    func renderDynamic(
        brand: String,
        directive: String,
        sku: String?,
        aspect: String?,
        count: Int,
        resultPath: String?
    ) async {
        let resolvedBrand = CreativeBrand(slug: brand)
        let resolvedAspect = AspectPreset(rawValue: aspect ?? "4:5") ?? .portrait45
        await renderDynamic(
            brand: resolvedBrand, directive: directive, sku: sku,
            aspect: resolvedAspect, count: count, recipeId: nil, resultPath: resultPath
        )
    }

    private func runDynamic(
        brand: CreativeBrand, directive: String, sku: String?,
        aspect: AspectPreset, count: Int, recipeId: String?, reference: String? = nil,
        parentAssetId: String? = nil
    ) async throws -> CreativeBundle {
        let clampedCount = max(1, min(count, 8))

        // Replicate is the provider for pure-generation directives. Product-in-scene renders
        // (anything carrying a sku or a reference image) stay on the image service :3847,
        // which owns the brand reference images and the byte-exact composite-then-edit
        // pipeline: those are two different jobs, and only one of them is generation.
        //
        // The fallback ordering matters more than it used to. The image service runs on the
        // owner's own network, so for a stranger it is not a fallback at all, and Replicate
        // is the only path that exists. That is why the vendor swap was worth doing rather
        // than just deleting the feature.
        let isProductInScene = (sku?.isEmpty == false) || (reference?.isEmpty == false)
        if !isProductInScene {
            do {
                return try await runDynamicViaReplicate(
                    brand: brand, directive: directive, aspect: aspect,
                    count: clampedCount, recipeId: recipeId, parentAssetId: parentAssetId
                )
            } catch {
                // Replicate unavailable: degrade to the companion service path. Record why so
                // the fallback rate is observable.
                WakeLog.shared.log("creative: Replicate render failed (\(error.localizedDescription)); falling back to the image service :3847")
            }
        }

        // Adaptive: use the brand's learned preferred model (escalates up the
        // ladder as the feedback loop sees repeated negatives for that brand).
        // The bandit now spans providers, so clamp to a companion-compatible model:
        // the :3847 pipeline only speaks the qwen ladder.
        let preferredModel = FeedbackStore.shared.preferredImageModel(forBrand: brand.rawValue)
        let chosenModel = ModelLadder.miniImage.contains(preferredModel)
            ? preferredModel
            : (ModelLadder.miniImage.first ?? "qwen-image-edit-plus")
        var payload: [String: Any] = [
            "brand": brand.rawValue,
            "directive": directive,
            "aspect": aspect.rawValue,
            "count": clampedCount,
            "model": chosenModel
        ]
        if let sku, !sku.isEmpty { payload["sku"] = sku }
        if let reference, !reference.isEmpty { payload["reference"] = reference }

        let (rendered, _) = try await postFirstReachable(
            paths: Self.imageServiceURLs("/api/images/render-dynamic"),
            body: payload,
            perRequestTimeoutSec: TimeInterval(90 + clampedCount * 60)
        )

        guard (rendered["ok"] as? Bool) == true,
              let relPaths = rendered["images"] as? [String], !relPaths.isEmpty else {
            let err = (rendered["error"] as? String) ?? "render-dynamic returned no images"
            throw CreativeError.http(502, err)
        }

        // Pull every sibling down via the same Tailscale scp path as single
        // renders, but concurrently: each scp runs in its own subprocess, so a
        // task group keeps the main actor responsive instead of serially
        // blocking it for ~13-25s per image. Results are reordered to match
        // relPaths so sibling order is stable.
        var localByIndex: [Int: String] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            for (idx, rel) in relPaths.enumerated() {
                group.addTask { (idx, await self.fetchRenderedImage(outputPath: rel, brand: brand)) }
            }
            for await (idx, path) in group {
                if let path { localByIndex[idx] = path }
            }
        }
        // Keep local and remote paths index-aligned across only the siblings
        // whose scp succeeded, so images[k] always corresponds to remoteImages[k].
        let successfulIdx = relPaths.indices.filter { localByIndex[$0] != nil }
        let localPaths: [String] = successfulIdx.map { localByIndex[$0]! }
        let remotePaths: [String] = successfulIdx.map { relPaths[$0] }
        guard !localPaths.isEmpty else { throw CreativeError.allPathsFailed }

        let bundleId = bundleID(brand: brand)
        let bundle = CreativeBundle(
            id: bundleId,
            createdAt: Date(),
            brand: brand,
            intent: .imageOnly,
            utterance: directive,
            imageURL: nil,
            localImagePath: localPaths.first,
            copy: nil,
            imageBrief: CreativeImageBrief(scene: aspect.rawValue, prompt: directive),
            adVariants: [],
            script: nil,
            providerPath: "3847-dynamic",
            degraded: false,
            notes: nil,
            workflow: .image,
            images: localPaths,
            remoteImages: remotePaths,
            directive: directive,
            aspect: aspect.rawValue,
            recipeId: recipeId,
            batchID: bundleId,
            approval: .draft,
            tags: [],
            videoPath: nil,
            imageModel: (rendered["model"] as? String) ?? chosenModel,
            videoModel: nil,
            rating: .none,
            feedbackNote: nil,
            parentAssetId: parentAssetId
        )
        // Internal provenance sidecar so each asset carries its own recipe
        // (ComfyUI pattern). Never includes anything beyond what the bundle has;
        // stays under ~/.grux, never exported.
        writeProvenanceSidecar(for: bundle)
        return bundle
    }

    /// Pure-generation render via Replicate. No sku, no reference image:
    /// Replicate serves the bytes over HTTPS, so unlike the companion service
    /// path there is no scp hop. Bytes land directly in the
    /// brand's creative dir as img-<ts>-<nonce> siblings and are wrapped in the
    /// same CreativeBundle shape, so filing / approval / feedback all come free.
    /// Throws on any failure so runDynamic can degrade to the companion service path.
    private func runDynamicViaReplicate(
        brand: CreativeBrand, directive: String, aspect: AspectPreset,
        count: Int, recipeId: String?, parentAssetId: String?
    ) async throws -> CreativeBundle {
        // FOUR, not eight. Replicate image models cap num_outputs at 4 where fal allowed 8,
        // and the client clamps too; clamping in both places is deliberate so a caller
        // reading this line is not told a number the vendor will silently reduce.
        let clampedCount = max(1, min(count, 4))
        let modelId = ReplicateModels.imageModel()
        let images = try await ReplicateClient.shared.generateImages(
            prompt: directive, aspect: aspect, count: clampedCount, model: modelId
        )
        guard !images.isEmpty else { throw CreativeError.allPathsFailed }

        let dir = creativeDir(brand: brand)
        var localPaths: [String] = []
        for img in images {
            let filename = "img-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(img.fileExtension)"
            let dest = dir.appendingPathComponent(filename)
            do {
                try img.data.write(to: dest, options: .atomic)
                localPaths.append(dest.path)
            } catch {
                WakeLog.shared.log("creative: generated image write failed, \(error.localizedDescription)")
            }
        }
        guard !localPaths.isEmpty else { throw CreativeError.allPathsFailed }

        let bundleId = bundleID(brand: brand)
        let bundle = CreativeBundle(
            id: bundleId,
            createdAt: Date(),
            brand: brand,
            intent: .imageOnly,
            utterance: directive,
            imageURL: nil,
            localImagePath: localPaths.first,
            copy: nil,
            imageBrief: CreativeImageBrief(scene: aspect.rawValue, prompt: directive),
            adVariants: [],
            script: nil,
            providerPath: "fal-queue",
            degraded: false,
            notes: nil,
            workflow: .image,
            images: localPaths,
            remoteImages: [],
            directive: directive,
            aspect: aspect.rawValue,
            recipeId: recipeId,
            batchID: bundleId,
            approval: .draft,
            tags: [],
            videoPath: nil,
            imageModel: modelId,
            videoModel: nil,
            rating: .none,
            feedbackNote: nil,
            parentAssetId: parentAssetId
        )
        writeProvenanceSidecar(for: bundle)
        WakeLog.shared.log("creative: fal bundle id=\(bundle.id.prefix(24)) brand=\(brand.slug) model=\(modelId) imgs=\(localPaths.count)")
        return bundle
    }

    /// Write a JSON provenance sidecar next to each local image of a bundle, so
    /// the asset is self-describing if it gets routed. Internal only.
    private func writeProvenanceSidecar(for bundle: CreativeBundle) {
        let prov: [String: Any] = [
            "id": bundle.id,
            "brand": bundle.brand.rawValue,
            "imageModel": bundle.imageModel ?? "",
            "videoModel": bundle.videoModel ?? "",
            "aspect": bundle.aspect ?? "",
            "recipeId": bundle.recipeId ?? "",
            "parentAssetId": bundle.parentAssetId ?? "",
            "directive": bundle.directive ?? bundle.utterance,
            "createdAt": ISO8601DateFormatter().string(from: bundle.createdAt),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: prov, options: [.prettyPrinted, .sortedKeys]) else { return }
        for path in bundle.images {
            let sidecar = (path as NSString).deletingPathExtension + ".prov.json"
            try? data.write(to: URL(fileURLWithPath: sidecar), options: .atomic)
        }
    }

    private func writeDynamicResult(_ b: CreativeBundle, to path: String) {
        let summary = """
        fire-image @ \(ISO8601DateFormatter().string(from: Date()))
        VERDICT: PASS
        brand: \(b.brand.rawValue)
        aspect: \(b.aspect ?? "?")
        images: \(b.images.count)
        first: \(b.localImagePath ?? "(none)")
        directive: \(b.directive ?? "")
        """
        try? summary.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Library + output actions

    /// Set approval state on a bundle (library workflow). On approve, also pings
    /// the companion service's approval log (best effort) so downstream tools can pick it up.
    func setApproval(_ bundle: CreativeBundle, to state: ApprovalState, siblingIndex: Int = 0) {
        guard let idx = inbox.firstIndex(where: { $0.id == bundle.id }) else { return }
        var updated = inbox[idx]
        updated.approval = state
        inbox[idx] = updated
        persist(updated)
        if state == .approved, !bundle.remoteImages.isEmpty {
            let i = min(max(siblingIndex, 0), bundle.remoteImages.count - 1)
            let filename = (bundle.remoteImages[i] as NSString).lastPathComponent
            let brandSlug = bundle.brand.rawValue
            Task {
                _ = try? await self.postFirstReachable(
                    paths: Self.imageServiceURLs("/api/images/approve"),
                    body: ["brand": brandSlug, "filename": filename],
                    perRequestTimeoutSec: 10
                )
            }
        }
    }

    /// Record a thumbs up/down (and optional note) on a bundle. Updates the
    /// asset and feeds the adaptive per-brand model policy (self-learning loop).
    func setRating(_ bundle: CreativeBundle, to rating: AssetRating, note: String? = nil) {
        guard let idx = inbox.firstIndex(where: { $0.id == bundle.id }) else { return }
        var updated = inbox[idx]
        updated.rating = rating
        if let note, !note.isEmpty { updated.feedbackNote = note }
        inbox[idx] = updated
        persist(updated)
        let model = updated.imageModel ?? "qwen-image-edit-plus"
        let newPref = FeedbackStore.shared.record(
            bundleId: updated.id, brand: updated.brand.rawValue,
            model: model, rating: rating, note: note
        )
        if newPref != model {
            self.lastError = nil
            WakeLog.shared.log("creative: feedback escalated \(updated.brand.slug) image model to \(newPref)")
        }
    }

    /// Set/replace the tags on a bundle (library search).
    func setTags(_ bundle: CreativeBundle, tags: [String]) {
        guard let idx = inbox.firstIndex(where: { $0.id == bundle.id }) else { return }
        var updated = inbox[idx]
        updated.tags = tags
        inbox[idx] = updated
        persist(updated)
    }

    /// Animate one sibling of a bundle into a short clip via the companion service's i2v route,
    /// then attach the downloaded mp4 to the bundle (bundle.videoPath).
    func animate(_ bundle: CreativeBundle, siblingIndex: Int = 0) {
        guard !bundle.remoteImages.isEmpty else {
            lastError = "no server-side still to animate (re-render to enable video)"
            return
        }
        let i = min(max(siblingIndex, 0), bundle.remoteImages.count - 1)
        let rel = bundle.remoteImages[i]
        Task { await self.runAnimate(bundleId: bundle.id, brand: bundle.brand, rel: rel) }
    }

    private func runAnimate(bundleId: String, brand: CreativeBrand, rel: String) async {
        beginWork()
        defer { endWork() }
        do {
            let prompt = "Gentle slow push-in on the product, the light shifts softly, every detail and any lettering stays crisp and legible, calm and warm, no camera shake"
            let (resp, _) = try await postFirstReachable(
                paths: Self.imageServiceURLs("/api/images/render-video"),
                body: ["brand": brand.rawValue, "imagePath": rel, "prompt": prompt, "resolution": "720P", "duration": 5],
                perRequestTimeoutSec: 600
            )
            guard (resp["ok"] as? Bool) == true, let videoRel = resp["video"] as? String else {
                throw CreativeError.http(502, (resp["error"] as? String) ?? "video render failed")
            }
            guard let localVideo = await fetchRenderedFile(outputPath: videoRel, brand: brand, ext: "mp4") else {
                throw CreativeError.allPathsFailed
            }
            guard let idx = inbox.firstIndex(where: { $0.id == bundleId }) else {
                // Bundle was deleted while the clip rendered; don't leave the
                // downloaded mp4 orphaned on disk.
                try? FileManager.default.removeItem(atPath: localVideo)
                return
            }
            var updated = inbox[idx]
            updated.videoPath = localVideo
            updated.videoModel = (resp["model"] as? String) ?? "wan2.6-i2v"
            inbox[idx] = updated
            persist(updated)
            WakeLog.shared.log("creative: animated bundle \(bundleId.prefix(20)) -> \(videoRel)")
        } catch {
            self.lastError = "animate: \(error.localizedDescription)"
            WakeLog.shared.log("creative: animate failed, \(error.localizedDescription)")
        }
    }

    /// Re-render the bundle's directive at every other platform aspect, landing
    /// each as its own bundle in the gallery. Needs a stored directive.
    func exportAspects(_ bundle: CreativeBundle) {
        guard let directive = bundle.directive, !directive.isEmpty else {
            lastError = "this bundle has no saved directive to re-render"
            return
        }
        let brand = bundle.brand
        let recipeId = bundle.recipeId
        let parentId = bundle.id
        let targets = AspectPreset.allCases.filter { $0.rawValue != bundle.aspect }
        Task {
            // Manage isWorking once for the whole export, and render the aspects
            // concurrently (their network + scp waits overlap) instead of
            // serially, so a 3-aspect export finishes in roughly one render's time.
            beginWork()
            defer { endWork() }
            await withTaskGroup(of: CreativeBundle?.self) { group in
                for aspect in targets {
                    group.addTask {
                        do {
                            return try await self.runDynamic(brand: brand, directive: directive, sku: nil, aspect: aspect, count: 1, recipeId: recipeId, parentAssetId: parentId)
                        } catch {
                            await MainActor.run { self.lastError = "export \(aspect.rawValue): \(error.localizedDescription)" }
                            return nil
                        }
                    }
                }
                for await result in group {
                    if let b = result {
                        self.persist(b)
                        self.inbox.insert(b, at: 0)
                    }
                }
            }
        }
    }

    /// Push a keeper into a DRAFT social post on the render service (never auto-publishes).
    func draftToSocial(_ bundle: CreativeBundle, siblingIndex: Int = 0, caption: String? = nil, platform: String = "instagram") {
        guard !bundle.remoteImages.isEmpty else {
            lastError = "no server-side still to draft (re-render to enable)"
            return
        }
        let i = min(max(siblingIndex, 0), bundle.remoteImages.count - 1)
        let rel = bundle.remoteImages[i]
        let text = caption?.isEmpty == false ? caption! : "New from \(bundle.brand.displayName)."
        let brandSlug = bundle.brand.rawValue
        Task {
            do {
                let (resp, _) = try await postFirstReachable(
                    paths: Self.imageServiceURLs("/api/posts/draft-from-image"),
                    body: ["brand": brandSlug, "imagePath": rel, "text": text, "platform": platform],
                    perRequestTimeoutSec: 15
                )
                if (resp["ok"] as? Bool) == true {
                    self.lastError = nil
                    WakeLog.shared.log("creative: social draft created for \(brandSlug)")
                } else {
                    self.lastError = "draft: \((resp["error"] as? String) ?? "failed (brand may not be in brands.yml)")"
                }
            } catch {
                self.lastError = "draft: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Smoke test

    func runSmokeTest() async {
        WakeLog.shared.log("creative: fire-voice-image-test triggered")
        // Runs untagged so the smoke test needs no brand to be configured.
        // Full path: :3850 wrapper -> :3847 image render -> scp download.
        let countBefore = self.inbox.count
        self.lastError = nil
        await run(
            utterance: "Render a hero shot of a ceramic mug on a warm marble counter beside a citrus slice.",
            brand: .untagged,
            intent: .fullBundle
        )
        let outPath = NSHomeDirectory() + "/.grux/voice-image-test-result.txt"
        // Only treat inbox[0] as ours when run actually grew the inbox and
        // did not record an error. Otherwise a failed run would silently
        // report the previous bundle as PASS.
        let runGrewInbox = self.inbox.count > countBefore
        let latest = (runGrewInbox && self.lastError == nil) ? self.inbox.first : nil
        let summary: String
        if let b = latest {
            summary = """
            voice-image-test @ \(ISO8601DateFormatter().string(from: Date()))
            VERDICT: \(b.degraded ? "DEGRADED" : "PASS")
            brand: \(b.brand.rawValue)
            intent: \(b.intent.rawValue)
            path: \(b.providerPath)
            image_url: \(b.imageURL ?? "(none)")
            local_image: \(b.localImagePath ?? "(none)")
            copy.headline: \(b.copy?.headline ?? "(none)")
            ad_variants: \(b.adVariants.count)
            saved_bundle: ~/.grux/creative/\(b.brand.rawValue)/\(b.id).json
            """
        } else {
            summary = "voice-image-test @ \(ISO8601DateFormatter().string(from: Date()))\nVERDICT: FAIL\nlast_error: \(self.lastError ?? "(none)")"
        }
        try? summary.write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Errors

enum CreativeError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case allPathsFailed
    case missingClaudeKey
    var errorDescription: String? {
        switch self {
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(180))"
        case .decoding(let m): return "decode: \(m)"
        case .allPathsFailed: return "all upstream paths failed"
        case .missingClaudeKey: return "Anthropic key missing, set in Settings"
        }
    }
}

// MARK: - Claude tool surface

// Voice triggers route through Claude's tool-use. When the user says
// "Grux, render a hero shot of X" or "draft a creative brief for Y",
// the model picks one of these tools, fills in the args, and we hand the
// utterance to CreativeEngine. The tool returns a one-line confirmation
// the assistant speaks back. Side effect: bundle lands in the Inbox.
enum CreativeTool {
    static let toolNames: Set<String> = [
        "creative_render_image",
        "creative_full_bundle"
    ]

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "creative_render_image",
                description: """
                Render a brand-aware hero shot via the configured image-gen \
                service (:3847, qwen-image-edit-plus). Use when they say \
                'render a hero shot', 'render an image of', 'make a \
                picture of', 'photo of', followed by a scene description, \
                optionally with a brand cue ('for <brand>'). Result appears \
                in the Media Studio.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "utterance": [
                            "type": "string",
                            "description": "Full natural-language brief, verbatim from the user. Include the scene description and any brand cue."
                        ],
                        "brand": [
                            "type": "string",
                            "description": "Optional brand slug override. If omitted, the brand is read from the utterance ('for <brand>') and left untagged when nothing matches."
                        ]
                    ],
                    "required": ["utterance"]
                ]
            ),
            ClaudeTool(
                name: "creative_full_bundle",
                description: """
                Generate a full creative bundle (copy, image brief, ad \
                variants, script) via the Mac-local Node content-studio \
                wrapper on :3850, composed with claude-sonnet-4-6. Use when \
                they say 'draft a creative brief', 'write an ad for', \
                'campaign for', 'post for', 'copy for', or otherwise ask \
                for written marketing assets tied to a brand. Falls back to \
                image-only then direct Claude if the wrapper is unreachable.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "utterance": [
                            "type": "string",
                            "description": "Full natural-language brief, verbatim from the user. Include the intent and any brand or product cue."
                        ],
                        "brand": [
                            "type": "string",
                            "description": "Optional brand slug override. If omitted, the brand is read from the utterance and left untagged when nothing matches."
                        ]
                    ],
                    "required": ["utterance"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        let utterance = ((input["utterance"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return "error: utterance required" }
        let brand: CreativeBrand
        if let raw = input["brand"] as? String {
            brand = CreativeBrand(slug: raw)
        } else {
            brand = CreativeBrand.parse(from: utterance,
                                        known: await CreativeBrandRegistry.shared.registrySlugs)
        }
        let intent: CreativeIntent = (name == "creative_render_image") ? .imageOnly : .fullBundle
        // Fire and forget. Bundle generation takes 5 to 45 s; the assistant
        // should not block speech on it. The Inbox + orb hint carry the
        // user-facing feedback. The string returned here is what the model
        // sees as the tool result.
        Task { await CreativeEngine.shared.run(utterance: utterance, brand: brand, intent: intent) }
        return "ok: \(intent.rawValue) for \(brand.displayName) queued. Check Media Studio."
    }
}

// MARK: - SwiftUI Studio view
//
// Image + video generation homebase. Text-side outputs (copy, ad copy as
// prose, threads posts, emails) live in Chat. The Studio surfaces only the
// visual side of a bundle: the hero image (or placeholder), the brief, and
// the workflow that produced it.
//
// Layout: composer up top (brief textarea + brand chip strip + workflow
// chip strip + Generate). Gallery below as a generous 2-column grid of
// image cards. Tap a card → SwiftUI sheet with the full image + brief and
// an optional "show full bundle" toggle that reveals the underlying copy
// / ad variants / script text for callers who do want it.

struct CreativeStudioView: View {
    @ObservedObject private var engine = CreativeEngine.shared
    @ObservedObject private var registry = CreativeBrandRegistry.shared

    @State private var brief: String = ""
    @State private var pickedBrand: CreativeBrand? = nil
    @State private var sheetBundleID: String? = nil
    @FocusState private var briefFocused: Bool

    // Dynamic Studio structured controls (Phase 3). The brief box is the
    // freeform "and also..." direction; these refine it. The compiler folds
    // them into one qwen-style directive sent to /api/images/render-dynamic.
    @State private var cSetting: String = ""
    @State private var cSurface: String = ""
    @State private var cLighting: String = ""
    @State private var cTimeOfDay: String = ""
    @State private var cMood: String = ""
    @State private var cLens: String = ""
    @State private var cProps: String = ""
    @State private var aspectPreset: AspectPreset = .portrait45
    @State private var genCount: Int = 1
    @State private var strictBrand: Bool = true

    @StateObject private var recipeStore = RecipeStore.shared
    @State private var librarySearch: String = ""
    @State private var galleryFilter: GalleryFilter = .all
    // Optional uploaded product reference (for brands with no companion config, or to
    // override the default SKU reference). Sent as base64 to /render-dynamic.
    @State private var uploadedReferencePath: String? = nil

    private var hasDirection: Bool {
        ![brief, cSetting, cSurface, cLighting, cTimeOfDay, cMood, cLens, cProps]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var canGenerate: Bool {
        pickedBrand != nil && hasDirection && !engine.isWorking
    }

    private var galleryBundles: [CreativeBundle] {
        let base = engine.inbox.filter { galleryFilter.matches($0) }
        let q = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { b in
            let hay = [
                b.utterance, b.directive ?? "", b.brand.slug, b.brand.displayName,
                b.aspect ?? "", b.approval.rawValue, b.tags.joined(separator: " "),
                b.videoPath != nil ? "video clip" : ""
            ].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                composer
                    .padding(.horizontal, 48)
                    .padding(.top, 48)

                gallery
                    .padding(.horizontal, 48)
                    .padding(.bottom, 80)
            }
        }
        .background(GruxTheme.base)
        .foregroundStyle(GruxTheme.textPrimary)
        .sheet(item: Binding<CreativeBundle?>(
            get: { sheetBundleID.flatMap { id in engine.inbox.first(where: { $0.id == id }) } },
            set: { newValue in sheetBundleID = newValue?.id }
        )) { bundle in
            CreativeStudioDetailSheet(
                engine: engine,
                bundleID: bundle.id,
                onDismiss: { sheetBundleID = nil }
            )
        }
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MEDIA STUDIO")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .kerning(2.6)
                    .foregroundStyle(GruxTheme.textTertiary)
                Text("What do you want to make?")
                    .font(.system(size: 36, weight: .heavy, design: .default).width(.condensed))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineSpacing(2)
            }

            briefField

            brandStrip
                .frame(maxWidth: .infinity, alignment: .leading)

            controlPanel

            recipeRow

            generateRow

            engineStatus
        }
    }

    // MARK: engine status

    /// The engine's one error channel, finally rendered. `lastError` was
    /// written at a dozen engine sites and read by nothing: DesignStudioView's
    /// banner observes DesignStudioEngine, a different class, so this channel
    /// was write-only and the fresh-install image path went silent. Absence
    /// gets the same notice card every private-service surface uses, MOUNTED
    /// rather than quoted, so it keeps probing and stands down by itself the
    /// moment a service answers or the user configures one. Anything else is
    /// one compact line with a dismiss, sitting under the button that caused
    /// it: a render that went wrong is a fact to acknowledge in place, not a
    /// redesign.
    @ViewBuilder
    private var engineStatus: some View {
        if engine.lastErrorIsAbsence {
            // The card's probe loop fires the closure when the service comes
            // up OR when the user configures one. Clearing the error channel
            // returns the studio to idle so the next Generate runs against
            // the live service (the nil write drops the absence flag via
            // lastError's didSet). Nothing auto-renders: a render spends,
            // and the user asks for it.
            PrivateServiceNoticeView(service: .mediaService) { @MainActor in
                engine.lastError = nil
            }
        } else if let message = engine.lastError {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(GruxTheme.warnAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button { engine.lastError = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(GruxTheme.warnAmber.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GruxTheme.warnAmber.opacity(0.25), lineWidth: 0.7))
        }
    }

    // MARK: recipes (saved looks)

    private var brandRecipes: [CreativeRecipe] {
        recipeStore.recipes(forBrand: pickedBrand?.slug ?? "untagged")
    }

    private var recipeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stripLabel("RECIPES", optional: true)
                Spacer()
                Button { saveCurrentAsRecipe() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text("SAVE LOOK").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.8)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(hasDirection ? GruxTheme.accentPrimaryLight : GruxTheme.textTertiary)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .disabled(!hasDirection)
                .help("Save the current direction as a reusable recipe")
            }
            if brandRecipes.isEmpty {
                Text("No saved looks yet. Dial in a direction and tap Save look.")
                    .font(.system(size: 12)).foregroundStyle(GruxTheme.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(brandRecipes) { recipe in
                            recipeChip(recipe)
                        }
                    }
                }
            }
        }
    }

    private func recipeChip(_ recipe: CreativeRecipe) -> some View {
        Button { apply(recipe) } label: {
            HStack(spacing: 5) {
                Image(systemName: recipe.favorite ? "star.fill" : "wand.and.stars")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(recipe.favorite ? GruxTheme.warnAmber : GruxTheme.textSecondary)
                Text(recipe.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(recipe.aspect.rawValue)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(GruxTheme.textPrimary)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(recipe.favorite ? "Unfavorite" : "Favorite") { recipeStore.toggleFavorite(recipe.id) }
            Button("Duplicate") { _ = recipeStore.fork(recipe.id, newName: recipe.name + " copy") }
            Divider()
            DestructiveMenuButton("Delete",
                                  question: "Delete this recipe?",
                                  detail: "The saved settings for this recipe are removed. Images "
                                      + "you already generated are not touched.",
                                  confirmLabel: "Delete recipe") { recipeStore.delete(recipe.id) }
        }
        .help("Tap to load this look. Right click for favorite, duplicate, delete.")
    }

    private func currentControls() -> SceneControls {
        func nilIfEmpty(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let props = cProps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return SceneControls(
            setting: nilIfEmpty(cSetting), surface: nilIfEmpty(cSurface), lighting: nilIfEmpty(cLighting),
            timeOfDay: nilIfEmpty(cTimeOfDay), mood: nilIfEmpty(cMood), lens: nilIfEmpty(cLens),
            props: props, strictBrand: strictBrand
        )
    }

    private func apply(_ recipe: CreativeRecipe) {
        let c = recipe.controls
        cSetting = c.setting ?? ""
        cSurface = c.surface ?? ""
        cLighting = c.lighting ?? ""
        cTimeOfDay = c.timeOfDay ?? ""
        cMood = c.mood ?? ""
        cLens = c.lens ?? ""
        cProps = c.props.joined(separator: ", ")
        strictBrand = c.strictBrand
        aspectPreset = recipe.aspect
        brief = recipe.freeformAddon
        recipeStore.markUsed(recipe.id)
    }

    private func saveCurrentAsRecipe() {
        guard hasDirection else { return }
        let slug = pickedBrand?.slug ?? "untagged"
        // Auto-name from the most descriptive knob so the chip is recognizable.
        let base = [cSetting, cSurface, cMood, brief].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Look"
        let name = String(base.prefix(28))
        recipeStore.add(
            name: name, brandSlug: slug,
            controls: currentControls(), freeformAddon: brief, aspect: aspectPreset
        )
    }

    private var briefField: some View {
        ZStack(alignment: .topLeading) {
            if brief.isEmpty {
                Text("Describe the image or video you want, plain language. The brand and workflow chips below scope the rest.")
                    .font(.system(size: 15))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $brief)
                .font(.system(size: 15))
                .foregroundStyle(GruxTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 110)
                .focused($briefFocused)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            // Soft accent border on focus. 1 px subtle, not a chunky ring.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    briefFocused ? GruxTheme.accentPrimaryLight.opacity(0.55) : Color.white.opacity(0.10),
                    lineWidth: briefFocused ? 1.0 : 0.6
                )
                .animation(.easeOut(duration: 0.16), value: briefFocused)
        )
        .onTapGesture { briefFocused = true }
    }

    private var brandStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            stripLabel("BRAND", optional: false)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(registry.brands, id: \.slug) { brand in
                        brandChip(brand)
                    }
                }
            }
            // Say so once the registry has answered with nothing. Untagged
            // still works, so this is a quiet note rather than an error. A
            // cached registry still counts as having brands, so this stays
            // silent in the common offline-but-cached case.
            if !registry.registryHasBrands && registry.lastRegistryFetch != nil {
                HStack(spacing: 6) {
                    Circle()
                        .fill(GruxTheme.textTertiary.opacity(0.6))
                        .frame(width: 4, height: 4)
                    Text("no brands found, untagged only")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
            }
        }
    }

    private func brandChip(_ brand: CreativeBrand) -> some View {
        let isPicked = pickedBrand == brand
        let isUntagged = (brand == .untagged)
        return Button { pickedBrand = brand } label: {
            // Full brand name (from the registry project name for registry
            // brands), never a truncated shortName. Proportional caption-scale
            // type keeps the longer names tight; the strip scrolls horizontally.
            Text(registry.displayName(for: brand))
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isPicked ? Color.black.opacity(0.85) : (isUntagged ? GruxTheme.textSecondary : brand.accentColor))
                .background(
                    Capsule().fill(isPicked ? brand.accentColor : brand.accentColor.opacity(0.10))
                )
                .overlay(
                    Capsule().stroke(brand.accentColor.opacity(isPicked ? 0.0 : 0.45), lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
        .help(registry.displayName(for: brand))
    }

    // Note: the old workflow chip row (image / platformPack / videoDraft) was
    // removed when the composer moved to the dynamic control panel (aspect +
    // count + strict carry the real intent now). Its state and views were
    // deleted to avoid dead code. Per-workflow behavior returns via recipes.

    private var generateRow: some View {
        // The disabled-to-iridescent button is the only state cue. No
        // chatty hint line, no live readout. If the button is dim, you
        // haven't picked something yet.
        HStack(alignment: .center, spacing: 14) {
            Button { fireGenerate() } label: {
                HStack(spacing: 8) {
                    if engine.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .progressViewStyle(.circular)
                            .tint(Color.black)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(engine.isWorking ? "GENERATING" : "GENERATE")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .kerning(1.4)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .foregroundStyle(canGenerate ? Color.black : GruxTheme.textTertiary)
                .background(
                    Capsule().fill(canGenerate
                        ? AnyShapeStyle(GruxTheme.iridescent)
                        : AnyShapeStyle(Color.white.opacity(0.06))
                    )
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canGenerate)
            Spacer()
        }
    }

    // MARK: control panel (structured direction)

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            stripLabel("DIRECTION", optional: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                knobField("Setting", $cSetting, "a sunlit loft")
                knobField("Surface", $cSurface, "reclaimed oak counter")
                knobField("Lighting", $cLighting, "golden hour")
                knobField("Time of day", $cTimeOfDay, "morning")
                knobField("Mood", $cMood, "calm, editorial")
                knobField("Lens / depth", $cLens, "shallow depth of field")
            }
            knobField("Props (comma separated)", $cProps, "a ceramic mug, a eucalyptus sprig")

            HStack(alignment: .bottom, spacing: 20) {
                aspectControl
                countControl
                strictToggle
                referenceControl
                Spacer()
            }
        }
    }

    private var referenceControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REFERENCE")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.0)
                .foregroundStyle(GruxTheme.textTertiary)
            if let path = uploadedReferencePath {
                Button { uploadedReferencePath = nil } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip").font(.system(size: 10, weight: .bold))
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: 120)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(Color.black.opacity(0.85))
                    .background(Capsule().fill(GruxTheme.accentCo))
                }
                .buttonStyle(.plain)
                .help("Uploaded reference. Click to remove and use the brand default.")
            } else {
                Button { pickReference() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .bold))
                        Text("UPLOAD").font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .help("Upload a product reference (PNG or JPEG). Required for brands with no built-in reference.")
            }
        }
    }

    private func pickReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            uploadedReferencePath = url.path
        }
    }

    private func knobField(_ label: String, _ binding: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .kerning(1.0)
                .foregroundStyle(GruxTheme.textTertiary)
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(GruxTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6))
        }
    }

    private var aspectControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASPECT")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.0)
                .foregroundStyle(GruxTheme.textTertiary)
            HStack(spacing: 6) {
                ForEach(AspectPreset.allCases) { a in
                    Button { aspectPreset = a } label: {
                        Text(a.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(aspectPreset == a ? Color.black.opacity(0.85) : GruxTheme.textSecondary)
                            .background(Capsule().fill(aspectPreset == a ? GruxTheme.accentPrimaryLight : Color.white.opacity(0.06)))
                            .overlay(Capsule().stroke(aspectPreset == a ? Color.clear : Color.white.opacity(0.18), lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                    .help(a.platformHint)
                }
            }
        }
    }

    private var countControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VARIATIONS")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.0)
                .foregroundStyle(GruxTheme.textTertiary)
            HStack(spacing: 8) {
                stepButton("minus") { genCount = max(1, genCount - 1) }
                Text("\(genCount)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .frame(minWidth: 16)
                stepButton("plus") { genCount = min(8, genCount + 1) }
            }
        }
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(GruxTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private var strictToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BRAND")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.0)
                .foregroundStyle(GruxTheme.textTertiary)
            Button { strictBrand.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: strictBrand ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .bold))
                    Text(strictBrand ? "STRICT" : "LOOSE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(strictBrand ? Color.black.opacity(0.85) : GruxTheme.textSecondary)
                .background(Capsule().fill(strictBrand ? GruxTheme.successMint : Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(strictBrand ? Color.clear : Color.white.opacity(0.18), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
            .help("Strict enforces the brand palette and style cues in the prompt")
        }
    }

    private func stripLabel(_ text: String, optional: Bool) -> some View {
        // The Generate button's disabled-to-iridescent transition already
        // carries the "you need to pick this" signal. No REQUIRED chip noise.
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(GruxTheme.textTertiary)
            if false {
                Text("REQUIRED")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .kerning(1.4)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .foregroundStyle(GruxTheme.accentPrimaryLight)
                    .background(Capsule().fill(GruxTheme.accentPrimary.opacity(0.16)))
            }
        }
    }

    private func fireGenerate() {
        guard let brand = pickedBrand else { return }
        let directive = PromptCompiler.compileDirective(
            controls: currentControls(), freeform: brief, brandSlug: brand.slug
        )
        let aspect = aspectPreset
        let count = genCount
        let refPath = uploadedReferencePath
        Task { @MainActor in
            // Read + base64 the reference off the main thread so the button stays
            // responsive, and guard the size (server body limit is 15 MB; 11 MB
            // raw is a safe ceiling once base64-inflated).
            var reference: String? = nil
            var tooLarge = false
            if let p = refPath {
                (reference, tooLarge) = await Task.detached { () -> (String?, Bool) in
                    let attrs = try? FileManager.default.attributesOfItem(atPath: p)
                    let size = (attrs?[.size] as? Int) ?? 0
                    if size > 11_000_000 { return (nil, true) }
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return (nil, false) }
                    let mime = (p as NSString).pathExtension.lowercased() == "png" ? "png" : "jpeg"
                    return ("data:image/\(mime);base64," + data.base64EncodedString(), false)
                }.value
            }
            if tooLarge {
                engine.lastError = "Reference image is too large (max about 11 MB). Resize it and try again."
                return
            }
            await engine.renderDynamic(brand: brand, directive: directive, sku: nil, aspect: aspect, count: count, reference: reference)
        }
        // Inputs stay so the user can tweak one knob and regenerate without
        // retyping. Matches the Midjourney / DALL-E pattern.
    }

    // MARK: gallery

    private let cols: [GridItem] = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    private var gallery: some View {
        // Evaluate the filtered list once per body pass (it allocates while
        // filtering) instead of three times across the header, branch, and grid.
        let bundles = galleryBundles
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("GALLERY")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .kerning(2.6)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                librarySearchField
            }

            if !engine.inbox.isEmpty {
                galleryFilterBar
                countBreakdown
            }

            if engine.inbox.isEmpty {
                emptyGalleryHero
            } else if bundles.isEmpty {
                Text(librarySearch.isEmpty
                     ? "No renders in \"\(galleryFilter.rawValue)\" yet."
                     : "No renders match \"\(librarySearch)\".")
                    .font(.system(size: 13)).foregroundStyle(GruxTheme.textTertiary)
                    .padding(.vertical, 30)
            } else {
                LazyVGrid(columns: cols, spacing: 24) {
                    ForEach(bundles) { bundle in
                        CreativeStudioCard(bundle: bundle)
                            .onTapGesture { sheetBundleID = bundle.id }
                    }
                }
            }
        }
    }

    private var galleryFilterBar: some View {
        HStack(spacing: 8) {
            ForEach(GalleryFilter.allCases) { filter in
                let count = engine.inbox.filter { filter.matches($0) }.count
                let isOn = galleryFilter == filter
                Button { galleryFilter = filter } label: {
                    HStack(spacing: 5) {
                        Image(systemName: filter.icon).font(.system(size: 9, weight: .bold))
                        Text(filter.rawValue).font(.system(size: 11, weight: .bold, design: .monospaced))
                        Text("\(count)").font(.system(size: 10, weight: .heavy, design: .monospaced)).opacity(0.7)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .foregroundStyle(isOn ? Color.black.opacity(0.85) : GruxTheme.textSecondary)
                    .background(Capsule().fill(isOn ? GruxTheme.accentPrimaryLight : Color.white.opacity(0.06)))
                    .overlay(Capsule().stroke(isOn ? Color.clear : Color.white.opacity(0.16), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var countBreakdown: some View {
        let total = engine.inbox.count
        let withVideo = engine.inbox.filter { $0.videoPath != nil }.count
        let approved = engine.inbox.filter { $0.approval == .approved }.count
        return Text("\(total) renders  ·  \(withVideo) with video  ·  \(approved) approved")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(GruxTheme.textTertiary)
    }

    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(GruxTheme.textTertiary)
            TextField("Search brand, tag, aspect, text", text: $librarySearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                // Ideal with a floor, the same shape GruxSearchField uses: a
                // search field that refuses to shrink pushes whatever shares
                // its row (here the GALLERY label) off the edge. Capped at 220
                // rather than .infinity because the Spacer beside it is what
                // holds the field right; an infinite max would eat the Spacer
                // and stretch the field across the row.
                .frame(minWidth: GruxLayout.searchFieldMin, idealWidth: 220, maxWidth: 220)
            if !librarySearch.isEmpty {
                Button { librarySearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(GruxTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6))
    }

    private var emptyGalleryHero: some View {
        VStack(spacing: 10) {
            Text("Untitled studio.")
                .font(.system(size: 22, weight: .semibold, design: .serif).italic())
                .foregroundStyle(GruxTheme.textTertiary)
            Text("Your first generation will land here.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(GruxTheme.textTertiary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.6, dash: [4, 6]))
                )
        )
    }
}

// MARK: - Gallery card

private struct CreativeStudioCard: View {
    let bundle: CreativeBundle
    // Not @ObservedObject: the card only needs the engine to fire actions, and
    // the parent gallery (which does observe the engine) re-passes a fresh bundle
    // when anything changes. Observing here would re-render every card on every
    // engine mutation.
    private var engine: CreativeEngine { CreativeEngine.shared }

    private var headline: String {
        bundle.copy?.headline ?? bundle.imageBrief?.scene ?? bundle.utterance
    }

    // Correct, content-derived type label: a still that was animated reads
    // "IMAGE + CLIP" (not the old hardcoded "IMAGE").
    private var typeLabel: String {
        bundle.videoPath != nil ? "IMAGE + CLIP" : "IMAGE"
    }

    // Exact model id(s), internal UI only (never exported per the no-stack rule).
    private var modelLabel: String {
        var parts: [String] = []
        if let m = bundle.imageModel { parts.append(m) }
        if bundle.videoPath != nil, let v = bundle.videoModel { parts.append(v) }
        return parts.joined(separator: "  +  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            visual
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(bundle.brand.accentColor.opacity(0.20), lineWidth: 0.8)
                )
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        if bundle.videoPath != nil {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill").font(.system(size: 8, weight: .black))
                                Text("CLIP").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.5)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .foregroundStyle(Color.black.opacity(0.85))
                            .background(Capsule().fill(GruxTheme.successMint))
                        }
                        if bundle.approval == .approved {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(GruxTheme.successMint)
                                .padding(5)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        if bundle.images.count > 1 {
                            HStack(spacing: 3) {
                                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9, weight: .bold))
                                Text("\(bundle.images.count)").font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                        }
                        if let aspect = bundle.aspect {
                            Text(aspect)
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                        }
                    }
                    .padding(8)
                }

            HStack(spacing: 8) {
                Circle().fill(bundle.brand.accentColor).frame(width: 6, height: 6)
                Text(bundle.brand.displayName)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(bundle.brand.accentColor)
                Spacer()
                Text(typeLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Model line (internal only) + feedback + actions.
            HStack(spacing: 8) {
                if !modelLabel.isEmpty {
                    Image(systemName: "cpu").font(.system(size: 8, weight: .bold)).foregroundStyle(GruxTheme.textTertiary)
                    Text(modelLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ratingThumbs
                actionMenu
            }
            // Swallow taps in the footer bar so stray clicks near the small
            // thumb/menu controls do not bubble to the card's open-sheet gesture.
            .contentShape(Rectangle())
            .onTapGesture { }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.6)
        )
        .contentShape(Rectangle())
    }

    private var ratingThumbs: some View {
        HStack(spacing: 4) {
            Button { engine.setRating(bundle, to: bundle.rating == .up ? .none : .up) } label: {
                Image(systemName: bundle.rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(bundle.rating == .up ? GruxTheme.successMint : GruxTheme.textTertiary)
            }
            .buttonStyle(.plain).help("Good. Feeds the model learning loop for this brand.")
            Button { engine.setRating(bundle, to: bundle.rating == .down ? .none : .down) } label: {
                Image(systemName: bundle.rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(bundle.rating == .down ? GruxTheme.destructiveRose : GruxTheme.textTertiary)
            }
            .buttonStyle(.plain).help("Needs work. Repeated negatives escalate this brand to a stronger model.")
        }
    }

    private var actionMenu: some View {
        Menu {
            ForEach(StudioAction.live) { a in
                Button { perform(a) } label: { Label(a.title, systemImage: a.icon) }
            }
            Divider()
            Section("Coming soon") {
                ForEach(StudioAction.comingSoon) { a in
                    Button { } label: { Label(a.title, systemImage: a.icon) }.disabled(true)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GruxTheme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func perform(_ a: StudioAction) {
        switch a {
        case .animate: engine.animate(bundle)
        case .approve: engine.setApproval(bundle, to: .approved)
        case .reject: engine.setApproval(bundle, to: .rejected)
        case .exportAspects: engine.exportAspects(bundle)
        case .draftSocial: engine.draftToSocial(bundle)
        default: break
        }
    }

    @ViewBuilder private var visual: some View {
        if let path = bundle.localImagePath, let img = ImageThumbCache.shared.thumb(at: path, maxPixel: 700) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .center) {
                    if bundle.videoPath != nil {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.45), radius: 6)
                    }
                }
        } else {
            // Image-less card. Dimmer brand gradient (so it does not read
            // as a finished poster) plus a NEEDS IMAGE chip in the corner so
            // the user can see at a glance that this asset is still owed.
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        bundle.brand.accentColor.opacity(0.22),
                        bundle.brand.accentColor.opacity(0.08),
                        Color.black.opacity(0.55)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Text(bundle.brand.displayName.first.map(String.init) ?? "·")
                    .font(.system(size: 220, weight: .heavy, design: .default).width(.condensed))
                    .foregroundStyle(Color.white.opacity(0.04))
                    .offset(y: 8)
                HStack(spacing: 5) {
                    Circle()
                        .fill(bundle.brand.accentColor)
                        .frame(width: 5, height: 5)
                    Text("NEEDS IMAGE · TAP TO RENDER")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .kerning(1.0)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(bundle.brand.accentColor)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(10)
            }
        }
    }
}

// MARK: - Detail sheet

/// AppKit AVPlayerView wrapped for SwiftUI. We deliberately do NOT use SwiftUI's
/// `VideoPlayer`: in a release (compiled) build its internal VideoPlayerView
/// fails to resolve its AVPlayerView superclass metadata and crashes on play
/// ("failed to demangle superclass of VideoPlayerView ... AVPlayerView").
/// AVPlayerView via NSViewRepresentable is rock solid in the same build. Verified
/// by an isolated compiled repro before this change.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Self-contained clip player. Owns its AVPlayer in @State and is given a stable
/// SwiftUI identity by the caller (.id(videoPath)), so parent re-renders never
/// churn the player.
private struct ClipPlayerView: View {
    let videoPath: String
    @State private var player: AVPlayer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLIP")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            Group {
                if let player {
                    AVPlayerViewRepresentable(player: player)
                } else {
                    Color.black.opacity(0.2)
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(GruxTheme.successMint.opacity(0.35), lineWidth: 0.8))
        }
        .onAppear {
            if player == nil {
                player = AVPlayer(url: URL(fileURLWithPath: videoPath))
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct CreativeStudioDetailSheet: View {
    @ObservedObject var engine: CreativeEngine
    let bundleID: String
    let onDismiss: () -> Void

    @State private var autoRetried: Bool = false
    // Which batch sibling is shown in the hero. Defaults to the first image.
    @State private var shownImagePath: String? = nil
    @State private var newTag: String = ""
    @State private var fbNote: String = ""

    // Always read the live bundle from the engine so approvals and a freshly
    // animated clip appear in place without reopening the sheet.
    private var bundle: CreativeBundle? { engine.inbox.first { $0.id == bundleID } }

    private func heroPath(_ b: CreativeBundle) -> String? { shownImagePath ?? b.localImagePath }
    private func selectedIndex(_ b: CreativeBundle) -> Int {
        guard let p = heroPath(b), let i = b.images.firstIndex(of: p) else { return 0 }
        return i
    }

    var body: some View {
        Group {
            if let b = bundle {
                content(b)
            } else {
                VStack(spacing: 12) {
                    Text("This render was removed.")
                        .font(.system(size: 13)).foregroundStyle(GruxTheme.textSecondary)
                    Button("Close", action: onDismiss).buttonStyle(.plain)
                }
                .frame(minWidth: 720, minHeight: 580)
                .background(GruxTheme.base)
            }
        }
    }

    private func content(_ b: CreativeBundle) -> some View {
        VStack(spacing: 0) {
            sheetHeader(b)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    visual(b)
                    if b.images.count > 1 { siblingStrip(b) }
                    if let vp = b.videoPath {
                        ClipPlayerView(videoPath: vp).id(vp)
                    }
                    outputActions(b)
                    comingSoonRow(b)
                    feedbackBlock(b)
                    utilityActions(b)
                    tagsBlock(b)
                    provenanceBlock(b)
                }
                .padding(28)
            }
        }
        .frame(minWidth: 720, minHeight: 580)
        .background(GruxTheme.base)
        .foregroundStyle(GruxTheme.textPrimary)
        .onAppear {
            shownImagePath = nil
            autoRetried = false
            fbNote = b.feedbackNote ?? ""
            if b.localImagePath == nil && !autoRetried {
                autoRetried = true
                Task { await engine.renderImageNow(for: b) }
            }
        }
    }

    private func sheetHeader(_ b: CreativeBundle) -> some View {
        HStack(spacing: 10) {
            Circle().fill(b.brand.accentColor).frame(width: 6, height: 6)
            Text(b.brand.displayName)
                .font(.system(size: 12, weight: .heavy, design: .monospaced)).kerning(1.0)
            if let aspect = b.aspect {
                Text("·").foregroundStyle(GruxTheme.textTertiary)
                Text(aspect).font(.system(size: 11, design: .monospaced)).foregroundStyle(GruxTheme.textTertiary)
            }
            if b.videoPath != nil {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 8, weight: .black))
                    Text("CLIP").font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(Color.black.opacity(0.85))
                .background(Capsule().fill(GruxTheme.successMint))
            }
            approvalBadge(b)
            Spacer()
            if engine.isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.04)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.black.opacity(0.35))
        .overlay(Divider().opacity(0.15), alignment: .bottom)
    }

    @ViewBuilder private func approvalBadge(_ b: CreativeBundle) -> some View {
        switch b.approval {
        case .approved:
            Label("APPROVED", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(GruxTheme.successMint)
        case .rejected:
            Label("REJECTED", systemImage: "xmark.seal.fill")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(GruxTheme.destructiveRose)
        case .draft:
            EmptyView()
        }
    }

    @ViewBuilder private func visual(_ b: CreativeBundle) -> some View {
        if let path = heroPath(b), let img = ImageThumbCache.shared.thumb(at: path, maxPixel: 1100) {
            Image(nsImage: img)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(b.brand.accentColor.opacity(0.25), lineWidth: 0.8))
        } else {
            ZStack {
                LinearGradient(colors: [b.brand.accentColor.opacity(0.30), b.brand.accentColor.opacity(0.10), Color.black.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular).tint(b.brand.accentColor)
                    Text(autoRetried ? "RENDERING" : "NO IMAGE YET")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced)).kerning(1.4)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(autoRetried
                         // The port number was in this copy and named nothing a
                         // reader could act on. Which port an internal service
                         // listens on is not a fact a user has, or wants.
                         ? "Calling the image service. If this stalls, that service is offline."
                         : "The image service did not return an image. Tap Render image to retry.")
                        .font(.system(size: 11)).multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.65)).frame(maxWidth: 360)
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(b.brand.accentColor.opacity(0.30), lineWidth: 0.8))
        }
    }

    private func siblingStrip(_ b: CreativeBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VARIATIONS · \(b.images.count)")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(b.images, id: \.self) { path in
                        let isShown = (heroPath(b) == path)
                        Button { shownImagePath = path } label: {
                            Group {
                                if let img = ImageThumbCache.shared.thumb(at: path, maxPixel: 200) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                } else { Color.white.opacity(0.05) }
                            }
                            .frame(width: 72, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isShown ? b.brand.accentColor : Color.white.opacity(0.12), lineWidth: isShown ? 1.6 : 0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // Output actions: the real workflow on a keeper.
    private func outputActions(_ b: CreativeBundle) -> some View {
        HStack(spacing: 8) {
            pill(icon: "checkmark.seal", label: "Approve", color: GruxTheme.successMint) {
                engine.setApproval(b, to: .approved, siblingIndex: selectedIndex(b))
            }
            pill(icon: "xmark.seal", label: "Reject", color: GruxTheme.destructiveRose) {
                engine.setApproval(b, to: .rejected)
            }
            pill(icon: "film", label: b.videoPath == nil ? "Animate" : "Re-animate", color: GruxTheme.accentPrimaryLight) {
                engine.animate(b, siblingIndex: selectedIndex(b))
            }
            pill(icon: "rectangle.on.rectangle.angled", label: "Export aspects", color: GruxTheme.accentPrimaryLight) {
                engine.exportAspects(b)
            }
            pill(icon: "paperplane", label: "Draft to social", color: GruxTheme.accentCo) {
                engine.draftToSocial(b, siblingIndex: selectedIndex(b))
            }
            Spacer()
        }
        .disabled(engine.isWorking)
        .opacity(engine.isWorking ? 0.5 : 1)
    }

    private func utilityActions(_ b: CreativeBundle) -> some View {
        HStack(spacing: 8) {
            if b.localImagePath == nil {
                pill(icon: "photo.fill", label: "Render image", color: b.brand.accentColor) {
                    Task { await engine.renderImageNow(for: b) }
                }
            }
            pill(icon: "arrow.triangle.2.circlepath", label: "Regenerate", color: b.brand.accentColor) {
                engine.regenerate(b)
            }
            if let path = heroPath(b) {
                pill(icon: "doc.on.doc", label: "Copy image", color: GruxTheme.textSecondary) { copyImage(path) }
            }
            Menu {
                if let p = heroPath(b) { Button("Show image in Finder") { revealFile(p) } }
                if let v = b.videoPath { Button("Show clip in Finder") { revealFile(v) } }
                Button("Show JSON in Finder") { revealJSON(b) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                    Text("REVEAL").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.8)
                }
                .foregroundStyle(GruxTheme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(GruxTheme.textSecondary.opacity(0.10)))
                .overlay(Capsule().stroke(GruxTheme.textSecondary.opacity(0.30), lineWidth: 0.6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            pill(icon: "trash", label: "", color: GruxTheme.destructiveRose) {
                engine.delete(b); onDismiss()
            }
        }
    }

    private func copyImage(_ path: String) {
        guard let img = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    private func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func revealJSON(_ b: CreativeBundle) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux/creative/\(b.brand.slug)/\(b.id).json")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func pill(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                if !label.isEmpty {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.8)
                }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private func tagsBlock(_ b: CreativeBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TAGS")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Enumerate for stable ForEach identity even if a duplicate
                    // tag ever sneaks in; remove/add read the live bundle to
                    // avoid clobbering a concurrent edit.
                    ForEach(Array(b.tags.enumerated()), id: \.offset) { _, tag in
                        Button {
                            guard let live = bundle else { return }
                            engine.setTags(live, tags: live.tags.filter { $0 != tag })
                        } label: {
                            HStack(spacing: 4) {
                                Text(tag).font(.system(size: 11, weight: .semibold))
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .foregroundStyle(GruxTheme.textSecondary)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove tag")
                    }
                    TextField("add tag", text: $newTag)
                        .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 110)
                        .onSubmit {
                            let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                            newTag = ""
                            guard !t.isEmpty, let live = bundle, !live.tags.contains(t) else { return }
                            engine.setTags(live, tags: live.tags + [t])
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.04)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                }
            }
        }
    }

    // Coming-soon functions: the foundation surface for future tasks.
    private func comingSoonRow(_ b: CreativeBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMING SOON")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StudioAction.comingSoon) { a in
                        HStack(spacing: 5) {
                            Image(systemName: a.icon).font(.system(size: 10, weight: .semibold))
                            Text(a.title).font(.system(size: 11, weight: .semibold))
                            Text("SOON")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .foregroundStyle(GruxTheme.warnAmber)
                                .background(Capsule().fill(GruxTheme.warnAmber.opacity(0.16)))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .background(Capsule().fill(Color.white.opacity(0.04)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                        .help("\(a.title): coming soon")
                    }
                }
            }
        }
    }

    // Self-learning feedback: thumbs + optional note. Adapts the brand's model.
    private func feedbackBlock(_ b: CreativeBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FEEDBACK")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            HStack(spacing: 8) {
                ratingPill(b, .up, "hand.thumbsup", GruxTheme.successMint, "Good")
                ratingPill(b, .down, "hand.thumbsdown", GruxTheme.destructiveRose, "Needs work")
                TextField("optional note (e.g. this brand needs a stronger model)", text: $fbNote)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit {
                        guard let live = bundle, live.rating != .none else { return }
                        engine.setRating(live, to: live.rating, note: fbNote)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.04)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.6))
            }
            Text("Your ratings teach Grux per brand. Repeated negatives auto-escalate the image model (qwen-image-edit-plus to qwen-image-edit-max).")
                .font(.system(size: 10)).foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ratingPill(_ b: CreativeBundle, _ r: AssetRating, _ icon: String, _ color: Color, _ label: String) -> some View {
        let on = (b.rating == r)
        return Button {
            engine.setRating(b, to: on ? .none : r, note: fbNote.isEmpty ? nil : fbNote)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? icon + ".fill" : icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(on ? Color.black.opacity(0.85) : color)
            .background(Capsule().fill(on ? color : color.opacity(0.10)))
            .overlay(Capsule().stroke(on ? Color.clear : color.opacity(0.30), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    // Full lineage, collapsed by default. Internal only (never exported).
    private func provenanceBlock(_ b: CreativeBundle) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                provRow("Image model", b.imageModel ?? "unknown")
                if let vm = b.videoModel { provRow("Clip model", vm) }
                provRow("Aspect", b.aspect ?? "?")
                provRow("Brand", b.brand.displayName)
                if let r = b.recipeId { provRow("Recipe", r) }
                if let p = b.parentAssetId { provRow("Derived from", p) }
                provRow("Created", b.createdAt.formatted(date: .abbreviated, time: .shortened))
                provRow("Provider", b.providerPath)
                provRow("ID", b.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DIRECTIVE").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.0)
                        .foregroundStyle(GruxTheme.textTertiary)
                    Text(b.directive ?? b.utterance)
                        .font(.system(size: 12)).foregroundStyle(GruxTheme.textPrimary.opacity(0.8))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }
            .padding(.top, 8)
        } label: {
            Text("PROVENANCE")
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
        }
        .tint(GruxTheme.textSecondary)
    }

    private func provRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(GruxTheme.textTertiary)
                .frame(width: 92, alignment: .leading)
            Text(v)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(GruxTheme.textPrimary.opacity(0.8))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared section label

private func sectionLabel(_ text: String, color: Color) -> some View {
    HStack(spacing: 6) {
        Rectangle().fill(color).frame(width: 12, height: 2)
        Text(text.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .kerning(1.4)
            .foregroundStyle(color)
        Spacer()
    }
}

