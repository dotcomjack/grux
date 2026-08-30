import XCTest
@testable import Grux

/// The domain monitor was the THIRD place in the app to render an unconfigured
/// capability as an error, after the Usage tab and the reactor. Its sentence read
/// "No GoDaddy credentials. Set goDaddyApiKey/goDaddyApiSecret in Keychain, drop
/// ~/.grux/godaddy-creds.json, or export GODADDY_API_KEY/SECRET", which offered a
/// stranger three routes they cannot take and named two internal storage slots to
/// take them with.
///
/// These tests hold the two properties that fix required, so the fourth instance
/// cannot be written by hand again.
@MainActor
final class DomainMonitorCapabilityTests: XCTestCase {

    private let envKey = "GODADDY_API_KEY"
    private let envSecret = "GODADDY_API_SECRET"

    override func tearDown() {
        unsetenv(envKey)
        unsetenv(envSecret)
        super.tearDown()
    }

    /// A credentials file on the machine running this makes the environment
    /// branch unmeasurable, because the check is an OR and the file arm answers
    /// first. Skip rather than pass, since passing here would be meaningless.
    private func requireNoCredentialsFile() throws {
        let path = NSHomeDirectory() + "/.grux/godaddy-creds.json"
        try XCTSkipIf(FileManager.default.fileExists(atPath: path),
                      "~/.grux/godaddy-creds.json exists on this machine, so the environment "
                      + "branch cannot be isolated here")
    }

    // MARK: - The registry must not call a working feature unconfigured

    /// The bug this prevents is subtle and would have looked like a correct
    /// build: `key.godaddy` resolves from the Keychain, the monitor also accepts
    /// environment variables, so an install configured that way would have shown
    /// a setup card over a domain sweep that works, and counted it in the
    /// sidebar as needing attention.
    func testEnvironmentCredentialsCountAsConfigured() throws {
        try requireNoCredentialsFile()
        unsetenv(envKey)
        unsetenv(envSecret)
        XCTAssertFalse(DomainMonitor.credentialsFoundOutsideKeychain(),
                       "with no file and no environment there is nothing outside the Keychain")

        setenv(envKey, "test-key", 1)
        setenv(envSecret, "test-secret", 1)
        XCTAssertTrue(DomainMonitor.credentialsFoundOutsideKeychain(),
                      "the monitor reads these, so the registry has to see them too")
    }

    /// Half a pair is not a credential. The monitor requires both, so the
    /// registry must not report satisfied on one.
    func testHalfAPairIsNotConfigured() throws {
        try requireNoCredentialsFile()
        setenv(envKey, "test-key", 1)
        unsetenv(envSecret)
        XCTAssertFalse(DomainMonitor.credentialsFoundOutsideKeychain(),
                       "a key with no secret cannot authenticate anything")

        unsetenv(envKey)
        setenv(envSecret, "test-secret", 1)
        XCTAssertFalse(DomainMonitor.credentialsFoundOutsideKeychain())
    }

    /// The resolver has to route through that check, not merely have it
    /// available. Asserting the helper alone would leave the wiring untested,
    /// which is how the registry would go on lying while a green test said
    /// otherwise.
    ///
    /// The guard is doing real work here, and skipping is the honest outcome
    /// rather than a weakness. `isSatisfied` returns true if EITHER the alternate
    /// source or the Keychain answers, so on a machine whose Keychain already
    /// holds a registrar key this assertion passes whether the wiring exists or
    /// not. That is precisely the vacuous shape this project has already shipped
    /// once, when a permission test wrote `true` into a cache key on a machine
    /// where the permission was granted and passed against the planted defect.
    /// A test that cannot fail is worse than a missing one, because it is
    /// counted.
    func testResolverHonoursTheAlternateSource() throws {
        try XCTSkipUnless(
            KeychainStore.get(.goDaddyApiKey).isEmpty,
            "a registrar key is in this machine's Keychain, so isSatisfied answers from the "
            + "Keychain arm and the alternate-source arm cannot be observed here"
        )
        // Whichever arm is available on this machine, the precondition is that
        // the helper says yes. Asserting it makes the skip above the only way
        // this test can be inconclusive.
        if !DomainMonitor.credentialsFoundOutsideKeychain() {
            setenv(envKey, "test-key", 1)
            setenv(envSecret, "test-secret", 1)
        }
        XCTAssertTrue(DomainMonitor.credentialsFoundOutsideKeychain(),
                      "precondition: something outside the Keychain must be readable")

        XCTAssertTrue(CapabilityResolver.isSatisfied(.keyGodaddy),
                      "the resolver must agree with the code that actually makes the request")
    }

