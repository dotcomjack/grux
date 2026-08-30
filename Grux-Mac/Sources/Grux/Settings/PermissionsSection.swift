import SwiftUI

/// Every macOS permission Grux can ask for, what it buys, what saying no costs,
/// and whether it is granted right now.
///
/// This exists because the explanation was reachable in exactly one place and it
/// was the wrong one. The copy lived in onboarding, and the only route back was
/// Settings, General, "Restart onboarding", which resets the WHOLE flow:
/// model, name, first captured frame. Somebody staring at a macOS permission
/// dialog wondering what Accessibility is for does not go looking under
/// "Restart onboarding", and would not want to redo three unrelated steps if they
/// did.
///
/// It also matters more than a normal settings panel because TCC grants expire
/// out from under an app. A macOS update, a Settings toggle, a reset, or a
/// change of signing identity revokes every one of them, and the operator hit
/// exactly that: nine system prompts in a row with nothing to explain any of
/// them, because first-run had already happened months earlier.
///
/// So: a permanent home, live status, and the same `why` string the onboarding
/// screen shows, from contract section 1.2.1.
struct PermissionsSection: View {

    /// Recomputed on every render rather than cached. Permissions are live
    /// system reads and the user may be granting one in System Settings in
    /// another window, so a cached value would show stale state at exactly the
    /// moment the user is looking for confirmation.
    @State private var refreshToken = 0

    private var permissions: [SetupRequirement] { CapabilityRequest.onboardingOrder }

    var body: some View {
        Section("Permissions") {
            Text("What Grux can ask macOS for, and what stays off if you say no. None of these are required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(permissions, id: \.rawValue) { req in
                row(req)
            }
        }
        .id("general.permissions")
        // Any window activation may follow a trip to System Settings, so re-read
        // rather than making the user hunt for a refresh button.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshToken &+= 1
        }
    }

    @ViewBuilder
    private func row(_ req: SetupRequirement) -> some View {
        let granted = CapabilityResolver.isSatisfied(req)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? GruxTheme.successMint : GruxTheme.textTertiary)
                    .accessibilityHidden(true)
                Text(req.label)
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                if granted {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Two different actions, because two different things happen.
                    // A promptable permission can raise the system dialog from
                    // here; one macOS only exposes in System Settings cannot, and
                    // a button claiming otherwise would do nothing visible.
                    if CapabilityRequest.style(for: req) == .systemSettingsOnly {
                        Button("Open Settings") { CapabilityRequest.openSystemSettings(for: req) }
                    } else {
                        Button("Grant") {
                            Task {
                                _ = await CapabilityRequest.request(req)
                                refreshToken &+= 1
                            }
                        }
                    }
                }
            }

            // The case for granting it. Falls back to the card text so a newly
            // added capability reads thin rather than blank.
            Text(req.why.isEmpty ? req.rationale : req.why)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        // Rebuilds the row when a grant lands, so the tick appears without a
        // settings round trip.
        .id("\(req.rawValue)-\(refreshToken)-\(granted)")
    }
}
