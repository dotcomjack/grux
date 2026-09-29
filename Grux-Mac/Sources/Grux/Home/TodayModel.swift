import Foundation

/// What Today shows, decided where a test can drive it (Phase D, P-D-1).
///
/// "What is next" is a judgment, and a judgment rendered inline in a view
/// cannot be tested. Everything here is pure: the view resolves the live
/// stores and hands the values over.
enum TodayModel {

    // MARK: - One clock for the whole surface

    /// `7:30 PM`, never `19:30`. The one formatter every Today card and the
    /// Home briefing use, pinned to a POSIX locale so "PM" never comes out
    /// localized. A 24 hour time is the single likeliest copy defect here.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    // MARK: - Next

    struct TaskLine: Equatable {
        var id: UUID
        var title: String
        var dueAt: Date?
    }

    struct Next: Equatable {
        enum Kind: Equatable { case event, task }
        var kind: Kind
        var title: String
        /// "Now, until 3:30 PM", "At 2:00 PM", "Tomorrow at 9:00 AM",
        /// "Due at 5:00 PM", "All day", or "" for a task with no due time.
        var when: String
        /// The tab one tap away.
        var tab: String
        /// Up to two things after it, one line each.
        var then: [String]
    }

    /// A task with no due time is what to do after anything in the next hour.
    /// An event sooner than that wins; one later in the day does not push an
    /// undated task off the card.
    static let undatedTaskHorizon: TimeInterval = 3600

    private struct Candidate {
        var next: Next
        var at: Date
        var rank: Int   // 0 in progress, 1 timed, 2 all day
        var order: Int  // insertion order, so equal times keep the caller's priority order
    }

