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
    @ObservedObject private var activity = ActivityStripModel.shared
    @ObservedObject private var metaAds = MetaAdsStore.shared
    // Observed so a Reduce Motion toggle gives the view a dependency edge and
    // re-renders immediately (GruxTheme.reduceMotion alone is a static getter).
    @ObservedObject private var themeConfig = ThemeConfig.shared

    // Calendar is the one non-reactive source (a plain @MainActor service, not a
    // store), polled into @State on appear + a slow timer rather than observed.
    // EventKit's fetch is synchronous, so the cadence is deliberately gentle.
    @State private var nextEvent: CalendarService.EventSummary?
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
        let mailRing = ReactorRing(label: "MAIL", fraction: mailFrac, readout: "\(unread)",
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
            let orbSize: CGFloat = compact ? 150 : 190
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
                    .padding(.horizontal, 18)
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
            nextEvent = nil
            return
        }
        calendarDenied = false
        let now = Date()
        let upcoming = CalendarService.shared
            .events(from: now, to: now.addingTimeInterval(7 * 86_400))
            .filter { $0.end > now }
            .sorted { $0.start < $1.start }
        nextEvent = upcoming.first
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
        return ReactorPanel(icon: "envelope.fill", title: "MAILBOX",
                            value: "\(unread)",
                            sub: unread == 0 ? "Inbox zero" : (newest.isEmpty ? "unread" : "from \(newest)"),
                            tint: GruxTheme.accentCo, dim: unread == 0,
                            onTap: { jump("mailbox") })
    }

    private var calendarPanel: some View {
        if calendarDenied {
            return ReactorPanel(icon: "calendar", title: "CALENDAR",
                                value: "··", sub: "Grant calendar access",
                                tint: GruxTheme.warnAmber, dim: true)
        }
        let rel: String = nextEvent.map {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: $0.start, relativeTo: Date())
        } ?? "Clear"
        return ReactorPanel(icon: "calendar", title: "CALENDAR",
                            value: rel,
                            sub: nextEvent?.title ?? "Nothing scheduled",
                            tint: GruxTheme.accentPrimary, dim: nextEvent == nil,
                            onTap: { jump("calendar") })
    }

    private var metaAdsPanel: some View {
        let snap = metaAds.snapshot
        let spendC = snap?.spendTodayCents ?? 0
        let capC = snap?.effectiveDailyCapCents ?? 0
        let frac = capC > 0 ? Double(spendC) / Double(capC) : 0
        return ReactorPanel(icon: "megaphone.fill", title: "META ADS",
                            value: Self.cents(spendC),
                            sub: snap.map { "\($0.mode) · \($0.attentionCount) need you" } ?? "offline",
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
        .onTapGesture { MicController.toggle() }
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
