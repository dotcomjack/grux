import XCTest
@testable import Grux

/// What GruxPhone's Info.plist claims must match what the app actually does.
///
/// The phone declared `UIBackgroundModes: location` plus both
/// `NSLocationWhenInUseUsageDescription` and
/// `NSLocationAlwaysAndWhenInUseUsageDescription`, while `LocationService` had no
/// callers anywhere in the repository. No authorization was ever requested and
/// `startUpdatingLocation` was never reached, which the service records itself:
/// `allowsBackgroundLocationUpdates = false  // opt-in later`.
///
/// Two costs, and the second is the one that matters for an open source release.
/// Declaring a background mode the app does not use is an App Store rejection
/// trigger. And a stranger who opens Info.plist sees background location with
/// always-authorization and reasonably concludes the app tracks them. It does not.
/// The declaration was false in the frightening direction, which is the worst
/// direction for a privacy claim to be false in.
///
/// This guard is BIDIRECTIONAL on purpose. It does not simply assert the keys are
/// absent, which would become wrong the day somebody wires the service up and
/// would then be deleted rather than fixed. It asserts the plist AGREES with the
/// code, in whichever direction the code goes.
final class PhoneDeclarationsMatchBehaviourTests: XCTestCase {

    private func phoneRoot() throws -> URL {
        let root = NoPersonalIdentityTests.phoneRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("GruxPhone is absent, so nothing here runs")
        }
        return root
    }

    /// True when any file other than LocationService itself mentions it, which is
    /// the cheapest honest proxy for "something starts location updates".
    private func locationServiceHasCallers() throws -> Bool {
        let root = try phoneRoot()
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return false }
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            if (rel as NSString).lastPathComponent == "LocationService.swift" { continue }
            let text = (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            // Comments stripped: a comment explaining why location is unwired must
            // not read as a caller and flip this guard's expectation.
            var code: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if let r = line.range(of: "//") {
                    code.append(String(line[line.startIndex..<r.lowerBound]))
                } else {
                    code.append(String(line))
                }
            }
            if code.joined(separator: "\n").contains("LocationService") { return true }
        }
        return false
    }

    private func infoPlist() throws -> [String: Any] {
        let url = try phoneRoot().appendingPathComponent("GruxPhone/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist is not a dictionary")
    }

    func testLocationDeclarationsMatchWhetherLocationIsActuallyUsed() throws {
        let used = try locationServiceHasCallers()
        let plist = try infoPlist()
        let modes = plist["UIBackgroundModes"] as? [String] ?? []
        let hasBackgroundLocation = modes.contains("location")
        let whenInUse = plist["NSLocationWhenInUseUsageDescription"] != nil
        let always = plist["NSLocationAlwaysAndWhenInUseUsageDescription"] != nil

        if used {
            XCTAssertTrue(whenInUse, """
                Something now calls LocationService, so the app will request location
                authorization, and iOS traps immediately when the matching usage
                description is missing. Add NSLocationWhenInUseUsageDescription to
                project.yml, and NSLocationAlwaysAndWhenInUse... only if the code really
                asks for always. Add the background mode only if it really needs one.
                """)
        } else {
            XCTAssertFalse(hasBackgroundLocation, """
                Info.plist declares the `location` background mode while nothing in the
                app calls LocationService. That is an App Store rejection trigger, and in
                an open source release it tells every reader the app tracks them in the
                background when it does not.
                """)
            XCTAssertFalse(whenInUse || always, """
                Info.plist carries a location usage description while nothing requests
                location authorization. The string is shown to nobody and reads as a
                capability the app does not have.
                """)
        }
    }

    /// Guards the premise. If LocationService is deleted outright this fails, which
    /// is the prompt to delete this test with it rather than leave a guard watching
    /// a file that no longer exists and passing vacuously forever.
    func testLocationServiceStillExists() throws {
        let url = try phoneRoot().appendingPathComponent("GruxPhone/LocationService.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), """
            LocationService.swift is gone. If location was removed for good, delete the
            0x11 LOCATION frame and LocationPayload from both PhoneProtocol files too,
            and delete this test. If it moved, repoint this.
            """)
    }

    /// The audio background mode IS real and must not be collateral damage. The
    /// whole point of the phone is a mic that keeps streaming while the screen is
    /// off, so losing this would silently break the product's one job.
    func testTheAudioBackgroundModeSurvives() throws {
        let modes = try infoPlist()["UIBackgroundModes"] as? [String] ?? []
        XCTAssertTrue(modes.contains("audio"),
            "the audio background mode is gone, so the phone stops capturing the moment "
            + "the screen locks, which is the one thing it exists to do")
    }
}
