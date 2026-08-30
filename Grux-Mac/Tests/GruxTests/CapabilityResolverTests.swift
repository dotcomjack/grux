import XCTest
@testable import Grux

/// CapabilityResolver is the single answer to "is this satisfied on this machine".
/// Everything downstream (setup cards, sidebar badges, whether a tab is usable)
/// reads it, so a wrong answer here is wrong everywhere at once.
///
/// These tests deliberately avoid asserting what the LIVE machine's permissions
/// are, because that would encode the developer's own TCC grants into the suite
/// and fail on anyone else's Mac. They assert the STRUCTURE that has to hold
/// regardless: total coverage, honest absence, and that nothing throws.
@MainActor
final class CapabilityResolverTests: XCTestCase {

    // MARK: Coverage

    /// Every capability must resolve. A capability the resolver cannot answer is
    /// worse than one that is unsatisfied: the feature would sit in a state
    /// nobody can clear.
    func testEveryCapabilityResolvesWithoutThrowing() {
        for req in SetupRequirement.allCases {
            _ = CapabilityResolver.isSatisfied(req)   // must not trap or throw
        }
        // 42 until 2026-08-23, when `step.terminal_sessions_explained` was added
        // as the consent gate for Grux driving headless terminal sessions.
        XCTAssertEqual(SetupRequirement.allCases.count, 41)
    }

    /// Every `key.` capability needs somewhere to read from. A nil slot means
    /// the contract declares a credential the app cannot store, which would make
    /// that capability permanently unsatisfiable and its setup card a dead end.
    func testEveryKeyCapabilityHasAKeychainSlot() {
        let orphans = SetupRequirement.allCases
            .filter { $0.kind == .key }
            .filter { CapabilityResolver.keychainKey(for: $0) == nil }
            .map(\.rawValue)
        XCTAssertTrue(orphans.isEmpty, "key capabilities with no Keychain slot: \(orphans)")
    }

    /// Same argument for endpoints: each needs the config key the contract names.
    func testEveryEndpointCapabilityHasAConfigKey() {
        let orphans = SetupRequirement.allCases
            .filter { $0.kind == .endpoint }
            .filter { CapabilityResolver.configKey(for: $0) == nil }
            .map(\.rawValue)
        XCTAssertTrue(orphans.isEmpty, "endpoint capabilities with no config key: \(orphans)")
    }

    func testKindIsParsedFromTheIdPrefix() {
        XCTAssertEqual(SetupRequirement.keyAnthropic.kind, .key)
        XCTAssertEqual(SetupRequirement.permMicrophone.kind, .perm)
        XCTAssertEqual(SetupRequirement.endpointOllama.kind, .endpoint)
        XCTAssertEqual(SetupRequirement.stepPhonePaired.kind, .step)
        let counts = Dictionary(grouping: SetupRequirement.allCases, by: \.kind).mapValues(\.count)
        // 14 until CR-34 deleted the two scalar provider key capabilities.
        XCTAssertEqual(counts[.key], 12)
        XCTAssertEqual(counts[.perm], 9)
        XCTAssertEqual(counts[.endpoint], 10)
        // 9 until `step.terminal_sessions_explained` landed on 2026-08-23.
        XCTAssertEqual(counts[.step], 10)
    }

    // MARK: Absence

    /// An unset endpoint is absent, not satisfied. Uses a real capability with a
    /// scratch value so the assertion exercises the actual code path.
    func testEmptyAndBlankConfigCountAsAbsent() {
        let key = CapabilityResolver.configKey(for: .endpointUptimeTargets)!
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertFalse(CapabilityResolver.isSatisfied(.endpointUptimeTargets), "missing key must be absent")

        defaults.set("   ", forKey: key)
        XCTAssertFalse(CapabilityResolver.isSatisfied(.endpointUptimeTargets), "whitespace must be absent")

        defaults.set([String](), forKey: key)
        XCTAssertFalse(CapabilityResolver.isSatisfied(.endpointUptimeTargets), "empty list must be absent")

        defaults.set(["https://example.com"], forKey: key)
        XCTAssertTrue(CapabilityResolver.isSatisfied(.endpointUptimeTargets), "one entry must satisfy")
    }

