import Foundation

/// How Grux draws in a terminal.
///
/// ## The rules, and they are enforced rather than intended
///
/// **Colour is never the only carrier of meaning.** Every state has a glyph AND a word
/// before it has a colour, so `NO_COLOR=1`, a pipe, a screen reader and a monochrome
/// terminal all lose decoration and nothing else. `TerminalStyleTests` asserts that the
/// plain rendering of every state is still distinguishable.
///
/// **One accent, meaning one thing.** Violet marks where you are: the live beat, the current
/// question. It never marks success, never marks a warning, and never decorates a heading
/// for emphasis. Success and attention have their own glyphs and their own colours, and
/// those two exist because a person scanning forty rows needs the shape of the answer before
/// they read it.
///
/// **Answer first, reasoning under it, machine detail last and dimmed.** A capability row
/// reads `✓ Microphone` before it reads `perm.microphone`, because the id is for the agent
/// and the label is for the person.
///
/// **A non-TTY gets plain text.** No spinner, no cursor movement, no truncation to a width
/// nobody is looking at. A pipe is a machine reading, and a machine wants the whole line.
public struct TerminalStyle: Sendable {

    public let isTTY: Bool
    public let colour: Bool
    public let width: Int

    /// Below this a table is worse than a list, so the renderer stops trying to align.
    public static let narrowThreshold = 60

    public var isNarrow: Bool { width < Self.narrowThreshold }

    public init(isTTY: Bool, colour: Bool, width: Int) {
        self.isTTY = isTTY
        self.colour = colour
        self.width = width
    }

    /// Read from the real environment.
    ///
    /// `NO_COLOR` is honoured on PRESENCE, not on value, which is what the convention
    /// specifies: setting it to `0` still means no colour, and treating that as "colour on"
    /// is the most common way tools get it wrong.
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment,
                              isatty: Bool = Foundation.isatty(STDOUT_FILENO) == 1,
                              columns: Int? = nil) -> TerminalStyle {
        let dumb = (environment["TERM"] ?? "") == "dumb"
        let noColour = environment["NO_COLOR"] != nil
        let width = columns
            ?? environment["COLUMNS"].flatMap(Int.init)
            ?? Self.windowWidth()
            ?? 80
        return TerminalStyle(isTTY: isatty,
                             colour: isatty && !noColour && !dumb,
                             width: max(40, min(width, 100)))
    }

    private static func windowWidth() -> Int? {
        var w = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 else { return nil }
        return Int(w.ws_col)
    }

    // MARK: - Ink

    /// The palette, and it is deliberately short.
    ///
    /// Read from the app's own ThemeConfig so somebody moving between the window and the
    /// terminal sees one product: accent violet 0x7B61FF, and the 256-colour cube's nearest
    /// neighbours for the rest.
    public enum Ink: String, Sendable {
        /// Where you are. The one accent. Never success, never warning.
        case accent = "\u{1B}[38;5;141m"
        /// Satisfied, done, present.
        case ok = "\u{1B}[38;5;114m"
        /// Needs a person. Not an error: an unanswered question.
        case attention = "\u{1B}[38;5;179m"
        /// Machine detail, ids, paths. Present but not competing.
        case dim = "\u{1B}[38;5;244m"
        case bold = "\u{1B}[1m"
    }

    public func ink(_ colour: Ink, _ text: String) -> String {
        guard self.colour else { return text }
        return colour.rawValue + text + "\u{1B}[0m"
    }
}

// MARK: - States

/// What a row can be, with its glyph.
///
/// THE GLYPH IS THE MEANING and the colour is a second copy of it. Every one of these is
/// distinguishable in a pipe, and a test says so.
public enum RowState: Sendable {
    /// Present, measured.
    case satisfied
    /// Missing and something you chose needs it.
    case needed
    /// Missing and optional. The feature runs anyway, on a lesser path.
    case optional
    /// You said no, and that is a complete answer.
    case skipped
    /// True because you said so, not because anything looked.
    case attested

    public var glyph: String {
        switch self {
        case .satisfied: return "+"
        case .needed:    return "!"
        case .optional:  return "-"
        case .skipped:   return "."
        case .attested:  return "~"
        }
    }

