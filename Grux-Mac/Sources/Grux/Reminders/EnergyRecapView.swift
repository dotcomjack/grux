import SwiftUI
import AppKit

// 8pm energy + focus recap card. Numbers up top, narrated paragraph in the
// middle, two action chips at the bottom (REPLAY / DONE). Tighter than the
// 10pm DailyRecap surface since this is purely the attention truth.
struct EnergyRecapView: View {
    let data: EnergyRecap
    var onReplay: () -> Void = {}
    var onClose: () -> Void = {}

    // Which project chip is expanded (nil = collapsed). Toggles on click;
    // clicking the same chip again collapses.
    @State private var expandedProject: String? = nil

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d  ·  h:mm a"
        return df
    }()

    var body: some View {
        GruxGlassCard(tone: .normal) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().background(Color.white.opacity(0.06))
                metricsRow
                narrativeBlock
                projectsSection
                topAppsSection
                footerActions
            }
            .padding(26)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(GruxTheme.iridescent)
                    .frame(width: 48, height: 48)
                    .blur(radius: 0.5)
                    .shadow(color: GruxTheme.violetGlow(strong: true), radius: 12)
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeat(2))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ENERGY RECAP")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .kerning(3.5)
                    .foregroundStyle(GruxTheme.iridescent)
                Text(Self.dateFormatter.string(from: data.generatedAt))
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            Spacer()
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 10) {
            metric(label: "HOURS",
                   value: String(format: "%.1f", data.hoursWorked),
                   accent: GruxTheme.accentPrimaryLight)
            metric(label: "BREAKS",
                   value: "\(data.focusBreakCount)",
                   accent: GruxTheme.warnAmber)
            metric(label: "LONGEST",
                   value: longestLabel,
                   accent: GruxTheme.successMint)
        }
    }

    private var longestLabel: String {
        let m = data.longestFocusBlockMinutes
        if m >= 60 {
            let hrs = Double(m) / 60.0
            return String(format: "%.1fh", hrs)
        }
        return "\(m)m"
    }

    private func metric(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .kerning(2)
                .foregroundStyle(accent)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(GruxTheme.textPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(accent.opacity(0.22), lineWidth: 0.6)
        )
    }

    private var narrativeBlock: some View {
        Text(data.summaryText)
            .font(.system(size: 14, weight: .medium, design: .default))
            .foregroundStyle(GruxTheme.textPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .strokeBorder(GruxTheme.iridescentRim, lineWidth: 0.8)
            )
    }

    // Project chips with click-to-expand inline detail. Chip shows project
    // name + minutes; clicking opens a panel below with the completed tasks
    // and ambient notes tagged to that project today. Lets the user dive into
    // "what got done on this project today" without leaving the recap.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("PROJECTS")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(GruxTheme.successMint)
                if !data.topProjects.isEmpty {
                    Text("\(data.topProjects.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(GruxTheme.successMint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(GruxTheme.successMint.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(GruxTheme.successMint.opacity(0.35), lineWidth: 0.6))
                }
                Spacer()
                if expandedProject != nil {
                    Text("tap chip to close")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(.tertiary)
                } else if !data.topProjects.isEmpty {
                    Text("tap a chip to dive in")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(.tertiary)
                }
            }
            if data.topProjects.isEmpty {
                Text("No project matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                // HStack with FlowLayout-ish behavior via wrapping is overkill
                // for 1-5 chips. Use LazyVGrid with a max column width so a
                // single chip stays pill-shaped instead of stretching to the
                // full card width (LazyVGrid columns fill their allocated
                // width by default).
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 8)],
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(data.topProjects, id: \.name) { p in
                        chip(for: p)
                    }
                }
                if let exp = expandedProject,
                   let detail = data.topProjects.first(where: { $0.name == exp }) {
                    expandedDetail(detail)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func chip(for p: EnergyRecap.ProjectDetail) -> some View {
        let isActive = (expandedProject == p.name)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedProject = isActive ? nil : p.name
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(GruxTheme.successMint.opacity(isActive ? 0.95 : 0.55))
                    .frame(width: 5, height: 5)
                Text(p.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(minutesLabel(p.minutes))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(GruxTheme.textPrimary.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isActive
                          ? GruxTheme.successMint.opacity(0.18)
                          : Color.white.opacity(0.04))
            )
            .overlay(
                Capsule()
                    .strokeBorder(GruxTheme.successMint.opacity(isActive ? 0.55 : 0.25),
                                  lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    private func expandedDetail(_ p: EnergyRecap.ProjectDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GruxTheme.successMint.opacity(0.75))
                Text(p.name.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(GruxTheme.successMint)
                Spacer()
                Text("\(minutesLabel(p.minutes)) tracked")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .kerning(1.1)
                    .foregroundStyle(.tertiary)
            }
            detailColumn(
                label: "COMPLETED",
                items: p.completedTaskTitles,
                emptyLabel: "Nothing marked complete on this project today."
            )
            detailColumn(
                label: "NOTES",
                items: p.ambientNotes,
                emptyLabel: "No ambient notes captured for this project today."
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(GruxTheme.successMint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(GruxTheme.successMint.opacity(0.28), lineWidth: 0.7)
        )
    }

    private func detailColumn(label: String, items: [String], emptyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(GruxTheme.textPrimary.opacity(0.55))
            if items.isEmpty {
                Text(emptyLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(GruxTheme.successMint.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(text)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(GruxTheme.textPrimary.opacity(0.92))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var topAppsSection: some View {
        listSection(
            title: "TOP APPS",
            items: data.topApps,
            accent: GruxTheme.accentPrimaryLight,
            emptyLabel: "Nothing tracked."
        )
    }

    private func listSection(
        title: String, items: [EnergyRecap.TopEntry],
        accent: Color, emptyLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(accent)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.6))
                }
                Spacer()
            }
            if items.isEmpty {
                Text(emptyLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(accent.opacity(0.6))
                                .frame(width: 4, height: 4)
                            Text(entry.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(GruxTheme.textPrimary.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(minutesLabel(entry.minutes))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(GruxTheme.textPrimary.opacity(0.7))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(accent.opacity(0.20), lineWidth: 0.6)
        )
    }

    private func minutesLabel(_ m: Int) -> String {
        if m >= 60 {
            let hrs = Double(m) / 60.0
            return String(format: "%.1fh", hrs)
        }
        return "\(m)m"
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            GruxChip(title: "REPLAY", systemImage: "play.fill", style: .secondary) {
                onReplay()
            }
            GruxChip(title: "DONE", systemImage: "checkmark", style: .primary) {
                onClose()
            }
            Spacer()
            Text(data.provider)
                .font(GruxTheme.Font.microCaps)
                .kerning(1.2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .trailing)
        }
    }
}
