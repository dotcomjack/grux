import SwiftUI
import AppKit

// Glass Reminder Toast: the single proactive-nudge surface. Every reminder
// type routes through this view so the aesthetic stays cohesive.
// Design cues: Omi/Limitless dark-first glass, iridescent violet primary,
// warm amber reserved for time-based urgency, mint for success.
struct ReminderToastView: View {
    let reminder: GruxReminder
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSnooze: ((Int) -> Void)?

    @State private var hover = false

    var body: some View {
        GruxGlassCard(tone: reminder.kind.tone) {
            VStack(alignment: .leading, spacing: 10) {
                header
                bodyText
                if hasActions { chipRow }
            }
            .padding(16)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: reminder.kind.sfSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(headerIconStyle)
                .symbolEffect(.pulse, options: .nonRepeating)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.kind.label)
                    .font(GruxTheme.Font.microCaps)
                    .kerning(2)
                    .foregroundStyle(kindLabelStyle)
                Text(reminder.title)
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if reminder.scheduledFor != nil {
                scheduledPill
            }
        }
    }

    private var bodyText: some View {
        MarkdownText(content: reminder.body)
            .markdownFont(GruxTheme.Font.body)
            .markdownForegroundColor(GruxTheme.textSecondary)
            .markdownBlockSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            if onAccept != nil {
                GruxChip(title: acceptLabel, systemImage: acceptIcon, style: .success) { onAccept?() }
            }
            if onSnooze != nil {
                GruxChip(title: "SNOOZE 10m", systemImage: "moon", style: .secondary) { onSnooze?(10) }
            }
            Spacer(minLength: 0)
            if onDismiss != nil {
                GruxChip(title: "DISMISS", systemImage: "xmark", style: .secondary) { onDismiss?() }
            }
        }
    }

    private var hasActions: Bool {
        onAccept != nil || onDismiss != nil || onSnooze != nil
    }

    private var acceptLabel: String {
        switch reminder.kind {
        case .commitment: return "ON IT"
        case .drift: return "REFOCUS"
        case .mentor: return "GOT IT"
        case .stuck: return "HELP ME"
        case .dailyRecap: return "OKAY"
        case .energyRecap: return "OKAY"
        case .morningBrief: return "OKAY"
        case .info: return "OKAY"
        }
    }

    private var acceptIcon: String {
        switch reminder.kind {
        case .commitment: return "bolt.fill"
        case .drift: return "arrow.uturn.left"
        case .mentor: return "checkmark"
        case .stuck: return "hand.raised.fill"
        case .dailyRecap: return "checkmark"
        case .energyRecap: return "checkmark"
        case .morningBrief: return "checkmark"
        case .info: return "checkmark"
        }
    }

    private var headerIconStyle: AnyShapeStyle {
        switch reminder.kind.tone {
        case .urgent: return AnyShapeStyle(GruxTheme.warnAmber)
        case .success: return AnyShapeStyle(GruxTheme.successMint)
        case .normal: return AnyShapeStyle(GruxTheme.iridescent)
        }
    }

    private var kindLabelStyle: AnyShapeStyle {
        switch reminder.kind.tone {
        case .urgent: return AnyShapeStyle(GruxTheme.warnAmber)
        case .success: return AnyShapeStyle(GruxTheme.successMint)
        case .normal: return AnyShapeStyle(GruxTheme.iridescent)
        }
    }

    private var scheduledPill: some View {
        let date = reminder.scheduledFor!
        return HStack(spacing: 4) {
            Image(systemName: "clock.fill").font(.system(size: 8, weight: .bold))
            Text(Self.formatRelative(date: date))
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .kerning(0.8)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    // "3m ago" / "in 12m" style. Stays compact.
    static func formatRelative(date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        let abs = Swift.abs(seconds)
        let unit: String
        let count: Int
        if abs < 60 { unit = "s"; count = abs }
        else if abs < 3600 { unit = "m"; count = abs / 60 }
        else if abs < 86400 { unit = "h"; count = abs / 3600 }
        else { unit = "d"; count = abs / 86400 }
        return seconds >= 0 ? "IN \(count)\(unit)" : "\(count)\(unit) AGO"
    }
}
