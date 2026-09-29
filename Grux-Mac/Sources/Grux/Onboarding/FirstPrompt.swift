import Foundation

/// P-F-1, Task F1: the first thing a stranger sees, as a model the view reads,
/// so "one question and nothing else" is something a test can hold.
///
/// The view itself waits on the operator choosing a shape from the 1:1
/// visuals (`docs/superpowers/visuals/first-run-*.png`), because the decision
/// record puts the first-run prompt with Tuning and Labs: rethought, and
/// shown before it is built. Everything the view will say lives here now.
@MainActor
enum FirstPrompt {

    static let question = "What do you want to do with Grux?"

    /// The one decision on the screen is the answer. Listening is NAMED here,
    /// and asked for later, on its own screen, in the order `SetupOrder` puts
    /// it, so this screen never raises a prompt nobody asked for.
    static let decisions = 1

    static let placeholder = "Say it however you like. Run my inbox, keep me on track, help me ship code."

    struct Listening { let title: String; let lead: String; let body: String }

    /// Listening, named on the first screen with its off state explained, in
    /// the words Settings already uses rather than a second copy of them. The
    /// lead is the accepted render's bold line (first-run-a.png).
    static var listening: Listening {
        Listening(title: ListeningSection.copy.title,
                  lead: "Listening is off until you turn it on, later in this setup.",
                  body: ListeningMode.off.explanation + " "
                    + "Once it is on: " + ListeningMode.alwaysOn.explanation + " "
                    + ListeningSection.copy.body)
    }

    /// What the microphone button says BEFORE macOS asks, which is the rule
    /// for every prompt in this flow.
    static let micExplanation = "To say it instead of typing, Grux asks macOS for the microphone. It listens only "
        + "while the button is lit, and what you say becomes text on this Mac. This is not listening; that "
        + "comes later in setup, and you choose."
    static let micRefused = "The microphone is off for Grux in System Settings. Type instead, or turn it on there."

    /// For somebody who would rather pick from a list than describe it: the
    /// three levels, which were the front door before this.
    static let pickFromAList = "I would rather pick from a list"
}

/// The doors in the rail, explained once, for Settings and the first-run flow.
@MainActor
enum DoorsCopy {
    struct Copy { let title: String; let body: String }

    /// Names the rows behind the door from the registry, so the explanation
    /// cannot drift from what the door actually holds.
    static var developer: Copy {
        let labels = SidebarIA.behind(.developer).map(\.label)
        let list = labels.count > 1
            ? labels.dropLast().joined(separator: ", ") + " and " + (labels.last ?? "")
            : labels.joined()
        return Copy(
            title: "Show the Developer door",
            body: "\(list) live behind the Developer door, for people who write software. It is off on a new "
                + "install. Turning it on asks for nothing: no permission, no key. With it off, everything "
                + "behind it keeps its settings and still opens from the command palette.")
    }

    static var labs: Copy {
        Copy(title: "Labs",
             body: "Surfaces still being built live behind the Labs door, marked BETA once, at the door. "
                + "Everything there works, and any of it can change.")
    }
}
