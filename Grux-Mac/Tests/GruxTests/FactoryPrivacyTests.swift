import XCTest
@testable import GruxAgentCore

final class FactoryPrivacyTests: XCTestCase {

    func testCalendarWordInADiffIsAllowed() {
        let diff = "+++ b/Calendar/View.swift\n+let title = \"Calendar\"\n"
        XCTAssertEqual(FactoryPrivacy.check(diff: diff, scoreCommand: "bash factory/score.sh", env: [:]), .allow)
    }

    func testBannedPathIsRefused() {
        let diff = "+++ b/notes.md\n+see ~/.grux/mail/inbox.json\n"
        let verdict = FactoryPrivacy.check(diff: diff, scoreCommand: "bash factory/score.sh", env: [:])
        guard case .refuse(let reason) = verdict else { return XCTFail("expected refuse") }
        XCTAssertEqual(reason, "banned-path")
        XCTAssertFalse(reason.contains("~/.grux"))
    }

    func testLibraryCalendarsPathIsRefused() {
        let cmd = "cat ~/Library/Calendars/x.ics"
        guard case .refuse(let reason) = FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]) else {
            return XCTFail("expected refuse")
        }
        XCTAssertEqual(reason, "banned-path")
        XCTAssertFalse(reason.contains("Calendars"))
    }

    func testKeyShapedEnvIsRefused() {
        guard case .refuse(let reason) = FactoryPrivacy.check(diff: "", scoreCommand: "true", env: ["X": "sk-live-abc"]) else {
            return XCTFail("expected refuse")
        }
        XCTAssertEqual(reason, "key-shape")
        XCTAssertFalse(reason.contains("sk-"))
    }

    func testFactoryDirIsAllowed() {
        let diff = "+++ b/x\n+~/.grux/factory/out\n"
        XCTAssertEqual(FactoryPrivacy.check(diff: diff, scoreCommand: "true", env: [:]), .allow)
    }

    /// One factory path on a line used to clear the whole line.
    func testFactoryPathBesidePrivatePathIsRefused() {
        let cmd = "cat ~/.grux/factory/score.sh ~/.grux/mail/inbox.json"
        XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .refuse("banned-path"))
    }

    func testTwoFactoryPathsOnOneLineAreAllowed() {
        let cmd = "cp ~/.grux/factory/a.txt ~/.grux/factory/b.txt"
        XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .allow)
    }

    /// The same tree spelled through the home variable or the home folder.
    func testExpandedGruxPathsAreRefused() {
        for cmd in ["cat $HOME/.grux/mail/inbox.json",
                    "cat ${HOME}/.grux/mail/inbox.json",
                    "cat /Users/someone/.grux/mail/inbox.json",
                    "tar czf out.tgz ~/.grux"] {
            XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .refuse("banned-path"), cmd)
        }
    }

    /// Any `..` in a blob that names the support tree is refused, however the
    /// path is spelled or split.
    func testTraversalNearTheSupportTreeIsRefused() {
        for cmd in ["cat ~/.grux/factory/../mail/inbox.json",
                    "cd ~/.grux/factory && cat ../mail/inbox.json",
                    "cat ~/.grux/factory\\\n/../mail/inbox.json",
                    "cat ~/.grux/factory\\\r\n/../mail/inbox.json",
                    "cd ~/.grux/factory;cd ..;cat mail/inbox.json",
                    "cd ~/.grux/factory && cd .. && cat mail/x",
                    "(cd ~/.grux/factory; cd ..)"] {
            XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]),
                           .refuse("grux-path-traversal"), cmd)
        }
    }

    func testTraversalWithoutTheSupportTreeIsAllowed() {
        let diff = "+++ b/Sources/A.swift\n+let up = \"../shared\"\n"
        XCTAssertEqual(FactoryPrivacy.check(diff: diff, scoreCommand: "bash factory/score.sh", env: [:]), .allow)
    }

    func testFactoryPathWithoutTraversalIsAllowed() {
        let diff = "+++ b/notes.md\n+out goes to ~/.grux/factory/x\n"
        XCTAssertEqual(FactoryPrivacy.check(diff: diff, scoreCommand: "bash factory/score.sh", env: [:]), .allow)
    }

    /// `~name` is that person's home, and a quote may close the variable
    /// before the path goes on.
    func testTildeUserAndQuotedHomeAreRefused() {
        for cmd in ["cat ~someone/.grux/mail/inbox.json",
                    "cat \"$HOME\"/.grux/mail/inbox.json",
                    "cat \"${HOME}\"/.grux/mail/inbox.json"] {
            XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .refuse("banned-path"), cmd)
        }
    }

    /// Quoting changes how the shell reads a word, not the path it names.
    func testQuotedAndEscapedSpellingsAreRefused() {
        for cmd in ["cat '/Users/someone'/.grux/mail",
                    "cat '~someone'/.grux/mail",
                    "cat \"$HOME\"'/.grux/mail'",
                    "cat /Users/some\\ one/.grux/mail",
                    "cat $'/Users/someone'/.grux/mail",
                    "cat ~/.grux/factory/a;cat ~/.grux/mail",
                    "cat {~/.grux/factory/a,~/.grux/mail}"] {
            XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .refuse("banned-path"), cmd)
        }
        let diff = "+++ b/run.sh\n+~/.grux/mail/inbox.json\n"
        XCTAssertEqual(FactoryPrivacy.check(diff: diff, scoreCommand: "true", env: [:]), .refuse("banned-path"))
    }

    /// A `~` in the middle of a word is not a home folder.
    func testTildeInsideAWordIsAllowed() {
        for cmd in ["curl example.com/~a/.grux", "cat notes~/.grux", "ls '/Users/someone'/.grux/factory/out"] {
            XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .allow, cmd)
        }
    }

    func testExpandedFactoryPathsAreAllowed() {
        for cmd in ["ls $HOME/.grux/factory/out", "ls /Users/someone/.grux/factory/out", "ls ~/.grux/factory",
                    "ls ~someone/.grux/factory/out", "ls \"$HOME\"/.grux/factory/out"] {
            XCTAssertEqual(FactoryPrivacy.check(diff: "", scoreCommand: cmd, env: [:]), .allow, cmd)
        }
    }
}
