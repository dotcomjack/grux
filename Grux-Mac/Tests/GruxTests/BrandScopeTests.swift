import XCTest
@testable import Grux

/// Covers the app-wide brand filter (approved UI/UX decision 3) after the brand
/// vocabulary moved out of the binary and into the user's own
/// `~/.grux/brands.json`.
///
/// ## Why nothing here names a brand
///
/// The old version of this file asserted on three hardcoded enum cases named
/// after the original owner's companies, which is the same defect the production
/// code had: one person's businesses compiled in. Worse, it would have made the
/// suite pass or fail depending on
/// whether a config file happened to exist on the machine running it. So every
/// test below constructs its own throwaway ids and exercises the MECHANISM:
/// what a token matches, what an unreadable one degrades to, and that an
/// already-persisted token still decodes.
///
/// `BrandScope(id:)` is the roster-free initializer used throughout. The
/// roster-checked `init?(rawValue:)` is only exercised for its negative case,
/// with an id no roster could ever contain.
final class BrandScopeTests: XCTestCase {

    // A token no `~/.grux/brands.json` can hold, so a test that must be
    // unconfigured stays unconfigured on the author's own machine too.
    private func unknownToken() -> String { "not-a-brand-\(UUID().uuidString)" }

    // MARK: - Matching

    func testAllMatchesEveryVoice() {
        for voice in ["acme", "globex", "Initech", "anything at all", ""] {
            XCTAssertTrue(BrandScope.all.matches(voice: voice), "all should match \(voice)")
        }
    }

    func testScopeMatchesItsOwnVoiceAndNoOther() {
        let acme = BrandScope(id: "acme")
        XCTAssertTrue(acme.matches(voice: "acme"))
        XCTAssertFalse(acme.matches(voice: "globex"))
        XCTAssertFalse(acme.matches(voice: ""))
    }

    func testMatchIsCaseInsensitiveOnBothSides() {
        XCTAssertTrue(BrandScope(id: "AcMe").matches(voice: "acme"))
        XCTAssertTrue(BrandScope(id: "acme").matches(voice: "ACME"))
        XCTAssertTrue(BrandScope(id: "acme").matches(voice: "  Acme  "))
    }

    // MARK: - Degrading

    func testBlankTokenDegradesToAll() {
        // A filter with no selection would render as nothing highlighted and
        // every surface filtered to zero rows, with no visible cause.
        XCTAssertEqual(BrandScope(id: ""), .all)
        XCTAssertEqual(BrandScope(id: "   "), .all)
    }

    func testUnknownTokenIsNotSelectableButStillConstructs() {
        let token = unknownToken()
        // Roster-checked: names nothing this install has.
        XCTAssertNil(BrandScope(rawValue: token))
        // Roster-free: still constructs, so a persisted tag survives.
        XCTAssertEqual(BrandScope(id: token).rawValue, token.lowercased())
    }

    // MARK: - The empty roster

    func testAllIsAlwaysSelectableSoTheBarIsNeverEmpty() {
        // With no brands.json this is exactly ["All"], which is the intended
        // needs-setup state. The assertion holds either way: nothing downstream
        // may divide by zero or force-unwrap a first element.
        XCTAssertFalse(BrandScope.selectable.isEmpty)
        XCTAssertEqual(BrandScope.selectable.first, .all)
        XCTAssertTrue(BrandScope.selectable.contains(.all))
    }

    func testConfiguredNeverContainsTheAllSentinel() {
        // A brand id of "all" would silently match every other brand's mail, so
        // the roster drops it. `configured` is what callers reach for when they
        // need ONE concrete brand, and it must never hand back the sentinel.
        XCTAssertFalse(BrandScope.configured.contains(.all))
    }

    func testAllIsSelectableEvenWithNoRoster() {
        // The one token that must resolve on a machine that has never been
        // configured, because it is the default and the only way back.
        XCTAssertEqual(BrandScope(rawValue: BrandScope.allToken), .all)
    }

    // MARK: - Persistence compatibility

