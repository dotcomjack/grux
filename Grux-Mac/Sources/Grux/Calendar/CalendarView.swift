import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Calendar tab: month grid on the left, selected-day agenda on the right.
// Reads/writes through CalendarService (EventKit). Dark-first GruxTheme
// styling, tight control scale (small paddings, 11-13pt type).
struct CalendarView: View {

    @State private var monthAnchor: Date = Date()
    @State private var selectedDay: Date = Foundation.Calendar.current.startOfDay(for: Date())
    @State private var monthEvents: [CalendarService.EventSummary] = []
    @State private var hasAccess = false
    @State private var checkedAccess = false
    @State private var showNewEvent = false
    @State private var statusMessage: String?

    private var calendar: Foundation.Calendar {
        var c = Foundation.Calendar(identifier: .gregorian)
        c.firstWeekday = 1 // Sunday
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if checkedAccess && !hasAccess {
                noAccessState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    monthGrid
                        // Was 420 which, with the 260 day agenda, forced a 680
                        // detail min and clipped the nav sidebar when the window
                        // narrowed. 340 keeps the 7-column grid usable while
                        // letting Calendar reflow down to the window floor.
                        .frame(minWidth: 340)
                        // Serve the grid FIRST, and this is load-bearing rather
                        // than cosmetic. HStack offers space in order of
                        // increasing flexibility, so without this the agenda
                        // (200...320, flexibility 120) is served before the grid
                        // (340 floor, no ceiling, flexibility infinite): at the
                        // 599pt pane floor the agenda is proposed 299, accepts
                        // it because 299 is inside its range, and the grid is
                        // then handed 299 but returns its 340 floor. The stack
                        // reports 640 into 599 and clips 41pt off the right.
                        // With priority the grid is offered 599 less the
                        // agenda's 200 floor and both fit.
                        .layoutPriority(1)
                    Divider().opacity(0.3)
                    dayAgenda
                        .frame(minWidth: 200, maxWidth: 320)
                }
            }
            if let status = statusMessage {
                statusBar(status)
            }
        }
        .background(GruxTheme.base)
        .task {
            hasAccess = await CalendarService.shared.requestAccess()
            checkedAccess = true
            reload()
        }
        .sheet(isPresented: $showNewEvent) {
            NewEventSheet(defaultDay: selectedDay) { created in
                if created { reload() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        GruxToolbar(monthTitle) {
            HStack(spacing: GruxSpacing.xs) {
                iconButton("chevron.left", help: "Previous month") { shiftMonth(-1) }
                iconButton("chevron.right", help: "Next month") { shiftMonth(1) }
            }

            Button("Today") { goToToday() }
                .buttonStyle(.plain)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .padding(.horizontal, GruxSpacing.s + 2).padding(.vertical, GruxSpacing.xs + 1)
                .background(Capsule().fill(Color.white.opacity(0.06)))

            Spacer()

            iconButton("square.and.arrow.down", help: "Import .ics file") { importICS() }
            iconButton("square.and.arrow.up", help: "Export month as .ics") { exportICS() }

            GruxToolbarButton(title: "New Event", systemImage: "plus",
                              prominent: true, helpText: "New Event") {
                showNewEvent = true
            }
            .disabled(!hasAccess)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GruxTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        VStack(spacing: GruxSpacing.s - 2) {
            HStack(spacing: 0) {
                ForEach(["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], id: \.self) { d in
                    Text(d)
                        .font(GruxTheme.Font.microCaps)
                        .kerning(1)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, GruxSpacing.s)

            let days = monthGridDays
            let rows = days.count / 7
            GeometryReader { geo in
                let cellH = max(56, (geo.size.height - CGFloat(rows - 1) * 4) / CGFloat(rows))
                VStack(spacing: 4) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { col in
                                dayCell(days[row * 7 + col])
                                    .frame(maxWidth: .infinity)
                                    .frame(height: cellH)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, GruxSpacing.m)
        .padding(.bottom, GruxSpacing.m)
    }

    private func dayCell(_ day: Date?) -> some View {
        Group {
            if let day = day {
                let isToday = calendar.isDateInToday(day)
                let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
                let dayEvents = events(on: day)
                Button {
                    selectedDay = calendar.startOfDay(for: day)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 11, weight: isToday ? .heavy : .semibold))
                            .foregroundStyle(isToday ? GruxTheme.accentPrimaryLight : GruxTheme.textPrimary)
                            .padding(.top, 5).padding(.leading, 6)
                        ForEach(dayEvents.prefix(2)) { ev in
                            // Month grid chips are tight, so show title only (no
                            // leading time prefix) and tail truncate, so a long
                            // name degrades to "Appoint..." with the start visible.
                            // Full title (and time) stays discoverable via the
                            // hover tooltip and the day agenda detail.
                            Text(ev.title)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(GruxTheme.textSecondary)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(GruxTheme.accentPrimary.opacity(0.18))
                                )
                                .padding(.horizontal, 3)
                                .help(chipTooltip(ev))
                        }
                        if dayEvents.count > 2 {
                            Text("+\(dayEvents.count - 2) more")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(GruxTheme.textTertiary)
                                .padding(.leading, 6)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? GruxTheme.accentPrimary.opacity(0.16) : Color.white.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? GruxTheme.accentPrimary.opacity(0.6)
                                    : (isToday ? GruxTheme.accentPrimaryLight.opacity(0.4) : Color.white.opacity(0.06)),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Day agenda

    private var dayAgenda: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text(agendaTitle)
                .font(GruxTheme.Font.caption)
                .kerning(0.5)
                .foregroundStyle(GruxTheme.textSecondary)
                .padding(.top, GruxSpacing.m)

            let dayEvents = events(on: selectedDay)
            if dayEvents.isEmpty {
                GruxEmptyState(
                    icon: "calendar.badge.checkmark",
                    line: "Nothing scheduled",
                    voiceHint: "Grux, add that to my calendar",
                    compact: true
                )
            } else {
                ScrollView {
                    VStack(spacing: GruxSpacing.s - 2) {
                        ForEach(dayEvents) { ev in
                            agendaRow(ev)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agendaRow(_ ev: CalendarService.EventSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(GruxTheme.accentPrimary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(2)
                Text(ev.isAllDay ? "All day" : "\(timeString(ev.start)) - \(timeString(ev.end))")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                if let location = ev.location {
                    Label(location, systemImage: "mappin")
                        .font(.system(size: 10))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .lineLimit(1)
                }
                Text(ev.calendarName)
                    .font(GruxTheme.Font.microCaps)
                    .kerning(0.8)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            Spacer(minLength: 0)
            Button {
                delete(ev)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(GruxTheme.destructiveRose.opacity(0.85))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Delete event")
        }
        .padding(GruxSpacing.s)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: - Empty access state

    private var noAccessState: some View {
        GruxEmptyState(
            icon: "calendar.badge.exclamationmark",
            line: "Calendar access is off",
            detail: "Enable Grux in System Settings > Privacy & Security > Calendars, then come back.",
            ctaTitle: "Open System Settings",
            ctaAction: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            },
            iconColor: GruxTheme.warnAmber
        )
    }

    private func statusBar(_ text: String) -> some View {
        Text(text)
            .font(GruxTheme.Font.caption)
            .foregroundStyle(GruxTheme.textSecondary)
            .padding(.horizontal, GruxSpacing.l)
            .padding(.vertical, GruxSpacing.s - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
    }

    // MARK: - Data

    private func reload() {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return }
        // Pad a week each side so leading/trailing grid cells from adjacent
        // months still show their dots after a future grid enhancement.
        let start = interval.start.addingTimeInterval(-7 * 86400)
        let end = interval.end.addingTimeInterval(7 * 86400)
        monthEvents = CalendarService.shared.events(from: start, to: end)
        hasAccess = CalendarService.shared.hasAccess
    }

    private func events(on day: Date) -> [CalendarService.EventSummary] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return monthEvents.filter { $0.start < dayEnd && $0.end > dayStart }
    }

    private func delete(_ ev: CalendarService.EventSummary) {
        do {
            try CalendarService.shared.deleteEvent(id: ev.id)
            statusMessage = "Deleted '\(ev.title)'"
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = next
            reload()
        }
    }

    private func goToToday() {
        monthAnchor = Date()
        selectedDay = calendar.startOfDay(for: Date())
        reload()
    }

    // MARK: - Import / Export

    private func importICS() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = "Couldn't read \(url.lastPathComponent)"
            return
        }
        let parsed = ICSImportExport.parse(text)
        guard !parsed.isEmpty else {
            statusMessage = "No events found in \(url.lastPathComponent)"
            return
        }
        do {
            let created = try CalendarService.shared.importICSEvents(parsed)
            statusMessage = "Imported \(created.count) event(s) from \(url.lastPathComponent)"
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func exportICS() {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM"
        panel.nameFieldStringValue = "grux-calendar-\(df.string(from: monthAnchor)).ics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let icsEvents = CalendarService.shared.exportICSEvents(from: interval.start, to: interval.end)
        let serialized = ICSImportExport.serialize(icsEvents)
        do {
            try serialized.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(icsEvents.count) event(s) to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Grid math

    // nil entries pad the grid so day 1 lands on its weekday column.
    private var monthGridDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor),
              let dayCount = calendar.range(of: .day, in: .month, for: monthAnchor)?.count else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    // MARK: - Format helpers

    private var monthTitle: String {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        return df.string(from: monthAnchor)
    }

    private var agendaTitle: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        return df.string(from: selectedDay).uppercased()
    }

    private func timeString(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: d)
    }

    // Tooltip for a month grid chip: full untruncated title plus the time the
    // chip itself drops to save width. All day events skip the time line.
    private func chipTooltip(_ ev: CalendarService.EventSummary) -> String {
        if ev.isAllDay {
            return "\(ev.title)\nAll day"
        }
        return "\(ev.title)\n\(timeString(ev.start)) - \(timeString(ev.end))"
    }
}

// MARK: - New event sheet

private struct NewEventSheet: View {
    let defaultDay: Date
    let onDone: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var isAllDay = false
    @State private var start: Date
    @State private var end: Date
    @State private var calendarId = ""
    @State private var errorText: String?

    private let calendars = CalendarService.shared.calendars().filter { $0.allowsModifications }

    init(defaultDay: Date, onDone: @escaping (Bool) -> Void) {
        self.defaultDay = defaultDay
        self.onDone = onDone
        // Default: next round hour on the selected day.
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = Date()
        let hour = cal.component(.hour, from: now) + 1
        let s = cal.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: defaultDay) ?? defaultDay
        _start = State(initialValue: s)
        _end = State(initialValue: s.addingTimeInterval(3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Event")
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(GruxTheme.Font.body)

            Toggle("All day", isOn: $isAllDay)
                .font(GruxTheme.Font.body)
                .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                DatePicker(
                    "Starts",
                    selection: $start,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .font(GruxTheme.Font.body)
            }
            if !isAllDay {
                DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                    .font(GruxTheme.Font.body)
            }

            TextField("Location (optional)", text: $location)
                .textFieldStyle(.roundedBorder)
                .font(GruxTheme.Font.body)

            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(GruxTheme.Font.body)
                .lineLimit(2...4)

            if !calendars.isEmpty {
                Picker("Calendar", selection: $calendarId) {
                    Text("Default").tag("")
                    ForEach(calendars) { c in
                        Text(c.title).tag(c.id)
                    }
                }
                .font(GruxTheme.Font.body)
            }

            if let errorText = errorText {
                Text(errorText)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.destructiveRose)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                    onDone(false)
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(GruxSpacing.l)
        // 380 is still the width this sheet renders at, but as an IDEAL inside
        // the shared sheet budget rather than a hard demand. A sheet is bounded
        // by the window it hangs off, and a fixed width that outgrows the 840pt
        // window floor does not shrink, it clips off BOTH edges at once because
        // SwiftUI centres an oversized child. GruxLayout.sheetMax is that
        // ceiling, and it is what stops a later edit to this number from
        // reintroducing the overflow.
        .frame(minWidth: GruxLayout.sheetMin, idealWidth: 380, maxWidth: GruxLayout.sheetMax)
        .background(GruxTheme.base)
    }

    private func create() {
        do {
            let effectiveEnd = isAllDay ? start.addingTimeInterval(86400) : end
            _ = try CalendarService.shared.createEvent(
                title: title,
                start: start,
                end: effectiveEnd,
                isAllDay: isAllDay,
                location: location.isEmpty ? nil : location,
                notes: notes.isEmpty ? nil : notes,
                calendarHint: calendarId.isEmpty ? nil : calendarId
            )
            dismiss()
            onDone(true)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
