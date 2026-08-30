import XCTest

/// The release path in `build.sh`, asserted as text because there is no way to
/// unit test a shell script's Apple interactions and the cost of it being wrong
/// is discovering it on launch morning.
///
/// It WAS wrong. `GRUX_NOTARIZE=1` zipped the app and uploaded it to notarytool
/// without ever changing the signing certificate, and Apple notarizes only
/// Developer ID signed code. So the release path was a guaranteed rejection and
/// nobody had run it. Measured on the dev build: `spctl -a` returns "rejected"
/// and `stapler validate` reports no ticket, which is what a stranger's Mac
/// concludes on download.
///
/// A `Developer ID Application` certificate was installed the whole time. The
/// script simply pinned the Apple Development one, for a good reason (TCC grants
/// are keyed to the signing identity, so holding it stable stops three
/// permissions re-prompting on every rebuild) that happens to be the opposite of
/// what distribution needs.
final class ReleaseSigningPathTests: XCTestCase {

    private static func buildScript() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .appendingPathComponent("build.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The release identity must be resolved by NAME, not pinned by hash.
    /// Certificates rotate; a pinned Developer ID hash would silently fall back
    /// to ad-hoc signing the day it expires, and ad-hoc cannot be notarized
    /// either.
    func testReleaseModeSelectsDeveloperIDByName() throws {
        let s = try Self.buildScript()
        XCTAssertTrue(s.contains("GRUX_RELEASE"),
                      "build.sh has no release mode, so every build is dev-signed")
        XCTAssertTrue(s.contains("Developer ID Application"),
                      "release mode does not select a Developer ID certificate, which is the "
                      + "only kind Apple will notarize")
    }

    /// Notarizing a dev-signed build is a guaranteed rejection, so the script
    /// must refuse rather than spend a round trip discovering it.
    ///
    /// Asserts the GUARD CONDITION, not the presence of a token. The first
    /// version searched 900 characters after the first "GRUX_NOTARIZE" for the
    /// substring "GRUX_RELEASE" and passed when the guard was replaced with
    /// `if false`, because the FATAL message text below it also contains
    /// "GRUX_RELEASE", and because the first match was in a comment so the window
    /// covered the wrong block entirely. Mutation testing caught it.
    func testNotarizeRefusesWithoutReleaseMode() throws {
        let s = try Self.buildScript()
        XCTAssertTrue(s.contains(#"if [[ "${GRUX_RELEASE:-0}" != "1" ]]; then"#),
            "the notarize path no longer refuses a non-release build, so it can upload an "
            + "Apple-Development-signed app that Apple rejects on sight")
    }

    /// Credentials must be checked before the upload, not discovered by a
    /// confusing notarytool error.
    func testNotarizeChecksItsCredentialsFirst() throws {
        let s = try Self.buildScript()
        for v in ["APPLE_ID", "APPLE_APP_PASSWORD", "APPLE_TEAM_ID"] {
            XCTAssertTrue(s.contains(v), "build.sh never references \(v)")
        }
    }

    /// The only check that speaks for a stranger's Mac. A stapled ticket that
    /// Gatekeeper still rejects is not a shippable build, and stapler exiting 0
    /// does not prove Gatekeeper agrees.
    ///
    /// Anchored INSIDE the notarize block, after the upload. `spctl -a` appears
    /// three times in this script, so a bare `contains` passed even with the
    /// real check removed. Mutation testing caught that too.
    func testReleaseVerifiesWithGatekeeperNotJustStapler() throws {
        let s = try Self.buildScript()
        guard let submit = s.range(of: "notarytool submit") else {
            return XCTFail("build.sh no longer submits for notarization")
        }
        let afterUpload = String(s[submit.upperBound...])
        XCTAssertTrue(afterUpload.contains("spctl -a"),
            "nothing asks Gatekeeper whether it would open the notarized app. A stapled "
            + "ticket is not the same verdict, and Gatekeeper's is the only one a stranger's "
            + "Mac acts on.")
        XCTAssertTrue(afterUpload.contains("accepted"),
            "the Gatekeeper result is not checked for acceptance, so a rejection passes silently")
    }

    /// A release build must not overwrite the dev install. The identities differ,
    /// so installing one revokes the other's TCC grants, and a release build
    /// would silently cost three permission re-grants.
    ///
    /// Asserts the ORDER of two anchors rather than a character distance. The
    /// first version required `exit 0` within 700 characters of
    /// `Grux-release.app`, which is a proxy for the real invariant and a brittle
    /// one: adding an xattr repair step and its rationale to the release block
    /// pushed `exit 0` past the cutoff and failed this test while the script
    /// still could not reach the install. Measured at the time:
    /// `/Applications/Grux.app` was still signed Apple Development after a
    /// release build, so the behaviour was right and the ruler was wrong.
    ///
    /// A window is also weaker than it looks in the other direction. It passes on
    /// any `exit 0` in range, including one belonging to a different branch.
    func testReleaseBuildDoesNotInstallOverTheDevApp() throws {
        let s = try Self.buildScript()
        guard let release = s.range(of: "Grux-release.app") else {
            return XCTFail("release mode no longer diverts the artifact away from /Applications")
        }
        guard let install = s.range(of: "cp -R \"$APP\" /Applications/") else {
            return XCTFail("the /Applications install moved, so this guard no longer "
                           + "watches the thing a release build must not reach")
        }
        XCTAssertLessThan(release.lowerBound, install.lowerBound,
            "the release branch now sits AFTER the install, so ordering proves nothing")

        let between = String(s[release.upperBound..<install.lowerBound])
        XCTAssertTrue(between.contains("exit 0"),
            "release mode falls through into the /Applications install, which revokes the dev "
            + "install's TCC grants on every release build. Nothing between the release artifact "
            + "and `cp -R \"$APP\" /Applications/` exits the script.")
    }

    /// The artifact the script hands over is the one it must verify, and it must
    /// not be handed into a folder that undoes the verification.
    ///
    /// Staging happens in /tmp precisely because iCloud and Finder attach xattrs
    /// that codesign refuses. The delivery then went to ~/Desktop, which on a Mac
    /// with Desktop and Documents syncing is exactly such a folder. Measured on a
    /// real release run: the stage had 0 xattrs and passed --strict, the delivered
    /// copy had com.apple.FinderInfo reapplied by the fileprovider FASTER than the
    /// `xattr -cr` above it could clear it, and the script exited FATAL on its last
    /// line after a successful notarization. Losing a good build to the copy is the
    /// most expensive place to fail.
    ///
    /// So two things are pinned now. The destination is not a synced folder, and
    /// the STAGE is what gets verified fatally, because the stage is what the
    /// shippable zip is cut from and what Apple actually notarized.
    func testReleaseVerifiesTheDeliveredArtifactStrictly() throws {
        let s = try Self.buildScript()
        guard let out = s.range(of: "OUT=\"$HOME/"),
              let ditto = s.range(of: "ditto \"$APP\" \"$OUT\"") else {
            return XCTFail("the release delivery step moved, so this guard is watching nothing")
        }
        XCTAssertLessThan(out.lowerBound, ditto.lowerBound)

        let dest = String(s[out.lowerBound..<s.index(out.lowerBound, offsetBy: 60)])
        XCTAssertFalse(dest.contains("Desktop") || dest.contains("Documents"), """
            the release is delivered into a folder covered by Desktop and Documents syncing.             The fileprovider reapplies com.apple.FinderInfo there faster than xattr -cr clears             it, and codesign --strict then fails on the delivered copy after a successful             notarization.
            """)

        let after = String(s[ditto.upperBound...])
        XCTAssertTrue(after.contains("xattr -cr \"$OUT\""),
            "nothing strips xattrs at the DESTINATION.")
        XCTAssertTrue(after.contains("--strict") && after.contains("\"$APP\""), """
            the STAGE is never verified with --strict. It is the artifact of record: the zip             is cut from it and Apple notarized it, so it is the one whose failure must stop             the build. Plain --verify passes on a bundle carrying disallowed xattrs, which is             how this class of defect hides.
            """)
    }

    /// Hardened runtime and a secure timestamp are both notarization
    /// requirements, so losing either turns into an Apple rejection rather than
    /// a local failure.
    func testSigningKeepsHardenedRuntimeAndTimestamp() throws {
        let s = try Self.buildScript()
        XCTAssertTrue(s.contains("--options runtime"), "hardened runtime is required to notarize")
        XCTAssertTrue(s.contains("--timestamp \""), "a secure timestamp is required to notarize")
    }
}
