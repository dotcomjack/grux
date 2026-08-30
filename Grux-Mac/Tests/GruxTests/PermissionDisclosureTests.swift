import XCTest

/// The macOS permission prompt is the ONE sentence a user reads while deciding
/// whether to hand an app their microphone, and macOS shows it exactly once.
/// Whatever the app does with that grant afterwards, it never asks again.
///
/// So the string has to describe every use, not the most flattering one. This
/// suite asserts that: if the tree contains code that captures continuously,
/// the microphone string must say so.
///
/// Written after the audit found `NSMicrophoneUsageDescription` reading "so you
/// can dictate messages and voice commands in chat" while `AmbientListener`
/// installs a permanent tap on the input node and the product is marketed on
/// hearing your meetings. Both halves were true; the prompt only mentioned one.
final class PermissionDisclosureTests: XCTestCase {

    /// Repo root from this file's own path, so the test works from any working
    /// directory and from Xcode as well as the command line.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
    }

    private static func infoPlist() throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        guard let d = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            throw XCTSkip("Info.plist did not parse as a dictionary")
        }
        return d
    }

    private func usage(_ key: String) throws -> String {
        let d = try Self.infoPlist()
        guard let s = d[key] as? String, !s.isEmpty else {
            XCTFail("\(key) is missing or empty; macOS shows a blank prompt")
            return ""
        }
        return s
    }

    // MARK: - the invariant

    /// The app captures continuously (`AmbientListener` installs a tap on the
    /// AVAudioEngine input node), so the prompt must disclose continuous
    /// listening. This asserts the LINK, not a fixed sentence: if the
    /// continuous-capture code is ever removed, the requirement lifts with it.
    func testMicrophoneStringDisclosesContinuousListeningWhileTheCodeExists() throws {
        let listener = Self.repoRoot()
            .appendingPathComponent("Sources/Grux/Ambient/AmbientListener.swift")
        let src = (try? String(contentsOf: listener, encoding: .utf8)) ?? ""
        let capturesContinuously = src.contains("installTap") && src.contains("inputNode")

        try XCTSkipUnless(capturesContinuously,
                          "no continuous mic capture in the tree, so the disclosure is not required")

        let raw = try usage("NSMicrophoneUsageDescription")
        let text = raw.lowercased()
        let discloses = ["continuous", "continuously", "always on", "ambient"]
            .contains { text.contains($0) }
        XCTAssertTrue(discloses,
            "AmbientListener installs a permanent tap on the microphone input node, but "
            + "NSMicrophoneUsageDescription does not disclose continuous listening. macOS "
            + "shows this string once and never asks again.\nGot: \(raw)")
    }

    /// Disclosing continuous capture without saying it is optional would be
    /// accurate and still alarming. The default IS off (`ambientEnabled` and
    /// `wakeWordEnabled` both default false, `ambientMode` defaults to `.wake`),
    /// so the prompt is allowed to say so, and should.
    func testMicrophoneStringSaysContinuousListeningIsOptional() throws {
        let text = try usage("NSMicrophoneUsageDescription").lowercased()
        let optional = ["off by default", "turn it on", "if you turn", "you can turn", "opt in"]
            .contains { text.contains($0) }
        XCTAssertTrue(optional,
            "the string discloses continuous listening but not that it is off by default, "
            + "which reads as more invasive than the app actually is")
    }

    /// The claim that audio stays on the device is the single most load-bearing
    /// sentence in the prompt and the whole reason the app is native. If it is
    /// made, it has to be made; this test exists so that removing on-device
    /// transcription forces someone to confront the promise.
    func testLocalOnlyClaimIsBackedByOnDeviceTranscription() throws {
        let text = try usage("NSMicrophoneUsageDescription").lowercased()
        let claimsLocal = ["never uploaded", "on this mac", "locally", "on-device", "on device"]
            .contains { text.contains($0) }
        try XCTSkipUnless(claimsLocal, "the string makes no locality claim, nothing to back")

        // WhisperKit is the on-device engine. Package.swift is the honest place
        // to check: a dependency cannot be faked by a comment.
        let pkg = try String(contentsOf: Self.repoRoot().appendingPathComponent("Package.swift"),
                             encoding: .utf8)
        XCTAssertTrue(pkg.contains("WhisperKit"),
            "the microphone prompt claims audio is transcribed on this Mac, but WhisperKit "
            + "is no longer a dependency. Either restore on-device transcription or stop "
            + "making the claim.")
    }

    /// Every usage string macOS can surface must be non-empty and specific. A
    /// one-word string is worse than none: it looks deliberate.
    func testEveryUsageStringIsPresentAndSubstantive() throws {
        let d = try Self.infoPlist()
        let keys = d.keys.filter { $0.hasSuffix("UsageDescription") }
        XCTAssertFalse(keys.isEmpty, "no usage descriptions found; the plist path is wrong")
        for k in keys {
            let s = (d[k] as? String) ?? ""
            XCTAssertGreaterThan(s.count, 25, "\(k) is too terse to be meaningful: \"\(s)\"")
            XCTAssertTrue(s.hasSuffix("."), "\(k) should read as a sentence: \"\(s)\"")
        }
    }

    /// The bundle id is part of this suite's concern because macOS keys every
    /// TCC grant to it: change the id and every permission above is revoked.
    func testBundleIdentifierIsTheCurrentOne() throws {
        let d = try Self.infoPlist()
        XCTAssertEqual(d["CFBundleIdentifier"] as? String, "com.gruxai.grux")
    }
}
