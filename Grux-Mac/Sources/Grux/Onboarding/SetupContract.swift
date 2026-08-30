import Foundation

/// The contract's capability vocabulary and feature state machine, in Swift.
///
/// A direct transcription of `docs/contract.md`. The contract is FROZEN: the id
/// sets are closed, ids are stable and never renamed, and a call site must never
/// invent one. That is why the ids live here as an enum rather than as strings at
/// the point of use, and why every case carries its `label` and `remediation`
/// verbatim from the contract tables.
///
/// Transcribed, not invented. Before adding a case, add the row to
/// `docs/contract.md` first, or file a change request under its
/// "Contract change requests" heading. A case here with no row there is drift,
/// and the reconciler treats an unknown id exactly as it treats a typo.
///
/// VERBATIM IS LOAD-BEARING, and it had drifted. This file previously carried 3
/// of the 40 ids, and 2 of those 3 had `remediation` text that no longer matched
/// the contract while the doc comment still claimed it did. Both were regenerated
/// from the tables. `SetupRequirementContractTests` now compares every string
/// against the contract file itself, so the claim is checked rather than trusted.
///
/// `remediation` is written for a SETUP CARD, where pointing at Settings is the
/// correct instruction. Onboarding says something different on purpose: a person
/// standing in the onboarding flow with a paste field in front of them must not
/// be told to go to Settings. That copy lives in the onboarding views.
enum SetupRequirement: String, CaseIterable, Identifiable {

    // MARK: Capabilities, class `key` (contract 1.1)

    case keyAnthropic = "key.anthropic"
    case keyGithub = "key.github"
    case keyAppstoreconnect = "key.appstoreconnect"
    case keyElevenlabs = "key.elevenlabs"
    case keyReddit = "key.reddit"
    case keyReplicate = "key.replicate"
    case keyBrave = "key.brave"
    case keyResend = "key.resend"
    case keySlack = "key.slack"
    case keyGodaddy = "key.godaddy"
    case keyNotion = "key.notion"
    case keyTelegram = "key.telegram"

    // MARK: Capabilities, class `perm` (contract 1.2)

    case permScreenRecording = "perm.screen_recording"
    case permMicrophone = "perm.microphone"
    case permAccessibility = "perm.accessibility"
    case permAutomation = "perm.automation"
    case permCalendar = "perm.calendar"
    case permContacts = "perm.contacts"
    case permNotifications = "perm.notifications"
    case permSystemAudio = "perm.system_audio"
    case permFullDiskAccess = "perm.full_disk_access"

    // MARK: Capabilities, class `endpoint` (contract 1.3)

    case endpointRegistry = "endpoint.registry"
    case endpointRepoList = "endpoint.repo_list"
    case endpointUptimeTargets = "endpoint.uptime_targets"
    case endpointWebhookInbox = "endpoint.webhook_inbox"
    case endpointOllama = "endpoint.ollama"
    case endpointMediaService = "endpoint.media_service"
    case endpointImap = "endpoint.imap"
    case endpointSocialAccounts = "endpoint.social_accounts"
    case endpointSandboxRoot = "endpoint.sandbox_root"
    case endpointMicrosoftGraph = "endpoint.microsoft_graph"

    // MARK: Setup steps (contract 3.1)

    case stepFirstFrameReviewed = "step.first_frame_reviewed"
    case stepAgentCliInstalled = "step.agent_cli_installed"
    case stepCaptureExclusionsConfirmed = "step.capture_exclusions_confirmed"
    case stepRecordingConsentAcknowledged = "step.recording_consent_acknowledged"
    case stepSpeechModelDownloaded = "step.speech_model_downloaded"
    case stepCorpusSourcesConfirmed = "step.corpus_sources_confirmed"
    case stepTerminalFocusHookInstalled = "step.terminal_focus_hook_installed"
    case stepTerminalSessionsExplained = "step.terminal_sessions_explained"
    case stepPhonePaired = "step.phone_paired"
    case stepYoutubeTranscriptsEnabled = "step.youtube_transcripts_enabled"

    var id: String { rawValue }

