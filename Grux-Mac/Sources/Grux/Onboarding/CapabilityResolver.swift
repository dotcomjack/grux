import AppKit
import AVFoundation
import Contacts
import CoreGraphics
import EventKit
import Foundation
import UserNotifications

/// Answers one question for every capability in the contract: is it satisfied on
/// THIS machine, right now.
///
/// The whole point is that nothing else in the app gets to decide. Before this
/// existed, every credential-gated surface hand-rolled its own check, and two of
/// the ones examined got it wrong in user-visible ways: Reactor printed a raw
/// provider payload, and Usage told the reader to run a `defaults write` command.
///
/// Three rules this file is built around.
///
/// **Permissions are asked, never remembered.** A permission is read from the
/// live system API on every call. Caching a granted permission is the defect
/// that matters here: a user who revokes Screen Recording in System Settings
/// would keep seeing a feature that claims to be ready, and would meet the
/// failure as a broken screen rather than as a setup card. The one exception is
/// documented at `permNotifications` and it is exceptional for an API reason,
/// not a convenience one.
///
/// **Absence is never an error.** Every path returns a Bool. Nothing throws,
/// nothing logs an alarm, nothing returns an optional the caller has to unwrap
/// into a failure. Contract section 3: a missing capability renders
/// `needs-setup` and never an error.
///
/// **Empty means not set.** Matching AppState's existing convention, a blank
/// credential is simply absent. No install ships with a value in any of these.
///
/// `@MainActor` because resolution reads main-actor state (AppState.config,
/// OnboardingModel) and because every caller is a SwiftUI view body, which is
/// already on the main actor. Making it nonisolated would only mean copying that
/// state somewhere it could go stale, which is the exact failure the first rule
/// above exists to prevent.
@MainActor
enum CapabilityResolver {

    // MARK: - Entry point

    static func isSatisfied(_ requirement: SetupRequirement) -> Bool {
        switch requirement.kind {
        case .key:
            return keyIsSatisfied(
                alternateSaysYes: alternateSource(for: requirement)?() ?? false,
                keychainValue: keychainValue(for: requirement),
                companionSaysYes: companion(for: requirement)?.isSatisfied())
        case .perm:     return permissionGranted(requirement)
        case .endpoint:
            // The alternate source is consulted HERE TOO, and forgetting that
            // was a live bug for the length of one edit. It was wired only into
            // the `.key` branch, so adding one for `endpoint.imap` compiled,
            // read correctly, and would never have been called.
            if let alt = alternateSource(for: requirement), alt() { return true }
            return endpointConfigured(requirement)
        case .step:     return stepCompleted(requirement)
        }
    }

    /// The precedence rule for a `key.` capability, as a pure function of the
    /// three things that can answer for it.
    ///
    /// Pulled out of `isSatisfied` because it was otherwise UNTESTABLE on any
    /// machine that already has credentials, which includes the one this is
    /// developed on. `isSatisfied` reads the real Keychain, and the alternate
    /// arm only changes the answer when the Keychain arm would have said no, so
    /// a test on a configured machine passes identically whether the alternate
    /// source is consulted or deleted. Three tests skipped for exactly that
    /// reason before this existed, and three honest skips still leave the rule
    /// unverified.
    ///
    /// - Parameters:
    ///   - alternateSaysYes: some other code path can already read this
    ///     credential. See `alternateSource(for:)`.
    ///   - keychainValue: what the Settings field writes, trimmed.
    ///   - companionSaysYes: the second half of a pair, or nil when unpaired.
    static func keyIsSatisfied(alternateSaysYes: Bool,
                               keychainValue: String,
                               companionSaysYes: Bool?) -> Bool {
        // First, because a credential the app can already read is satisfied
        // whatever the Keychain holds. Getting this order wrong is what would
        // put a setup card over a feature that works.
        if alternateSaysYes { return true }
        guard !keychainValue.isEmpty else { return false }
        // A paired credential needs both halves. See `companion(for:)`.
        return companionSaysYes ?? true
    }

