import XCTest
@testable import Grux

/// D170 item 2: Settings, Credentials' Notion row says "Paste your Notion integration
/// secret in Settings, and the database you want Grux to write to" and had one field,
/// for the secret. Notion counts as connected only with both (`NotionClient.isConnected`),
/// so a person who pasted the secret there saw "set" and a Notion that never wrote.
/// The row now carries the database as its second field, read from what Notion
/// gives a person to copy: the database's link or its id.
@MainActor
final class NotionCredentialCompanionTests: XCTestCase {

    func test_theNotionRowAsksForTheDatabaseToo() throws {
        XCTAssertTrue(FeatureRegistry.credentialsToOffer.contains(.keyNotion), "the row this guards is no longer offered")
        let companion = try XCTUnwrap(CapabilityResolver.companion(for: .keyNotion),
                                      "the Notion row has one field while its line asks for two things")
        XCTAssertTrue(companion.title.contains("database"), companion.title)
    }

    func test_theDatabaseIsReadFromALinkOrAnId() {
        let id = "0123456789abcdef0123456789abcdef"
        let dashed = "01234567-89ab-cdef-0123-456789abcdef"
        XCTAssertEqual(CapabilityResolver.notionDatabaseId(from: id), id)
        XCTAssertEqual(CapabilityResolver.notionDatabaseId(from: "  \(dashed)\n"), id)
        XCTAssertEqual(CapabilityResolver.notionDatabaseId(from: dashed.uppercased()), id)
        // The link Notion copies: the view id after ?v= is also 32 hex and is not the database.
        XCTAssertEqual(CapabilityResolver.notionDatabaseId(
            from: "https://www.notion.so/myteam/Reading-list-\(id)?v=fedcba9876543210fedcba9876543210&pvs=4"), id)
        XCTAssertEqual(CapabilityResolver.notionDatabaseId(from: "https://www.notion.so/\(id)#heading"), id)
        // One under, one over, and not hex.
        XCTAssertNil(CapabilityResolver.notionDatabaseId(from: String(id.dropLast())))
        XCTAssertNil(CapabilityResolver.notionDatabaseId(from: id + "0"))
        XCTAssertNil(CapabilityResolver.notionDatabaseId(from: "0123456789abcdef0123456789abcdeg"))
        XCTAssertNil(CapabilityResolver.notionDatabaseId(from: "Reading list"))
        XCTAssertNil(CapabilityResolver.notionDatabaseId(from: ""))
    }

    /// W57-FIX P3 4: Integrations stored a pasted link as the id, which Credentials
    /// then counted as set while every Notion write failed; and its picker lost
    /// its checkmark for an id Credentials stored without dashes.
    func test_integrationsStoresTheSameIdAndKnowsItAgain() {
        let id = "0123456789abcdef0123456789abcdef"
        let dashed = "01234567-89ab-cdef-0123-456789abcdef"
        XCTAssertEqual(NotionClient.storedDatabaseId("https://www.notion.so/team/Tasks-\(id)?v=fedcba9876543210fedcba9876543210"), id)
        XCTAssertEqual(NotionClient.storedDatabaseId("  \(dashed) "), id)
        XCTAssertEqual(NotionClient.storedDatabaseId(""), "")
        XCTAssertEqual(NotionClient.storedDatabaseId(" not an id "), "not an id", "kept as typed, so verify says why it fails")
        XCTAssertTrue(NotionClient.sameDatabase(dashed, id))
        XCTAssertTrue(NotionClient.sameDatabase(id, id))
        XCTAssertFalse(NotionClient.sameDatabase(id, "fedcba9876543210fedcba9876543210"))
        XCTAssertFalse(NotionClient.sameDatabase("", ""))
    }
}
