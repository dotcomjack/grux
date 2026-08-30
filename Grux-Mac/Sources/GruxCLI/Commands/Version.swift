import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux version

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "This binary, the app, and whether they match.")

    /// The version of the bundle this binary is IN, read from that bundle's own Info.plist.
    ///
    /// Correct by construction rather than baked in at build time. The CLI ships inside
    /// Grux.app/Contents/MacOS, so its own Info.plist is two directories up, and a symlink
    /// on PATH resolves to whichever bundle it actually points at. That is precisely the
    /// skew worth catching: a symlink left behind by an older install reports that older
    /// app's version and disagrees with the one that wrote the status file.
    ///
    /// Outside a bundle it says "dev", which is honest. A local `swift build` genuinely is
    /// not the app, and claiming a match would be a lie in the one command whose entire job
    /// is to report whether things match.
    static let cliVersion: String = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else {
            return "dev"
        }
        return version
    }()

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        // THE RAIL, like every other command. A command whose rail is missing looks like a
        // command with something to hide, and "which of these two is which version" is a
        // PROVE question: it reports what is true now and how to check it.
        frame.open(.prove)
        print(r.row(state: .satisfied, label: "grux", detail: Self.cliVersion, labelWidth: 14))

        guard case .success(let status) = SetupStatusReader.read() else {
            print(r.row(state: .optional, label: "Grux.app", detail: "not reported yet",
                        labelWidth: 14))
            print("")
            print(r.style.ink(.dim, r.prose(
                "Open Grux once so it can report its version.")))
            leave(.waitingOnYou)
        }

        // A LOCAL BUILD IS NOT A FAULT, so it must not wear the fault glyph. The first
        // version of this printed `!` beside the app and then said a match was not
        // expected, which is a row and a sentence disagreeing on the same screen.
        let matches = Self.cliVersion == status.appVersion
        let isDev = Self.cliVersion == "dev"
        print(r.row(state: matches ? .satisfied : (isDev ? .optional : .needed),
                    label: "Grux.app", detail: status.appVersion, labelWidth: 14))
        print("")
        if matches || isDev {
            // SKEW IS REAL ONCE THE BINARY IS SYMLINKED ONTO PATH. A stale symlink pointing
            // at an app that was replaced is the ordinary way these drift apart, and a
            // version command that cannot say so is not worth having.
            print(r.style.ink(.dim, r.prose(isDev
                ? "This is a local build, so a version match is not expected."
                : "They match.")))
            leave(.done)
        }
        print(r.prose("These came from different builds. The binary inside "
                      + "Grux.app/Contents/MacOS always matches the app it shipped with, so a "
                      + "symlink pointing somewhere else is the usual cause."))
        leave(.selfRepairAvailable)
    }
}
