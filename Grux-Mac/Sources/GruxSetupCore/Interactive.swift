import Foundation

/// Reading keys from a real terminal, and the state machine behind a multi-select.
///
/// ## Why the decoding is split from the terminal
///
/// Raw mode is untestable in a suite: there is no TTY, and putting one there means a pty
/// and a subprocess for what is fundamentally a byte-to-meaning function. So `Key.decode`
/// takes bytes and returns meaning, `MultiSelect` takes keys and returns a new state, and
/// neither touches a file descriptor. The only part that talks to a terminal is
/// `RawMode`, which has no logic in it at all.
///
/// That split is the same one the reviewed prototype has: its keyboard handler and its
/// driver both go through one `send()`, so a scripted walk exercises the code a person
/// uses. A selection state machine that only runs under a human finger is a selection
/// state machine nobody has tested.

// MARK: - Keys

public enum Key: Equatable, Sendable {
    case up, down, space, enter, escape
    case char(Character)

    /// Decode one keypress from the bytes available.
    ///
    /// Returns the key and how many bytes it consumed, so a caller feeding a buffer can
    /// advance correctly. An arrow key is three bytes (ESC, `[`, letter) and a bare ESC is
    /// one, and telling them apart is the whole reason this returns a length.
    public static func decode(_ bytes: [UInt8]) -> (key: Key, consumed: Int)? {
        guard let first = bytes.first else { return nil }
        switch first {
        case 0x1B:
            // ESC alone, or the start of a sequence we have not fully received yet.
            guard bytes.count >= 3, bytes[1] == 0x5B else { return (.escape, 1) }
            switch bytes[2] {
            case 0x41: return (.up, 3)
            case 0x42: return (.down, 3)
            // Left and right are deliberately not mapped. A list that scrolls sideways on
            // an arrow key somebody pressed by accident is a surprise, and there is nothing
            // to the left.
            case 0x43, 0x44: return (.escape, 3)
            default: return (.escape, 3)
            }
        case 0x20: return (.space, 1)
        case 0x0A, 0x0D: return (.enter, 1)
        case 0x03: return (.escape, 1)   // ctrl-c, treated as "leave", never as a crash
        default:
            guard let scalar = Unicode.Scalar(UInt32(first)), first >= 0x20 else {
                return (.escape, 1)
            }
            return (.char(Character(scalar)), 1)
        }
    }
}

// MARK: - The terminal

/// Puts the terminal in raw mode for the life of a block, and always puts it back.
///
/// ALWAYS PUTS IT BACK. A CLI that exits with the terminal in raw mode leaves the person
/// with no echo and no line editing, which looks like their shell broke. The restore runs
/// on every path out including a thrown error, and `atexit` covers a hard exit from
/// somewhere deeper.
public enum RawMode {

    nonisolated(unsafe) private static var saved: termios?

    public static var isSupported: Bool { isatty(STDIN_FILENO) == 1 }

    public static func withRawMode<T>(_ body: () throws -> T) rethrows -> T {
        guard isSupported else { return try body() }
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        saved = original
        atexit { RawMode.restore() }

        var raw = original
        // Character at a time, no echo. ISIG stays ON so ctrl-c still signals; the decoder
        // also maps 0x03 for the case where a caller has turned it off.
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        withUnsafeMutablePointer(to: &raw.c_cc) { cc in
            cc.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { restore() }
        return try body()
    }

    public static func restore() {
        guard var s = saved else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &s)
        saved = nil
    }

    /// One keypress, or nil at end of input.
    public static func readKey() -> Key? {
        var buffer = [UInt8]()
        while true {
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            guard n == 1 else { return nil }
            buffer.append(byte)
            // An escape sequence needs three bytes. Anything else decodes on the first.
            if buffer[0] == 0x1B, buffer.count < 3 { continue }
            if let (key, _) = Key.decode(buffer) { return key }
            buffer.removeAll()
        }
    }
}

// MARK: - The selection

/// A multi-select over a grouped list, as pure state.
///
/// Mirrors the reviewed prototype: a cursor, a set of chosen ids, presets on the number
/// keys, `a` for all and `n` for none. Every one of those goes through `apply`, so a test
/// walks the same code a finger does.
public struct MultiSelect: Equatable, Sendable {