    /// The word, for a reader who does not know the glyphs yet. Never omitted on a narrow
    /// terminal, because that is exactly where a legend does not fit either.
    public var word: String {
        switch self {
        case .satisfied: return "ready"
        case .needed:    return "needed"
        case .optional:  return "optional"
        case .skipped:   return "skipped"
        case .attested:  return "your word"
        }
    }

    public var ink: TerminalStyle.Ink {
        switch self {
        case .satisfied: return .ok
        case .needed:    return .attention
        case .optional:  return .dim
        case .skipped:   return .dim
        case .attested:  return .dim
        }
    }
}

// MARK: - The six beats

/// The shape every Grux command shares.
///
/// Printed as a rail at the top of every command, including the ones with only a single
/// beat to run. A beat with nothing to do is printed and passed through rather than skipped,
/// because a command whose rail is missing COST looks like a command with something to hide.
public enum Beat: String, CaseIterable, Sendable {
    case look = "LOOK"
    case choose = "CHOOSE"
    case cost = "COST"
    case grant = "GRANT"
    case handOff = "HAND OFF"
    case prove = "PROVE"

    public var summary: String {
        switch self {
        case .look:    return "what is already true on this Mac"
        case .choose:  return "the features you want"
        case .cost:    return "what that will ask for, and what it never will"
        case .grant:   return "the asks, cheapest to refuse first"
        case .handOff: return "a prompt for your own coding agent"
        case .prove:   return "what is true now, and how to check it yourself"
        }
    }
}

public struct Renderer {

    public let style: TerminalStyle
    public init(style: TerminalStyle) { self.style = style }

    /// The rail. On a narrow terminal it collapses to the current beat and a position,
    /// because six labels wrapped over three lines teaches nothing.
    public func rail(current: Beat?) -> String {
        guard let current else { return "" }
        if style.isNarrow {
            let n = (Beat.allCases.firstIndex(of: current) ?? 0) + 1
            return style.ink(.accent, "[" + current.rawValue + "]")
                + style.ink(.dim, " \(n) of \(Beat.allCases.count)")
        }
        // BRACKETS, not just colour. The rule this file opens with is that colour is never
        // the only carrier of meaning, and the rail was breaking it: in a pipe, or under
        // NO_COLOR, every beat rendered identically and two different screens printed the
        // same header. Caught by reading a dry run's output, where LOOK and COST were
        // indistinguishable.
        return Beat.allCases.map { beat in
            beat == current ? style.ink(.accent, "[" + beat.rawValue + "]")
                            : style.ink(.dim, " " + beat.rawValue + " ")
        }.joined(separator: style.ink(.dim, " "))
    }

