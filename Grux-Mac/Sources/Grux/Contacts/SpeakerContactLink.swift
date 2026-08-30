import Foundation

// One persisted association between an enrolled voice profile
// (SpeakerProfileStore) and a system contact (CNContact.identifier). A
// speaker maps to at most one contact; a contact may own several voice
// profiles (e.g. "Sarah" and "Sarah on speakerphone").
struct SpeakerContactLink: Codable, Identifiable, Equatable {
    let speakerProfileId: UUID
    var contactIdentifier: String
    var createdAt: Date

    var id: UUID { speakerProfileId }

    init(speakerProfileId: UUID, contactIdentifier: String, createdAt: Date = Date()) {
        self.speakerProfileId = speakerProfileId
        self.contactIdentifier = contactIdentifier
        self.createdAt = createdAt
    }
}

// A candidate pairing produced by name matching. Shown in the contact
// detail card so a diarized meeting speaker can be linked in one click.
struct SpeakerLinkSuggestion: Identifiable, Equatable {
    let speakerProfileId: UUID
    let speakerName: String
    let score: Double

    var id: UUID { speakerProfileId }
}

// JSON-backed store of speaker-to-contact links. Lives in
// ~/Library/Application Support/Grux/speaker-contact-links.json. Flat list,
// saved on every mutation; the file stays tiny (one row per enrolled voice).
// The init(storeURL:) overload exists so tests can point it at a temp dir.
@MainActor
final class SpeakerContactLinkStore: ObservableObject {
    static let shared = SpeakerContactLinkStore()

    @Published private(set) var links: [SpeakerContactLink] = []

    private let storeURL: URL

    init(storeURL: URL) {
        self.storeURL = storeURL
        links = Persistence.load([SpeakerContactLink].self, from: storeURL, fallback: [])
    }

    private convenience init() {
        self.init(storeURL: Persistence.supportDir.appendingPathComponent("speaker-contact-links.json"))
    }

    // MARK: - CRUD

    // Upsert: linking an already-linked speaker re-points it at the new
    // contact instead of creating a duplicate row.
    @discardableResult
    func link(speakerProfileId: UUID, contactIdentifier: String) -> SpeakerContactLink {
        if let idx = links.firstIndex(where: { $0.speakerProfileId == speakerProfileId }) {
            links[idx].contactIdentifier = contactIdentifier
            persist()
            return links[idx]
        }
        let link = SpeakerContactLink(speakerProfileId: speakerProfileId, contactIdentifier: contactIdentifier)
        links.append(link)
        persist()
        return link
    }

    @discardableResult
    func unlink(speakerProfileId: UUID) -> Bool {
        let before = links.count
        links.removeAll { $0.speakerProfileId == speakerProfileId }
        if links.count != before {
            persist()
            return true
        }
        return false
    }

    // MARK: - Lookup

    func contactIdentifier(for speakerProfileId: UUID) -> String? {
        links.first { $0.speakerProfileId == speakerProfileId }?.contactIdentifier
    }

    func speakerProfileIds(for contactIdentifier: String) -> [UUID] {
        links.filter { $0.contactIdentifier == contactIdentifier }.map { $0.speakerProfileId }
    }

    func isLinked(speakerProfileId: UUID) -> Bool {
        links.contains { $0.speakerProfileId == speakerProfileId }
    }

    // MARK: - Matching

    // Pure name similarity in [0, 1]. Token-based so "Sarah" matches
    // "Sarah Chen" and "J. Doe" still scores against "Jane Doe".
    //   1.0  exact normalized match
    //   0.95 same tokens, any order
    //   0.7  at least one full token shared (first or last name hit)
    //   0.5  a token of one is a prefix (3+ chars) of a token of the other
    //   0.45 whole-string containment
    //   0.0  otherwise
    static func nameMatchScore(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1.0 }
        let ta = Set(na.split(separator: " ").map(String.init))
        let tb = Set(nb.split(separator: " ").map(String.init))
        if ta == tb { return 0.95 }
        if !ta.intersection(tb).isEmpty { return 0.7 }
        for x in ta {
            for y in tb {
                let shorter = x.count <= y.count ? x : y
                let longer = x.count <= y.count ? y : x
                if shorter.count >= 3 && longer.hasPrefix(shorter) { return 0.5 }
            }
        }
        if na.contains(nb) || nb.contains(na) { return 0.45 }
        return 0
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Suggest unlinked voice profiles whose name resembles the contact's.
    // Injectable profile list keeps the matcher testable without touching
    // SpeakerProfileStore's singleton disk state.
    func suggestions(forContactNamed contactName: String,
                     profiles: [(id: UUID, name: String)],
                     minScore: Double = 0.45) -> [SpeakerLinkSuggestion] {
        let linked = Set(links.map { $0.speakerProfileId })
        return profiles
            .filter { !linked.contains($0.id) }
            .compactMap { p -> SpeakerLinkSuggestion? in
                let score = Self.nameMatchScore(p.name, contactName)
                guard score >= minScore else { return nil }
                return SpeakerLinkSuggestion(speakerProfileId: p.id, speakerName: p.name, score: score)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.speakerName.localizedCaseInsensitiveCompare($1.speakerName) == .orderedAscending
            }
    }

    // Convenience overload against the live enrolled-speaker roster.
    func suggestions(forContactNamed contactName: String) -> [SpeakerLinkSuggestion] {
        suggestions(
            forContactNamed: contactName,
            profiles: SpeakerProfileStore.shared.profiles.map { ($0.id, $0.name) }
        )
    }

    // Best contact match for a diarized speaker, e.g. when a meeting cluster
    // gets enrolled under a real name and we want to attach contact context.
    func suggestContact(forSpeakerNamed speakerName: String,
                        contacts: [(identifier: String, name: String)],
                        minScore: Double = 0.45) -> (identifier: String, score: Double)? {
        var best: (identifier: String, score: Double)?
        for c in contacts {
            let score = Self.nameMatchScore(speakerName, c.name)
            guard score >= minScore else { continue }
            if best == nil || score > best!.score {
                best = (c.identifier, score)
            }
        }
        return best
    }

    // MARK: - Persistence

    private func persist() {
        Persistence.save(links, to: storeURL)
    }
}