    /// Human, title case. Verbatim from the contract tables.
    var label: String {
        switch self {
        case .keyAnthropic: return "Anthropic API key"
        case .keyGithub: return "GitHub token"
        case .keyAppstoreconnect: return "App Store Connect API key"
        case .keyElevenlabs: return "ElevenLabs API key"
        case .keyReddit: return "Reddit API credentials"
        case .keyReplicate: return "Replicate API token"
        case .keyBrave: return "Web search API key"
        case .keyResend: return "Email sending API key"
        case .keySlack: return "Slack token"
        case .keyGodaddy: return "Domain registrar key"
        case .keyNotion: return "Notion token"
        case .keyTelegram: return "Telegram bot token"
        case .permScreenRecording: return "Screen Recording"
        case .permMicrophone: return "Microphone"
        case .permAccessibility: return "Accessibility"
        case .permAutomation: return "Automation"
        case .permCalendar: return "Calendar"
        case .permContacts: return "Contacts"
        case .permNotifications: return "Notifications"
        case .permSystemAudio: return "System audio capture"
        case .permFullDiskAccess: return "Full Disk Access"
        case .endpointRegistry: return "Project registry"
        case .endpointRepoList: return "Repository list"
        case .endpointUptimeTargets: return "Sites to monitor"
        case .endpointWebhookInbox: return "Webhook inbox"
        case .endpointOllama: return "Local model server"
        case .endpointMediaService: return "Image generation service"
        case .endpointImap: return "Mail server"
        case .endpointSocialAccounts: return "Social accounts"
        case .endpointSandboxRoot: return "Watched folder"
        case .endpointMicrosoftGraph: return "Microsoft 365 mail"
        case .stepFirstFrameReviewed: return "Review the first capture"
        case .stepAgentCliInstalled: return "Install the agent command line tool"
        case .stepCaptureExclusionsConfirmed: return "Confirm what stays private"
        case .stepRecordingConsentAcknowledged: return "Confirm you will tell people"
        case .stepSpeechModelDownloaded: return "Fetch the speech model"
        case .stepCorpusSourcesConfirmed: return "Choose what gets indexed"
        case .stepTerminalFocusHookInstalled: return "Install the terminal hook"
        case .stepTerminalSessionsExplained: return "Understand terminal sessions"
        case .stepPhonePaired: return "Pair your iPhone"
        case .stepYoutubeTranscriptsEnabled: return "Turn on YouTube transcripts"
        }
    }