    func testDecodesTheBareStringTheEnumUsedToWrite() throws {
        // `~/.grux/jax/brand-filter.json` literally contains `"all"`. The enum
        // encoded its raw value as a bare JSON string and the struct must keep
        // doing that, or the migration needs a backfill it does not have.
        let decoded = try JSONDecoder().decode(BrandScope.self, from: Data("\"acme\"".utf8))
        XCTAssertEqual(decoded.rawValue, "acme")
        XCTAssertEqual(try JSONDecoder().decode(BrandScope.self, from: Data("\"all\"".utf8)), .all)
    }

    func testEncodesBackToTheSameBareString() throws {
        let data = try JSONEncoder().encode(BrandScope(id: "acme"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"acme\"")
    }

    func testRoundTripsThroughJSON() throws {
        for token in ["all", "acme", "globex"] {
            let scope = BrandScope(id: token)
            let back = try JSONDecoder().decode(BrandScope.self, from: JSONEncoder().encode(scope))
            XCTAssertEqual(back, scope)
        }
    }

    func testDecodingDoesNotConsultTheRoster() throws {
        // The load-bearing property. A token from a build whose roster has since
        // changed, or from a brand the user removed, must decode rather than
        // throw: it rides inside larger persisted documents.
        let token = unknownToken()
        XCTAssertNil(BrandScope(rawValue: token), "precondition: token must be unconfigured")
        let json = Data("\"\(token)\"".utf8)
        XCTAssertEqual(try JSONDecoder().decode(BrandScope.self, from: json).rawValue,
                       token.lowercased())
    }

    func testAMalformedTokenDegradesInsteadOfThrowing() throws {
        // A number where a string belongs. Throwing here would take the whole
        // enclosing file down, so it degrades to the match-everything default.
        let decoded = try JSONDecoder().decode([BrandScope].self, from: Data("[\"acme\", 42, \"\"]".utf8))
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].rawValue, "acme")
        XCTAssertEqual(decoded[1], .all)
        XCTAssertEqual(decoded[2], .all)
    }
}

/// The same mechanism on the mail side, where the stakes are higher: the inbox
/// token is persisted on every draft in `~/.grux/support/drafts.json`, and that
/// file is decoded as one array. A single token that threw would lose every
/// staged reply the user has waiting, which is why decoding degrades.
final class SupportInboxTokenTests: XCTestCase {

    private func unknownToken() -> String { "not-an-inbox-\(UUID().uuidString)" }

    func testDecodesTheBareStringTheEnumUsedToWrite() throws {
        let decoded = try JSONDecoder().decode(SupportInbox.self, from: Data("\"acme\"".utf8))
        XCTAssertEqual(decoded.rawValue, "acme")
        XCTAssertEqual(decoded.id, "acme")
    }

    func testEncodesBackToTheSameBareString() throws {
        let data = try JSONEncoder().encode(SupportInbox(id: "acme"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"acme\"")
    }

    func testOneBadTokenDoesNotTakeTheWholeArrayDown() throws {
        // The drafts file, in miniature: three records, one of them unreadable.
        let decoded = try JSONDecoder().decode([SupportInbox].self,
                                               from: Data("[\"acme\", 42, \"globex\"]".utf8))
        XCTAssertEqual(decoded.count, 3, "a malformed token must not lose the other records")
        XCTAssertEqual(decoded[0].rawValue, "acme")
        XCTAssertTrue(decoded[1].rawValue.isEmpty, "unreadable degrades to a blank, unroutable inbox")
        XCTAssertEqual(decoded[2].rawValue, "globex")
    }

    func testDecodingDoesNotConsultTheRoster() throws {
        let token = unknownToken()
        XCTAssertNil(SupportInbox(rawValue: token), "precondition: token must be unconfigured")
        let decoded = try JSONDecoder().decode(SupportInbox.self, from: Data("\"\(token)\"".utf8))
        XCTAssertEqual(decoded.rawValue, token.lowercased())
    }

    func testAnUnconfiguredTokenIsNotRoutable() {
        // The failable initializer is what the account config and the CLI
        // trigger use, and it has to be able to say "not this install".
        XCTAssertNil(SupportInbox(rawValue: unknownToken()))
        XCTAssertNil(SupportInbox(rawValue: ""))
    }

    func testRosterIsSafeToReadWithNoConfiguration() {
        // Never crashes, never force-unwraps. On an unconfigured machine this is
        // empty and the hourly sweep sweeps nothing, which is the intended state.
        XCTAssertEqual(SupportInbox.roster.count, BrandRoster.supportInboxes.count)
        for inbox in SupportInbox.roster {
            XCTAssertFalse(inbox.rawValue.isEmpty, "a roster entry with a blank id must be dropped on load")
        }
    }
}

/// The roster file itself: how its two arrays reconcile, and what one hand-edit
/// slip does to the rest of the file.
///
/// Decodes `BrandRoster.Roster` directly instead of reading
/// `~/.grux/brands.json`, so these say the same thing on a machine that has a
/// roster and one that has never been configured.
final class BrandRosterFileTests: XCTestCase {

