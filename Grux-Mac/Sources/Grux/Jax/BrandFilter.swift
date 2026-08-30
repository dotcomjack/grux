import SwiftUI

// BrandFilter: the one persisted, app-wide brand focus (approved UI/UX design,
// decision 3). A single segmented control cascades across the Jax HQ Drafts
// surface, the Mailbox, and the Cognition Map, so the user can work one brand
// at a time. "All" is the default. Persisted to ~/.grux/jax so the choice
// survives relaunch.
//
// The scope token is persisted here AND used as the brand-voice key the mail
// and Jax paths match on, so it is an identifier, not display text.

// A brand focus. This was an enum with one person's three companies compiled in
// as cases; the vocabulary now comes from the user's own ~/.grux/brands.json
// (see BrandRoster) and only the "all" sentinel is compiled in.
//
// It is a struct wrapping a String rather than an enum with a dynamic case list
// for one reason: the token is PERSISTED, in ~/.grux/jax/brand-filter.json and
// as `brandVoice` on every staged draft. Coding as a bare string keeps that file
// format byte-identical, so an already-persisted token decodes with no migration
// and no backfill, and a token written by a build whose roster has since changed
// still decodes instead of throwing. Decoding never consults the roster; only
// the failable init below does.
struct BrandScope: Codable, Hashable, Identifiable {

    // The reserved match-everything token. Compiled in because it is Grux's own
    // sentinel rather than anybody's brand, and BrandRoster drops a configured
    // brand that tries to claim it (a brand named "all" would silently match
    // every other brand's mail).
    static let allToken = "all"
    static let all = BrandScope(id: allToken)

    let rawValue: String
    var id: String { rawValue }

    // Free-form, never fails, never reads the roster. This is what the decoder
    // and the tests use: a persisted token has to survive whether or not the
    // brand behind it is still configured. A blank token degrades to `all`,
    // because a filter with no selection would render as nothing selected with
    // no way to tell why.
    init(id: String) {
        let token = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rawValue = token.isEmpty ? Self.allToken : token
    }

    // Roster-checked. Callers that turn an arbitrary string (a brand tag on a
    // cognition event, a rules-sheet argument) into a scope want to know when it
    // names nothing this install knows about, so they can fall back rather than
    // select an option that is not in the bar. With no roster configured every
    // token except "all" returns nil, which is the honest answer.
    init?(rawValue: String) {
        let scope = BrandScope(id: rawValue)
        guard scope == .all || BrandRoster.brand(id: scope.rawValue) != nil else { return nil }
        self = scope
    }

    // Display text, from the user's own roster. A scope whose brand has since
    // been removed from the roster still renders (as its own token, upcased)
    // rather than blanking out.
    var label: String {
        self == .all ? "All" : BrandRoster.label(forId: rawValue)
    }

    // Everything the filter bar offers: "All" first, then the configured
    // brands. With no roster this is just ["All"], which is the correct
    // needs-setup state and is why the bar can never be empty.
    static var selectable: [BrandScope] {
        [.all] + BrandRoster.brands.map { BrandScope(id: $0.id) }
    }

    // The configured brands alone, without the "All" sentinel. Callers that
    // need ONE concrete brand use this and must handle it being empty; there is
    // no first element to force-unwrap on a fresh install.
    static var configured: [BrandScope] {
        BrandRoster.brands.map { BrandScope(id: $0.id) }
    }

    // Does this scope include something tagged with the given brand voice?
    // .all matches everything.
    func matches(voice: String) -> Bool {
        self == .all
            || rawValue == voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Coded as a bare string, exactly as the enum's raw value was, so an
    // already-persisted file needs no migration. An unreadable token degrades to
    // `all` rather than throwing: this value rides inside larger persisted
    // documents, and one bad token must never take a whole file with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(id: (try? container.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

@MainActor
final class BrandFilter: ObservableObject {
    static let shared = BrandFilter()

    @Published var scope: BrandScope { didSet { save() } }

    private let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/jax", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("brand-filter.json")
    }()

    private init() {
        // A persisted scope whose brand is no longer in the roster would leave
        // the bar with nothing highlighted and every surface filtered down to
        // zero rows, with no visible cause. Self-heal to "All" instead. This
        // runs during init, so the property observer does not fire and the
        // healed value is not written back over the user's choice; put the
        // brand back in brands.json and the selection returns.
        let loaded = Persistence.load(BrandScope.self, from: url, fallback: .all)
        scope = BrandScope.selectable.contains(loaded) ? loaded : .all
    }

    private func save() { Persistence.save(scope, to: url) }
}

// The shared segmented control. Drop it at the top of any brand-scoped surface.
// `count` is optional ("2 of 9") so a surface can show how the filter narrowed.
struct BrandFilterBar: View {
    @ObservedObject private var filter = BrandFilter.shared
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BrandScope.selectable) { scope in
                let on = filter.scope == scope
                Button { filter.scope = scope } label: {
                    Text(scope.label)
                        .font(.system(size: 12, weight: on ? .bold : .medium))
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        // One selected-tint for every brand. This used to
                        // special-case a single brand's own colour, which is
                        // that company's branding rather than Grux's, and it
                        // could never be right for a brand it had not heard of.
                        .background(on ? GruxTheme.accentPrimary.opacity(0.9) : Color.clear)
                        // Near-black ink on the accent fill, where the theme's
                        // own foreground colours do not carry enough contrast.
                        .foregroundStyle(on
                                         ? Color(red: 0x1a/255, green: 0x12/255, blue: 0x06/255)
                                         : GruxTheme.textSecondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(GruxTheme.textTertiary).padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(Color(red: 0x16/255, green: 0x12/255, blue: 0x08/255))
        .overlay(Capsule().strokeBorder(GruxTheme.textTertiary.opacity(0.15), lineWidth: 1))
        .clipShape(Capsule())
    }
}
