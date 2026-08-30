import SwiftUI
import GruxShellCore

/// The permanent home for the terminal session engine.
///
/// First run names it once. This is where the answer still is in six months,
/// which is the half of the house rule that onboarding alone cannot satisfy.
///
/// WHY THIS SHOWS THE RESOLVED BINARY. "Grux drives your agent CLI" is not a
/// fact a user can check. A path is. `AccountSwitcher.resolveClaudeBinary()` is
/// the same resolution the spawner uses, so what is printed here is what will
/// actually run, and a wrong or missing CLI stops being a silent failure.
///
/// WHY IT SHOWS ENVIRONMENT CREDENTIALS. `AccountSwitcher` strips twenty
/// credential variables before spawning so a session authenticates as the
/// user's logged-in subscription over OAuth rather than silently billing an API
/// account. That protection is invisible, and the one thing a user might
/// reasonably want to know is whether their shell is currently exporting a key
/// at all. Reporting presence is honest and cheap. It never prints a value.
@MainActor
struct TerminalSessionsSettingsView: View {

    /// Mirrored rather than read on every render, because the resolver answers
    /// out of UserDefaults and SwiftUI is not watching that: flipping the
    /// toggle would write the choice and leave the control drawn in its old
    /// position. Same reasoning as `stepBinding` in the onboarding flow.
    @State private var understood: Bool =
        CapabilityResolver.isSatisfied(.stepTerminalSessionsExplained)

