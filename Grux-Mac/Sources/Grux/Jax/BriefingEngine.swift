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

        var label: String {
            switch self {
            case .emailNeedsYou:   return "Needs a reply"
            case .opsSignal:       return "Ops"
            case .goalAdvanced:    return "Goal advanced"
            case .agenda:          return "Today"
            case .task:            return "On deck"
            case .approvalPending: return "Awaiting your tap"
            case .proposalPending: return "Self-upgrade"
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
            }
        }
    }

    let id: UUID
    var kind: Kind
    var title: String
    var detail: String

    init(id: UUID = UUID(), kind: Kind, title: String, detail: String = "") {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
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

    init(id: UUID = UUID(), date: Date = Date(), slot: Slot, spokenText: String, items: [BriefingItem]) {
        self.id = id
        self.date = date
        self.slot = slot
        self.spokenText = spokenText
        self.items = items
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
        let d = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
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
        let spoken = await composeSpokenText(slot: slot, items: items)

        let briefing = Briefing(slot: slot, spokenText: spoken, items: items)
        persist(briefing)
        latest = briefing

        if shouldSpeak { speak(spoken) }
        WakeLog.shared.log("jax briefing: \(slot.rawValue) done, \(items.count) item\(items.count == 1 ? "" : "s")\(shouldSpeak ? " (spoke)" : "")")
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

        // 1. Emails needing the user: unread messages across synced inboxes. These
        //    are the "needs a reply" rows. Cap so a flooded inbox does not
        //    drown the briefing.
        let unread = MailStore.shared.messages
            .filter { $0.isUnread }
            .prefix(5)
        for msg in unread {
            let from = msg.fromName.isEmpty ? msg.fromEmail : msg.fromName
            let subject = msg.subject.isEmpty ? "(no subject)" : msg.subject
            items.append(BriefingItem(
                kind: .emailNeedsYou,
                title: subject,
                detail: "from \(from)"
            ))
        }

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
                .prefix(4)
            for ev in agenda {
                let title = ev.title.isEmpty ? "(untitled)" : ev.title
                let when = ev.isAllDay ? "All day" : Self.clockLabel(ev.start)
                items.append(BriefingItem(kind: .agenda, title: title, detail: when))
            }
        }

        // 5. Top NOW / NEXT tasks to hit (morning + on-demand). Snapshot of the
        //    same FocusTask pool Home reads.
        if slot != .night {
            let nows = AppState.shared.activeTasks.filter { $0.priority == .now }
            let nexts = AppState.shared.activeTasks.filter { $0.priority == .next }
            for t in (nows + nexts).prefix(3) {
                items.append(BriefingItem(
                    kind: .task,
                    title: t.title,
                    detail: t.project
                ))
            }
        }

        // 6. Things parked in the Jax HQ approval queue and Foundry proposals
        //    waiting on the user's tap. Counts surfaced as single summary rows so
        //    they read as "you have N waiting", not a wall of detail.
        let pendingApprovals = JaxApprovalCount.pending()
        if pendingApprovals > 0 {
            items.append(BriefingItem(
                kind: .approvalPending,
                title: "\(pendingApprovals) waiting on your tap",
                detail: "Jax HQ approval queue"
            ))
        }
        let pendingProposals = ProposalStore.shared.ranked().count
        if pendingProposals > 0 {
            items.append(BriefingItem(
                kind: .proposalPending,
                title: "\(pendingProposals) self-upgrade proposal\(pendingProposals == 1 ? "" : "s")",
                detail: "awaiting your review"
            ))
        }

        return items
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
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
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

    private func composeSpokenText(slot: Briefing.Slot, items: [BriefingItem]) async -> String {
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so on a local-only or custom-endpoint install
        // every briefing was the deterministic fallback and the paid path was
        // unreachable. No key on the ROUTED provider still falls back to a
        // deterministic spoken brief so Jax always has something to say (same
        // posture as MorningBrief's offline path). Resolved ONCE per briefing.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else {
            return Self.fallbackSpoken(slot: slot, items: items)
        }

        let needsReply = items.filter { $0.kind == .emailNeedsYou }
        let ops = items.filter { $0.kind == .opsSignal }
        let goals = items.filter { $0.kind == .goalAdvanced }
        let agenda = items.filter { $0.kind == .agenda }
        let tasks = items.filter { $0.kind == .task }
        let waiting = items.filter { $0.kind == .approvalPending || $0.kind == .proposalPending }

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

        Rules for the spoken briefing:
        - First person, talking straight to them. You are their mind, so speak as them to them: "morning, here is where we stand", "you have two emails that actually need you", "the storefront moved overnight".
        - One short flowing paragraph, 45 to 90 words. No lists, no bullets, no headings, no markdown. Plain spoken prose, this is read aloud.
        - Lead with the things that NEED them (emails to reply to, anything waiting on their tap). Then ops, then goals that moved, then the day ahead.
        - Be sharp and economical. Name the one or two things that matter most, do not recite everything.
        - If nothing genuinely needs them, say so honestly and briefly. Do not invent urgency.
        - No em dashes and no en dashes. Use commas, periods, or colons.
        - No emoji. No vendor, model, or tech-stack names.
        """

        let user = """
        SLOT: \(slot.rawValue)
        NOW: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))

        EMAILS_NEEDING_YOU (unread, want a reply):
        \(renderLines(needsReply))

        OPS_SIGNAL (ad pacing / operations):
        \(renderLines(ops))

        GOALS_ADVANCED (roadmap items that moved):
        \(renderLines(goals))

        AGENDA_TODAY (calendar):
        \(renderLines(agenda))

        TASKS_ON_DECK (NOW then NEXT):
        \(renderLines(tasks))

        WAITING_ON_YOUR_TAP (approvals + self-upgrade proposals):
        \(renderLines(waiting))

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
            let cleaned = sanitize(reply)
            if cleaned.isEmpty { return Self.fallbackSpoken(slot: slot, items: items) }
            // POST grounding: a spoken briefing that asserts a product price/size/SKU that
            // contradicts the catalog is the $18 bug, spoken aloud. Vet against the catalog;
            // if it is not surfaceable, speak the deterministic fallback (real counts only,
            // never an invented number) instead of the model's line.
            let briefForVet = "\(slot.rawValue) briefing. \(renderLines(ops)) \(renderLines(goals))"
            let verdict = GroundingGate.vet(draft: cleaned, brief: briefForVet)
            guard verdict.surfaceable else {
                WakeLog.shared.log("jax briefing: blocked ungrounded fact, speaking fallback. \(verdict.refusalLine)")
                return Self.fallbackSpoken(slot: slot, items: items)
            }
            return cleaned
        } catch {
            WakeLog.shared.log("jax briefing compose FAILED: \(error.localizedDescription)")
            return Self.fallbackSpoken(slot: slot, items: items)
        }
    }

    private func renderLines(_ items: [BriefingItem]) -> String {
        guard !items.isEmpty else { return "(none)" }
        return items.map { i in
            i.detail.isEmpty ? "- \(i.title)" : "- \(i.title) (\(i.detail))"
        }.joined(separator: "\n")
    }

    // Strip the model's stray formatting and enforce the no-dash house rule on
    // anything the user will hear / read.
    private func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out
            .replacingOccurrences(of: "\u{2014}", with: ", ")  // em dash
            .replacingOccurrences(of: "\u{2013}", with: ", ")  // en dash
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Deterministic spoken brief for the no-key / model-failure path. Pure and
    // nonisolated so it unit-tests without booting the singleton graph. Never
    // produces a dash (house rule).
    nonisolated static func fallbackSpoken(slot: Briefing.Slot, items: [BriefingItem]) -> String {
        let needsReply = items.filter { $0.kind == .emailNeedsYou }.count
        let waiting = items.filter { $0.kind == .approvalPending || $0.kind == .proposalPending }.count
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
        if waiting > 0 {
            parts.append("\(waiting) thing\(waiting == 1 ? "" : "s") \(waiting == 1 ? "is" : "are") waiting on your tap.")
        }
        if goals > 0 {
            parts.append("\(goals) goal\(goals == 1 ? "" : "s") moved.")
        }
        if needsReply == 0 && waiting == 0 && goals == 0 {
            parts.append("Nothing urgent needs you right now. The empire is steady.")
        }
        return parts.joined(separator: " ")
    }

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
enum JaxApprovalCount {
    static func pending() -> Int {
        let url = Persistence.jaxDir.appendingPathComponent("approvals.json")
        guard let data = try? Data(contentsOf: url) else { return 0 }
        // Tolerate both a bare array and an envelope { "items": [...] } / a
        // store that stamps a status field; count anything not already
        // resolved. Fall back to total array length when no status is present.
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let pending = arr.filter { row in
                guard let status = row["status"] as? String else { return true }
                let s = status.lowercased()
                return s != "approved" && s != "denied" && s != "rejected" && s != "done" && s != "resolved"
            }
            return pending.count
        }
        if let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = env["items"] as? [[String: Any]] {
            return arr.count
        }
        return 0
    }
}
