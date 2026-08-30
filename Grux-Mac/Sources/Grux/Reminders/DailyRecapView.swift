import SwiftUI
import AppKit

// Full-screen-feeling glass takeover. Bigger and more ceremonial than a
// normal reminder toast - this is the one time per day Grux breaks the
// discreet-toast convention. Centered on the main screen.
struct DailyRecapView: View {
    let data: DailyRecapData
    var onGoodNight: () -> Void = {}
    var onPlanTomorrow: () -> Void = {}

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d  ·  h:mm a"
        return df
    }()

    var body: some View {
        GruxGlassCard(tone: .normal) {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().background(Color.white.opacity(0.06))
                narrativeBlock
                sectionsRow
                footerActions
            }
            .padding(28)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(GruxTheme.iridescent)
                    .frame(width: 52, height: 52)
                    .blur(radius: 0.5)
                    .shadow(color: GruxTheme.violetGlow(strong: true), radius: 14)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeat(3))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DAILY RECAP")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .kerning(3.5)
                    .foregroundStyle(GruxTheme.iridescent)
                Text(Self.dateFormatter.string(from: data.date))
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            Spacer()
        }
    }

    private var narrativeBlock: some View {
        Text(data.narrative)
            .font(.system(size: 15, weight: .medium, design: .default))
            .foregroundStyle(GruxTheme.textPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
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

    private var sectionsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            recapSection(
                title: "SHIPPED",
                count: data.shippedToday.count,
                items: data.shippedToday,
                emptyLabel: "Nothing closed.",
                accent: GruxTheme.successMint
            )
            recapSection(
                title: "OPEN",
                count: data.openCommitments.count,
                items: data.openCommitments,
                emptyLabel: "No open commitments.",
                accent: GruxTheme.warnAmber
            )
            recapSection(
                title: "TOMORROW",
                count: data.tomorrowTop3.count,
                items: data.tomorrowTop3,
                emptyLabel: "Stack's light.",
                accent: GruxTheme.accentPrimaryLight
            )
        }
    }

    private func recapSection(title: String, count: Int, items: [String], emptyLabel: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(accent)
                if count > 0 {
                    Text("\(count)")
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
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, text in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(accent.opacity(0.6))
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

    private var footerActions: some View {
        HStack(spacing: 10) {
            GruxChip(title: "GOOD NIGHT", systemImage: "moon.fill", style: .primary) {
                onGoodNight()
            }
            GruxChip(title: "PLAN TOMORROW", systemImage: "sunrise", style: .secondary) {
                onPlanTomorrow()
            }
            Spacer()
            Text("Grux has saved this recap.")
                .font(GruxTheme.Font.microCaps)
                .kerning(1.2)
                .foregroundStyle(.tertiary)
        }
    }
}