    /// Exact UI text, second person. Verbatim from the contract tables.
    /// The contract caps these at 140 characters and the tests measure it.
    var remediation: String {
        switch self {
        case .keyAnthropic:
            return "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
        case .keyGithub:
            return "Connect GitHub in Settings so Grux can read your repositories. A classic token with repo scope is enough."
        case .keyAppstoreconnect:
            return "Add your App Store Connect key, issuer ID and .p8 file in Settings to let Grux publish builds."
        case .keyElevenlabs:
            return "Optional. Add an ElevenLabs key for a natural voice. Grux uses the built-in macOS voice without one."
        case .keyReddit:
            return "Connect Reddit in Settings to read mentions of your product."
        case .keyReplicate:
            return "Add a Replicate API token in Settings to generate images."
        case .keyBrave:
            return "Add a Brave Search API key in Settings so Grux can search the web. The free tier is enough."
        case .keyResend:
            return "Add your email provider API key in Settings so Grux can send mail. Grux has no SMTP client."
        case .keySlack:
            return "Connect Slack in Settings so Grux can read and post in your workspace."
        case .keyGodaddy:
            return "Add your registrar API key and secret in Settings so Grux can read your domains and DNS."
        case .keyNotion:
            return "Paste your Notion integration secret in Settings, and the database you want Grux to write to."
        case .keyTelegram:
            return "Add a Telegram bot token and chat id in Settings so Grux can send alerts to your phone. Nothing is sent until you add both."
        case .permScreenRecording:
            return "Grux needs Screen Recording to see what you are working on. Open System Settings, Privacy and Security, Screen Recording, and enable Grux."
        case .permMicrophone:
            return "Grux needs the microphone to hear you. Open System Settings, Privacy and Security, Microphone, and enable Grux."
        case .permAccessibility:
            return "Grux needs Accessibility to read the active window title. Open System Settings, Privacy and Security, Accessibility, and enable Grux."
        case .permAutomation:
            return "Grux needs Automation to control other apps. Approve the prompt macOS shows, or enable Grux under Privacy and Security, Automation."
        case .permCalendar:
            return "Grux needs Calendar access to read and create events. Open System Settings, Privacy and Security, Calendars, and enable Grux."
        case .permContacts:
            return "Grux needs Contacts access to match people to conversations. Open System Settings, Privacy and Security, Contacts, and enable Grux."
        case .permNotifications:
            return "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."
        case .permSystemAudio:
            return "Grux needs system audio to transcribe meetings. Open System Settings, Privacy and Security, Screen Recording, and enable Grux."
        case .permFullDiskAccess:
            return "Grux needs Full Disk Access to read your messages. Open System Settings, Privacy and Security, Full Disk Access, and enable Grux."
        case .endpointRegistry:
            return "Point Grux at your project registry URL in Settings. Grux reads your projects from it and writes status changes back."
        case .endpointRepoList:
            return "Tell Grux which repositories to watch in Settings. Nothing is watched until you do."
        case .endpointUptimeTargets:
            return "Add the URLs you want Grux to check in Settings."
        case .endpointWebhookInbox:
            return "Turn on the local webhook listener in Settings and choose a port to let other machines push updates in."
        case .endpointOllama:
            return "Install Ollama and start it, or point Grux at your Ollama host in Settings."
        case .endpointMediaService:
            return "Point Grux at your image generation service in Settings, or use a hosted provider key instead."
        case .endpointImap:
            return "Add a mail account, its server and an app password in Settings to let Grux read your inbox."
        case .endpointSocialAccounts:
            // WAS "Connect the social accounts you want Grux to watch in Settings.", which
            // named a Settings screen that does not exist. Social Ops talks to a service you
            // run, and the only thing that switches it on is this file.
            return "List your posting service, one URL per line, in ~/.grux/social-ops-hosts.txt. Grux reads it at launch and when the Social Ops panel opens."
        case .endpointSandboxRoot:
            return "Choose the folder Grux should guard in Settings."
        case .endpointMicrosoftGraph:
            return "Add your Microsoft 365 tenant, app id and a mailbox in Settings to let Grux read that inbox. Nothing connects until you do."
        case .stepFirstFrameReviewed:
            return "Grux will show you one frame, and the exact text it would send, before anything leaves your Mac. Nothing is sent until you approve."
        case .stepAgentCliInstalled:
            return "Install the coding agent command line tool, then restart Grux. It was not found at any location Grux checks."
        case .stepCaptureExclusionsConfirmed:
            return "Check the list of apps Grux will never look at. Password managers and banking apps are excluded by default."
        case .stepRecordingConsentAcknowledged:
            return "Recording a call captures everyone on it, and some places require you to say so first. Confirm you will, then Grux can record."
        case .stepSpeechModelDownloaded:
            return "Grux fetches a one time on-device speech model before it can transcribe. Connect to the internet and open Meetings once."
        case .stepCorpusSourcesConfirmed:
            return "Pick which of your messages, notes and sent mail Grux may index. Nothing is indexed until you choose."
        case .stepTerminalSessionsExplained:
            return "Read what a headless session runs and which credential it spends, then turn terminal sessions on in Settings."
        case .stepTerminalFocusHookInstalled:
            return "Grux adds one entry to your coding tool's settings and one script beside it. It removes nothing else."
        case .stepPhonePaired:
            return "Open Pair iPhone in Settings and scan the code with the Grux phone app. The pairing secret never leaves your Mac and your phone."
        case .stepYoutubeTranscriptsEnabled:
            return "Grux reads YouTube captions with yt-dlp when you paste a video link. Turn it on in Settings, and off there whenever you want."
        }
    }

    /// Why this is wanted, without the instructions for granting it.
    ///
    /// DERIVED from `remediation` rather than written again. Every contract
    /// remediation opens with the reason and then says how ("Grux needs the
    /// microphone to hear you. Open System Settings, ..."), so the first
    /// sentence is the reason, already approved, already under the contract
    /// test. Writing a second set of sentences would have created exactly the
    /// pair of strings that drifted last time: two places telling one person
    /// about one capability, agreeing on the day they were written.
    ///
    /// This exists because a macOS permission prompt is a bad place to learn
    /// why. The dialog is modal, it is written by Apple, and the only thing Grux
    /// gets to put in it is one usage-description line. Showing the reason on a
    /// screen the user can read at their own pace, BEFORE the prompt appears, is
    /// the difference between a considered yes and a reflexive no.
    var rationale: String {
        guard let end = Self.firstSentenceEnd(in: remediation) else { return remediation }
        return String(remediation[...end])
    }