    public struct Item: Equatable, Sendable {
        public let id: String
        public let label: String
        public let group: String
        public let badge: String?
        public init(id: String, label: String, group: String, badge: String? = nil) {
            self.id = id
            self.label = label
            self.group = group
            self.badge = badge
        }
    }

    public enum Outcome: Equatable, Sendable { case running, confirmed, cancelled }

    /// A named starting point. A struct rather than a tuple because a tuple is not
    /// Equatable, and this whole type exists to be compared in a test.
    public struct Preset: Equatable, Sendable {
        public let key: Character
        public let name: String
        public let ids: [String]
        public init(key: Character, name: String, ids: [String]) {
            self.key = key
            self.name = name
            self.ids = ids
        }
    }

    public let items: [Item]
    public let presets: [Preset]
    public private(set) var cursor: Int
    public private(set) var chosen: Set<String>
    public private(set) var outcome: Outcome

    public init(items: [Item], presets: [Preset] = [], chosen: Set<String> = []) {
        self.items = items
        self.presets = presets
        self.cursor = 0
        self.chosen = chosen
        self.outcome = .running
    }

    public mutating func apply(_ key: Key) {
        guard outcome == .running else { return }
        switch key {
        case .down:
            // CLAMPS, never wraps. A list that jumps from the last row back to the first is
            // how somebody toggles a feature they never saw.
            cursor = min(items.count - 1, cursor + 1)
        case .up:
            cursor = max(0, cursor - 1)
        case .space:
            guard items.indices.contains(cursor) else { return }
            let id = items[cursor].id
            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        case .enter:
            outcome = .confirmed
        case .escape:
            outcome = .cancelled
        case .char(let c):
            switch c {
            case "a": chosen = Set(items.map(\.id))
            case "n": chosen.removeAll()
            case "j": cursor = min(items.count - 1, cursor + 1)
            case "k": cursor = max(0, cursor - 1)
            default:
                if let preset = presets.first(where: { $0.key == c }) {
                    // A preset REPLACES the selection rather than adding to it. Adding would
                    // make pressing two presets produce a third thing nobody named.
                    let known = Set(items.map(\.id))
                    chosen = Set(preset.ids).intersection(known)
                }
            }
        }
    }

    /// The window of rows to draw, so a 39 row list works in a terminal that is not 45 rows
    /// tall. Keeps the cursor off the edges where possible.
    public func window(height: Int) -> (range: Range<Int>, above: Int, below: Int) {
        guard items.count > height else {
            return (0..<items.count, 0, 0)
        }
        let lead = max(0, min(cursor - height / 2, items.count - height))
        return (lead..<(lead + height), lead, items.count - (lead + height))
    }
}


// MARK: - Secrets

/// Reading a secret from a person, with the echo off.
///
/// THE ONLY WAY A CREDENTIAL MAY ENTER GRUX FROM A TERMINAL. Never a flag, never an
/// environment variable. A flag lands in shell history and in `ps` output for every process
/// on the machine; an environment variable is inherited by every child process. Neither can
/// be taken back once it has happened, and somebody pasting a key into a terminal has no
/// reason to expect either.
///
/// It also refuses to read a secret from a pipe. A piped secret came from somewhere, and
/// that somewhere is a file or a history entry or another process's arguments, all of which
/// are the thing this exists to avoid. Saying so is better than accepting it quietly.
public enum SecretPrompt {

    public enum Failure: Error, Equatable {
        /// Nothing is attached, so there is nobody to ask and no safe way to read one.
        case notATerminal
        /// The person pressed ctrl-c or ctrl-d.
        case cancelled
        /// They entered nothing.
        case empty
    }

    /// Prompt once, with the terminal's echo disabled for the duration.
    ///
    /// The echo is restored on EVERY path out, including a thrown error, and `RawMode` also
    /// installs an `atexit` backstop. A terminal left with echo off looks to somebody like
    /// their shell has broken, and they will not connect it to a command that already exited.
    public static func read(_ prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) == 1 else { throw Failure.notATerminal }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw Failure.notATerminal }
        var quiet = original
        quiet.c_lflag &= ~UInt(ECHO)

        FileHandle.standardOutput.write(Data(prompt.utf8))
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0 else {
            throw Failure.notATerminal
        }
        defer {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
            // The newline the person's own Return did not echo, so the next line does not
            // start halfway across the screen.
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        guard let line = readLine(strippingNewline: true) else { throw Failure.cancelled }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed
    }
}
