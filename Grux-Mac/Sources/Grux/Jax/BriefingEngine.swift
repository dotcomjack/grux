import Foundation

// Jax's voice-first briefing engine.
//
// Twice a day, at 07:00 and 21:00 local, Jax speaks a short briefing in the
// user's own ElevenLabs voice clone: not a status dump, but their own mind
// telling them what needs them today. The morning brief is forward ("morning,
// three things need you today..."), the night brief is a close-out ("end of the
// day, here is where the empire stands..."). Each briefing is assembled
// READ-ONLY from the live stores (no store ever has its logic duplicated here),
// composed by the model wearing the Jax persona, spoken aloud via
// SpeechEngine.shared, and persisted to ~/.grux/jax/briefings/ so Home and
// Jax HQ can render the transcript and the item list after it speaks.
//
// Cadence math mirrors FoundryGovernor exactly: every boundary goes through a
// Calendar pinned to the machine's zone so DST never skews the fire time, and a
// once-per-window guard (same local day + slot) keeps a 60s tick from
// double-firing inside the same minute. The on-demand entry point briefNow()
// runs the same assemble -> compose -> speak -> persist path with no schedule
// gate, for the Home "brief me" button and CLI hooks.

// MARK: - Persisted model

// One line item inside a briefing: a single thing Jax surfaced, grouped by
// where it came from so Jax HQ can render sections (emails, ops, goals).
struct BriefingItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case emailNeedsYou      // an unread message that wants a reply
        case opsSignal          // ad pacing / ops snapshot worth a glance
        case goalAdvanced       // a roadmap goal that moved overnight
        case agenda             // today's calendar highlight
        case task               // a NOW / NEXT task to hit
        case approvalPending    // something parked in the Jax HQ approval queue
        case proposalPending    // a Foundry self-upgrade proposal awaiting review
        case approvalTurnedDown // a queued card the tray would turn down if approved now (D169)
        case decisions          // the day's decisions: how many, how fast, what they cost

        var label: String {
            switch self {
            case .emailNeedsYou:   return "Needs a reply"
            case .opsSignal:       return "Ops"
            case .goalAdvanced:    return "Goal advanced"
            case .agenda:          return "Today"
            case .task:            return "On deck"
            case .approvalPending: return "Awaiting your OK"
            case .proposalPending: return "Self-upgrade"
            case .approvalTurnedDown: return "Would be turned down"
            case .decisions:       return "Decisions"
            }
        }

        // SF Symbol so Home / Jax HQ rows can render a glyph without a lookup
        // table living in the view layer.
        var icon: String {
            switch self {
            case .emailNeedsYou:   return "envelope.badge"
            case .opsSignal:       return "chart.line.uptrend.xyaxis"
            case .goalAdvanced:    return "flag.checkered"
            case .agenda:          return "calendar"
            case .task:            return "bolt"
            case .approvalPending: return "hand.tap"
            case .proposalPending: return "wand.and.stars"
            case .approvalTurnedDown: return "hand.raised.slash"
            case .decisions:       return "gauge.with.dots.needle.33percent"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var title: String
    var detail: String
    // How many things a summary row stands for ("2 waiting for your OK" is
    // one row and two approvals), so a spoken count adds them, not the rows.
    // Nil on a row that is one thing, and on every briefing saved before it.
    var count: Int?
    var names: [String]?

    init(id: UUID = UUID(), kind: Kind, title: String, detail: String = "", count: Int? = nil, names: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.count = count
        self.names = names
    }
}

// A single briefing: when it fired, which slot it was, the spoken transcript,
// and the structured items behind it. `slot` lets Home / Jax HQ label the
// card and lets the once-per-window guard dedupe per slot per local day.
struct Briefing: Codable, Identifiable, Hashable {
    enum Slot: String, Codable, CaseIterable {
        case morning     // 07:00 local, forward-looking
        case night       // 21:00 local, close-out
        case onDemand    // briefNow(), unscheduled

        var displayName: String {
            switch self {
            case .morning:  return "Morning Briefing"
            case .night:    return "Night Briefing"
            case .onDemand: return "Briefing"
            }
        }
    }

    let id: UUID
    var date: Date
    var slot: Slot
    var spokenText: String
    var items: [BriefingItem]
    /// Whether this briefing reached a speaker (D117). Nil for a briefing saved
    /// before Grux recorded it, which never claims it was spoken.
    var spoken: Bool?

    // Time-aware card title. A scheduled morning/night brief keeps its label;
    // an on-demand brief is titled by the part of day it was generated in, so a
    // 5pm refresh reads "Evening Briefing", never a stale "Morning Briefing".
    var displayTitle: String {
        switch slot {
        case .morning: return "Morning Briefing"
        case .night:   return "Night Briefing"
        case .onDemand:
            switch BriefingWindow.dayPart(for: date) {
            case .morning:   return "Morning Briefing"
            case .afternoon: return "Afternoon Briefing"
            case .evening:   return "Evening Briefing"
            case .lateNight: return "Late Briefing"
            }
        }
    }

    /// The title Home shows (D179). A briefing read in a later part of the day,
    /// or on a later day, says when it was written, so "Afternoon Briefing"
    /// under "Good evening" is never taken for this evening's.
    func cardTitle(now: Date = Date()) -> String {
        let cal = BriefingWindow.calendar
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = BriefingWindow.timeZone
        f.dateFormat = "h:mm a"
        let clock = f.string(from: date)
        // A clock set back leaves a briefing dated after now: no time to come,
        // but another day is still named.
        if date > now {
            guard !cal.isDate(date, inSameDayAs: now) else { return displayTitle }
            f.dateFormat = "MMM d"
            return "\(displayTitle), \(f.string(from: date))"
        }
        if cal.isDate(date, inSameDayAs: now) {
            // Late night is two spans of one date (before 5 AM, from 10 PM).
            let early = { (d: Date) in cal.component(.hour, from: d) < 5 }
            let samePart = BriefingWindow.dayPart(for: date) == BriefingWindow.dayPart(for: now)
                && early(date) == early(now)
            return samePart ? displayTitle : "\(displayTitle), \(clock)"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "\(displayTitle), yesterday at \(clock)"
        }
        f.dateFormat = "MMM d"
        return "\(displayTitle), \(f.string(from: date)) at \(clock)"
    }

    init(id: UUID = UUID(), date: Date = Date(), slot: Slot, spokenText: String, items: [BriefingItem],
         spoken: Bool? = nil) {
        self.id = id
        self.date = date
        self.slot = slot
        self.spokenText = spokenText
        self.items = items
        self.spoken = spoken
    }
}

// MARK: - Disk layout

// Briefings live under ~/.grux/jax/briefings/, one JSON file per briefing plus
// a latest.json pointer so Home / Jax HQ can render the freshest one without
// scanning the directory. Kept in ~/.grux (not Application Support) to sit
// beside the other Jax-and-phone local state; nothing here is iCloud-mirrored
// (briefings touch private mail + ops).
enum BriefingPaths {
    static var dir: URL {
        let d = Persistence.gruxDir
            .appendingPathComponent("jax", isDirectory: true)
            .appendingPathComponent("briefings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var latestURL: URL { dir.appendingPathComponent("latest.json") }

    // Per-briefing filename: sortable timestamp + slot, so a plain directory
    // listing is already in chronological order.
    static func fileURL(for briefing: Briefing) -> URL {
        let stamp = Self.fileStampFormatter.string(from: briefing.date)
        return dir.appendingPathComponent("\(stamp)-\(briefing.slot.rawValue).json")
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = BriefingWindow.timeZone
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}

// MARK: - Settings copy for the spoken briefing (D191 item 4)

/// The Spoken replies switch and its caption, built from the gates they describe.
/// The caption said "It needs a mail account to have anything to say", while a
/// briefing names approvals, proposals, goals and the day ahead with no mail at
/// all. What mail gates is the schedule: `tick` fires a slot only when Jax HQ is
/// ready, and Jax HQ requires a mail account. Home's speaker (`briefNow`) has no
/// such gate, and `speaks` needs Tuning's Talks back as well.
enum SpokenBriefingCopy {
    static var toggleLabel: String {
        "Read me a briefing at \(clock(BriefingWindow.morningHour)) and \(clock(BriefingWindow.nightHour))"
    }

    static func caption(scheduleNeedsMail: Bool) -> String {
        let hours = "\(clock(BriefingWindow.morningHour)) and \(clock(BriefingWindow.nightHour))"
        let schedule = scheduleNeedsMail
            ? "Grux speaks a short summary of what is waiting and how the day went at \(hours), once a mail account is added in Mail."
            : "Grux speaks a short summary of what is waiting and how the day went at \(hours)."
        return "Off by default. When on, \(schedule) The speaker on Home's briefing card reads one any time. "
            + "Talks back in Tuning has to be on too. With it off the briefing is still written and still there to read, it just does not talk."
    }

    /// Whether the scheduled slots wait for a mail account: the same row `jaxHQIsReady` resolves.
    @MainActor static var scheduleNeedsMail: Bool {
        FeatureRegistry.rows.first { $0.id == "jax.hq" }?.requires.contains(.endpointImap) ?? false
    }

    static func clock(_ hour: Int) -> String {
        let h = hour % 24
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(h < 12 ? "AM" : "PM")"
    }
}

// MARK: - Window math (pure, DST-safe), mirrors FoundryGovernorWindow

enum BriefingWindow {
    // The machine's own zone. A 07:00 briefing has to mean 07:00 where the user
    // actually is, so this follows the system rather than pinning one region.
    static var timeZone: TimeZone { .current }

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    // Slot trigger hours in the user's wall-clock time.
    static let morningHour = 7
    static let nightHour = 21

    // Coarse part of day, used to frame on-demand briefings (opener, tone, card
    // title) by the CURRENT time so a briefing is never stuck saying "morning"
    // in the afternoon, and to decide when a shown briefing has gone stale.
    enum DayPart { case morning, afternoon, evening, lateNight }

    static func dayPart(for date: Date, calendar: Calendar = calendar) -> DayPart {
        switch calendar.component(.hour, from: date) {
        case 5..<12:  return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default:      return .lateNight
        }
    }

    // True when `date` falls inside a slot's firing minute window (the whole
    // top-of-hour hour). The scheduler ticks every 60s and the once-per-slot
    // per-day guard prevents a re-fire, so matching the full hour means a
    // briefing that misses 07:00:xx exactly (app launched at 07:14) still
    // fires for the morning slot the same day.
    static func activeSlot(at date: Date, calendar: Calendar = calendar) -> Briefing.Slot? {
        let hour = calendar.component(.hour, from: date)
        if hour == morningHour { return .morning }
        if hour == nightHour { return .night }
        return nil
    }

    // Once-per-window guard: same local day AND same slot already fired.
    static func sameLocalDay(_ a: Date, _ b: Date, calendar: Calendar = calendar) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    // Next firing instant strictly after `date` for a given slot. Calendar's
    // nextTimePreservingSmallerComponents policy absorbs the spring-forward
    // skip so the morning slot never silently vanishes on that one day.
    static func nextFire(slot: Briefing.Slot, after date: Date, calendar: Calendar = calendar) -> Date? {
        let hour: Int
        switch slot {
        case .morning: hour = morningHour
        case .night:   hour = nightHour
        case .onDemand: return nil
        }
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: 0),
            matchingPolicy: .nextTimePreservingSmallerComponents
        )
    }
}

// MARK: - The engine

@MainActor
final class BriefingEngine: ObservableObject {
    static let shared = BriefingEngine()

    // The freshest briefing, published so Home and Jax HQ re-render the card
    // the moment a briefing speaks. nil before the first briefing of this
    // install (Home shows its own "all quiet" state).
    @Published private(set) var latest: Briefing?

    // True while a briefing is being assembled / composed / spoken, so a Home
    // "brief me" button can disable itself and the scheduler never overlaps a
    // manual run with a scheduled one.
    @Published private(set) var isBriefing = false

    // Last fire time per scheduled slot, persisted so a relaunch inside the
    // same firing hour does not re-speak a briefing the user already heard.
    @Published private(set) var lastMorningAt: Date?
    @Published private(set) var lastNightAt: Date?

    // Throttle for passive (silent, Home-onAppear) refreshes, so a paid LLM
    // briefing fires at most once per window no matter how often Home reappears.
    private var lastPassiveRefreshAt: Date?

    private var timer: Timer?

    private struct PersistedState: Codable {
        var lastMorningAt: Date?
        var lastNightAt: Date?
    }

    private var stateURL: URL { BriefingPaths.dir.appendingPathComponent("schedule-state.json") }

    init() {
        let persisted = Persistence.load(PersistedState.self, from: stateURL, fallback: PersistedState())
        self.lastMorningAt = persisted.lastMorningAt
        self.lastNightAt = persisted.lastNightAt
        self.latest = Self.loadBriefing(from: BriefingPaths.latestURL)
            ?? Self.loadLatestFromDisk()
    }

    // Optional-returning Briefing loader. Persistence.load requires a non-nil
    // fallback of the concrete type, so wrap it: decode directly and return nil
    // on any miss (absent file, older schema). Static + nonisolated so init and
    // the disk-scan fallback can both use it.
    private static func loadBriefing(from url: URL) -> Briefing? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Briefing.self, from: data)
    }

    // MARK: - Lifecycle

    // Start the scheduler tick. Safe to call repeatedly (idempotent guard).
    // Integrator calls this once at app boot.
    func start(tickSeconds: TimeInterval = 60) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Fire one tick immediately so a launch inside a slot's hour catches up
        // without waiting a full tick interval. During the first-run flow this
        // tick is a no-op (see dueSlot): a first launch at 7:30 AM must not have
        // the Mac start talking over the onboarding screen. The timer keeps
        // running, so the catch-up lands on the first tick after the flow ends.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // The scheduler's whole decision: which slot, if any, is due right now.
    // Pure and clock-injectable so the gate below is testable without a Timer,
    // without waiting for 7:00 AM, and without the side effects of a real
    // briefing (a paid model call, a disk write, and Jax talking out loud).
    /// - Parameter featureOn: whether `jax.hq`, the feature the briefing belongs to, is
    ///   ready. Passed in rather than read here so this stays pure and testable, the same
    ///   reason `onboardingPresenting` is a parameter.
    nonisolated static func dueSlot(
        at now: Date,
        onboardingPresenting: Bool,
        featureOn: Bool,
        lastMorningAt: Date?,
        lastNightAt: Date?
    ) -> Briefing.Slot? {
        // A briefing SPEAKS, aloud, in the user's cloned voice. Behind the
        // first-run flow that is a stranger's Mac talking at them before they
        // have been asked for anything: launch at 7:30 AM and the onboarding
        // screen is the only thing on screen while the machine starts speaking.
        // So the schedule does not exist until onboarding reports done.
        //
        // The gate opens on its own and needs no relaunch. The 60s timer keeps
        // ticking through onboarding, every tick a no-op, so the first tick
        // after the flow finishes still catches up inside the slot hour. This
        // is also why the per-slot stamps are only written past this guard:
        // stamping while the flow was on screen would silently eat that day's
        // briefing.
        guard !onboardingPresenting else { return nil }

        // AND THE FEATURE HAS TO BE ON. `onboardingPresenting` is `stage != .done`, so it
        // flips false the instant somebody reaches OR SKIPS the end of the flow and never
        // returns. From that moment this spoke on schedule forever, on a machine with no
        // mail account, no model key and no feature selection.
        //
        // The app was already telling the person the opposite: the briefing's home is
        // `jax.hq`, the registry declares it `requires: endpoint.imap`, and that is
        // unresolved on a fresh Mac. Declining the feature now actually stops the engine
        // rather than stopping only the screen that shows it.
        //
        // PASSED IN like `onboardingPresenting`, for the same reason: this stays a pure
        // nonisolated function a test can drive, and the actor-bound read happens in tick().
        guard featureOn else { return nil }

        guard let slot = BriefingWindow.activeSlot(at: now) else { return nil }
        let lastForSlot: Date? = (slot == .morning) ? lastMorningAt : lastNightAt
        // Already spoke this slot today: nothing to do.
        if let last = lastForSlot, BriefingWindow.sameLocalDay(last, now) { return nil }
        return slot
    }

    // One scheduler heartbeat. Exposed for tests (call tick() directly instead
    // of waiting on the Timer). Decides whether a slot is due and, if so,
    // fires it once.
    /// READY, not merely SELECTED, and the difference is the whole fix.
    ///
    /// This was `FeatureSelection.isOn("jax.hq")`, which is what the finding suggested and
    /// what I wrote. It does nothing on the machine it was written for. `isOn` returns TRUE
    /// for everything when nobody has ever chosen (FeatureSelection.swift:50), and NOTHING IN
    /// THE APP EVER CHOOSES: every writer of a selection (`choose`, `enable`, `disable`,
    /// `clear`) lives in GruxControlTools, which is the CLI. No onboarding screen and no
    /// Settings pane writes one.
    ///
    /// Measured on the Mac Mini, which is the clean profile this was supposed to protect: its
    /// `com.gruxai.grux` domain holds four keys and `grux.features.selected` is not among
    /// them. So `isOn` answered true, `speakRepliesAloud` defaults true, and both halves of
    /// the gate were open on the one machine that had never been configured.
    ///
    /// `FeatureRegistry.state(of:)` composes both questions: it returns `.notChosen` for
    /// somebody who deselected it from the CLI, and otherwise resolves the row's
    /// requirements. `jax.hq` requires `endpoint.imap`, which is unresolved with no mail
    /// account, so a fresh Mac gets `.needsSetup` and stays quiet. That is also exactly what
    /// the app already tells the person: the tab renders a setup card.
    ///
    /// Cost is not a concern here the way it would be on a poll: this is reached at most
    /// twice a day, on a slot hour.
    @MainActor
    static func jaxHQIsReady() -> Bool {
        guard let row = FeatureRegistry.rows.first(where: { $0.id == "jax.hq" }) else {
            // No row means the registry changed underneath this. Silence is the safe answer
            // for something whose failure mode is the Mac talking out loud unbidden.
            return false
        }
        return FeatureRegistry.state(of: row) == .ready
    }

    func tick() {
        guard !isBriefing else { return }
        let now = Date()
        guard let slot = Self.dueSlot(
            at: now,
            onboardingPresenting: OnboardingModel.shared.isPresenting,
            featureOn: Self.jaxHQIsReady(),
            lastMorningAt: lastMorningAt,
            lastNightAt: lastNightAt
        ) else { return }
        // Stamp the slot BEFORE the async work so a second tick inside the same
        // minute can't double-fire while the first run is in flight.
        switch slot {
        case .morning: lastMorningAt = now
        case .night:   lastNightAt = now
        case .onDemand: break
        }
        persistState()
        Task { @MainActor [weak self] in
            await self?.runBriefing(slot: slot, speak: true)
        }
    }

    // MARK: - On-demand

    // Run a briefing right now, off-schedule. Used by the Home "brief me"
    // button and the `fire-jax-brief` CLI hook. Does not touch the slot
    // dedupe stamps, so it never suppresses the next scheduled briefing.
    func briefNow() async {
        guard !isBriefing else { return }
        await runBriefing(slot: .onDemand, speak: true)
    }

    // Keep the shown briefing live. Called when Home appears: if the latest
    // briefing is older than maxAgeMinutes OR was generated in a different part
    // of the day than now (a 7am morning brief shown at 5pm), regenerate it
    // SILENTLY (no TTS, this is a passive refresh, not a spoken briefing) and
    // time-framed for right now. This is why the card is never static.
    func refreshIfStale(maxAgeMinutes: Int = 45) async {
        guard !isBriefing else { return }
        let now = Date()
        // Inside a scheduled slot's hour (07:00 / 21:00), do NOT passively refresh:
        // the spoken scheduled brief owns that window, and a silent refresh in
        // flight could otherwise block the scheduled tick and drop the day's brief.
        if BriefingWindow.activeSlot(at: now) != nil { return }
        // Throttle paid LLM refreshes regardless of staleness/dayPart, so tab-
        // hopping back to Home (which re-fires onAppear) across a dayPart boundary
        // cannot trigger repeated full briefings.
        if let last = lastPassiveRefreshAt, now.timeIntervalSince(last) < 45 * 60 { return }
        if let l = latest {
            let fresh = now.timeIntervalSince(l.date) < Double(maxAgeMinutes) * 60
            let samePart = BriefingWindow.dayPart(for: l.date) == BriefingWindow.dayPart(for: now)
            if fresh && samePart { return }
        }
        lastPassiveRefreshAt = now
        await runBriefing(slot: .onDemand, speak: false)
    }

    // MARK: - Core run

    private func runBriefing(slot: Briefing.Slot, speak shouldSpeak: Bool) async {
        isBriefing = true
        defer { isBriefing = false }

        WakeLog.shared.log("jax briefing: assembling \(slot.rawValue)\(shouldSpeak ? "" : " (silent refresh)")…")
        let items = assembleItems(slot: slot)
        let spoken = await composeSpokenText(slot: slot, items: items, sources: currentSources())

        // Whether a person heard it, recorded before it is saved, so Jax HQ never
        // labels a briefing spoken that no speaker played (D117).
        let config = AppState.shared.config
        let spoke = Self.speaks(asked: shouldSpeak, spokenBriefingsEnabled: config.spokenBriefingsEnabled,
                                speakRepliesAloud: config.speakRepliesAloud,
                                voiceMuted: AppState.shared.voiceMuted, silent: AudioOutput.isSilent)
        let briefing = Briefing(slot: slot, spokenText: spoken, items: items, spoken: spoke)
        persist(briefing)
        latest = briefing

        if shouldSpeak { speak(spoken) }
        WakeLog.shared.log("jax briefing: \(slot.rawValue) done, \(items.count) item\(items.count == 1 ? "" : "s")"
                           + (spoke ? " (spoke)" : shouldSpeak ? " (written, not spoken)" : ""))
    }

    /// Whether a briefing reaches a speaker: asked to speak, spoken briefings on,
    /// replies aloud on, not muted, and not silenced by SILENT or HEADLESS. The
    /// same gates `speak` and the silence facade apply, in one answer.
    nonisolated static func speaks(asked: Bool, spokenBriefingsEnabled: Bool, speakRepliesAloud: Bool,
                       voiceMuted: Bool, silent: Bool) -> Bool {
        asked && spokenBriefingsEnabled && speakRepliesAloud && !voiceMuted && !silent
    }

    // MARK: - Speaking

    private func speak(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        // THE MAC DOES NOT TALK OUT LOUD TO SOMEBODY WHO HAS NOT SAID IT MAY.
        //
        // Measured on a fresh install: a person clicks through the first run flow at 9:20 PM
        // and within a minute the speakers say "End of the day. Nothing urgent needs you
        // right now. The empire is steady." No dialog preceded it and no key was needed,
        // because SpeechEngine falls through to system TTS when the ElevenLabs key is empty.
        // It happened again at 07:00. There was no setting anywhere that silenced it.
        //
        // Settings > Spoken replies > "Speak Grux's replies aloud" is the control, so the
        // off is the one already on screen and it already survives a restart. This was the
        // one scheduled speaker that did not read it: MorningBrief:51, DailyRecap:86 and
        // EnergyRecapScheduler:68 all do. The mute rides along because ChatService and
        // PIMConfirmationCard pair the two, though note it is session-only and ChatView
        // labels it "chat only", so it is the toggle above that actually silences this.
        //
        // ON ITS OWN THIS FIXES ONLY HALF THE FINDING. `speakRepliesAloud` DEFAULTS TO TRUE
        // (Models.swift:1006), so a fresh Mac still passes here. What stops the fresh Mac is
        // the feature gate in dueSlot; this is what gives the person somewhere to turn it
        // off afterwards, which the finding asked for separately and by name.
        // ITS OWN SWITCH, and this is the half the readiness gate cannot cover. That gate
        // asks whether Jax HQ is ready, which means "is there a mail account". Connecting an
        // inbox is not consent to be spoken to twice a day, and `endpoint.imap` is the LAST
        // step of the connections flow, so without this the first person to finish that flow
        // got a talking Mac at 07:00 having never been asked about briefings.
        //
        // Off by default. The briefing still runs and is still there to read; what it does
        // not do is start talking.
        guard AppState.shared.config.spokenBriefingsEnabled else { return }
        guard AppState.shared.config.speakRepliesAloud,
              !AppState.shared.voiceMuted else { return }
        // Voice-first: Jax speaks in the user's ElevenLabs clone via SpeechEngine.
        // speak() already routes through the configured voiceId (their clone,
        // config.elevenLabsVoiceId) and falls back to system TTS offline. Use
        // speakAfterCurrent so a briefing never cuts off a live conversation or
        // a streaming chat reply already in flight; it waits for a quiet window.
        SpeechEngine.shared.speakAfterCurrent(cleaned, maxWaitSeconds: 90)
    }

    // MARK: - Item assembly (READ-ONLY from live stores)

    // Pulls "what needs you" out of the same stores the rest of the app reads.
    // Nothing here mutates a store; every value is a snapshot. The model turns
    // these structured items into the spoken paragraph; the items themselves
    // render as the card rows in Home / Jax HQ.
    private func assembleItems(slot: Briefing.Slot) -> [BriefingItem] {
        var items: [BriefingItem] = []

        // 1. Emails needing the user. The same rule as the rail's Mail badge and
        //    Today's card (`MailNeedsYou.counts`), so the three never disagree;
        //    this used to take every UNREAD message, newsletters included,
        //    while the badge said 17 of 53 actually needed a reply.
        items += Self.mailItems(MailStore.shared.messages)

        // 2. Ops signal: the autonomous Meta ads engine snapshot, if present.
        //    Read-only from the on-disk snapshot the MetaAds tab already reads
        //    (~/.grux/meta-ads-snapshot.json). Soft: any parse failure simply
        //    yields no ops item, never a thrown error.
        if let ops = readMetaAdsOpsSignal() {
            items.append(ops)
        }

        // 3. Goals advanced overnight: roadmap items that completed in the
        //    trailing window. For the night brief this is "what moved today";
        //    for the morning brief it is "what moved while you slept".
        let since = goalLookbackStart(for: slot)
        let advanced = RoadmapStore.shared.items
            .filter { $0.status == .done }
            .filter { ($0.completedAt ?? .distantPast) >= since }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(4)
        for goal in advanced {
            items.append(BriefingItem(
                kind: .goalAdvanced,
                title: goal.title,
                detail: goal.subtitle
            ))
        }

        // 4. Today's agenda (morning + on-demand only; the night brief looks
        //    back, not ahead). Calendar highlights, read-only.
        if slot != .night, CalendarService.shared.hasAccess {
            let cal = Calendar.current
            let now = Date()
            let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
            let agenda = CalendarService.shared.events(from: now, to: endOfDay)
                .filter { cal.isDate($0.start, inSameDayAs: now) }
                .map { ev -> BriefingItem in
                    let title = ev.title.isEmpty ? "(untitled)" : ev.title
                    let when = ev.isAllDay ? "All day" : Self.clockLabel(ev.start)
                    return BriefingItem(kind: .agenda, title: title, detail: when)
                }
            items += Self.summarized(agenda, cap: 4)
        }

        // 5. Top NOW / NEXT tasks to hit (morning + on-demand). Snapshot of the
        //    same FocusTask pool Home reads.
        if slot != .night {
            let nows = AppState.shared.activeTasks.filter { $0.priority == .now }
            let nexts = AppState.shared.activeTasks.filter { $0.priority == .next }
            items += Self.summarized((nows + nexts).map {
                BriefingItem(kind: .task, title: $0.title, detail: $0.project)
            }, cap: 3)
        }

        // 6. Things parked in the approval queue and Foundry proposals
        //    waiting on the user's tap: one summary row each, counting every
        //    item and naming what the cards say (D143).
        items += Self.waitingItems(
            approvals: JaxApprovalCount.titles(),
            turnedDown: JaxApprovalCount.turnedDownTitles(),
            proposals: ProposalStore.waitingForReview(ProposalStore.shared.proposals).map(\.title)
        )

        // 7. The day's decisions, one line, and only when there were some: a
        //    briefing that says "no decisions yet" at 7 AM every morning is
        //    noise (Phase D, D4).
        if let decisions = Self.decisionItem(DecisionUsageSummary.today(DecisionLedger.shared.recent)) {
            items.append(decisions)
        }

        return items
    }

    /// Which sources this briefing can see: a mailbox connected, calendar
    /// access, an ops snapshot on disk. What it cannot see it never vouches for.
    private func currentSources() -> BriefingSources {
        BriefingSources(mail: !EmailAccountStore.shared.accounts.isEmpty,
                        calendar: CalendarService.shared.hasAccess,
                        ops: readMetaAdsOpsSignal() != nil)
    }

    /// Mail that needs the person, newest first, five at most.
    nonisolated static func mailItems(_ messages: [EmailMessage], limit: Int = 5) -> [BriefingItem] {
        messages.filter(MailNeedsYou.counts)
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { msg in
                let from = msg.fromName.isEmpty ? msg.fromEmail : msg.fromName
                let subject = msg.subject.isEmpty ? "(no subject)" : msg.subject
                return BriefingItem(kind: .emailNeedsYou, title: subject, detail: "from \(from)")
            }
    }

    /// "24 decisions today, 512 ms average, under $0.01", or nothing at all.
    nonisolated static func decisionItem(_ summary: DecisionUsageSummary) -> BriefingItem? {
        guard !summary.isEmpty else { return nil }
        return BriefingItem(kind: .decisions, title: summary.line, detail: summary.providerPhrase)
    }

    // The window for "goals advanced". Night brief: since 04:00 today (the day's
    // work). Morning / on-demand: the trailing 18 hours (overnight + yesterday
    // evening). Pinned to the machine's own zone so the boundary tracks the
    // user's day.
    private func goalLookbackStart(for slot: Briefing.Slot) -> Date {
        let cal = BriefingWindow.calendar
        let now = Date()
        switch slot {
        case .night:
            return cal.date(bySettingHour: 4, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(-18 * 3600)
        case .morning, .onDemand:
            return now.addingTimeInterval(-18 * 3600)
        }
    }

    // Reads the Meta ads engine snapshot the MetaAds tab writes and turns its
    // pacing into one ops line. Soft by design: any missing file / parse miss
    // returns nil so the briefing simply omits ops rather than failing.
    private func readMetaAdsOpsSignal() -> BriefingItem? {
        let url = Persistence.gruxDir
            .appendingPathComponent("meta-ads-snapshot.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Snapshot shape is owned by the companion engine; read leniently. Mode +
        // today's spend vs the daily cap are the two figures worth speaking.
        let mode = (obj["mode"] as? String) ?? "observe"
        let spendToday = (obj["spendToday"] as? Double)
            ?? (obj["spend_today"] as? Double)
            ?? 0
        let dailyCap = (obj["dailyCap"] as? Double)
            ?? (obj["daily_cap"] as? Double)
            ?? 16

        let detail = String(format: "$%.0f of $%.0f spent today, mode %@",
                            spendToday, dailyCap, mode)
        return BriefingItem(kind: .opsSignal, title: "Meta ads pacing", detail: detail)
    }

    private static func clockLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = BriefingWindow.timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    // MARK: - Compose spoken text (Jax persona, first-person-to-the-user)

    private func composeSpokenText(slot: Briefing.Slot, items: [BriefingItem], sources: BriefingSources) async -> String {
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so on a local-only or custom-endpoint install
        // every briefing was the deterministic fallback and the paid path was
        // unreachable. No key on the ROUTED provider still falls back to a
        // deterministic spoken brief so Jax always has something to say (same
        // posture as MorningBrief's offline path). Resolved ONCE per briefing.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty, Self.draftsWithModel(on: ModelRegistry.shared.resolvedProvider) else {
            return Self.fallbackSpoken(slot: slot, items: items)
        }

        let needsReply = items.filter { $0.kind == .emailNeedsYou }
        let ops = items.filter { $0.kind == .opsSignal }
        let goals = items.filter { $0.kind == .goalAdvanced }
        let agenda = items.filter { $0.kind == .agenda }
        let tasks = items.filter { $0.kind == .task }

        let tone: String
        switch slot {
        case .morning:
            tone = "This is the MORNING briefing. Forward-looking. Open the day. Lead with what needs them first, then point at the day ahead. Something like \"morning, three things need you today...\""
        case .night:
            tone = "This is the NIGHT briefing. A close-out. Look back at what moved today and flag what is still open going into tomorrow. Calm, settling, not a fresh to-do dump."
        case .onDemand:
            // Frame by the CURRENT part of day so the greeting and outlook match
            // the wall clock. Past appointments are past; do not say "morning"
            // in the afternoon.
            switch BriefingWindow.dayPart(for: Date()) {
            case .morning:
                tone = "This is a fresh briefing right now, in the MORNING. Forward-looking. Open the day. Lead with what needs them first, then the day ahead. Open with \"morning\"."
            case .afternoon:
                tone = "This is a fresh briefing right now, in the AFTERNOON. Midday check-in: where the day stands, what they have handled, and what still needs them before evening. Treat anything earlier today as already done. Open with \"afternoon\"."
            case .evening:
                tone = "This is a fresh briefing right now, in the EVENING. Winding down: what moved today and what is still open going into tomorrow. Today's earlier appointments are done. Open with \"evening\"."
            case .lateNight:
                tone = "This is a fresh briefing right now, LATE at night. Brief and calm: just what is genuinely still open. Today is over. Open with \"late check\"."
            }
        }

        // The model speaks AS Jax: the user's own mind, talking to them, in the
        // first person. The persona header carries the disclosure +
        // guardrail self-knowledge; this prompt only governs THIS briefing's
        // register and shape.
        let sys = """
        \(JaxProfile.shared.persona)

        RIGHT NOW you are speaking a spoken briefing directly to the user, out loud, in their own voice clone. \(tone)

        \(Self.spokenRules)
        """

        let user = """
        SLOT: \(slot.rawValue)
        NOW: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))

        EMAILS_NEEDING_YOU (unread, want a reply):
        \(Self.sourceLines(needsReply, connected: sources.mail))

        OPS_SIGNAL (ad pacing / operations):
        \(Self.sourceLines(ops, connected: sources.ops))

        GOALS_ADVANCED (roadmap items that moved):
        \(Self.sourceLines(goals, connected: true))

        AGENDA_TODAY (calendar):
        \(Self.sourceLines(agenda, connected: sources.calendar))

        TASKS_ON_DECK (NOW then NEXT):
        \(Self.sourceLines(tasks, connected: true))

        \(Self.waitingPromptSections(items))

        Speak the briefing now (45 to 90 words, one paragraph, out loud to the user):
        """

        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 320,
                temperature: 0.55,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "jaxBriefing"
            )
            let cleaned = Self.sanitize(reply)
            if cleaned.isEmpty { return Self.fallbackSpoken(slot: slot, items: items) }
            // POST grounding: a spoken briefing that asserts a product price/size/SKU that
            // contradicts the catalog is the $18 bug, spoken aloud. Vet against the catalog;
            // if it is not surfaceable, speak the deterministic fallback (real counts only,
            // never an invented number) instead of the model's line.
            let briefForVet = "\(slot.rawValue) briefing. \(Self.sourceLines(ops, connected: true)) \(Self.sourceLines(goals, connected: true))"
            let verdict = GroundingGate.vet(draft: cleaned, brief: briefForVet)
            guard verdict.surfaceable else {
                WakeLog.shared.log("jax briefing: blocked ungrounded fact, speaking fallback. \(verdict.refusalLine)")
                return Self.fallbackSpoken(slot: slot, items: items)
            }
            if let reason = Self.overclaim(cleaned, sources: sources) {
                WakeLog.shared.log("jax briefing: draft \(reason), speaking fallback.")
                return Self.fallbackSpoken(slot: slot, items: items)
            }
            return cleaned
        } catch {
            WakeLog.shared.log("jax briefing compose FAILED: \(error.localizedDescription)")
            return Self.fallbackSpoken(slot: slot, items: items)
        }
    }

    /// Whether the briefing on this route is drafted by the model. D139, live on
    /// 616a32a6 at 5:46 PM with qwen3.5:4b: of six drafts, four were refused and
    /// the two that passed every check still invented ("so we pause operations
    /// for that day", "need your final sign-off before they proceed", "a spend
    /// request"). A small local model does not keep the briefing's rules, so on
    /// the local route the briefing is composed from its items, every time.
    nonisolated static func draftsWithModel(on provider: ActiveProvider) -> Bool { provider != .local }

    /// The spoken briefing's rules, one string so a test can read what the model is told.
    nonisolated static let spokenRules = """
    Rules for the spoken briefing:
    - First person, talking straight to them. You are their mind, so speak as them to them: "morning, here is where we stand", "you have two emails that actually need you", "the storefront moved overnight".
    - One short flowing paragraph, 45 to 90 words. No lists, no bullets, no headings, no markdown. Plain spoken prose, this is read aloud.
    - Lead with the things that NEED them (emails to reply to, anything waiting for their OK). Then ops, then goals that moved, then the day ahead.
    - Be sharp and economical. Name the one or two things that matter most, do not recite everything.
    - If nothing genuinely needs them, say so honestly and briefly. Do not invent urgency.
    - You have taken no action. Never say you did, queued, sent, moved, scheduled, or are tracking anything: TASKS_ON_DECK are things on their list for them to do.
    - You hold nothing and will do nothing: never that you are holding, waiting on, ready for or about to do anything, and never what you will do next.
    - Never say they are off or have the day off, even for a holiday or an entry that reads like one: name what is on the calendar.
    - A section marked not connected is something you cannot see. Say nothing about it, never that it is clear or quiet.
    - Say nothing that is not in the sections below.
    - No em dashes and no en dashes. Use commas, periods, or colons.
    - No emoji. No vendor, model, or tech-stack names.
    """

    /// One section of the briefing prompt. A source Grux cannot see is named as
    /// unseen: "(none)" for it read to the model like a connected source with
    /// nothing in it, and it told a person with no mailbox that the day was
    /// "clear of urgent emails" (D121).
    nonisolated static func sourceLines(_ items: [BriefingItem], connected: Bool) -> String {
        guard connected else { return "(not connected: Grux cannot see this, so say nothing about it)" }
        guard !items.isEmpty else { return "(none)" }
        return items.map { i in
            if let names = i.names {
                let total = i.count ?? names.count
                var lines = ["- \(i.title):"] + names.prefix(promptNameCap).map { "  - \(spokenTitle($0))" }
                let named = min(names.count, promptNameCap)
                if total > named { lines.append("  - and \(total - named) more") }
                return lines.joined(separator: "\n")
            }
            return i.detail.isEmpty ? "- \(i.title)" : "- \(i.title) (\(i.detail))"
        }.joined(separator: "\n")
    }

    /// Why a drafted briefing says more than Grux knows, or nil when it does not.
    /// The briefing reads sources and lists; it takes no action, so a first
    /// person claim of one ("I've queued a backup", "I'm already tracking") is
    /// invented, and a word about mail, the calendar or ops with that source not
    /// connected vouches for something Grux cannot see (D121). A refused draft is
    /// replaced by `fallbackSpoken`, which says only real counts.
    nonisolated static func overclaim(_ draft: String, sources: BriefingSources) -> String? {
        let text = draft.replacingOccurrences(of: "\u{2019}", with: "'")
        if let claim = firstMatch(in: text, of: claimedActionPatterns) {
            return "claims an action Grux did not take: \"\(claim)\""
        }
        if let claim = firstMatch(in: text, of: claimedHoldPatterns) {
            return "claims a hold or a plan Grux does not have: \"\(claim)\""
        }
        if firstMatch(in: text, of: dayOffPatterns) != nil {
            return "says they have the day off"
        }
        if !sources.mail, firstMatch(in: text, of: [#"\b(e-?mails?|inbox(es)?|mailbox(es)?|mail)\b"#]) != nil {
            return "mentions mail with no mailbox connected"
        }
        if !sources.calendar,
           firstMatch(in: text, of: [#"\b(calendar|meetings?|appointments?|agenda|schedule)\b"#]) != nil {
            return "mentions the calendar with no calendar access"
        }
        if !sources.ops, firstMatch(in: text, of: [#"\b(ops|ads|ad spend|ad pacing)\b"#]) != nil {
            return "mentions ops with no ops snapshot"
        }
        return nil
    }

    // "I've queued", "we have already moved", "I watered", "I just booked", "I'm
    // already tracking". Verbs of looking ("I noticed", "I've checked") are not
    // actions on the person's things and pass.
    nonisolated private static let claimedActionPatterns: [String] = [
        #"\b(i|we)('ve| have| had)\s+(already\s+|just\s+)?(?!(noticed|looked|checked|counted|spotted|flagged)\b)([a-z]+ed|done|sent|made|set up|taken( care)?|built|written|run|put|got)\b"#,
        #"\b(i|we)\s+(already\s+|just\s+)?(queued|scheduled|sent|booked|moved|watered|backed up|ordered|paid|replied|filed|archived|deleted|cancell?ed|created|added|started|finished|completed|handled|fixed|called|emailed|posted|published|launched|cleared|took|did|made|wrote|ran|set up)\b"#,
        #"\b(i'm|i am|we're|we are)\s+(already\s+)?(tracking|watching|monitoring|handling|working on|keeping|taking care)\b"#,
    ]

    // D139, sense pass 16: "I am holding back on the Mini backup and plant
    // watering until you confirm", "need your green light before I proceed",
    // "Grux is ready to fire those focus reminders". The briefing holds nothing,
    // waits on nothing and plans nothing, so a first person hold, readiness or
    // promise is as invented as a past action. Words about the person's own
    // approvals waiting ("two things are waiting for your OK") have no first
    // person subject and pass.
    nonisolated private static let claimedHoldPatterns: [String] = [
        #"\b(i'm|i am|we're|we are|grux is|grux's)\s+(still\s+|just\s+)?(holding|waiting|pausing|parking|sitting on|standing by|ready|all set|set to|about to|going to)\b"#,
        #"\b(i|we|grux)\s+(am\s+|are\s+|is\s+)?(holding|waiting)\s+(back|off|on)\b"#,
        #"\bbefore (i|we|grux) (can\s+)?(proceed|go ahead|start|run|continue|move|act)\b"#,
        #"\b(i'll|i will|we'll|we will|grux will|grux'll|i'm going to|i am going to)\b"#,
    ]

    // "You have all day off due to the Day of the Dead": a holiday is not the
    // person's day off, and neither is an entry that says so, which may be a
    // colleague's "Sam OOO" on a shared calendar (wave 42 review, three rounds).
    // The briefing never says they are off; the composed one names the entry.
    nonisolated private static let dayOffPatterns: [String] = [
        #"\b(all\s+)?(the\s+|a\s+)?days?\s+off\b"#,
        #"\b(you're|you are)\s+off\b"#,
        #"\boff work\b"#,
    ]
    nonisolated private static func firstMatch(in text: String, of patterns: [String]) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: range),
                  let r = Range(m.range, in: text) else { continue }
            return String(text[r])
        }
        return nil
    }

    // Strip the model's stray formatting and enforce the no-dash house rule on
    // anything the user will hear / read.
    nonisolated static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out
            .replacingOccurrences(of: "\u{2014}", with: ", ")  // em dash
            .replacingOccurrences(of: "\u{2013}", with: ", ")  // en dash
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\"", with: "")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // The prompt says open with "afternoon", and the model wrote it lowercase
        // as the briefing's first word (D139, `jaxHQ-page1.png`).
        guard let first = out.first, first.isLowercase else { return out }
        return first.uppercased() + out.dropFirst()
    }

    // Deterministic spoken brief for the no-key / model-failure path. Pure and
    // nonisolated so it unit-tests without booting the singleton graph. Never
    // produces a dash (house rule).
    nonisolated static func fallbackSpoken(slot: Briefing.Slot, items: [BriefingItem]) -> String {
        let needsReply = items.filter { $0.kind == .emailNeedsYou }.count
        // D179: each place is counted apart and named, so the number matches
        // what the person finds when they open Approvals or Self-Upgrade.
        let approvals = items.filter { $0.kind == .approvalPending }
        let proposals = items.filter { $0.kind == .proposalPending }
        let waiting = total(approvals) + total(proposals)
        let goals = items.filter { $0.kind == .goalAdvanced }.count

        let opener: String
        switch slot {
        case .morning:  opener = "Morning."
        case .night:    opener = "End of the day."
        case .onDemand:
            switch BriefingWindow.dayPart(for: Date()) {
            case .morning:   opener = "Morning."
            case .afternoon: opener = "Afternoon."
            case .evening:   opener = "Evening."
            case .lateNight: opener = "Late check."
            }
        }

        var parts: [String] = [opener]
        if needsReply > 0 {
            parts.append("\(needsReply) email\(needsReply == 1 ? "" : "s") need\(needsReply == 1 ? "s" : "") a reply from you.")
        }
        // D143: what waits, by name, as the cards show it.
        let ok = total(approvals)
        if ok > 0 {
            let line = "\(ok) thing\(ok == 1 ? "" : "s") \(ok == 1 ? "is" : "are") waiting for your OK in Approvals"
            let names = approvals.flatMap { $0.names ?? [] }.map(spokenTitle)
            parts.append(spokenList(names, total: ok).map { "\(line): \($0)." } ?? "\(line).")
        }
        let review = total(proposals)
        if review > 0 {
            let line = "\(review) self-upgrade proposal\(review == 1 ? " is" : "s are") waiting for your review in Self-Upgrade"
            let names = proposals.flatMap { $0.names ?? [] }.map(spokenTitle)
            parts.append(spokenList(names, total: review).map { "\(line): \($0)." } ?? "\(line).")
        }
        if goals > 0 {
            parts.append("\(goals) goal\(goals == 1 ? "" : "s") moved.")
        }
        if needsReply == 0 && waiting == 0 && goals == 0 {
            parts.append(quietFallbackLine)
        }
        // D169: a card the tray would turn down is named as that, never as an OK to give.
        let turnedDown = items.filter { $0.kind == .approvalTurnedDown }
        if let names = spokenList(turnedDown.flatMap { $0.names ?? [] }.map(spokenTitle), total: total(turnedDown)) {
            // "too" only beside the approvals line (wave 61 review).
            let too = ok > 0 ? " too" : ""
            parts.append(total(turnedDown) == 1
                ? "\(names) is in Approvals\(too), but it would be turned down if approved now; its card says why."
                : "\(names) are in Approvals\(too), but they would be turned down if approved now; their cards say why.")
        }
        // D124: the day ahead and the list, by name, as the items hold them. An
        // agenda item exists only when the calendar could be read.
        let events = items.filter { $0.kind == .agenda }
        let agenda = events.map { e -> String in
            let title = spokenTitle(e.title)
            return e.detail.isEmpty ? title : (e.detail == "All day" ? "\(title), all day" : "\(title) at \(e.detail)")
        }
        if let line = spokenList(agenda, total: total(events)) { parts.append("On your calendar: \(line).") }
        let tasks = items.filter { $0.kind == .task }
        if let line = spokenList(tasks.map { spokenTitle($0.title) }, total: total(tasks)) {
            parts.append("On your list: \(line).")
        }
        return parts.joined(separator: " ")
    }

    /// What waits, as the drafting model is handed it: each place under its
    /// own heading (D179, wave 61 review: approvals and proposals shared one
    /// "waiting for your OK" heading, so a draft counted a proposal as an OK
    /// the tray does not hold).
    nonisolated static func waitingPromptSections(_ items: [BriefingItem]) -> String {
        """
        WAITING_FOR_YOUR_OK_IN_APPROVALS (only these are waiting for an OK):
        \(sourceLines(items.filter { $0.kind == .approvalPending }, connected: true))

        SELF_UPGRADE_PROPOSALS_FOR_REVIEW (in Self-Upgrade, not in Approvals; never count these as waiting for an OK):
        \(sourceLines(items.filter { $0.kind == .proposalPending }, connected: true))

        TURNED_DOWN_IF_APPROVED (in Approvals, but approving would be refused now; never ask for an OK on these):
        \(sourceLines(items.filter { $0.kind == .approvalTurnedDown }, connected: true))
        """
    }

    /// The rows for what waits on the person's tap: one for approvals, one for
    /// self-upgrade proposals, each counting every item and carrying the titles
    /// the cards show (D143: with only a count, a drafted briefing guessed what
    /// was waiting). A blank title counts and is never named.
    nonisolated static func waitingItems(approvals: [String], turnedDown: [String] = [], proposals: [String]) -> [BriefingItem] {
        func row(_ kind: BriefingItem.Kind, _ titles: [String], _ title: String) -> BriefingItem {
            let names = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return BriefingItem(kind: kind, title: title,
                                detail: spokenList(names.map(spokenTitle), total: titles.count) ?? "",
                                count: titles.count, names: names)
        }
        var items: [BriefingItem] = []
        if !approvals.isEmpty {
            items.append(row(.approvalPending, approvals, "\(approvals.count) waiting for your OK"))
        }
        // D169: what the tray would turn down is not waiting for an OK.
        if !turnedDown.isEmpty {
            items.append(row(.approvalTurnedDown, turnedDown, "\(turnedDown.count) would be turned down if approved now"))
        }
        if !proposals.isEmpty {
            items.append(row(.proposalPending, proposals,
                             "\(proposals.count) self-upgrade proposal\(proposals.count == 1 ? "" : "s")"))
        }
        return items
    }

    /// How many names a row hands the model; the rest are counted.
    nonisolated static let promptNameCap = 5

    /// The first `cap` items, the last of them standing for itself and every
    /// item left out (its `count`), so "and N more" counts the whole list and
    /// not only what was kept (wave 42 review: 7 tasks were spoken as 3).
    nonisolated static func summarized(_ items: [BriefingItem], cap: Int) -> [BriefingItem] {
        var kept = Array(items.prefix(cap))
        guard items.count > kept.count, !kept.isEmpty else { return kept }
        kept[kept.count - 1].count = 1 + items.count - kept.count
        return kept
    }

    /// "A", "A and B", "A, B, and 2 more": two named, the rest counted.
    /// `total` is how many things the names stand for, left out ones included.
    nonisolated private static func spokenList(_ names: [String], total: Int) -> String? {
        switch (names.count, total) {
        case (0, _): return nil
        case (1, 1): return names[0]
        case (2, 2): return "\(names[0]) and \(names[1])"
        case (1, _): return "\(names[0]), and \(total - 1) more"
        default: return "\(names[0]), \(names[1]), and \(total - 2) more"
        }
    }

    nonisolated private static func total(_ items: [BriefingItem]) -> Int {
        items.reduce(0) { $0 + ($1.count ?? 1) }
    }

    /// A stored title as the briefing speaks it: no dashes (house rule) and no
    /// closing mark of its own before the sentence's period ("Call mom?.").
    nonisolated private static func spokenTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: ", ")
            .replacingOccurrences(of: #"\s+,"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while let last = t.last, ".?!".contains(last) { t.removeLast() }
        return t.contains(where: { $0.isLetter || $0.isNumber }) ? t : "(untitled)"
    }

    // Said to every keyless stranger on a quiet day, so it carries none of the
    // owner's words (wave 35: it closed with "The empire is steady.").
    nonisolated static let quietFallbackLine = "Nothing urgent needs you right now."

    // MARK: - Persistence

    private func persist(_ briefing: Briefing) {
        Persistence.save(briefing, to: BriefingPaths.fileURL(for: briefing))
        Persistence.save(briefing, to: BriefingPaths.latestURL)
    }

    private func persistState() {
        Persistence.save(
            PersistedState(lastMorningAt: lastMorningAt, lastNightAt: lastNightAt),
            to: stateURL
        )
    }

    // Fallback when latest.json is absent (older install, manual delete):
    // pick the newest per-briefing file by name (filenames are timestamp-sorted).
    private static func loadLatestFromDisk() -> Briefing? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: BriefingPaths.dir, includingPropertiesForKeys: nil
        ) else { return nil }
        let candidates = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "latest.json" && $0.lastPathComponent != "schedule-state.json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let newest = candidates.first else { return nil }
        return loadBriefing(from: newest)
    }
}

