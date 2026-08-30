import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What Grux needs and whether this Mac has it.")

    @Flag(name: .long, help: "Emit the raw document instead of a table. For an agent.")
    var json = false

    @Flag(name: .long, help: "Do not ask the app to refresh first. Reads the file as it is.")
    var noRefresh = false

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let client = ControlClient()

        // THE APP REFRESHES, NEVER THIS BINARY.
        //
        // The obvious design is for the CLI to re-probe permissions so the answer is live.
        // It cannot. A TCC grant is keyed to the CLIENT, one row per bundle id, so
        // `AVCaptureDevice.authorizationStatus` asked from here returns whether the grux
        // binary has the microphone, never whether Grux.app does. Measured in this Mac's TCC
        // database: com.apple.Terminal and com.gruxai.grux hold separate rows for the same
        // service.
        //
        // So liveness comes from asking the app to recompute, which is the only process that
        // can answer. When it is not running the file is still read and its age is stated,
        // because a slightly old answer with a timestamp beats no answer at all.
        var refreshed = false
        if !noRefresh, client.isAvailable {
            refreshed = (try? client.call(tool: "grux_refresh_status").get()) != nil
        }

        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e):
            if json { FileHandle.standardError.write(Data("\(e)\n".utf8)) }
            leave(frame.explain(e))
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(status),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            leave(status.summary.featuresNeedingSetup == 0 ? .done : .waitingOnYou)
        }

        render(status, frame: frame, refreshed: refreshed, appRunning: client.isAvailable)
        // THE WHOLE MAC, so the scope is every chosen feature that still needs something.
        // `grux handoff` with no arguments means the same thing, and naming thirty nine ids
        // where the bare command is exact would be noise rather than precision, so the
        // renderer collapses to it when the scope IS everything outstanding.
        frame.handOff(Lookup.chosen(status)
            .filter { $0.state == "needsSetup" }.map(\.id))
        leave(status.summary.featuresNeedingSetup == 0 ? .done : .waitingOnYou)
    }

    private func render(_ status: SetupStatus, frame: Frame, refreshed: Bool, appRunning: Bool) {
        let r = frame.renderer
        frame.open(.prove)

        // The answer first.
        print(r.heading("  Grux \(status.appVersion)")
              + r.style.ink(.dim, "   \(status.summary.satisfied) of "
                            + "\(status.summary.capabilities) things it can use are set up"))

        // Then how much to trust it.
        let freshness: String
        if refreshed {
            freshness = "Just now, asked of the running app."
        } else if appRunning {
            freshness = "From the file. The app is running but did not answer, so this may be stale."
        } else if let age = SetupStatusReader.age(of: status) {
            freshness = "From the file, written \(Self.ago(age)). Grux is not running, so "
                + "nothing could recompute it."
        } else {
            freshness = "From the file. Its timestamp will not parse, so its age is unknown."
        }
        print(r.style.ink(.dim, r.prose(freshness)))
        print("")

        let needed = status.features.filter { $0.state == "needsSetup" }
        if needed.isEmpty {
            print(r.row(state: .satisfied, label: "Nothing is waiting on you.",
                        detail: nil, labelWidth: 0))
            print("")
            print(r.style.ink(.dim, r.prose(
                "\(status.summary.featuresReady) features are ready. "
                + "\(status.summary.selfAttested) answers are yours rather than measured.")))
        } else {
            // GROUPED BY WHAT THE ROW ASKS OF YOU, not by registry order.
            //
            // An errand and a decision are different kinds of thing and a flat list makes
            // them look like one queue to get through. AgentHandoff learned this already:
            // its first draft printed one list and read as a jumble. Decisions come LAST
            // for the same reason they do there, because that framing lands better
            // immediately before you act than buried among API tokens.
            let byID = Dictionary(uniqueKeysWithValues: status.capabilities.map { ($0.id, $0) })
            var seen = Set<String>()
            var errands: [SetupStatus.Capability] = []
            var decisions: [SetupStatus.Capability] = []
            for feature in needed {
                for id in feature.missing where !seen.contains(id) {
                    seen.insert(id)
                    guard let cap = byID[id] else { continue }
                    if cap.selfAttested { decisions.append(cap) } else { errands.append(cap) }
                }
            }

            print(r.legend(decisions.isEmpty ? [.needed] : [.needed, .attested]))

            func block(_ title: String, _ caps: [SetupStatus.Capability], _ state: RowState) {
                guard !caps.isEmpty else { return }
                print("")
                print("  " + r.heading(title))
                for cap in caps {
                    print(r.row(state: state, label: cap.label, detail: cap.id))
                    if let fix = cap.remediation {
                        print(r.style.ink(.dim, r.prose(fix, indent: 6)))
                    }
                }
            }
            block("SOMETHING TO GO AND DO", errands, .needed)
            block("SOMETHING TO DECIDE, AND ONLY YOU CAN", decisions, .attested)

            print("")
            // COUNT THE THINGS, NOT THE FEATURES. The first version said "6 features cannot
            // run yet" above a list of 5 rows, because several features want the same
            // capability. A count that does not match the list under it teaches the reader
            // to stop trusting the counts.
            let total = errands.count + decisions.count
            print(r.style.ink(.dim, r.prose(
                "\(total) thing\(total == 1 ? "" : "s") above \(total == 1 ? "is" : "are") "
                + "waiting on you, and \(needed.count) "
                + "feature\(needed.count == 1 ? "" : "s") \(needed.count == 1 ? "is" : "are") "
                + "held up by them. Everything else is ready and asks for nothing.")))
        }

        print("")
        print(r.rule())
        print("  " + r.style.ink(.dim, "grux status --json") + "   the same answer, for an agent")
        if !appRunning {
            print("  " + r.style.ink(.dim, "open -a Grux")
                  + "         start Grux so this can be recomputed")
        }
    }

    /// Plain English, because "1724876400" is not an age and "2h" is a unit test.
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<90: return "moments ago"
        case ..<5400: return "\(Int(seconds / 60)) minutes ago"
        case ..<172_800: return "\(Int(seconds / 3600)) hours ago"
        default: return "\(Int(seconds / 86400)) days ago"
        }
    }
}