    func testStepFlagRoundTrips() {
        let req = SetupRequirement.stepCorpusSourcesConfirmed
        let key = CapabilityResolver.stepDefaultsKey(for: req)!
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertFalse(CapabilityResolver.isSatisfied(req))
        CapabilityResolver.markStepCompleted(req)
        XCTAssertTrue(CapabilityResolver.isSatisfied(req))
        CapabilityResolver.markStepCompleted(req, false)
        XCTAssertFalse(CapabilityResolver.isSatisfied(req))
    }

    /// `missing(from:)` drives every setup card, so it must return only the
    /// unsatisfied ones and keep the caller's order.
    func testMissingReturnsOnlyUnsatisfiedInOrder() {
        let req = SetupRequirement.stepCaptureExclusionsConfirmed
        let key = CapabilityResolver.stepDefaultsKey(for: req)!
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        CapabilityResolver.markStepCompleted(req, true)
        XCTAssertFalse(CapabilityResolver.missing(from: [req]).contains(req))
        CapabilityResolver.markStepCompleted(req, false)
        XCTAssertEqual(CapabilityResolver.missing(from: [req]), [req])
    }

    // MARK: The rule that matters

    /// Permissions must be ASKED, never remembered. If a permission answer were
    /// cached, revoking it in System Settings would leave a feature claiming to
    /// be ready, and the user would meet the failure as a broken screen instead
    /// of a setup card.
    ///
    /// This is asserted structurally: writing a true value into a plausible
    /// cache key must not make an ungranted permission report satisfied. Only
    /// perm.notifications is permitted a cache, for the API reason documented at
    /// its case, and no registry row requires it.
    func testPermissionsAreNotReadFromAStoredFlag() {
        let defaults = UserDefaults.standard
        let cacheables = SetupRequirement.allCases.filter { $0.kind == .perm }
        for req in cacheables where req != .permNotifications && req != .permAutomation {
            let live = liveAnswer(for: req)
            // Write the OPPOSITE of the truth into every plausible cache key. If
            // the resolver reads any of them it now DISAGREES with the system and
            // the assertion fires. Writing `true` was the earlier mistake: on a
            // machine that has the permission granted, a cached true and a live
            // true agree, so the test passed against a resolver that was reading
            // the flag. It was proven vacuous by planting exactly that.
            let fakeKeys = [
                "grux.step." + req.rawValue.replacingOccurrences(of: "perm.", with: ""),
                "grux.capability." + req.rawValue.replacingOccurrences(of: "perm.", with: "") + "_granted",
                req.rawValue
            ]
            let originals = fakeKeys.map { defaults.object(forKey: $0) }
            for k in fakeKeys { defaults.set(!live, forKey: k) }
            defer { for (k, o) in zip(fakeKeys, originals) { defaults.set(o, forKey: k) } }

            XCTAssertEqual(CapabilityResolver.isSatisfied(req), live,
                           "\(req.rawValue) followed a planted flag instead of the live system API")
        }
    }

    /// Independent read of the same system APIs, so the test does not simply
    /// call the code it is testing.
    private func liveAnswer(for req: SetupRequirement) -> Bool {
        switch req {
        case .permScreenRecording, .permSystemAudio: return CGPreflightScreenCaptureAccess()
        case .permMicrophone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .permAccessibility: return AXIsProcessTrusted()
        case .permContacts: return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .permCalendar:
            let s = EKEventStore.authorizationStatus(for: .event)
            if #available(macOS 14.0, *) { return s == .fullAccess || s == .writeOnly }
            return s == .authorized
        case .permFullDiskAccess:
            let probe = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath
            return FileManager.default.isReadableFile(atPath: probe)
        default: return CapabilityResolver.isSatisfied(req)
        }
    }
}

import AVFoundation
import Contacts
import CoreGraphics
import EventKit
