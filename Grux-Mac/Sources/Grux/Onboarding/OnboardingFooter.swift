import SwiftUI

/// THE PRIMARY ACTION OF A FIRST-RUN SCREEN LIVES BELOW THE SCROLL AREA, NEVER
/// INSIDE IT.
///
/// Measured on a wiped Mac on 2026-09-22, walking the shipping build as a
/// stranger: at the default window (1040x732) "Here's your Grux" chose eight
/// features, which pushed Continue past the bottom edge. The screen scrolls, so
/// it was not a dead end, but nothing said so. There is no scrollbar at rest,
/// no fade, and Page Down, End and the arrow keys all left the window
/// byte-identical, so the only way to the button was a trackpad gesture aimed
/// at a screen that looked finished. Whether a person hits it depends on how
/// many features their sentence picked, which is the worst kind of bug: it
/// works for whoever built it.
///
/// A screen declares its action with `.onboardingPrimary`, and
/// `OnboardingView` renders it in a bar OUTSIDE the `ScrollView`. The button
/// then cannot move, whatever the content does.
struct OnboardingPrimaryAction: Equatable {
    var title: String
    var enabled: Bool
    /// The quiet way out, drawn small on the left. "Skip", usually.
    var secondaryTitle: String?
    var run: () -> Void
    var runSecondary: (() -> Void)?
    /// The stage that published this bar. Part of equality, so two screens that happen
    /// to read the same can never share a bar: the footer keeps the closure it already
    /// holds while the value compares equal, and a closure from the stage before would
    /// run `advance(from:)` for a stage that is no longer showing.
    var stage: OnboardingModel.Stage? = nil

    /// Closures cannot be compared, and they must not be: two actions are the
    /// same bar when they READ the same, on the same stage. Comparing anything else
    /// would make the preference change on every redraw, which is how a
    /// preference-driven footer turns into an update loop.
    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.enabled == b.enabled && a.secondaryTitle == b.secondaryTitle
            && a.stage == b.stage
    }
}

struct OnboardingPrimaryActionKey: PreferenceKey {
    static let defaultValue: OnboardingPrimaryAction? = nil
    static func reduce(value: inout OnboardingPrimaryAction?,
                       nextValue: () -> OnboardingPrimaryAction?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// Pin this screen's primary action to the bottom of the window.
    func onboardingPrimary(_ title: String,
                           stage: OnboardingModel.Stage,
                           enabled: Bool = true,
                           secondary: String? = nil,
                           runSecondary: (() -> Void)? = nil,
                           run: @escaping () -> Void) -> some View {
        preference(key: OnboardingPrimaryActionKey.self,
                   value: OnboardingPrimaryAction(title: title,
                                                  enabled: enabled,
                                                  secondaryTitle: secondary,
                                                  run: run,
                                                  runSecondary: runSecondary,
                                                  stage: stage))
    }
}

/// The bar itself. Sits under a hairline so it reads as chrome rather than as
/// the end of the content, which is what tells somebody there may be more above
/// it.
struct OnboardingFooterBar: View {
    let action: OnboardingPrimaryAction

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
            HStack {
                if let secondary = action.secondaryTitle {
                    Button(secondary) { action.runSecondary?() }
                        .buttonStyle(.plain)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                Spacer()
                // An empty title is a screen that offers only a way past, with
                // nothing to confirm. Setup has several.
                if !action.title.isEmpty {
                    Button(action.title) { action.run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!action.enabled)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 14)
        }
        .background(GruxTheme.base)
    }
}