// MARK: - Approval-queue count seam

// Lightweight, decoupled read of how many items sit in the Jax HQ approval
// queue. The ApprovalQueue store is a sibling Jax module built in parallel;
// to avoid a hard compile-time coupling to a type/signature that may still be
// in flux, this seam reads the on-disk queue directly with a lenient shape and
// returns 0 on any miss. If the integrator wires a live count later, replace
// the body with `ApprovalQueue.shared.pendingCount` (same return value).
// D125: the briefing counts what the approval queue itself says is waiting.
// Until 2026-11-01 this re-read a JSON file by hand: the wrong file (Application
// Support, where the queue never writes), filtered on a `status` key the queue
// never writes, so the briefing never named a waiting approval. Reading the
// queue leaves one rule for "waiting", the one Approvals and Now use.
@MainActor
enum JaxApprovalCount {
    static func pending(in queue: ApprovalQueue = .shared) -> Int {
        queue.pendingCount
    }

    /// What each waiting approval's card says, in the queue's order, leaving
    /// out a card the tray would turn down if approved now (D169).
    static func titles(in queue: ApprovalQueue = .shared) -> [String] {
        let on = queue.foundryEnabled()
        return queue.pending.filter { CannotRunNow.cardLine(for: $0, foundryEnabled: on) == nil }.map(\.action.summary)
    }

    /// The cards the tray holds Approve on (`CannotRunNow.cardLine`, the tray's own rule).
    static func turnedDownTitles(in queue: ApprovalQueue = .shared) -> [String] {
        let on = queue.foundryEnabled()
        return queue.pending.filter { CannotRunNow.cardLine(for: $0, foundryEnabled: on) != nil }.map(\.action.summary)
    }
}

struct BriefingSources: Equatable, Sendable {
    var mail: Bool
    var calendar: Bool
    var ops: Bool
}
