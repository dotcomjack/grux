import Foundation

/// Small pure answers the first run needs, held outside the views so a test can
/// check them without building SwiftUI.
///
/// All three exist for the same reason, found by walking a first run on a wiped
/// Mac on 2026-09-22: the flow asked for things it could already answer, and
/// said nothing about what it had already found.

// MARK: - The name macOS already knows

@MainActor
enum Identity {

    /// The name to put in the field before the person types anything.
    ///
    /// **Only when it looks like a human name.** A prefill that is WRONG is
    /// worse than an empty field, because the person accepts it without reading
    /// it and Grux then calls them by their account's short name forever. So
    /// this takes the first word of the account's full name, and only when that
    /// full name carries a surname too, or the single word is capitalised the
    /// way a name is. "Ada Lovelace" and "Ada" both give "Ada"; "svcacct",
    /// "admin" and an address give nothing, and the field stays empty exactly
    /// as it did before.
    ///
    /// An address is rejected outright: macOS lets the full name be anything,
    /// and some managed Macs set it to the login email.
    nonisolated static func suggestedName(fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return "" }

        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = words.first.map(String.init), first.count >= 2 else { return "" }
        // A name is letters. "svc-2" and "501" are not.
        guard first.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return "" }

        let looksLikeAName = words.count > 1 || (first.first?.isUppercase ?? false)
        return looksLikeAName ? first : ""
    }

    /// The same answer for the Mac this is running on.
    nonisolated static var systemSuggestion: String {
        suggestedName(fullName: NSFullUserName())
    }
}

// MARK: - What the model gate found before it asked

@MainActor
enum ModelGate {

    /// Shown when a local server answered before the person pressed anything.
    ///
    /// The screen used to open with "Paste an Anthropic API key" whatever was
    /// true on the Mac, so somebody already running Ollama, which is the free
    /// path the README leads with, was asked for a key they had deliberately
    /// not got. Looking first costs one request to a loopback address.
    static let foundTitle = "There is already a model on this Mac"

    /// Under "Use a local model instead". The old line promised Grux fetches a
    /// model whatever is running, which is false with no Ollama (W4, 2026-10-13).
    static let localLine = "Runs on this Mac. No key, no account, and nothing leaves the machine. "
        + "With Ollama running, Grux fetches the best model this Mac can run."
    static let ollamaLink = "Get Ollama, free, at ollama.com"
    static let ollamaURL = URL(string: "https://ollama.com")!

    /// The way past this step with no key and no local model. On a clean Mac
    /// Continue stayed disabled with nothing else to press (W4, 2026-10-13).
    /// Grux finishes setting up without a model; Now and Chat both say
    /// "Connect a model" and go to the same place.
    static let skip = "Skip for now"
    static let skipNote = "You can connect a model any time; Chat will ask for one."

    static func foundDetail(model: String) -> String {
        "Grux found \(model) running here. Use it and nothing leaves this Mac, "
            + "no key and no account. You can add a key later in Settings, Models."
    }

    static let useFound = "Use the model on this Mac"

    /// What the probe concluded. `none` covers "no server" and "not looked yet"
    /// deliberately: neither is something to say out loud on this screen.
    enum Probe: Equatable {
        case none
        case found(String)

        var model: String? {
            if case .found(let m) = self { return m }
            return nil
        }
    }
}
