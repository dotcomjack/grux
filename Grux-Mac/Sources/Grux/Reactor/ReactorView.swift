import SwiftUI

// The Reactor: a full-bleed holographic command surface where the user talks to
// Jax and the empire answers in real time. A breathing reactor orb dead-center,
// ringed by four live telemetry arc-gauges (Tasks / Mail / Agents / Spend),
// over a radial color-wash backdrop, anchored by the audio-reactive voice dock.
//
// Everything binds to already-resident @MainActor stores, so it paints real
// numbers on the first frame with no network wait, and all ambient motion lives
// in a single Canvas/TimelineView per layer (the CognitionConstellation budget),
// so it holds 60-120fps. v1 is pure gradient + Canvas, no shaders (Phase 5).
struct ReactorView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var bus = ShellStateBus.shared
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var voice = VoiceInput.shared
    @ObservedObject private var mail = MailStore.shared
    @ObservedObject private var accounts = EmailAccountStore.shared
    @ObservedObject private var activity = ActivityStripModel.shared
    @ObservedObject private var metaAds = MetaAdsStore.shared
    // Observed so a Reduce Motion toggle gives the view a dependency edge and
    // re-renders immediately (GruxTheme.reduceMotion alone is a static getter).
    @ObservedObject private var themeConfig = ThemeConfig.shared

    // Calendar is the one non-reactive source (a plain @MainActor service, not a
    // store), polled into @State on appear + a slow timer rather than observed.
    // EventKit's fetch is synchronous, so the cadence is deliberately gentle.
    @State private var upcomingEvents: [CalendarService.EventSummary] = []
    @State private var calendarDenied = false
    private let calendarPoll = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    private var accent: Color { bus.current.accent }
    private var orbState: GruxOrbState { bus.current.mode.orbState }

    private var metrics: ReactorMetrics {
        // TASKS: completion progress of today's active stack.
        let active = state.topLevelActiveTasks.count
        let done = state.completedTasks.count
        let taskTotal = active + done
        let taskFrac = taskTotal == 0 ? 0 : Double(done) / Double(taskTotal)
        let tasks = ReactorRing(label: "TASKS", fraction: taskFrac, readout: "\(done)/\(taskTotal)",
                                tint: GruxTheme.successMint, dashed: false, dim: taskTotal == 0)

        // MAIL: unread pressure (cyan, dims to nothing at inbox zero).
        let unread = mail.unreadCount()
        let mailFrac = min(1.0, Double(unread) / 30.0)
        let mailRing = ReactorRing(label: "MAIL", fraction: mailFrac,
                                   readout: Self.mailRingReadout(hasAccount: !accounts.accounts.isEmpty, unread: unread),
                                   tint: GruxTheme.accentCo, dashed: false, dim: unread == 0)

        // AGENTS: a dashed data-ring that fills with running swarm jobs.
        let running = activity.runningCount
        let agentFrac = min(1.0, Double(running) / 5.0)
        let agents = ReactorRing(label: "AGENTS", fraction: agentFrac, readout: "\(running)",
                                 tint: GruxTheme.accentPrimary, dashed: true, dim: running == 0)

        return ReactorMetrics(tasks: tasks, mail: mailRing, agents: agents)
    }

    var body: some View {
        GeometryReader { geo in
            // Altitude tier: shrink the instrument on a narrow window so the
            // radial assembly never collides with the edges.
            let compact = geo.size.width < 900
            let orbSize: CGFloat = compact ? GruxLayout.reactorCompactOrb : 190
            let innerR: CGFloat = compact ? 110 : 132
            let spacingR: CGFloat = compact ? 22 : 26
            // Resolve the 6-store snapshot ONCE per body pass and reuse it for
            // every consumer (no triple store reads / task re-filtering).
            let m = metrics
            let rm = GruxTheme.reduceMotion

            ZStack {
                backdrop
                ReactorRingsCanvas(metrics: m, accent: accent, reduceMotion: rm,
                                   innerRadius: innerR, ringSpacing: spacingR)
                ringLabels(m, innerR: innerR, spacing: spacingR)
                core(size: orbSize, reduceMotion: rm)
                panelColumns
                    .padding(.horizontal, GruxLayout.reactorInset)
                    .padding(.top, 56)
                    .padding(.bottom, 124)   // clear the voice dock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { ReactorVoiceDock(reduceMotion: rm) }
            .overlay(alignment: .topLeading) { eyebrow.padding(20) }
        }
        .background(GruxTheme.base)
        .onReceive(calendarPoll) { _ in refreshCalendar() }
        .onAppear {
            // Nudge the resident stores so every gauge + panel is warm on the
            // first frame, then keep them fresh. None of these block paint.
            metaAds.load()
            Task { await metaAds.refresh() }
            if CalendarService.shared.hasAccess {
                refreshCalendar()
            } else {
                // Prompt once, then read; until granted the panel shows a Grant state.
                Task { _ = await CalendarService.shared.requestAccess(); refreshCalendar() }
            }
        }
    }

    private func refreshCalendar() {
        // Distinguish "no calendar permission" from a genuinely empty week so the
        // panel can offer a Grant affordance instead of masking the gap as Clear.
        guard CalendarService.shared.hasAccess else {
            calendarDenied = true
            upcomingEvents = []
            return
        }
        calendarDenied = false
        let now = Date()
        upcomingEvents = CalendarService.shared.events(from: now, to: now.addingTimeInterval(7 * 86_400))
    }

    // MARK: - Radial telemetry panels (flanking HUD columns)

    private var panelColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                mailboxPanel
                calendarPanel
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                metaAdsPanel
                agentsPanel
            }
        }
    }

    private var mailboxPanel: some View {
        let unread = mail.unreadCount()
        // Resolve the sender ONLY from the unread set, so a zero-name fallback
        // never borrows an already-read message and names the wrong person.
        let newest = mail.messages.first(where: { $0.isUnread && !$0.fromName.isEmpty })?.fromName ?? ""
        let readout = Self.mailboxReadout(hasAccount: !accounts.accounts.isEmpty, unread: unread, newest: newest)
        return ReactorPanel(icon: "envelope.fill", title: "MAILBOX",
                            value: readout.value,
                            sub: readout.sub,
                            tint: GruxTheme.accentCo, dim: unread == 0,
                            onTap: { jump("mailbox") })
    }

    /// The Mailbox card's number and line. With no mailbox set up there is
    /// no count to show, and zero unread from nothing is not an empty inbox
    /// (D30: this read "0 / Inbox zero" while Now said "Set up Mailbox").
    static func mailboxReadout(hasAccount: Bool, unread: Int, newest: String) -> (value: String, sub: String) {
        guard hasAccount else { return ("··", "Not set up") }
        if unread == 0 { return ("0", "Inbox zero") }
        return ("\(unread)", newest.isEmpty ? "unread" : "from \(newest)")
    }

    static func mailRingReadout(hasAccount: Bool, unread: Int) -> String {
        hasAccount ? "\(unread)" : "··"
    }

    private var calendarPanel: some View {
        if calendarDenied {
            return ReactorPanel(icon: "calendar", title: "CALENDAR",
                                value: "··", sub: "Grant calendar access",
                                tint: GruxTheme.warnAmber, dim: true)
        }
        let readout = Self.calendarReadout(events: upcomingEvents, now: Date())
        return ReactorPanel(icon: "calendar", title: "CALENDAR",
                            value: readout.value,
                            sub: readout.sub,
                            tint: GruxTheme.accentPrimary, dim: readout.event == nil,
                            onTap: { jump("calendar") })
    }

    /// The Calendar card's number and line (D91: on Halloween it read "11h ago / Halloween",
    /// counting from the all-day event's midnight start, so today's event looked over).
    /// A meeting still ahead today comes first; then today's all-day event; then whatever
    /// starts soonest. An event underway reads "Now", an all-day one "Today", "Tomorrow", its
    /// weekday within six days or its date, and a later one how long until it starts. Nothing here reads "ago".
    static func calendarReadout(events: [CalendarService.EventSummary], now: Date,
                                calendar: Calendar = .current) -> (value: String, sub: String, event: CalendarService.EventSummary?) {
        let ahead = events.filter { $0.end > now }.sorted { $0.start < $1.start }
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
        let next = ahead.first { !$0.isAllDay && $0.start < endOfToday }
            ?? ahead.first { $0.isAllDay && $0.start < endOfToday }
            ?? ahead.first
        guard let next else { return ("Clear", "Nothing scheduled", nil) }
        if next.start <= now {
            return (next.isAllDay ? "Today" : "Now", next.title, next)
        }
        if next.isAllDay {
            if calendar.isDate(next.start, inSameDayAs: now) { return ("Today", next.title, next) }
            if calendar.isDate(next.start, inSameDayAs: endOfToday) { return ("Tomorrow", next.title, next) }
            let day = DateFormatter()
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            day.locale = calendar.locale ?? .current
            // A weekday names the next six days only: a week out, "Sat" on a Saturday
            // read as today (wave 24), so from seven days on the card reads the date.
            let daysOut = calendar.dateComponents([.day], from: startOfToday,
                                                  to: calendar.startOfDay(for: next.start)).day ?? 0
            day.setLocalizedDateFormatFromTemplate(daysOut < 7 ? "EEE" : "MMMd")
            return (day.string(from: next.start), next.title, next)
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        return (f.localizedString(for: next.start, relativeTo: now), next.title, next)
    }

    /// The Meta Ads card's number and line. No snapshot is no spend (D51: this read "$0.00"
    /// and "offline" for a service that was not set up).
    static func metaAdsReadout(spendCents: Int?, mode: String?, attention: Int, notSetUp: Bool) -> (value: String, sub: String) {
        guard let spendCents else { return ("··", notSetUp ? "Not set up" : "offline") }
        return (cents(spendCents), "\(mode ?? "") · \(attention) need you")
    }

    private var metaAdsPanel: some View {
        let snap = metaAds.snapshot
        let spendC = snap?.spendTodayCents ?? 0
        let capC = snap?.effectiveDailyCapCents ?? 0
        let frac = capC > 0 ? Double(spendC) / Double(capC) : 0
        let readout = Self.metaAdsReadout(spendCents: snap?.spendTodayCents, mode: snap?.mode,
                                          attention: snap?.attentionCount ?? 0, notSetUp: metaAds.lastErrorIsAbsence)
        return ReactorPanel(icon: "megaphone.fill", title: "META ADS",
                            value: readout.value,
                            sub: readout.sub,
                            tint: ReactorSignals.tint(frac), pacing: snap == nil ? nil : frac,
                            dim: snap == nil,
                            onTap: { jump("metaAds") })
    }

    private var agentsPanel: some View {
        let running = activity.runningCount
        return ReactorPanel(icon: "rectangle.stack.badge.play.fill", title: "AGENTS",
                            value: "\(running)",
                            sub: running == 0 ? "idle" : (activity.costLabel.map { "\($0) in flight" } ?? "running"),
                            tint: GruxTheme.accentPrimary, dim: running == 0,
                            onTap: { jump("agents") })
    }

    private static func cents(_ c: Int) -> String {
        String(format: "$%.2f", Double(c) / 100.0)
    }

    // MARK: - Center reactor core

    private func core(size: CGFloat, reduceMotion: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let amp = ReactorSignals.amplitude(
                isSpeaking: speech.isSpeaking, isBuffering: speech.isBuffering,
                outputLevel: speech.outputLevel, isRecording: voice.isRecording,
                liveLevel: voice.liveLevel, t: t)
            OrbView(state: orbState, level: amp)
                .frame(width: size, height: size)
                .shadow(color: accent.opacity(0.5), radius: 30)
                // Phase 5 bloom: an additive accent halo that swells with the
                // live audio level for a GPU-neon glow, done with layered
                // plusLighter blur (no Metal shader, so it keeps the 120fps +
                // instant-load promise). Gated behind a flag and reduceMotion.
                .background {
                    if bloomEnabled && !reduceMotion {
                        Circle()
                            .fill(accent)
                            .frame(width: size * 0.82, height: size * 0.82)
                            .blur(radius: 38 + CGFloat(amp) * 26)
                            .opacity(0.30 + Double(amp) * 0.30)
                            .blendMode(.plusLighter)
                    }
                }
        }
        .contentShape(Circle())
        .onTapGesture { MicController.toggle(source: "reactor") }
        .gruxHoverable(lift: 1.04, rimOnHover: 0, fillOnHover: 0)
        .help(state.micMuted ? "Mic muted, tap to resume" : "Tap the core to mute")
    }

    // Phase 5 toggle. On by default (the neon is the point); off falls back to the
    // pure layered-glow look. A true Metal SDF shader is a further opt-in.
    @AppStorage("reactorBloom") private var bloomEnabled: Bool = true

    private func jump(_ tab: String) { state.requestedTab = tab }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            GruxTheme.base
            RadialGradient(
                colors: [accent.opacity(0.16), accent.opacity(0.04), .clear],
                center: .center, startRadius: 40, endRadius: 460)
            // Faint vignette so the deck reads as a recessed glass panel.
            RadialGradient(
                colors: [.clear, .black.opacity(0.35)],
                center: .center, startRadius: 260, endRadius: 720)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: accent)
    }

    // MARK: - Labels + eyebrow

    private var eyebrow: some View {
        HStack(spacing: 8) {
            Image(systemName: "atom")
                .foregroundStyle(accent)
            Text("REACTOR")
                .font(GruxType.microCaps)
                .foregroundStyle(GruxTheme.textSecondary)
            Text(bus.current.mode.label.uppercased())
                .font(GruxType.microCaps)
                .foregroundStyle(accent)
        }
    }

    // Small ring kicker labels placed at the top of each ring so the instrument
    // is legible, not just decorative.
    private func ringLabels(_ m: ReactorMetrics, innerR: CGFloat, spacing: CGFloat) -> some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ForEach(Array(m.rings.enumerated()), id: \.offset) { i, ring in
                let radius = innerR + CGFloat(i) * spacing
                Text("\(ring.label)  \(ring.readout)")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .kerning(0.5)
                    .foregroundStyle(ring.dim ? GruxTheme.textTertiary : ring.tint.opacity(0.9))
                    .position(x: center.x, y: center.y - radius - 7)
            }
        }
        .allowsHitTesting(false)
    }

}