    /// The credential variables `AccountSwitcher` removes before it spawns.
    /// Kept short on purpose: this is a presence probe for the user's benefit,
    /// not a second copy of the strip list to drift against.
    private static let credentialVars = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY",
        "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"
    ]

    private var exportedCredentials: [String] {
        let env = ProcessInfo.processInfo.environment
        return Self.credentialVars.filter { (env[$0]?.isEmpty == false) }
    }

    /// Mirrored for the same reason as the toggle: the ceiling lives in
    /// UserDefaults and SwiftUI is not watching it.
    ///
    /// Seeded from the STORED preference rather than from
    /// `SessionConcurrency.ceiling`. See `storedPreference()`.
    @State private var maxParallel: Int = TerminalSessionsSettingsView.storedPreference()

    /// Mirrored for the same reason again: `ShellTrustCeiling.ceiling` answers
    /// out of UserDefaults, so a Picker bound straight to it would write the
    /// choice and leave the control drawn on the old row.
    @State private var trustCeiling: GruxShellCore.ShellMode = ShellTrustCeiling.ceiling

    /// The number the USER chose, which is a different question from
    /// `SessionConcurrency.ceiling`.
    ///
    /// That getter applies the live headroom discount, which is right for a
    /// swarm about to start and wrong for a control. Mirroring it would show a
    /// number nobody picked on any warm afternoon, and the `onChange` below
    /// would then hand that number back to the store, so one thermal blip would
    /// permanently rewrite the setting. `SessionConcurrency.structuralCeiling`
    /// documents that exact failure, which is why the stored value is bounded
    /// here by the structural ceiling and never by the live one.
    ///
    /// An install that has never opened this pane has nothing stored, so it
    /// reads the same starting number the spawner would use.
    private static func storedPreference() -> Int {
        let stored = UserDefaults.standard.object(forKey: SessionConcurrency.defaultsKey) as? Int
        return min(max(stored ?? SessionConcurrency.fallback, 1), SessionConcurrency.structuralCeiling)
    }

    /// Title case plus the one fact a picker row cannot carry on its own: which
    /// value an install that never touches this gets.
    private static func trustLabel(_ mode: GruxShellCore.ShellMode) -> String {
        let name = mode.rawValue.prefix(1).uppercased() + String(mode.rawValue.dropFirst())
        return mode == ShellTrustCeiling.conservativeDefault ? "\(name) (default)" : name
    }

    /// One line per mode, in the words of what it stops rather than what it is
    /// called. "Guarded" is not a thing a stranger can weigh; "asks before a
    /// command reaches the network" is.
    private static func trustExplanation(_ mode: GruxShellCore.ShellMode) -> String {
        switch mode {
        case .strict:  return "runs only an allowlist of development tools, and refuses anything else."
        case .guarded: return "runs anything, and asks first before a command reaches the network."
        case .trust:   return "runs anything without asking. Only while you are at the keyboard."
        }
    }

    /// nil means there is genuinely none. See AccountSwitcher.locateClaudeBinary: the
    /// old `resolveClaudeBinary().isEmpty` test could never be true, so this pane showed
    /// `claude` and hid its own not-found explanation on exactly the Macs that needed it.
    private var resolvedBinary: String? { AccountSwitcher.locateClaudeBinary() }

    var body: some View {
        Form {
            Section("Terminal sessions") {
                Text("""
                     Parts of Grux work by opening a headless terminal session on this Mac and \
                     driving the agent CLI you already have installed, so a long job can finish \
                     without you sitting through it.
                     """)
                .fixedSize(horizontal: false, vertical: true)

                Toggle("I understand what a session runs and what it spends", isOn: $understood)
                    .onChange(of: understood) { _, on in
                        CapabilityResolver.markStepCompleted(.stepTerminalSessionsExplained, on)
                        // `markStepCompleted` writes a defaults key and posts nothing, so
                        // the one thing now waiting on this step has to be told directly.
                        // Without this line, switching it on here would do nothing visible
                        // until the next launch.
                        TerminalFocusState.shared.startIfAllowed()
                    }

                // THIS SENTENCE HAS BEEN WRONG TWICE, in opposite directions.
                //
                // It first read "Turning this off does not stop a session already running",
                // which implied it stopped FUTURE ones. It stopped neither, so it was
                // rewritten to say the flag was an acknowledgement that no spawn path
                // consulted. That was true when it was written and is not true now: the step
                // is one of the three conditions `TerminalFocusState.startIfAllowed()` waits
                // for, which is how the four-terminal-window takeover on a fresh Mac got
                // fixed. A step nothing reads is decoration; a sentence that still says
                // nothing reads it is worse.
                Text("Grux does not watch your terminal windows until this is on. It does not stop a session already running: quit Grux to end them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What will run") {
                LabeledContent("Agent CLI") {
                    Text(resolvedBinary ?? "not found")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if resolvedBinary == nil {
                    Text("Grux could not find an agent CLI on this Mac, so session features stay unavailable until one is installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Which credential it spends") {
                Text("""
                     A session uses whatever that CLI is already signed in to. On a subscription \
                     the work draws from that plan. With an API key it is billed per call at API \
                     rates instead.
                     """)
                .fixedSize(horizontal: false, vertical: true)

                Text("""
                     Grux removes API key variables from the environment before it spawns a \
                     session, so a subscription session cannot quietly bill an API account.
                     """)
                .fixedSize(horizontal: false, vertical: true)

                Text("""
                     This is separate from the API key that powers chat. Signing the CLI in \
                     here does not give chat a key, and adding a key there does not sign the \
                     CLI in.
                     """)
                .fixedSize(horizontal: false, vertical: true)

                if exportedCredentials.isEmpty {
                    Label("No credential variables are exported in this environment.",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Exported here, and stripped before each session: \(exportedCredentials.joined(separator: ", "))",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Running more than one") {
                Text("""
                     Running several sessions at once is what pushes a plan into its rate limits. \
                     This caps the agent swarms Grux starts for you. Some paths, including \
                     Workflows and the Design Studio, start sessions that this does not yet cover.
                     """)
                .fixedSize(horizontal: false, vertical: true)

                // THE RANGE IS THE STRUCTURAL CEILING, NOT THE LIVE ONE, and
                // this line was the live one for one wave.
                // `SessionConcurrency.hardCeiling` is now derived from the
                // machine AS IT IS RIGHT NOW: `MachineLoad.current` halves it
                // under reduced headroom and zeroes it under minimal, so a
                // Stepper bound to it loses its top rows while the user is
                // looking at the control, and a number they had already chosen
                // becomes unreachable with nothing on screen able to say why.
                // `structuralCeiling` is the same derivation with headroom
                // pinned to `.full`, which is a fact about the hardware and
                // does not move while the app is open.
                Stepper(value: $maxParallel, in: 1...SessionConcurrency.structuralCeiling) {
                    LabeledContent("Most sessions at once", value: "\(maxParallel)")
                }
                // Guarded rather than unconditional, because `onAppear` seeds
                // the mirror and SwiftUI fires this for that assignment too.
                // An unguarded write would hand the stored number straight back
                // to the store every time the pane opened, which is only
                // harmless for as long as the two agree.
                .onChange(of: maxParallel) { _, n in
                    guard n != Self.storedPreference() else { return }
                    SessionConcurrency.ceiling = n
                }

                // The live ceiling is ALLOWED to sit below the setting. The one
                // thing it must not do is sit there silently: the user would
                // ask for six, watch two start, and have no way to tell a busy
                // machine from a broken feature.
                if SessionConcurrency.hardCeiling < maxParallel {
                    Label("This Mac is busy right now, so Grux will start at most \(SessionConcurrency.hardCeiling) until it frees up. Your setting stays at \(maxParallel) and applies again when it does.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("A task that asks for more gets this instead. A task that asks for fewer keeps its own number. The limit is per swarm, not across all of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The stepper stops at \(SessionConcurrency.structuralCeiling) because that is what this Mac's cores and memory can hold, at roughly \(Int(SessionConcurrency.memoryGBPerSession)) GB a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // WHY THIS LIVES BESIDE THE CONCURRENCY CEILING. They are the same
            // kind of control: a bound on what the model may ask a session for,
            // rather than a switch that turns a feature on. Both were decided
            // by the model alone until this wave, and a user who has come here
            // to ask how much a session can spend is the same user who wants to
            // know what it is allowed to run.
            Section("How far a session may be trusted") {
                Text("""
                     A session can run shell commands. The agent picks how much freedom each one \
                     gets when it starts, and this is the most it may pick.
                     """)
                .fixedSize(horizontal: false, vertical: true)

                Picker("Most a session may be trusted", selection: $trustCeiling) {
                    // Ordered most restrictive first by `selectableModes` itself,
                    // so the picker reads as a dial where down is safer.
                    ForEach(ShellTrustCeiling.selectableModes, id: \.self) { mode in
                        Text(Self.trustLabel(mode)).tag(mode)
                    }
                }
                .onChange(of: trustCeiling) { _, mode in ShellTrustCeiling.ceiling = mode }

                // All three on screen at once, deliberately. The choice is a
                // comparison, and a menu that shows one line at a time is the
                // same mistake as an alert: it takes the alternatives away at
                // the moment somebody needs to weigh them.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ShellTrustCeiling.selectableModes, id: \.self) { mode in
                        Text("\(Self.trustLabel(mode)) \(Self.trustExplanation(mode))")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // THE BINDING MOMENT, said on screen because it is the
                // difference between a control the user can trust and one that
                // quietly does not apply. `ShellSession` stores the mode when
                // the session starts and every later run inherits it, so
                // lowering this covers the next session and not the one already
                // working.
                Label("A session takes this when it starts. One already running keeps the mode it started with until it ends, so lowering this covers the next session, not the one on screen.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The agent can still ask for less than this and get it. It can never get more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            understood = CapabilityResolver.isSatisfied(.stepTerminalSessionsExplained)
            maxParallel = Self.storedPreference()
            trustCeiling = ShellTrustCeiling.ceiling
        }
    }
}