    private func roster(_ json: String) throws -> BrandRoster.Roster {
        try JSONDecoder().decode(BrandRoster.Roster.self, from: Data(json.utf8))
    }

    /// An inbox IS a brand. Listed without a matching `brands` entry it still
    /// swept mail and staged drafts, under a token the filter bar never offered,
    /// which put the reply rules and the unmute list for the one brand actually
    /// receiving mail out of reach of the app.
    func testAnInboxWithNoBrandEntryStillJoinsTheFilterVocabulary() throws {
        let r = try roster(#"{"supportInboxes":[{"id":"acme","label":"Acme"}]}"#)
        XCTAssertEqual(r.brands.map(\.id), ["acme"])
        XCTAssertEqual(r.supportInboxes.map(\.id), ["acme"])
    }

    /// Declared order is the filter bar's order, so folding appends and never
    /// reshuffles, and a brand named in both arrays appears once with the label
    /// it was declared under.
    func testFoldingKeepsDeclaredOrderAndDoesNotDuplicate() throws {
        let r = try roster(#"""
        {"brands":[{"id":"globex"},{"id":"acme","label":"Acme"}],
         "supportInboxes":[{"id":"acme","label":"Acme Support"},{"id":"initech"}]}
        """#)
        XCTAssertEqual(r.brands.map(\.id), ["globex", "acme", "initech"])
        XCTAssertEqual(r.brands.first { $0.id == "acme" }?.label, "Acme",
                       "the declared brand entry's label must win over the inbox's")
    }

    /// The fold runs one way only. A brand with no mailbox must never end up in
    /// the sweep roster, or the hourly triage tries to read mail for a brand
    /// that has no account behind it.
    func testFoldingNeverGivesABrandAMailbox() throws {
        let r = try roster(#"{"brands":[{"id":"acme"},{"id":"globex"}],"supportInboxes":[{"id":"acme"}]}"#)
        XCTAssertEqual(r.supportInboxes.map(\.id), ["acme"])
    }

    /// All or nothing, on purpose. `decodeIfPresent` returns nil for a missing
    /// key but THROWS on a present-but-wrong-typed one, so a single hand-edit
    /// slip takes the file down, and `BrandRoster.roster` turns that into an
    /// empty roster. Salvaging the other entries would half-load a roster, and
    /// salvaging this entry would drop a `bannedOffers` array, turning that
    /// brand's send guard off without saying so. Pinned as a test because the
    /// doc comment claimed the opposite until it was measured.
    func testATypeSlipInOneEntryTakesTheWholeFileRatherThanHalfLoading() {
        XCTAssertThrowsError(try roster(#"{"brands":[{"id":"acme","bannedOffers":"coupon"},{"id":"globex"}]}"#),
                             "a wrong-typed bannedOffers must not be silently salvaged")
        XCTAssertThrowsError(try roster(#"{"brands":[{"id":"acme","label":5}]}"#))
    }

    /// A null is not a type slip: an absent value and an explicit null both mean
    /// "not set", and that entry keeps loading with its defaults.
    func testAnExplicitNullIsTreatedAsAbsent() throws {
        let r = try roster(#"{"brands":[{"id":"acme","label":null},{"id":"globex"}]}"#)
        XCTAssertEqual(r.brands.map(\.id), ["acme", "globex"])
        XCTAssertEqual(r.brands.first?.label, "acme", "a blank label falls back to the id")
    }
}
