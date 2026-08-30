import SwiftUI

// Settings section for notification triage (blueprint section 03): one
// matrix grid of category rows x interrupt/batch/silent radio pills, a
// speak-on-interrupt toggle column, quiet hours pickers, and the Haiku
// escalation switch. Designed to drop into a SettingsView Form as a
// Section, e.g. in the General pane or the Voice & Ambient pane.

struct TriageMatrixSection: View {
    @ObservedObject private var store = TriagePolicyStore.shared

    var body: some View {
        Section("Notifications") {
            matrixGrid
            // NO Divider() HERE. Under `.formStyle(.grouped)` every child of a
            // Section is its own inset row, so a bare Divider draws an empty card
            // between the grid and the quiet-hours row rather than a hairline
            // inside one. Grouped rows already separate themselves.
            quietHoursRow
            Toggle("Classify unknown notifications with Haiku", isOn: $store.llmEscalationEnabled)
            Text("Unknown free-text notifications batch by default; Haiku files them into a category in the background and caches the answer. $0.01 estimated per day, usually less.")
                .font(GruxType.caption)
                .foregroundStyle(.secondary)
            if let last = store.recentLog.first {
                Text("Last routed: \(last.title) (\(last.category.label), \(last.action.label.lowercased()))")
                    .font(GruxType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Matrix

    private var matrixGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: GruxSpacing.m, verticalSpacing: GruxSpacing.s) {
            GridRow {
                Text("CATEGORY")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.2)
                    .foregroundStyle(GruxTheme.textTertiary)
                ForEach(TriageAction.allCases) { action in
                    Text(action.label.uppercased())
                        .font(GruxTheme.Font.microCaps)
                        .kerning(1.2)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .gridColumnAlignment(.center)
                }
                Text("SPEAK")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.2)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .gridColumnAlignment(.center)
                    .help("Also speak the title aloud when this category interrupts")
            }
            ForEach(TriageCategory.allCases) { category in
                GridRow {
                    Label(category.label, systemImage: category.systemImage)
                        .font(GruxType.body)
                        .labelStyle(.titleAndIcon)
                    ForEach(TriageAction.allCases) { action in
                        radioPill(category: category, action: action)
                            .gridColumnAlignment(.center)
                    }
                    speakToggle(category: category)
                        .gridColumnAlignment(.center)
                }
            }
        }
        .padding(.vertical, GruxSpacing.xs)
    }

    private func radioPill(category: TriageCategory, action: TriageAction) -> some View {
        let selected = store.action(for: category) == action
        return Button {
            store.policies[category] = action
        } label: {
            Circle()
                .strokeBorder(
                    selected ? GruxTheme.accentPrimary : Color.white.opacity(0.18),
                    lineWidth: selected ? 5 : 1.5
                )
                .frame(width: 14, height: 14)
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .help("\(category.label): \(action.label)")
        .accessibilityLabel("\(category.label) \(action.label)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func speakToggle(category: TriageCategory) -> some View {
        let on = store.speakOnInterrupt.contains(category)
        return Button {
            if on { store.speakOnInterrupt.remove(category) }
            else { store.speakOnInterrupt.insert(category) }
        } label: {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? GruxTheme.accentPrimary : GruxTheme.textTertiary)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.action(for: category) != .interrupt)
        .opacity(store.action(for: category) == .interrupt ? 1 : 0.35)
        .help(on ? "Speaking on interrupt" : "Silent on interrupt")
    }

    // MARK: - Quiet hours

    private var quietHoursRow: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Toggle("Quiet hours", isOn: $store.quietHours.enabled)
            if store.quietHours.enabled {
                HStack(spacing: GruxSpacing.m) {
                    hourPicker("From", minute: $store.quietHours.startMinute)
                    hourPicker("Until", minute: $store.quietHours.endMinute)
                    Spacer()
                }
            }
            Text("During quiet hours interrupts fold into the hourly digest instead of bannering. The morning recap carries anything that arrived overnight.")
                .font(GruxType.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hourPicker(_ label: String, minute: Binding<Int>) -> some View {
        HStack(spacing: GruxSpacing.xs) {
            Text(label)
                .font(GruxType.caption)
                .foregroundStyle(.secondary)
            Picker(label, selection: minute) {
                ForEach(0..<48, id: \.self) { halfHour in
                    Text(Self.formatMinute(halfHour * 30)).tag(halfHour * 30)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)
        }
    }

    static func formatMinute(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        return String(format: "%d:%02d", h, mm)
    }
}
