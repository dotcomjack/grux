import XCTest
@testable import Grux

/// The thread rail should be full of conversations a person recognises, not a
/// column of "New chat" and threads named after the error that broke them.
@MainActor
final class ThreadHousekeepingTests: XCTestCase {

    private func entry(title: String, messages: Int = 0, starred: Bool = false,
                       preview: String? = nil) -> ChatThreadIndexEntry {
        ChatThreadIndexEntry(id: UUID(), title: title, starred: starred,
                             updatedAt: Date(), createdAt: Date(),
                             messageCount: messages, preview: preview, hasSummary: false)
    }

    // MARK: - Empty threads discard themselves

    func test_anUntouchedNewChatIsDiscarded() {
        XCTAssertTrue(ChatThreadStore.shouldDiscard(entry(title: ChatTitleHygiene.neutralDefault)))
    }

    func test_aThreadWithAnythingInItIsKept() {
        XCTAssertFalse(ChatThreadStore.shouldDiscard(
            entry(title: ChatTitleHygiene.neutralDefault, messages: 1)))
    }

    /// Starring is how a person says they meant to keep it.
    func test_aStarredEmptyThreadIsKept() {
        XCTAssertFalse(ChatThreadStore.shouldDiscard(
            entry(title: ChatTitleHygiene.neutralDefault, starred: true)))
    }

    /// A deliberately named empty thread is a plan, not litter.
    func test_aNamedEmptyThreadIsKept() {
        XCTAssertFalse(ChatThreadStore.shouldDiscard(entry(title: "Filament order")))
    }

    // MARK: - Titles that shipped before the check existed

    /// The two titles measured in the rail on the running app.
    func test_aTitleNamedAfterTheErrorIsRepaired() {
        let repaired = ChatThreadStore.repairedTitle(
            for: entry(title: "big teets and http 400", messages: 46,
                       preview: "can you look at the filament order"))
        XCTAssertEqual(repaired, "Can you look at the filament order")
    }

    func test_aGoodTitleIsLeftAlone() {
        XCTAssertNil(ChatThreadStore.repairedTitle(
            for: entry(title: "Filament order for the printer", messages: 4)))
    }

    /// With nothing better to fall back on it becomes the neutral default,
    /// which is still an improvement on a status code.
    func test_aBadTitleWithNoUsablePreviewFallsBackToTheNeutralDefault() {
        XCTAssertEqual(ChatThreadStore.repairedTitle(
            for: entry(title: "HTTP 500", messages: 2, preview: nil)),
                       ChatTitleHygiene.neutralDefault)
    }

    func test_repairIsIdempotent() {
        let once = ChatThreadStore.repairedTitle(
            for: entry(title: "Rate limited (HTTP 429)", messages: 3, preview: "what time is it"))
        let repairedEntry = entry(title: try! XCTUnwrap(once), messages: 3, preview: "what time is it")
        XCTAssertNil(ChatThreadStore.repairedTitle(for: repairedEntry),
                     "the repair pass renames the same thread on every launch")
    }
}
