import XCTest
@testable import Grux

/// D135 item 8 (sense pass 14). Settings, Data & Capabilities asked for the Brave
/// key and the Replicate token twice on one page: once in the generated
/// Credentials list and again in hand-written fields under "Real-time web
/// research" and "Media generation", whose Show button put the stored key on
/// screen, which the Credentials row never does. Each offered credential now has
/// one field, its Credentials row, and the sections name that row.
@MainActor
final class CapabilitiesAsksEachKeyOnceTests: XCTestCase {

    private func settingsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/SettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Keys SettingsView itself may write, each on a page with no Credentials list.
    private let ownFieldElsewhere: [KeychainStore.Key: String] = [
        .anthropicApiKey: "the Models page's key field",
        .elevenLabsApiKey: "the Voice page's key field",
    ]

    /// The class: a credential the Credentials list offers is written by that
    /// list only, never by a second hand-written field.
    func test_noHandWrittenFieldWritesAnOfferedCredential() throws {
        let source = try settingsSource()
        for req in FeatureRegistry.credentialsToOffer {
            guard let slot = CapabilityResolver.keychainKey(for: req), ownFieldElsewhere[slot] == nil else { continue }
            XCTAssertFalse(source.contains("KeychainStore.set(.\(slot), "),
                           "SettingsView writes \(slot) in its own field, so \(req.label) is asked for twice; "
                           + "the Credentials row is its one field")
        }
    }

    func test_theSectionsNameTheOneRow() throws {
        XCTAssertEqual(CapabilityCredentialsSection.keyLivesInCredentials(.keyBrave),
                       "Its key goes in Web search API key, under Credentials on this page.")
        XCTAssertEqual(CapabilityCredentialsSection.keyLivesInCredentials(.keyReplicate),
                       "Its token goes in Replicate API token, under Credentials on this page.")
        let source = try settingsSource()
        XCTAssertFalse(source.contains("Brave Search API key (above)"),
                       "the music line pointed at a field above that is gone")
    }
}

/// Wave 40 P2: with the Brave field gone, Music picking's web-first warning read the
/// Keychain inside the body and nothing redrew it, so saving the key in its
/// Credentials row left "Web-first needs a web search key" standing. A Keychain
/// write now announces itself and Settings follows it.
@MainActor
final class KeychainWriteAnnouncesItselfTests: XCTestCase {

    private func announced(_ key: KeychainStore.Key, by write: () -> Void) -> Bool {
        var seen = false
        let token = NotificationCenter.default.addObserver(forName: KeychainStore.didChange, object: nil,
                                                           queue: nil) { note in
            if (note.userInfo?[KeychainStore.changedKey] as? String) == key.rawValue { seen = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        write()
        return seen
    }

    func test_setAndDelete_announceTheKey() {
        XCTAssertTrue(announced(.braveApiKey) { _ = KeychainStore.set(.braveApiKey, "brv_test") })
        XCTAssertTrue(announced(.braveApiKey) { _ = KeychainStore.set(.braveApiKey, "") })
        XCTAssertTrue(announced(.braveApiKey) { _ = KeychainStore.delete(.braveApiKey) })
    }

    func test_settingsFollowsTheAnnouncement() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/SettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("publisher(for: KeychainStore.didChange)"),
                      "Settings no longer follows Keychain writes, so the web-first warning goes stale")
        XCTAssertFalse(source.contains("&& !CapabilityResolver.isSatisfied(.keyBrave)"),
                       "the warning reads the Keychain in the body, which nothing redraws")
    }
}
