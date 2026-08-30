import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux config

/// One setting, read or written.
///
/// ## Never a secret, and that is structural rather than a promise
///
/// Every key here is an address, a path or a list of accounts. A credential cannot be read
/// or written through this door: it goes through `grux connect`, which prompts with the echo
/// off, and it lives in the Keychain where nothing reads it back.
///
/// ## Why the list is not every key in the contract
///
/// The contract's key table and this command had drifted apart in BOTH directions, and the
/// previous version of this comment recorded the drift as a fact about the app: it said 47
/// keys were "implemented nowhere". They were not. Fifteen were implemented under a
/// different Swift name. `grux.capture.excluded_bundle_ids` is
/// `GruxConfig.captureExcludedBundleIds`, live in four files including the window-title
/// privacy gate, and it read as dead only because a grep for the literal string found
/// nothing.
///
/// Re-measured 2026-08-29, and the CONTRACT was corrected rather than worked around. It now
/// declares 59 keys, every one accounted for:
///
///   26  reachable here.   10 are literal UserDefaults keys the resolver names;
///                         16 are bridged to the property that implements them
///                         (see ConfigBridge).
///   11  credentials, and they can never be here. A secret passed as a command argument is
///       in the shell history and in the process table for any local `ps`.
///       `grux connect` asks at a TTY with echo off.
///    9  marked `not implemented` in the contract itself, so the table stops implying they
///       work. They were going to be deleted; check-contract.py caught that
///       docs/capability-system.md builds on three of them as specified design, and a key
///       that describes intended design is not the same as a key nobody wrote down.
///   13  implemented, but not a person's to set from here. Some are derived
///       (`grux.schema.version`). Some are a record of consent rather than a preference:
///       `grux.capture.first_frame_reviewed` gates the whole capture loop, and writing it
///       from a command line would be forging the approval it stands for. Some live in a
///       dedicated store with its own screen, like `grux.model.custom_endpoints`.
///
/// 26 + 11 + 9 + 13 = 59, and no settable key is undeclared any more. Five were declared
/// wrongly or not at all and are fixed: the webhook inbox port under a name that never
/// existed in code, and `grux.mail.graph_accounts`, `grux.shell.trust_ceiling` and
/// `grux.services.rag_base_url` implemented but never written down. `grux.foundry.enabled`
/// was declared "off by default" the whole time and nothing implemented it, so the
/// self-upgrade loop ran on every launch; it is implemented now and bridged here.
///
/// Listing every declared key would present settings that do nothing as though they were settings, and
/// somebody would set one, see no effect, and reasonably conclude the command was broken.
struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or write one setting. Never a credential.",
        discussion: """
            With no arguments it lists every setting Grux reads. With a key it prints that \
            one. With a key and a value it sets it.

            A list-shaped setting takes comma separated entries.

            Credentials are not here and cannot be: use `grux connect`.
            """)

    @Argument(help: "A grux.* key. Omit to list them all.")
    var key: String?

    @Argument(help: "The new value. Omit to read.")
    var value: String?

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        var arguments: [String: Any] = [:]
        if let key { arguments["key"] = key }
        if let value { arguments["value"] = value }

        switch client.call(tool: "grux_config", arguments: arguments) {
        case .failure(let why):
            if !json { frame.open(.look) }
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            render(text, frame: frame)
        }
    }

    private func render(_ text: String, frame: Frame) {
        let r = frame.renderer
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any] else {
            print(r.prose(text))
            leave(.failed)
        }

        // The list.
        if let rows = obj["settings"] as? [[String: Any]] {
            frame.open(.look, "Everything Grux reads. Credentials are not here and cannot be.")
            let width = rows.compactMap { ($0["key"] as? String)?.count }.max() ?? 30
            var set = 0
            for row in rows {
                let k = (row["key"] as? String) ?? ""
                let v = (row["value"] as? String) ?? ""
                let isSet = (row["set"] as? Bool) ?? false
                if isSet { set += 1 }
                // The VALUE is the answer here, so it leads the dim column, and an unset
                // key says so in words rather than showing an empty gap the reader has to
                // interpret.
                // AN UNSET KEY WHOSE CAPABILITY IS SATISFIED IS NOT A GAP.
                //
                // Several capabilities are satisfied by a real store rather than by their
                // config key, so "not set" beside working mail is true about the key and
                // false about what the reader is actually asking. Say which.
                let handled = (row["capabilitySatisfied"] as? Bool) ?? false
                let capLabel = (row["capabilityLabel"] as? String) ?? ""
                let shown = isSet ? v
                    : (handled ? "not set, and not needed" : "not set")
                let room = max(12, r.style.width - width - 8)
                let clipped = shown.count > room
                    ? String(shown.prefix(room - 1)) + "\u{2026}" : shown
                let state: RowState = isSet ? .satisfied : (handled ? .satisfied : .skipped)
                print(r.row(state: state, label: k, detail: clipped,
                            labelWidth: width, indent: 4))
                if !isSet && handled && !capLabel.isEmpty {
                    print(String(repeating: " ", count: 6)
                          + r.style.ink(.dim, "\(capLabel) is already set up elsewhere"))
                }
            }
            print("")
            print(r.rule())
            // EVERY ROW ACCOUNTED FOR, and "handled elsewhere" is its own bucket rather
            // than being counted as a gap.
            let handled = rows.filter {
                (($0["set"] as? Bool) != true) && (($0["capabilitySatisfied"] as? Bool) == true)
            }.count
            var parts = ["\(set) set"]
            if handled > 0 { parts.append("\(handled) handled elsewhere") }
            let gap = rows.count - set - handled
            if gap > 0 { parts.append("\(gap) not set") }
            print(r.prose("\(rows.count) settings. " + r.list(parts) + "."))
            print("")
            print(r.style.ink(.dim, r.prose(
                "grux config <key> <value> to change one. A credential goes through "
                + "grux connect instead, which never shows what you type.", indent: 2)))
            leave(.done)
        }

        // One key, read or written.
        let k = (obj["key"] as? String) ?? ""
        let v = (obj["value"] as? String) ?? ""
        let isSet = (obj["set"] as? Bool) ?? false
        frame.open(value == nil ? .look : .prove)
        print(r.row(state: isSet ? .satisfied : .skipped, label: k,
                    detail: isSet ? v : "not set", labelWidth: k.count))
        // WHAT A VALID VALUE LOOKS LIKE, on the read, which is where somebody stands when
        // they are about to write one. Reading a key and being told only "not set" leaves
        // them to guess between true, yes and on, and a guess that misses is a refusal they
        // have to come back from. Only the bridged keys carry a shape; the older
        // UserDefaults-backed ones omit it and this stays quiet rather than inventing one.
        if value == nil, let shape = obj["shape"] as? String, !shape.isEmpty {
            print("")
            print(r.style.ink(.dim, r.prose("Takes \(shape).", indent: 4)))
        }
        leave(.done)
    }
}
