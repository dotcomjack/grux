import Foundation

// Pure rendering. `WorkdayLog → String` in GitHub-flavored Markdown.
// Used for:
//   * iCloud mirror `.md` file
//   * SwiftUI display via AttributedString(markdown:)
//
// Stable, deterministic, no clock or I/O, safe to golden-file test.

enum WorkdayLogRenderer {

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = .current
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, yyyy"
        f.timeZone = .current
        return f
    }()

    static func renderMarkdown(_ log: WorkdayLog) -> String {
        var lines: [String] = []

        lines.append("# \(log.dayKey) Workday")
        lines.append("")
        lines.append("_\(dayFormatter.string(from: log.windowStart)) · 6:00 AM → 5:59 AM next day · \(log.totalProductiveMinutes) productive min_")
        lines.append("")

        if !log.tags.isEmpty {
            let tagLine = log.tags.map { "`\($0)`" }.joined(separator: " ")
            lines.append("**Projects:** \(tagLine)")
            lines.append("")
        }

        // TL;DR section: short executive summary at the very top so a scanner
        // can pick up the day's biggest signal without reading further.
        if let summary = log.executiveSummary, !summary.isEmpty {
            lines.append("## TL;DR")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        // Time allocation + project + app-category bar charts. Each bar row
        // is wrapped in single backticks so SwiftUI's AttributedString
        // renders it as inline code and column-aligns cleanly. Same wrapping
        // looks right in the iCloud markdown mirror and any external viewer.
        lines.append(contentsOf: renderTimeSection(log))

        // Narrative
        lines.append("## Narrative")
        lines.append("")
        lines.append(log.narrative.isEmpty ? "_(no narrative generated)_" : log.narrative)
        lines.append("")

        // Shipped
        lines.append("## Shipped")
        lines.append("")
        lines.append("### Tasks")
        lines.append("")
        if log.completedTasks.isEmpty {
            lines.append("_(nothing marked complete)_")
        } else {
            for t in log.completedTasks {
                let time = clockFormatter.string(from: t.completedAt)
                let proj = t.project.isEmpty ? "" : " · `\(t.project)`"
                lines.append("- **\(t.title)**\(proj) · \(time)")
            }
        }
        lines.append("")

        lines.append("### Code")
        lines.append("")
        if log.codeShipped.isEmpty {
            lines.append("_(no code shipments recorded)_")
        } else {
            for shipment in log.codeShipped {
                let branchSuffix = shipment.gitBranch.map { " (`\($0)`)" } ?? ""
                lines.append("#### \(shipment.project)\(branchSuffix)")
                lines.append("")
                if !shipment.commits.isEmpty {
                    for c in shipment.commits {
                        let short = String(c.sha.prefix(7))
                        lines.append("- `\(short)` \(c.message) · +\(c.insertions)/-\(c.deletions), \(c.filesChanged) files")
                    }
                }
                if !shipment.claudeSessions.isEmpty {
                    for s in shipment.claudeSessions {
                        let cost = s.totalCost < 0.005 ? "$0.00" : String(format: "$%.2f", s.totalCost)
                        let outcome = s.outcomeSummary.isEmpty ? "_(no outcome recorded)_" : s.outcomeSummary
                        lines.append("- _Claude session \(String(s.sessionId.prefix(8)))…_ · \(s.turns) turns · \(cost) · \(outcome)")
                    }
                }
                lines.append("")
            }
        }

        // Conversations
        lines.append("## Conversations")
        lines.append("")
        if log.conversations.isEmpty {
            lines.append("_(no conversation windows recorded)_")
        } else {
            for c in log.conversations {
                let clock = clockFormatter.string(from: c.timestamp)
                let tag = c.source == .chat ? "Chat" : "Ambient"
                let dur = "\(c.durationMinutes)m"
                let topics = c.topics.isEmpty ? "" : " · _\(c.topics.joined(separator: ", "))_"
                lines.append("- **\(clock)** · \(tag) · \(dur)\(topics) · \(c.summary)")
            }
        }
        lines.append("")

        // Meetings attended (calendar events overlapping the workday window).
        // The "(ambient overlap)" annotation means a transcript session ran
        // during the meeting, so the recording captured what was said.
        lines.append("## Meetings attended")
        lines.append("")
        let meetings = log.meetingsAttended ?? []
        if meetings.isEmpty {
            lines.append("_(no meetings on calendar)_")
        } else {
            for m in meetings {
                let start = clockFormatter.string(from: m.tsStart)
                let end = clockFormatter.string(from: m.tsEnd)
                let dur = max(1, Int(m.tsEnd.timeIntervalSince(m.tsStart) / 60))
                let cal = m.calendarName.isEmpty ? "" : " · _\(m.calendarName)_"
                let attended = m.ambientSessionId != nil ? " · ambient overlap" : ""
                lines.append("- **\(start) to \(end)** · \(dur)m\(cal) · \(m.eventTitle)\(attended)")
            }
        }
        lines.append("")

        // Commitments
        lines.append("## Commitments")
        lines.append("")
        lines.append("### Made today")
        if log.commitments.made.isEmpty {
            lines.append("_(none)_")
        } else {
            for s in log.commitments.made { lines.append("- \(s)") }
        }
        lines.append("")
        lines.append("### Kept")
        if log.commitments.kept.isEmpty {
            lines.append("_(none)_")
        } else {
            for s in log.commitments.kept { lines.append("- \(s)") }
        }
        lines.append("")
        lines.append("### Still open")
        if log.commitments.stillOpen.isEmpty {
            lines.append("_(none)_")
        } else {
            for s in log.commitments.stillOpen { lines.append("- \(s)") }
        }
        lines.append("")

        // Focus stats
        lines.append("## Focus")
        lines.append("")
        lines.append("| Verdict | Minutes |")
        lines.append("| --- | ---: |")
        lines.append("| On task | \(log.focusStats.onTaskMinutes) |")
        lines.append("| Drifting | \(log.focusStats.driftingMinutes) |")
        lines.append("| Off task | \(log.focusStats.offTaskMinutes) |")
        if log.focusStats.systemSleptMinutes > 0 {
            lines.append("| System slept | \(log.focusStats.systemSleptMinutes) |")
        }
        lines.append("")
        if !log.focusStats.perAppMinutes.isEmpty {
            lines.append("**Per app (top 8):**")
            let sorted = log.focusStats.perAppMinutes.sorted { $0.value > $1.value }.prefix(8)
            for (app, mins) in sorted {
                lines.append("- \(app) · \(mins)m")
            }
            lines.append("")
        }

        // Insights
        lines.append("## Insights")
        lines.append("")
        if log.insights.isEmpty {
            lines.append("_(no insights generated)_")
        } else {
            for i in log.insights { lines.append("- \(i)") }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Time section (TL;DR-adjacent bar charts)

    // Width in cells for each bar's filled/empty zone. Labels are padded to
    // labelWidth so columns line up even when category names differ in
    // length. Wrapped in backticks at the call site to force monospace.
    private static let barWidth = 22
    // 14 chars fits a typical project-slug label and the canonical category
    // names ("Activity mix" / "App categories" rows max out at 8). Longer
    // labels get truncated with a single ellipsis char.
    private static let labelWidth = 14
    private static let filledCell = "█"
    private static let emptyCell = "░"

    private static func renderTimeSection(_ log: WorkdayLog) -> [String] {
        var lines: [String] = []
        let allocation = log.timeAllocation
        // Prefer the dense ScreenTimeWatcher-derived project map when the
        // assembler populated it; fall back to FocusWatcher's sparse map for
        // older logs on disk that pre-date the new field.
        let perProject = log.projectMinutesScreentime
            ?? log.focusStats.perProjectMinutes
        let categoryMinutes = log.appCategoryMinutes ?? [:]

        // Skip the whole section on truly empty days (no tracked dwell or
        // calendar minutes anywhere) so the report stays clean.
        let hasAlloc = allocation.map(totalAllocationMinutes) ?? 0
        if hasAlloc == 0 && perProject.isEmpty && categoryMinutes.isEmpty {
            return lines
        }

        lines.append("## Time")
        lines.append("")

        // 1. Activity mix (the main "where did time go" view). Rows sorted
        // by minutes descending so the biggest bucket is the first thing
        // the reader sees.
        if let alloc = allocation, totalAllocationMinutes(alloc) > 0 {
            let total = totalAllocationMinutes(alloc)
            lines.append("**Activity mix**")
            lines.append("")
            let rows: [(String, Int)] = [
                ("Coding",   alloc.codingMinutes),
                ("Meetings", alloc.meetingsMinutes),
                ("Comms",    alloc.commsMinutes),
                ("Browsing", alloc.browsingMinutes),
                ("Terminal", alloc.terminalMinutes),
                ("Design",   alloc.designMinutes),
                ("Docs",     alloc.docsMinutes),
                ("Music",    alloc.musicMinutes),
                ("Other",    alloc.otherMinutes),
            ].filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            for (label, mins) in rows {
                lines.append(barRow(label: label, minutes: mins, total: total))
            }
            lines.append("")
        }

        // 2. Per-project bars. Uses the existing perProjectMinutes derived
        // from KnownProjects matching. Truncate to top 8 to keep the report
        // scannable on long multi-project days.
        if !perProject.isEmpty {
            let total = perProject.values.reduce(0, +)
            if total > 0 {
                lines.append("**Per project**")
                lines.append("")
                let sorted = perProject.sorted { $0.value > $1.value }.prefix(8)
                for (project, mins) in sorted where mins > 0 {
                    lines.append(barRow(label: project, minutes: mins, total: total))
                }
                lines.append("")
            }
        }

        // 3. App-category bars. Same buckets the activity mix uses but on
        // raw foreground dwell (no meeting-substitution adjustment). Lets a
        // reader see where the BUCKETING came from vs. activity mix above.
        if !categoryMinutes.isEmpty {
            let total = categoryMinutes.values.reduce(0, +)
            if total > 0 {
                lines.append("**App categories**")
                lines.append("")
                let sorted = categoryMinutes.sorted { $0.value > $1.value }
                for (cat, mins) in sorted where mins > 0 {
                    lines.append(barRow(label: cat, minutes: mins, total: total))
                }
                lines.append("")
            }
        }

        return lines
    }

    private static func totalAllocationMinutes(_ a: TimeAllocationBreakdown) -> Int {
        a.codingMinutes + a.terminalMinutes + a.browsingMinutes
            + a.commsMinutes + a.meetingsMinutes + a.designMinutes
            + a.docsMinutes + a.musicMinutes + a.otherMinutes
    }

    private static func barRow(label: String, minutes: Int, total: Int) -> String {
        // Clamp pct so meeting/app-dwell overlap (a meeting on the calendar
        // while Zoom is also foreground) can't produce "107%" rows.
        let rawPct = total > 0 ? Int(round(Double(minutes) * 100.0 / Double(total))) : 0
        let pct = min(100, max(0, rawPct))
        let filled = total > 0
            ? min(barWidth, Int(round(Double(minutes) * Double(barWidth) / Double(total))))
            : 0
        let bar = String(repeating: filledCell, count: filled)
            + String(repeating: emptyCell, count: max(0, barWidth - filled))
        // Strip backticks so a project name like "My`Project" can't close
        // the inline-code span mid-row.
        let sanitized = label.replacingOccurrences(of: "`", with: "'")
        // Truncate with a single-char ellipsis when the label is longer than
        // the column; pad with spaces when shorter. Pad using grapheme-cluster
        // count rather than String.padding(toLength:) which counts UTF-16
        // code units and misaligns columns for non-ASCII labels.
        let paddedLabel: String
        if sanitized.count > labelWidth {
            paddedLabel = String(sanitized.prefix(labelWidth - 1)) + "…"
        } else {
            paddedLabel = sanitized + String(repeating: " ", count: labelWidth - sanitized.count)
        }
        let pctStr = String(format: "%3d%%", pct)
        let minsStr = formatMinutes(minutes)
        return "`\(paddedLabel) \(bar) \(pctStr)  \(minsStr)`"
    }

    private static func formatMinutes(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let rem = mins % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }
}