    /// The precedence rule itself, verified on every machine including one whose
    /// Keychain is already full. This is the assertion the three skips above
    /// cannot make.
    ///
    /// The first case is the whole point: nothing in the Keychain, no companion,
    /// but the credential is readable elsewhere, so the feature works and the
    /// registry must not claim it needs setup.
    func testKeyPrecedenceRule() {
        XCTAssertTrue(CapabilityResolver.keyIsSatisfied(
            alternateSaysYes: true, keychainValue: "", companionSaysYes: nil),
            "a credential the app can already read is satisfied, whatever the Keychain says")

        // The alternate arm outranks a missing companion too. A pair sourced
        // from outside the Keychain arrives complete or not at all, so failing
        // it on an empty companion field would hide a working feature.
        XCTAssertTrue(CapabilityResolver.keyIsSatisfied(
            alternateSaysYes: true, keychainValue: "", companionSaysYes: false))

        // Without the alternate arm, an empty Keychain is unconfigured.
        XCTAssertFalse(CapabilityResolver.keyIsSatisfied(
            alternateSaysYes: false, keychainValue: "", companionSaysYes: nil))

        // Unpaired: the Keychain value alone settles it.
        XCTAssertTrue(CapabilityResolver.keyIsSatisfied(
            alternateSaysYes: false, keychainValue: "sk-live", companionSaysYes: nil))

        // Paired: half is not satisfied. This is the case that would have
        // dropped somebody holding one half of a two-part credential past the
        // setup card and into an empty tab.
        XCTAssertFalse(CapabilityResolver.keyIsSatisfied(
            alternateSaysYes: false, keychainValue: "key-live", companionSaysYes: false))
        XCTAssertTrue(CapabilityResolver.keyIsSatisfied(
            alternateSaysYes: false, keychainValue: "key-live", companionSaysYes: true))
    }

    /// Four capabilities have an alternate source. This is a containment test:
    /// the mechanism exists to describe a divergence that already existed, and it
    /// must not quietly become a general bypass around the Settings fields, which
    /// would hollow out the setup UI one convenience at a time.
    ///
    /// Three of the four are READERS and are legitimate. `endpoint.imap`,
    /// `endpoint.microsoft_graph` and `endpoint.ollama` are all cases where the
    /// contract names a config key that nothing in the app writes, while the real
    /// data sits somewhere the user populated themselves. The alternate teaches
    /// the resolver where the truth is. It reads; it creates nothing.
    ///
    /// `endpoint.ollama` joined them on 2026-08-17 and is worth naming, because it
    /// is the same defect as `endpoint.imap` and was found the same way, by reading
    /// the remediation against the code that answers it. The contract says "point
    /// Grux at your Ollama host in Settings"; that control writes
    /// `config.ollamaBaseURL`; the resolver was checking `config.localLLMEndpoint`,
    /// a DIFFERENT endpoint (the ambient companion proxy on 3849, not Ollama on
    /// 11434). Following the instruction exactly satisfied nothing. The alternate
    /// asks whether a server at the configured host actually answered discovery,
    /// deliberately NOT whether the field is non-empty, since it ships with a
    /// default and every install would read as configured.
    ///
    /// `key.godaddy` is NOT that shape and is a known defect, not a precedent.
    /// It reads a file and then WRITES those credentials into the Keychain, and
    /// the Settings Remove button only blanks the Keychain slot, so the file
    /// survives and the next sweep re-seeds it. The user performs the documented
    /// off action and the integration stays on. When that is removed this list
    /// drops back to two, and this test is the thing that will say so.
    ///
    /// Note the mechanism itself is governed ONLY here: the frozen contract has
    /// no concept of an alternate source. This assertion is the whole control.
    ///
    /// `endpoint.social_accounts` joined the list deliberately, not as a shortcut. Its
    /// config key `grux.social.accounts` has no writer anywhere in the app, so the step could
    /// be ticked green while every Social Ops surface stayed empty, and the real gate for the
    /// whole feature is ~/.grux/social-ops-hosts.txt, which the contract never mentioned.
    /// The remediation now names that file, and this teaches the resolver to read it. Same
    /// decision, and the same defect shape, as endpoint.imap directly below.
    func testAlternateSourcesStayContained() {
        let withAlternates = SetupRequirement.allCases.filter {
            CapabilityResolver.alternateSource(for: $0) != nil
        }
        // Contract order: keys, then permissions, then endpoints, then steps.
        XCTAssertEqual(withAlternates,
                       [.keyGodaddy, .endpointOllama, .endpointImap, .endpointSocialAccounts,
                        .endpointMicrosoftGraph],
                       "adding an alternate source is a decision about the setup contract, not a "
                       + "shortcut; got \(withAlternates.map(\.rawValue))")
    }

