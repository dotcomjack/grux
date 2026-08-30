import XCTest
@testable import Grux

// Unit tests for SpeakerContactLinkStore. Every test instantiates its own
// store against a unique temp-dir JSON file so the singleton's real
// speaker-contact-links.json is never touched.
@MainActor
final class SpeakerContactLinkTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-link-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func makeStore() -> SpeakerContactLinkStore {
        SpeakerContactLinkStore(storeURL: tempDir.appendingPathComponent("links.json"))
    }

    // MARK: - CRUD

    func testLinkAndLookup() {
        let store = makeStore()
        let speakerId = UUID()
        let link = store.link(speakerProfileId: speakerId, contactIdentifier: "ABC:123")
        XCTAssertEqual(link.speakerProfileId, speakerId)
        XCTAssertEqual(link.contactIdentifier, "ABC:123")
        XCTAssertEqual(store.contactIdentifier(for: speakerId), "ABC:123")
        XCTAssertEqual(store.speakerProfileIds(for: "ABC:123"), [speakerId])
        XCTAssertTrue(store.isLinked(speakerProfileId: speakerId))
    }

    func testLinkUpsertsRatherThanDuplicates() {
        let store = makeStore()
        let speakerId = UUID()
        _ = store.link(speakerProfileId: speakerId, contactIdentifier: "first")
        _ = store.link(speakerProfileId: speakerId, contactIdentifier: "second")
        XCTAssertEqual(store.links.count, 1, "re-linking the same speaker must not duplicate")
        XCTAssertEqual(store.contactIdentifier(for: speakerId), "second")
        XCTAssertTrue(store.speakerProfileIds(for: "first").isEmpty)
    }

    func testMultipleSpeakersCanLinkToOneContact() {
        let store = makeStore()
        let a = UUID()
        let b = UUID()
        _ = store.link(speakerProfileId: a, contactIdentifier: "shared-contact")
        _ = store.link(speakerProfileId: b, contactIdentifier: "shared-contact")
        let ids = Set(store.speakerProfileIds(for: "shared-contact"))
        XCTAssertEqual(ids, Set([a, b]))
    }

    func testUnlink() {
        let store = makeStore()
        let speakerId = UUID()
        _ = store.link(speakerProfileId: speakerId, contactIdentifier: "x")
        XCTAssertTrue(store.unlink(speakerProfileId: speakerId))
        XCTAssertNil(store.contactIdentifier(for: speakerId))
        XCTAssertFalse(store.unlink(speakerProfileId: speakerId), "second unlink must report false")
    }

    func testPersistenceRoundTrip() {
        let url = tempDir.appendingPathComponent("links.json")
        let speakerId = UUID()
        do {
            let store = SpeakerContactLinkStore(storeURL: url)
            _ = store.link(speakerProfileId: speakerId, contactIdentifier: "persisted:42")
        }
        let reloaded = SpeakerContactLinkStore(storeURL: url)
        XCTAssertEqual(reloaded.links.count, 1)
        XCTAssertEqual(reloaded.contactIdentifier(for: speakerId), "persisted:42")
    }

    func testEmptyFileLoadsEmpty() {
        let store = SpeakerContactLinkStore(storeURL: tempDir.appendingPathComponent("missing.json"))
        XCTAssertTrue(store.links.isEmpty)
    }

    // MARK: - Name matching

    func testNameMatchScoreExact() {
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("Sarah Chen", "sarah chen"), 1.0)
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("  Sarah   Chen ", "Sarah Chen"), 1.0)
    }

    func testNameMatchScoreTokenReorder() {
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("Chen Sarah", "Sarah Chen"), 0.95)
    }

    func testNameMatchScoreSharedToken() {
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("Sarah", "Sarah Chen"), 0.7)
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("Mike Torres", "Mike T"), 0.7)
    }

    func testNameMatchScorePrefixToken() {
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("Sam", "Samuel Jones"), 0.5)
    }

    func testNameMatchScoreNoMatch() {
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("Sarah Chen", "Mike Torres"), 0.0)
        XCTAssertEqual(SpeakerContactLinkStore.nameMatchScore("", "Mike"), 0.0)
    }

    // MARK: - Suggestions

    func testSuggestionsRankAndFilter() {
        let store = makeStore()
        let exact = UUID()
        let partial = UUID()
        let unrelated = UUID()
        let profiles: [(id: UUID, name: String)] = [
            (partial, "Sarah"),
            (unrelated, "Mike Torres"),
            (exact, "Sarah Chen")
        ]
        let suggestions = store.suggestions(forContactNamed: "Sarah Chen", profiles: profiles)
        XCTAssertEqual(suggestions.map { $0.speakerProfileId }, [exact, partial],
                       "exact match first, partial second, unrelated dropped")
        XCTAssertGreaterThan(suggestions[0].score, suggestions[1].score)
    }

    func testSuggestionsExcludeAlreadyLinkedProfiles() {
        let store = makeStore()
        let linked = UUID()
        let free = UUID()
        _ = store.link(speakerProfileId: linked, contactIdentifier: "someone-else")
        let profiles: [(id: UUID, name: String)] = [
            (linked, "Sarah Chen"),
            (free, "Sarah")
        ]
        let suggestions = store.suggestions(forContactNamed: "Sarah Chen", profiles: profiles)
        XCTAssertEqual(suggestions.map { $0.speakerProfileId }, [free],
                       "profiles already linked to any contact must not be suggested")
    }

    func testSuggestContactForSpeaker() {
        let store = makeStore()
        let contacts: [(identifier: String, name: String)] = [
            ("c1", "Mike Torres"),
            ("c2", "Sarah Chen"),
            ("c3", "Sara Smith")
        ]
        let best = store.suggestContact(forSpeakerNamed: "Sarah", contacts: contacts)
        XCTAssertEqual(best?.identifier, "c2")
        XCTAssertEqual(best?.score, 0.7)
        XCTAssertNil(store.suggestContact(forSpeakerNamed: "Zebulon", contacts: contacts))
    }
}
