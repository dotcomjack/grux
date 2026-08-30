import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux export

/// This Mac's choices, with every secret left behind.
///
/// ## Safe by construction, not by redaction
///
/// The distinction matters. A redacting exporter reads secrets and promises to drop them,
/// which is a promise somebody has to keep on every future field. This one cannot leak a
/// credential because it never reads one: `setup-status.json` records that `key.anthropic`
/// is satisfied, and nowhere records what it is. There is no value in the source to omit.
///
/// So the test for this is not "did we redact" but "does the source contain anything that
/// could be a secret at all", and the answer is checked rather than asserted.
///
/// What travels is the ANSWER to "what did this person choose and what did they set up".
/// What does not travel is anything that would let the receiving machine act as them.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Your choices, as JSON, with every credential left behind.",
        discussion: """
            Writes to stdout unless you pass --out. Nothing here can be used to sign in as \
            you: Grux records that a credential is present, never what it is, so there is no \
            secret in the file to remove.
            """)

    @Option(name: .long, help: "Write here instead of stdout.")
    var out: String?

    /// The only fields that travel. A LIST, not a filter, so a field added to the status
    /// document later has to be named here before it can leave the machine. A filter would
    /// have carried it out silently.
    static let capabilityFields = ["id", "kind", "satisfied", "selfAttested"]

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        let chosen = status.features.filter(\.chosen).map(\.id).sorted()
        let off = status.features.filter { !$0.chosen }.map(\.id).sorted()

        let document: [String: Any] = [
            "grux": [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "appVersion": status.appVersion,
                "schema": status.schema,
            ],
            "features": ["chosen": chosen, "off": off],
            "capabilities": status.capabilities
                .sorted { $0.id < $1.id }
                .map { cap -> [String: Any] in
                    // Field by field, by name. Never a whole object copied across.
                    ["id": cap.id, "kind": cap.kind,
                     "satisfied": cap.satisfied, "selfAttested": cap.selfAttested]
                },
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print(r.prose("Could not build the export."))
            leave(.failed)
        }

        guard let out else {
            // No frame, no rail. This is going into a pipe or a file by definition.
            print(text)
            leave(.done)
        }

        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            frame.open(.look)
            print(r.prose("Could not write \(url.path): \(error.localizedDescription)"))
            leave(.failed)
        }

        frame.open(.prove)
        print(r.row(state: .satisfied, label: "Written", detail: url.path, labelWidth: 12))
        print(r.row(state: .satisfied, label: "Features",
                    detail: "\(chosen.count) on, \(off.count) off", labelWidth: 12))
        print(r.row(state: .satisfied, label: "Capabilities",
                    detail: "\(status.capabilities.count) states", labelWidth: 12))
        print("")
        print(r.style.ink(.dim, r.prose(
            "No credential is in this file. Grux records that a key is present, never what "
            + "it is, so there was nothing to leave out. The Mac you take this to will still "
            + "ask you for every one of them.", indent: 2)))
        leave(.done)
    }
}
