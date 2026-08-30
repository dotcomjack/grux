import SwiftUI
import AppKit

/// One real frame, and the exact text that would leave the Mac, shown before
/// any of it leaves the Mac.
///
/// Contract `step.first_frame_reviewed`, section 5.4. The claim this makes is
/// unusually strong for an onboarding screen, so it has to be literally true:
/// the text rendered here is the output of the same `SecretRedactor.redact`
/// that the live capture loop uses, on a frame captured from this machine, and
/// no network call happens on this screen at all.
///
/// If that ever stops being true the screen becomes a lie that is worse than
/// having no screen, which is why `redact` is called here directly rather than
/// through a preview-specific helper that could drift from the real path.
struct FirstFrameReview: View {

    /// Internal rather than private so the render harness can ask for a state.
    ///
    /// Three of these four had never been looked at by anybody. A headless
    /// render always lands on `.capturing`, because the `.task` has not
    /// completed when layout runs, so the only screenshot this view could ever
    /// produce was its spinner. `.needsPermission` and `.failed` are the states
    /// a real user is MOST likely to meet, on the one screen whose whole job is
    /// to prove that Grux is safe with a screenshot, and they were unphotographed.
    enum Phase: Equatable {
        case needsPermission
        case capturing
        case ready(image: NSImage, redacted: String, redactionCount: Int, app: String)
        case failed(String)
    }

    @State private var phase: Phase
    /// A fixed state, never loading. Set only by the harness initialiser.
    private let isFixed: Bool

    init() {
        _phase = State(initialValue: .capturing)
        isFixed = false
    }

    /// Renders one fixed state and never captures anything.
    ///
    /// The guard matters as much as the injection: without `isFixed` the
    /// `.task` below would fire, call `load()`, and overwrite the state the
    /// caller asked for, so the harness would photograph the spinner again
    /// while appearing to have asked for something else.
    init(fixed phase: Phase) {
        _phase = State(initialValue: phase)
        isFixed = true
    }

    var body: some View {
        Group {
            switch phase {
            case .needsPermission: permissionPrompt
            case .capturing:       capturingPlaceholder
            case .ready(let image, let text, let count, let app):
                review(image: image, text: text, count: count, app: app)
            case .failed(let why): failure(why)
            }
        }
        .frame(height: 240)
        .task { if !isFixed { await load() } }
    }

    // MARK: - States

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Onboarding copy, not the capability remediation. The contract's
            // sentence is written for a setup card met later; here the user is
            // being walked through the grant for the first time.
            Text("Grant Screen Recording in System Settings, Privacy and Security. Grux reads the screen only when you ask.")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Grant Screen Recording") {
                // macOS shows its own prompt, and a grant does not take effect
                // in the current process, so there is nothing to await here.
                // The honest thing is to say that rather than spin forever.
                _ = ScreenCapturer.shared.requestPermission()
                phase = .failed("Granted? Quit and reopen Grux, macOS needs the restart to hand over the permission.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capturingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Taking one frame...")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failure(_ why: String) -> some View {
        // Never an error dialog. A capability that cannot resolve renders as a
        // sentence and the user moves on; the contract forbids surfacing it as
        // an error, and this is the screen where that rule is most tempting to
        // break.
        //
        // TRY AGAIN was missing, and the cost was specific rather than cosmetic.
        // Nobody was ever STUCK here, because the step itself carries Not now and
        // Continue. But this screen is the one place in the flow that GIVES
        // before it asks: it shows the user the exact text Grux would send,
        // before anything leaves the machine. A capture that failed once, for
        // any transient reason, silently cost them the whole proof and left
        // walking past it as the only move. Re-running the capture is one button
        // and it is the difference between "this did not work" and "this does
        // not work".
        VStack(alignment: .leading, spacing: 10) {
            Text(why)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try again") {
                phase = .capturing
                Task { await load() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func review(image: NSImage, text: String, count: Int, app: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(GruxTheme.textTertiary.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(app)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)

                ScrollView {
                    Text(text.isEmpty ? "No readable text on screen right now." : text)
                        .font(GruxTheme.Font.mono)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Stating the count matters more than it looks. "We redact
                // secrets" is a promise; "1 secret removed" is evidence, and it
                // is checkable against the frame sitting next to it.
                if count > 0 {
                    Label("\(count) secret\(count == 1 ? "" : "s") removed",
                          systemImage: "checkmark.shield.fill")
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.successMint)
                }

                Text("Nothing has left this Mac.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
    }

    // MARK: - Load

    private func load() async {
        guard ScreenCapturer.shared.hasPermission() else {
            phase = .needsPermission
            return
        }
        do {
            let snap = try await ScreenCapturer.shared.captureAndOCR()
            let redacted = SecretRedactor.redact(snap.ocrText)
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Your screen"
            phase = .ready(image: NSImage(cgImage: snap.image,
                                          size: NSSize(width: snap.image.width,
                                                       height: snap.image.height)),
                           redacted: redacted,
                           redactionCount: Self.countRedactions(redacted),
                           app: app)
        } catch {
            phase = .failed("Grux could not read the screen just now. You can turn this on later in Settings.")
        }
    }

    /// Counts the redaction markers the redactor emits. Deliberately counts the
    /// marker rather than diffing against the original, because the original
    /// contains the secrets and must not be held alongside the redacted copy
    /// just to produce a number for the UI.
    static func countRedactions(_ redacted: String) -> Int {
        redacted.components(separatedBy: "[REDACTED").count - 1
    }
}