    /// Every alternate source must actually be REACHED by `isSatisfied`.
    ///
    /// `alternateSource` was wired into the `.key` branch only, so the one added
    /// for `endpoint.imap` compiled, read correctly and would never have been
    /// called. A capability whose alternate is unreachable is worse than one
    /// without: the code says the divergence is handled and the behaviour says
    /// it is not.
    func testEveryAlternateSourceIsReachableFromIsSatisfied() {
        for req in SetupRequirement.allCases
        where CapabilityResolver.alternateSource(for: req) != nil {
            let alt = CapabilityResolver.alternateSource(for: req)!
            guard alt() else { continue }   // cannot observe it on this machine
            XCTAssertTrue(CapabilityResolver.isSatisfied(req),
                          "\(req.rawValue) has an alternate source that says yes, but "
                          + "isSatisfied says no, so the branch never consults it")
        }
    }

    // MARK: - Unconfigured is a state, not a failure

    /// `needsSetup` and `lastError` are separate properties so that a single
    /// branch can never render both meanings again, and the section that reads
    /// them can be an exclusive chain.
    func testUnconfiguredAndFailedAreDistinctProperties() {
        let monitor = DomainMonitor.shared
        XCTAssertFalse(monitor.needsSetup && monitor.lastError != nil,
                       "unconfigured and failed are mutually exclusive states")
    }

    /// The remediation a person reads must come from the contract, and must not
    /// be the hand-written sentence that was there before.
    func testRemediationComesFromTheContractAndNamesNoInternals() {
        let remediation = SetupRequirement.keyGodaddy.remediation

        XCTAssertTrue(remediation.contains("Settings"),
                      "the reader needs somewhere to go; got: \(remediation)")
        for leak in ["goDaddyApiKey", "goDaddyApiSecret", "GODADDY_API_KEY",
                     "GODADDY_API_SECRET", "godaddy-creds.json", "Keychain", "export "] {
            XCTAssertFalse(remediation.contains(leak),
                           "'\(leak)' is an internal storage detail, not an instruction; "
                           + "got: \(remediation)")
        }
    }

    /// The registry row for the domain monitor has to exist, or the card the
    /// section now renders would fall back to "This feature" and list nothing.
    func testDomainMonitorHasARegistryRowThatNamesItsCredential() throws {
        let row = try XCTUnwrap(FeatureRegistry.row(forTab: "domains"),
                                "the Empire dashboard renders CapabilitySetupCard(featureKey: "
                                + "\"domains\"), which needs this row")
        XCTAssertTrue(row.requires.contains(.keyGodaddy),
                      "got \(row.requires.map(\.rawValue))")
    }
}