    /// The case for granting a macOS permission, shown BEFORE the system prompt
    /// is triggered. Contract section 1.2.1.
    ///
    /// Separate from `remediation` because that string is capped at 140
    /// characters and its job is to name the single next action. That is right
    /// for the setup card and useless at the moment of consent: macOS shows its
    /// own modal, the only text Grux gets inside it is one usage-description
    /// line, and somebody deciding whether to hand over a microphone needs to
    /// know what they get and what they lose, not which pane to open.
    ///
    /// EVERY entry names a consequence of declining. A permission screen that
    /// only lists upside reads as a sales pitch and earns a reflexive no, and
    /// the consequence is usually smaller than a user fears: almost nothing
    /// here breaks the app, it just switches a feature off.
    ///
    /// Empty for non-`perm` capabilities, which are configured rather than
    /// granted and whose remediation already names the action.
    var why: String {
        switch self {
        case .permScreenRecording:
            return "Grux can see what you are working on, so it can keep you on the task you chose and answer questions about what is on screen. Decline and Grux is text only: focus tracking and screen questions stay off, everything else still works."
        case .permMicrophone:
            return "You can talk to Grux instead of typing, and it can transcribe meetings on this Mac. Decline and voice and meeting notes stay off, everything else still works. Continuous listening is a separate switch that ships off."
        case .permAccessibility:
            return "Grux can read which app and window you are in, which is how it knows what you are working on and how it clicks things for you. Decline and focus tracking and app control stay off."
        case .permAutomation:
            return "Grux can drive the apps you already have open instead of telling you which buttons to press. Decline and Grux can advise but not act."
        case .permCalendar:
            return "Grux can line your meetings up with what it heard and put events in for you. Decline and the workday log has no meetings in it."
        case .permContacts:
            return "Grux can put names to the voices in a meeting and find an address without you typing it. Decline and speakers stay unnamed."
        case .permNotifications:
            return "Grux can tell you something happened without you watching the window. Decline and you only see updates when you go looking."
        case .permSystemAudio:
            return "Grux can transcribe the other side of a call, not just your microphone. Decline and you get your half of the conversation."
        case .permFullDiskAccess:
            return "Grux can read your Messages history and answer questions about past conversations. Decline and Messages stays unreadable, nothing else changes."
        default:
            return ""
        }
    }

    /// The rest: how to actually grant it.
    var instructions: String {
        guard let end = Self.firstSentenceEnd(in: remediation) else { return "" }
        let after = remediation.index(after: end)
        return String(remediation[after...]).trimmingCharacters(in: .whitespaces)
    }

    /// The first full stop that actually ENDS A SENTENCE.
    ///
    /// Splitting on the first "." was the obvious version and it was wrong in
    /// production text. The retired `key.fal` read "Add a fal.ai key in Settings
    /// to generate images", so the naive split rendered the rationale as "Add a
    /// fal." on screen, and `key.appstoreconnect` mentions a ".p8 file" and cut
    /// at "issuer ID and .". Neither is a sentence, and both would have shipped
    /// as visible nonsense on a first-run screen. The example is kept although
    /// that capability is gone: it is the clearest one, and a comment that
    /// explains WHY a rule exists outlives the case that taught it.
    ///
    /// A sentence end is a period followed by a space, or the end of the string.
    /// That is enough here because the contract writes plain declarative
    /// sentences; it is not a general purpose sentence splitter and does not
    /// pretend to be.
    private static func firstSentenceEnd(in text: String) -> String.Index? {
        var i = text.startIndex
        while let dot = text[i...].firstIndex(of: ".") {
            let next = text.index(after: dot)
            if next == text.endIndex || text[next] == " " { return dot }
            i = next
            if i == text.endIndex { return nil }
        }
        return nil
    }
}

/// Contract section 3. A feature is in exactly one state at any moment.
///
/// The binding rule, and the one most easily broken by accident: **a missing
/// capability never surfaces as an error.** No alert, no thrown exception, no
/// empty view. A feature that cannot resolve a capability renders `needsSetup`.
/// Anything else is a defect.
enum FeatureState: String {
    /// Every required capability resolved.
    case ready
    /// At least one required capability is missing and the user can fix it.
    case needsSetup
    /// Required capabilities satisfied; an optional one is producing the lesser
    /// path. Never silent: the point of the state is that the user knows.
    case degraded
    /// Cannot be satisfied on this machine or build. Impossibility, not absence.
    case unavailable
    /// The owner did not select this feature. CR-36, 2026-08-28.
    ///
    /// DISTINCT FROM `unavailable`, and the distinction is the whole reason it exists.
    /// `unavailable` means impossibility; telling somebody a feature cannot be satisfied on
    /// their machine when the truth is that they declined it is a different sentence with a
    /// different remedy. Hidden from the sidebar rather than struck through, because a
    /// person who chose twelve features should see twelve rows and not thirty nine with
    /// twenty seven crossed out.
    case notChosen
}