    /// Every requirement in `list` that is NOT satisfied, in contract order so a
    /// setup card reads the same way every time.
    static func missing(from list: [SetupRequirement]) -> [SetupRequirement] {
        list.filter { !isSatisfied($0) }
    }

    // MARK: - key.*

    /// The Keychain slot behind each `key.` capability, or nil when the contract
    /// declares a key the app has no storage for yet, which is drift the tests
    /// catch rather than a runtime problem.
    static func keychainKey(for requirement: SetupRequirement) -> KeychainStore.Key? {
        switch requirement {
        case .keyAnthropic:        return .anthropicApiKey
        case .keyElevenlabs:       return .elevenLabsApiKey
        case .keyBrave:            return .braveApiKey
        case .keyReplicate:        return .replicateApiKey
        case .keySlack:            return .slackUserToken
        case .keyNotion:           return .notionToken
        case .keyResend:           return .resendApiKey
        case .keyGodaddy:          return .goDaddyApiKey
        case .keyGithub:           return .gitHubToken
        case .keyAppstoreconnect:  return .appStoreConnectKey
        case .keyReddit:           return .redditCredentials
        case .keyTelegram:         return .telegramBotToken
        default:                   return nil
        }
    }

    private static func keychainValue(for requirement: SetupRequirement) -> String {
        guard let slot = keychainKey(for: requirement) else { return "" }
        return KeychainStore.get(slot).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A source for this credential that the Settings field does not own.
    ///
    /// Kept to the smallest possible set on purpose. Every entry here is a place
    /// a credential can live that a stranger will never use, so each one is a
    /// path the setup UI cannot teach and cannot verify. The registry has to
    /// know about them anyway, because the alternative is worse: a feature that
    /// works while the app insists it is unconfigured.
    ///
    /// Nothing is added here to make a feature convenient. It is added only when
    /// some existing code path ALREADY reads that source, which makes the
    /// divergence real whether the resolver acknowledges it or not.
    static func alternateSource(for requirement: SetupRequirement) -> (() -> Bool)? {
        switch requirement {
        case .keyGodaddy: return { DomainMonitor.credentialsFoundOutsideKeychain() }
        case .endpointSocialAccounts:
            // THE THIRD TIME THIS EXACT SHAPE HAS APPEARED, after endpoint.imap below and
            // step.terminal_sessions_explained.
            //
            // The contract gives this the config key `grux.social.accounts`. Nothing writes
            // it: no Settings pane, no onboarding screen. Its only other appearance in the
            // whole tree is GruxControlSocket's settableKeys, under a comment claiming that
            // list holds "exactly the keys the app genuinely consults". So a person could
            // set it, tick the step green, and watch every Social Ops surface stay empty.
            //
            // The real gate for the entire feature (SocialOpsStore, SocialOpsCoordinator and
            // BrandsPosterStore all agree on it) is ~/.grux/social-ops-hosts.txt, which the
            // contract never mentioned. This teaches the resolver where the answer is, and
            // the remediation text now names the file, matching what
            // PrivateServiceNotice.socialOps already tells the person on screen.
            return { !SocialOpsService.configuredHosts().isEmpty }
        case .endpointImap:
            // The mailbox was showing a setup card over 205 unread messages.
            //
            // Contract section 2.5 gives `endpoint.imap` the config key
            // `grux.mail.accounts`, and NOTHING IN THE APP WRITES THAT KEY. Mail
            // accounts live in `~/.grux/email/accounts.json` behind
            // `EmailAccountStore`, so the capability could never be satisfied by
            // anybody, ever. Mailbox, the briefing and the triage engine were
            // permanently needs-setup, and the sidebar counted three features as
            // waiting on something that already worked.
            //
            // Found in a screenshot taken for a different reason: the mail list
            // and its unread count were rendering, dimmed, behind a card saying
            // the feature needed a mail server. The config key is the contract's
            // and is left alone; this teaches the resolver where the accounts
            // actually are.
            return { !EmailAccountStore.shared.enabledAccounts.isEmpty }
        case .endpointOllama:
            // The contract's own remediation for this capability reads "Install
            // Ollama and start it, or point Grux at your Ollama host in
            // Settings". That control writes `config.ollamaBaseURL`, and nothing
            // consulted it. `endpointConfigured` checks `config.localLLMEndpoint`,
            // which is a DIFFERENT endpoint: LocalHealthMonitor's own header calls
            // them "the AmbientLLM proxy on the companion service at
            // cfg.localLLMEndpoint and the offline-chat Ollama base at
            // cfg.ollamaBaseURL", and their Settings prompts are ports 3849 and
            // 11434 respectively. So somebody who did exactly what the contract
            // told them to do still saw the capability unsatisfied. Same shape as
            // the mail-account divergence above, and found the same way.
            //
            // Deliberately NOT "ollamaBaseURL is non-empty". That field ships with
            // a default of http://localhost:11434, so the emptiness test is true
            // on every install including one with no local model anywhere, and
            // using it would mark the capability satisfied for everybody. A
            // default is not a configuration.
            //
            // `local` is non-nil only once a server at that host actually answered
            // ModelRegistry.discoverLocal(), which AppState runs unconditionally
            // at launch. That is the honest question: is a local model reachable,
            // rather than has a string been typed.
            return { ModelRegistry.shared.local != nil }
        case .endpointMicrosoftGraph:
            // Same shape as the mail account store above, and named here for the
            // same reason: contract section 2.5 gives this capability the
            // descriptor list `grux.mail.graph_accounts`, while the tenant, the
            // app id and the mailbox map actually live in a file and the client
            // secret in its own Keychain item. `clientConfig()` is the existing
            // reader and returns nil unless all of them are present, which is
            // exactly the question this capability asks.
            return { GraphMailStore.shared.clientConfig() != nil }
        default:          return nil
        }
    }

    /// Some credentials are a PAIR, and the contract says so in its own
    /// remediation: key.godaddy reads "your registrar API key and secret". One
    /// half is not a satisfied capability, and treating it as one is how a user
    /// with a key but no secret would have been dropped past the setup card
    /// into an empty tab.
    ///
    /// Returns nil when the capability has no second half.
    static func companion(for requirement: SetupRequirement) -> CredentialCompanion? {
        switch requirement {
        case .keyGodaddy:
            return CredentialCompanion(
                title: "Registrar API secret",
                placeholder: "the secret half of the key pair",
                isSatisfied: { !KeychainStore.get(.goDaddyApiSecret).isEmpty },
                save: { raw in
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return false }
                    _ = KeychainStore.set(.goDaddyApiSecret, t)
                    return true
                })
        case .keyTelegram:
            return CredentialCompanion(
                title: "Telegram chat id",
                placeholder: "the chat or channel the alerts go to",
                isSatisfied: { !KeychainStore.get(.telegramChatId).isEmpty },
                save: { raw in
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return false }
                    _ = KeychainStore.set(.telegramChatId, t)
                    return true
                })
        default:
            return nil
        }
    }

    // MARK: - perm.*

    private static func permissionGranted(_ requirement: SetupRequirement) -> Bool {
        switch requirement {
        case .permScreenRecording:
            return CGPreflightScreenCaptureAccess()

        case .permSystemAudio:
            // Deliberately the same check. macOS grants system audio capture
            // under Screen Recording, which is not a guess: the contract's own
            // remediation for this id sends the user to Privacy and Security,
            // Screen Recording. Two ids, one system switch.
            return CGPreflightScreenCaptureAccess()

        case .permMicrophone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        case .permAccessibility:
            return AXIsProcessTrusted()

        case .permCalendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            if #available(macOS 14.0, *) {
                return status == .fullAccess || status == .writeOnly
            }
            return status == .authorized

        case .permContacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized

        case .permNotifications:
            // THE ONE CACHED PERMISSION, and the reason is an API constraint
            // rather than convenience. UNUserNotificationCenter exposes
            // authorization only through an async callback, and this resolver is
            // called from view bodies that cannot await. The cache is refreshed
            // by `refreshNotificationStatus()` on launch and whenever a setup
            // card appears, so it is at worst one refresh stale.
            //
            // Safe to cache HERE and nowhere else: no feature in the registry
            // requires perm.notifications, it appears only as optional, so a
            // stale read cannot put a feature in the wrong state. If a future
            // row ever requires it, this needs to become async instead.
            return cachedNotificationAuthorization

        case .permAutomation:
            // Automation has no global status. macOS grants it per TARGET
            // application, so this reads the last observation rather than
            // probing: `isSatisfied` is called from view bodies that cannot
            // await, and a probe belongs somewhere it can be scheduled.
            //
            // NOTHING USED TO WRITE THIS KEY. It was documented as "what was
            // last observed by an actual automation attempt" and no automation
            // attempt ever recorded one, so `UserDefaults.bool` returned false
            // for an unset key on every read and the value was false forever.
            // The onboarding card that sends people to System Settings could
            // therefore never notice them coming back having granted it, which
            // is the same dead end the Notifications card had.
            // `refreshAutomationObservation()` is the writer.
            //
            // Same safety argument as notifications: no registry row requires
            // perm.automation, it is optional everywhere it appears.
            return UserDefaults.standard.bool(forKey: automationObservedKey)

        case .permFullDiskAccess:
            // No API exists. The conventional probe is to read a path that only
            // a Full Disk Access grant can reach. Reading is not destructive and
            // touches nothing the user owns.
            let probe = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString)
                .expandingTildeInPath
            return FileManager.default.isReadableFile(atPath: probe)

        default:
            return false
        }
    }

    /// Refreshes the one cached permission. Call on launch and before showing a
    /// setup card. Cheap, and never prompts: `getNotificationSettings` reads
    /// existing state rather than requesting authorization.
    static func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            UserDefaults.standard.set(granted, forKey: notificationCacheKey)
        }
    }

    private static var cachedNotificationAuthorization: Bool {
        UserDefaults.standard.bool(forKey: notificationCacheKey)
    }

    /// The one writer of that cache besides `refreshNotificationStatus`, so
    /// `CapabilityRequest` can record an answer it has just awaited rather than kicking off
    /// another callback and reading the old value again.
    static func setNotificationAuthorizationCache(_ granted: Bool) {
        UserDefaults.standard.set(granted, forKey: notificationCacheKey)
    }

    private static let notificationCacheKey = "grux.capability.notifications_granted"
    static let automationObservedKey = "grux.capability.automation_observed"

    /// The applications Grux actually drives, so the probe asks about targets
    /// this app has a reason to control rather than a global that macOS does
    /// not have. Counted from the AppleScript call sites: Terminal 12, Music 10,
    /// Chrome 4, Notes 3.
    static let automationTargets = [
        "com.apple.Terminal", "com.apple.Music", "com.apple.Notes", "com.google.Chrome",
    ]

    /// Ask TCC what it has ALREADY decided about each target, and record it.
    ///
    /// Never prompts: `AEDeterminePermissionToAutomateTarget` with
    /// `askUserIfNeeded: false` reports the existing decision and nothing else,
    /// which is what makes this safe to call from a poll.
    ///
    /// The three-way result is the whole point, and `-600` is the reason it
    /// cannot be a boolean. `procNotFound` means the TARGET IS NOT RUNNING, so
    /// TCC has nothing to say about it, and a granted-but-closed Terminal is
    /// indistinguishable from an app that does not exist. Treating that as "not
    /// granted" would flip a real grant back off the moment somebody quit the
    /// app it was granted for. So:
    ///
    /// - any target answering `noErr` is a grant, and latches true
    /// - any target answering `errAEEventNotPermitted` is an explicit refusal
    /// - anything else, including `-600` and "not decided yet", says nothing and
    ///   leaves the last real observation alone
    @discardableResult
    static func refreshAutomationObservation() -> Bool {
        let statuses = automationTargets.map {
            NotesIngester.automationPermission(forBundleId: $0)
        }
        let verdict = automationVerdict(
            statuses: statuses,
            previous: UserDefaults.standard.bool(forKey: automationObservedKey))
        UserDefaults.standard.set(verdict, forKey: automationObservedKey)
        return verdict
    }

    /// The three-way rule, separated from the probing so it can be checked
    /// without putting a Mac into a particular state first. Whether Terminal
    /// happens to be running is not something a test should have to arrange.
    nonisolated static func automationVerdict(statuses: [OSStatus], previous: Bool) -> Bool {
        if statuses.contains(OSStatus(noErr)) { return true }
        if statuses.contains(OSStatus(errAEEventNotPermitted)) { return false }
        return previous
    }

    // MARK: - endpoint.*

    /// The config key behind each endpoint, taken from contract section 2.5 so
    /// the two cannot drift apart by retyping.
    static func configKey(for requirement: SetupRequirement) -> String? {
        switch requirement {
        case .endpointOllama:         return "grux.model.ollama_host"
        case .endpointRegistry:       return "grux.portfolio.registry_url"
        case .endpointRepoList:       return "grux.github.repos"
        case .endpointUptimeTargets:  return "grux.uptime.targets"
        case .endpointSocialAccounts: return "grux.social.accounts"
        case .endpointSandboxRoot:    return "grux.sandbox.watched_root"
        case .endpointMediaService:   return "grux.media.service_url"
        case .endpointImap:           return "grux.mail.accounts"
        case .endpointMicrosoftGraph: return "grux.mail.graph_accounts"
        case .endpointWebhookInbox:   return "grux.webhook.inbox_port"
        default:                      return nil
        }
    }

    private static func endpointConfigured(_ requirement: SetupRequirement) -> Bool {
        // endpoint.ollama is satisfied by a CONFIGURED host, and deliberately
        // does not probe whether the server is up right now.
        //
        // The comment here used to claim the opposite, that a configured but
        // not-running host is unsatisfied, which is not what the code below does
        // and is not what it should do. Two reasons. This resolver is called
        // from SwiftUI view bodies on every render, so a synchronous network
        // probe belongs nowhere near it. And the distinction is real: SETUP is
        // whether the user has told Grux where the server is, which is what the
        // contract's own remediation asks for. A server that is momentarily
        // stopped is a runtime condition for the feature to report, not an
        // unfinished setup step, and treating it as one would make the sidebar
        // count flicker every time Ollama restarted.
        if requirement == .endpointOllama {
            let configured = AppState.shared.config.localLLMEndpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty { return true }
        }
        guard let key = configKey(for: requirement) else { return false }
        let defaults = UserDefaults.standard
        // A list-shaped config key (mail accounts, repos, targets) counts as
        // configured only when it holds at least one entry. An empty array is
        // absence, exactly like an empty string.
        if let array = defaults.array(forKey: key) { return !array.isEmpty }
        if let string = defaults.string(forKey: key) {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    // MARK: - step.*

    /// Setup steps are the only capability class the app itself completes, so
    /// they are the only class that is legitimately a stored flag.
    static func stepDefaultsKey(for requirement: SetupRequirement) -> String? {
        guard requirement.kind == .step else { return nil }
        return "grux.step." + requirement.rawValue.replacingOccurrences(of: "step.", with: "")
    }

    // MARK: The two kinds of step, and why the distinction is load-bearing

    /// Steps Grux DETECTS by looking at this machine.
    ///
    /// THE LOOP THIS CLOSES. Every `step.*` used to resolve to a `UserDefaults` boolean
    /// written only by an in-app control, so somebody could install the agent CLI, fetch
    /// the speech model and write the focus hook, and Grux would still report needs-setup
    /// with nothing on screen to explain why. `AgentHandoff` shipped a paragraph warning
    /// the reader about exactly that, because the alternative was pretending.
    ///
    /// For these four, DETECTION WINS OVER THE FLAG in both directions. Present on disk
    /// means satisfied even if nobody ticked anything, which is what lets an agent do the
    /// work and have Grux simply notice. Absent means unsatisfied even if a stale flag says
    /// otherwise, which is what stops a tick surviving an uninstall.
    static let detectedSteps: Set<SetupRequirement> = [
        .stepAgentCliInstalled,
        .stepSpeechModelDownloaded,
        .stepTerminalFocusHookInstalled,
        .stepPhonePaired,
    ]

    /// Steps Grux can only take somebody's word for, and rightly.
    ///
    /// Four are consent decisions and one is an acknowledgement: an agent that ticks them
    /// has not completed setup, it has removed the point of the step. The sixth is a
    /// setting the app itself owns. None of these is a defect to be fixed by finding a
    /// probe; a probe for "you confirmed you will tell people you are recording" does not
    /// exist and should not. `grux status` reports them with `self_attested: true` so no
    /// VERIFY section ever implies a detection that did not happen.
    static let selfAttestedSteps: Set<SetupRequirement> = [
        .stepRecordingConsentAcknowledged,
        .stepCaptureExclusionsConfirmed,
        .stepCorpusSourcesConfirmed,
        .stepFirstFrameReviewed,
        .stepTerminalSessionsExplained,
        .stepYoutubeTranscriptsEnabled,
    ]

    /// Where the coding agent's hook script lives. Same path `TerminalFocusState` writes
    /// to and checks, named once here so the two cannot drift into disagreeing about
    /// whether the hook is installed.
    // nonisolated: it reads NSHomeDirectory and nothing else, and a default argument is
    // evaluated outside the actor, so a MainActor-isolated property cannot be one.
    nonisolated static var terminalFocusHookPath: String {
        NSHomeDirectory() + "/.claude/hooks/terminal-focus.sh"
    }

    /// The on-device speech model, and what counts as HAVING it.
    ///
    /// The directory existing is not the question: an interrupted download leaves one
    /// behind. WhisperKit writes three compiled bundles and the model is unusable without
    /// all three, so all three are named. Path measured on a real install rather than taken
    /// from the library's documentation.
    nonisolated static var speechModelPath: String {
        NSHomeDirectory()
            + "/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en"
    }

    nonisolated static let speechModelBundles = [
        "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
    ]

    /// TAKES ITS PATH so a test can watch it say NO.
    ///
    /// On the machine that wrote this, all three detection artifacts are present, so a test
    /// asserting "the flag cannot change the answer" passes with both answers true and
    /// proves almost nothing. A probe nobody has seen fail is not evidence. The parameter
    /// exists only so the negative and positive halves can both be driven against a
    /// temporary directory, and no caller in the app ever passes it.
    nonisolated static func speechModelIsDownloaded(at path: String = speechModelPath) -> Bool {
        let fm = FileManager.default
        return speechModelBundles.allSatisfy { fm.fileExists(atPath: path + "/" + $0) }
    }

    /// Same reasoning as above.
    nonisolated static func terminalFocusHookIsInstalled(at path: String = terminalFocusHookPath) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func stepCompleted(_ requirement: SetupRequirement) -> Bool {
        switch requirement {
        case .stepAgentCliInstalled:
            return AccountSwitcher.locateClaudeBinary() != nil
        case .stepSpeechModelDownloaded:
            return speechModelIsDownloaded()
        case .stepTerminalFocusHookInstalled:
            return terminalFocusHookIsInstalled()
        case .stepPhonePaired:
            return KeychainStore.exists(.phonePairingSecret)
        case .stepRecordingConsentAcknowledged:
            // READ FROM THE CONFIG, WHICH IS WHERE THE ANSWER ACTUALLY LANDS. The same
            // reason `stepFirstFrameReviewed` below is read from onboarding: this fact
            // already had a home before the resolver existed, and a second flag beside it is
            // a second flag that can disagree.
            //
            // It DID disagree, and the way it failed is the worst shape available. The
            // recording consent modal is the gate with legal weight, and answering it yes
            // writes `config.recordingConsentAcknowledged`. This capability read a separate
            // UserDefaults key that the modal never touches, so somebody who had answered
            // the dialog still had the step reported as outstanding, and
            // `grux meeting start` refused with exit 2 telling them to go and answer a
            // dialog they had already answered. No number of attempts would ever change it.
            return AppState.shared.config.recordingConsentAcknowledged
        case .stepFirstFrameReviewed:
            // Predates this resolver and already persists its own state through
            // onboarding, so it is read from there rather than duplicated into a second
            // flag that could disagree with it.
            //
            // THE THIRD CONDITION IS THE FIX, and without it this reported consent that
            // nobody had given. `.firstLook` is only in the flow `if level.includesPermissions`
            // (OnboardingModel.stages(for:)), so somebody who picks Level 1 is never shown a
            // frame at all. `skippedFirstLook` stays false because they never reached a
            // screen they could skip, and `stage` reaches `.done` because the flow finished.
            // Both original conditions passed and the answer was true.
            //
            // Measured on the Mac Mini, which had never run Grux before this week:
            // `step.first_frame_reviewed` read TRUE in its setup-status.json while
            // `perm.screen_recording` read false, so no frame had ever been captured, let
            // alone reviewed. The contract's own words for this step are "Grux will show you
            // one frame, and the exact text it would send, before anything leaves your Mac.
            // Nothing is sent until you approve."
            //
            // This does not strand anybody: with it false the focus surface renders
            // needs-setup, and Settings > General > "Restart onboarding" walks the flow
            // that shows the frame.
            return firstFrameWasReviewed(stage: OnboardingModel.shared.stage,
                                        skippedFirstLook: OnboardingModel.shared.skippedFirstLook,
                                        level: OnboardingModel.shared.level)
        default:
            guard let key = stepDefaultsKey(for: requirement) else { return false }
            return UserDefaults.standard.bool(forKey: key)
        }
    }

    /// Pure, so every level can be driven without rewriting somebody's onboarding.json.
    ///
    /// `advance` mutates the singleton and PERSISTS, which is why OnboardingModel already
    /// splits its own transition decision out for the same reason.
    static func firstFrameWasReviewed(stage: OnboardingModel.Stage,
                                      skippedFirstLook: Bool,
                                      level: OnboardingModel.Level) -> Bool {
        stage == .done
            && skippedFirstLook == false
            && OnboardingModel.stages(for: level).contains(.firstLook)
    }

    /// Marks a setup step complete. The only writer, so a step cannot be set
    /// from three places with three different key spellings.
    static func markStepCompleted(_ requirement: SetupRequirement, _ done: Bool = true) {
        // WRITTEN WHERE IT IS READ. A step whose truth lives somewhere else has to be
        // written there too, or the onboarding checkbox sets a key nothing consults and the
        // control springs back the next time the screen is drawn.
        if requirement == .stepRecordingConsentAcknowledged {
            AppState.shared.config.recordingConsentAcknowledged = done
            AppState.shared.saveAll()
            SetupStatusFile.write()
            return
        }
        guard let key = stepDefaultsKey(for: requirement) else { return }
        UserDefaults.standard.set(done, forKey: key)
        // Written AFTER the set, not before, and safe to do inline because the set IS the
        // work and it is complete on return. Anything whose work finishes asynchronously
        // must use SetupStatusFile.writeAfter instead: that ordering is the bug
        // mic-status.json shipped with for weeks.
        SetupStatusFile.write()
    }
}

extension SetupRequirement {
    /// The capability class, parsed from the id's own prefix. The contract makes
    /// the prefix meaningful, so it is read rather than duplicated in a table
    /// that could disagree with the id.
    enum Kind: String { case key, perm, endpoint, step }

    var kind: Kind {
        Kind(rawValue: rawValue.split(separator: ".").first.map(String.init) ?? "") ?? .step
    }
}


/// The second half of a paired credential, for the few capabilities whose own
/// remediation names two things.
struct CredentialCompanion {
    let title: String
    let placeholder: String
    let isSatisfied: () -> Bool
    /// Returns false when the value is rejected, so the field can say so rather
    /// than silently storing something that will never work.
    let save: (String) -> Bool
}
