import SwiftUI

// JaxHQStyle: presentation helpers for the Jax HQ surface. Jax HQ binds to the
// REAL sibling Jax singletons (ApprovalQueue.shared, BriefingEngine.shared,
// DecisionGate types, plus RoadmapStore for goals in motion), so this file holds
// only the view-layer glue: tints/labels/icons for those models, shared chrome
// (section shell, brand tag, empty line), formatters, and the styled inputs.
//
// Zero em/en dashes. Money is $N (MetaAdsFormat.dollars). GruxTheme tokens only.

// MARK: - GatePersona presentation (the assistant / user disclosure split)

// GatePersona is the tiny queue-facing token the gate stamps on a PendingApproval
// (DecisionGate.swift). We extend it with the view-layer tint/icon/chip glue.
extension GatePersona {
    var tint: Color {
        switch self {
        case .sarah: return GruxTheme.accentCo
        case .owner: return GruxTheme.accentPrimaryLight
        case .none: return GruxTheme.textTertiary
        }
    }

    var icon: String {
        switch self {
        case .sarah: return "person.fill.badge.plus"
        case .owner: return "person.crop.circle.fill"
        case .none: return "lock.fill"
        }
    }

    // Short chip label: who an outbound message would be signed as.
    var chipLabel: String {
        switch self {
        case .sarah: return "AS SARAH"
        case .owner: return "AS YOU"
        case .none: return ""
        }
    }
}

// MARK: - ProposedAction.Kind presentation

extension ProposedAction.Kind {
    var icon: String {
        switch self {
        case .spend: return "dollarsign.circle.fill"
        case .externalComms: return "paperplane.fill"
        case .other: return "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .spend: return "SPEND"
        case .externalComms: return "COMMS"
        case .other: return "REVIEW"
        }
    }

    var tint: Color {
        switch self {
        case .spend: return GruxTheme.warnAmber
        case .externalComms: return GruxTheme.accentCo
        case .other: return GruxTheme.textSecondary
        }
    }
}

// MARK: - Briefing.Slot presentation

extension Briefing.Slot {
    var icon: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .night: return "moon.stars.fill"
        case .onDemand: return "waveform"
        }
    }

    var kicker: String {
        switch self {
        case .morning: return "MORNING BRIEFING"
        case .night: return "NIGHT BRIEFING"
        case .onDemand: return "BRIEFING"
        }
    }
}

// MARK: - Shared section shell

// A titled section card matching the MetaAds power-tool look: an eyebrow header
// with an optional count badge and trailing control, then content inside a rounded
// panel that sits on GruxTheme.base. Used by all four HQ sections so they read as
// one current surface (Chat is the face; HQ matches it).
struct JaxSection<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = GruxTheme.textTertiary
    var count: Int? = nil
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MetaAdsEyebrow(text: title, icon: icon, tint: tint)
                if let count = count {
                    Text("\(count)")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.16)))
                }
                Spacer()
                if let trailing = trailing { trailing }
            }
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

// A muted empty-state line inside a section when it has nothing to show.
struct JaxEmptyLine: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(GruxTheme.textTertiary)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(GruxTheme.textSecondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// Brand tag chip shared across sections.
struct JaxBrandTag: View {
    let brand: String
    var body: some View {
        Text(brand.uppercased())
            .font(GruxTheme.Font.microCaps)
            .kerning(0.8)
            .foregroundStyle(GruxTheme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Time helpers

enum JaxTime {
    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Styled inputs (padding 8x12, radius 8, accent ring)

// Grux is dark-first violet, so the web "gold focus ring" convention maps to the brand
// accent ring here. Tight inputs, never chunky.
func jaxField(text: Binding<String>, placeholder: String) -> some View {
    TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(GruxTheme.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GruxTheme.accentPrimary.opacity(0.35), lineWidth: 1)
        )
}