    static func next(tasks: [TaskLine], events: [CalendarService.EventSummary],
                     now: Date, calendar: Calendar = .current) -> Next? {
        var candidates: [Candidate] = []
        for e in events where e.end > now {
            if e.isAllDay {
                // An all-day event never beats a timed event or a task: it is
                // context for the day, not the next thing to do.
                guard calendar.isDate(e.start, inSameDayAs: now) || e.start <= now else { continue }
                candidates.append(Candidate(next: Next(kind: .event, title: e.title, when: "All day",
                                                       tab: "calendar", then: []),
                                            at: .distantFuture, rank: 2, order: candidates.count))
            } else if e.start <= now {
                // A meeting you are in is the most relevant thing on the screen.
                candidates.append(Candidate(next: Next(kind: .event, title: e.title,
                                                       when: "Now, until \(clock(e.end, calendar: calendar))",
                                                       tab: "calendar", then: []),
                                            at: now, rank: 0, order: candidates.count))
            } else {
                candidates.append(Candidate(next: Next(kind: .event, title: e.title,
                                                       when: eventWhen(e.start, now: now, calendar: calendar),
                                                       tab: "calendar", then: []),
                                            at: e.start, rank: 1, order: candidates.count))
            }
        }
        for t in tasks {
            let at = t.dueAt ?? now.addingTimeInterval(undatedTaskHorizon)
            let when = t.dueAt.map { dueWhen($0, now: now, calendar: calendar) } ?? ""
            candidates.append(Candidate(next: Next(kind: .task, title: t.title, when: when, tab: "tasks", then: []),
                                        at: at, rank: 1, order: candidates.count))
        }
        let ordered = candidates.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.at != b.at { return a.at < b.at }
            return a.order < b.order
        }
        guard var first = ordered.first?.next else { return nil }
        first.then = ordered.dropFirst().prefix(2).map { c in
            c.next.when.isEmpty ? c.next.title : "\(c.next.title), \(c.next.when.lowercasedFirst)"
        }
        return first
    }

    static func eventWhen(_ start: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(start, inSameDayAs: now) { return "At \(clock(start, calendar: calendar))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(start, inSameDayAs: tomorrow) {
            return "Tomorrow at \(clock(start, calendar: calendar))"
        }
        return "\(HomeBriefingBuilder.weekdayLabel(start, calendar: calendar)) at \(clock(start, calendar: calendar))"
    }

    static func dueWhen(_ due: Date, now: Date, calendar: Calendar) -> String {
        if due < now { return "Overdue" }
        if calendar.isDate(due, inSameDayAs: now) { return "Due at \(clock(due, calendar: calendar))" }
        return "Due " + eventWhen(due, now: now, calendar: calendar).replacingOccurrences(of: " at ", with: " by ")
            .replacingOccurrences(of: "Tomorrow", with: "tomorrow")
    }

    // MARK: - Mail that needs you

    struct MailSummary: Equatable, Identifiable {
        var id: String
        var from: String
        var subject: String
    }

    /// The same rule as the rail's badge (`MailNeedsYou.counts`: the floor and
    /// the engine's judgment), so the card and the badge can never disagree.
    static func mailThatNeedsYou(_ messages: [EmailMessage], limit: Int = 3) -> (items: [MailSummary], total: Int) {
        let needing = messages.filter(MailNeedsYou.counts).sorted { $0.date > $1.date }
        let items = needing.prefix(limit).map { m in
            MailSummary(id: m.id,
                        from: m.fromName.isEmpty ? m.fromEmail : m.fromName,
                        subject: m.subject.isEmpty ? "(no subject)" : m.subject)
        }
        return (Array(items), needing.count)
    }

    // MARK: - Watching

    struct WatchItem: Equatable, Identifiable {
        var id: String
        var icon: String
        var line: String
        var tab: String
    }

    struct WatchInput: Equatable {
        var focusTask: String?
        var drifting: Bool = false
        var jobsRunning: Int = 0
        var jobsWaitingOnYou: Int = 0
        var proposals: Int = 0
        /// Focus checks recorded today, so the Focus log stays one tap away on
        /// a day with no task in focus (C11).
        var focusChecksToday: Int = 0
    }

    /// What Grux is keeping an eye on for the person: the task in focus (the
    /// Focus log folds into this card, Phase C task C11), agent jobs and
    /// improvements waiting on them. Approvals are NOT here: the tray at the
    /// foot of the rail owns them (C10), and one view must not say it twice.
    static func watching(_ w: WatchInput) -> [WatchItem] {
        var out: [WatchItem] = []
        if let task = w.focusTask, !task.isEmpty {
            out.append(WatchItem(id: "focus", icon: "scope",
                                 line: w.drifting ? "Focusing on \(task), and you have drifted" : "Focusing on \(task)",
                                 tab: "focus"))
        } else if w.focusChecksToday > 0 {
            out.append(WatchItem(id: "focus", icon: "eye",
                                 line: plural(w.focusChecksToday, "focus check", "focus checks") + " today",
                                 tab: "focus"))
        }
        if w.jobsWaitingOnYou > 0 {
            out.append(WatchItem(id: "jobs.waiting", icon: "pause.circle",
                                 line: plural(w.jobsWaitingOnYou, "agent job", "agent jobs") + " waiting on you",
                                 tab: "agents"))
        }
        if w.jobsRunning > 0 {
            out.append(WatchItem(id: "jobs.running", icon: "cpu",
                                 line: plural(w.jobsRunning, "agent job", "agent jobs") + " running",
                                 tab: "agents"))
        }
        if w.proposals > 0 {
            out.append(WatchItem(id: "proposals", icon: "wand.and.stars",
                                 line: plural(w.proposals, "improvement", "improvements") + " to review",
                                 tab: "selfUpgrade"))
        }
        return out
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        if n == 1 { return "1 \(one)" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return "\(f.string(from: NSNumber(value: n)) ?? String(n)) \(many)"
    }

    // MARK: - The say-it line

    /// One line inviting the person to just say it, honest about the
    /// microphone the same way the composer placeholder is (Phase B, B10).
    /// Driven by the shared tell, never a second source of truth.
    static func sayItLine(_ tell: ListeningTell) -> String {
        switch tell {
        case .armed:    return "Just say it. Grux is listening, no wake word needed."
        case .speaking: return "Grux is talking. Say something to answer."
        case .thinking: return "Grux is working on what you asked."
        case .muted:    return "Your microphone is muted. Tap the orb to just say it."
        case .off:      return "Listening is off. Turn it on in Tuning to just say it."
        case .notHearing: return "Grux can't hear your microphone right now. Tap the orb to try again."
        }
    }

    // MARK: - Empty states, as data

    enum Copy {
        static let nextEmpty = "Nothing on the calendar and no open tasks. Add a task, or just say what you want to do."
        static let mailEmpty = "Nothing in your mail needs you right now."
        static let mailNoAccount = "Connect a mailbox and Grux shows only the mail that needs a reply."
        static let watchingEmpty = "Nothing running in the background. When Grux works on something for you, it shows up here."
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        return f.lowercased() + dropFirst()
    }
}