    /// A capability or feature row, on the grid.
    ///
    /// One column for the glyph, one for the label, one for the machine id. The id is padded
    /// from the LABEL column rather than from the line start, so ids line up with each other
    /// across every command instead of each command inventing its own gutter.
    /// - Parameter detailIsTheAnswer: keep the detail on a narrow terminal, stacked under
    ///   the label instead of beside it.
    ///
    ///   The default is right for a capability id, which is machine detail beside a label
    ///   that already said everything. It is WRONG wherever the detail is the thing somebody
    ///   ran the command for: `grux transcribe --out` printed "Written" and "Words" with no
    ///   path and no number below 60 columns, and `grux meeting stop` printed six labels and
    ///   no values, which includes the one row that says whether it heard anything at all.
    public func row(state: RowState, label: String, detail: String? = nil,
                    labelWidth: Int = 30, indent: Int = 2,
                    detailIsTheAnswer: Bool = false) -> String {
        let glyph = style.ink(state.ink, state.glyph)
        // PAD ONLY WHEN SOMETHING FOLLOWS. A column exists to line the next column up, so
        // padding with nothing after it is just trailing whitespace on every row, which is
        // what a narrow terminal got in the first version: `+ Grux.app` followed by twelve
        // spaces and a newline.
        let stacks = style.isNarrow && detailIsTheAnswer && detail != nil
        let showsDetail = (detail != nil) && (!style.isNarrow || stacks) && !stacks
        let padded = (showsDetail && label.count < labelWidth)
            ? label + String(repeating: " ", count: labelWidth - label.count)
            : label
        var line = String(repeating: " ", count: indent) + "\(glyph) \(padded)"
        if showsDetail, var detail {
            // THE GRID HAS TO FIT INSIDE ITS OWN WIDTH ON A TTY. Everything else here is
            // sized from the terminal and then the detail column was appended whole, so a
            // long one simply ran off the end and wrapped wherever the terminal chose,
            // which breaks the alignment the grid exists to provide. Measured on the
            // shipped binary at 80 columns: `grux support-bundle --dry-run` printed a 106
            // character row, and its neighbour landed at exactly 100, so two adjacent rows
            // wrapped differently and the column stopped reading as a column.
            //
            // IN A PIPE IT STAYS WHOLE. A detail is DATA, a machine is reading, and there
            // is no width to fit. That is the same asymmetry `grux logs` is built on and it
            // is deliberate in both places.
            if style.isTTY {
                let used = indent + 2 + padded.count + 2
                let room = style.width - used
                // Below a dozen characters a clip says nothing, so the column is dropped
                // rather than reduced to an ellipsis pretending to be information.
                if room < 12 { return line }
                if detail.count > room {
                    detail = String(detail.prefix(room - 1)) + "\u{2026}"
                }
            }
            line += "  " + style.ink(.dim, detail)
        }
        if stacks, let detail {
            // STACKED, NOT APPENDED. The longest of these runs past the clamp's 40 column
            // floor, so putting it after the label just moves the overflow.
            line += "\n" + String(repeating: " ", count: indent + 2)
                + style.ink(.dim, detail)
        }
        return line
    }

    /// The legend. Printed once per command that uses glyphs, because a glyph nobody
    /// explained is decoration.
    public func legend(_ states: [RowState]) -> String {
        let parts = states.map { "\(style.ink($0.ink, $0.glyph)) \(style.ink(.dim, $0.word))" }
        return "  " + parts.joined(separator: style.ink(.dim, "   "))
    }

    public func heading(_ text: String) -> String {
        style.ink(.bold, text)
    }

    /// Wraps prose to the terminal width with a hanging indent, or leaves it alone when
    /// nothing is looking at a width.
    public func prose(_ text: String, indent: Int = 2) -> String {
        // ONE WIDTH GOVERNS THE WHOLE SCREEN. This used to wrap to a hard 76 whenever stdout
        // was not a terminal, while `rule()` kept honouring the real width, so `COLUMNS=60`
        // in a pipe drew a 56 character rule under 76 character paragraphs. The width is
        // already clamped to a sane range in `detect`, and a pipe with no COLUMNS still
        // lands at 80, so there was never anything for the special case to protect.
        let limit = style.width - indent
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty { line = String(word) }
            else if line.count + 1 + word.count <= limit { line += " " + word }
            else { lines.append(pad + line); line = String(word) }
        }
        if !line.isEmpty { lines.append(pad + line) }
        return lines.joined(separator: "\n")
    }

    /// One shell command over as many lines as it needs, still runnable.
    ///
    /// A trailing backslash continues a command in every shell this ships to, and the
    /// continuation lines are indented so the whole thing still reads as one command. The
    /// alternative was clipping, and a clipped command is not a command.
    public func wrapCommand(_ command: String, width: Int) -> [String] {
        let limit = max(24, width)
        guard command.count > limit else { return [command] }
        var lines: [String] = []
        var current = ""
        for word in command.split(separator: " ") {
            // The 2 is the ` \` this line will need if anything follows it.
            let room = limit - (lines.isEmpty ? 0 : 4) - 2
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= room {
                current += " " + word
            } else {
                lines.append(current + " \\")
                current = "    " + String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// A list a person reads aloud, not a machine's comma join.
    ///
    /// "Meetings, Chat" is a data structure. "Meetings and Chat" is a sentence, and this
    /// text sits inside one.
    public func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    public func rule() -> String {
        style.ink(.dim, "  " + String(repeating: "-", count: max(20, style.width - 4)))
    }
}
