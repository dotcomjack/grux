import XCTest
import GruxShellCore

/// The two scored safety winners, now in the Mac sources.
/// Force catches `git branch -f`. Delete catches `git branch --delete`.
/// Plain `git push` still returns on the earlier push check.
final class ShellSafetyWinnerTests: XCTestCase {
    private func kind(_ command: String) -> String {
        let got = ShellSafety.detectNetworkOrExternalEffect(command: command) ?? ""
        if got == "git --force operation is destructive on the remote" { return "force" }
        if got.contains("reaches the remote") { return "push" }
        if got.isEmpty { return "nil" }
        return "other"
    }

    func testForceWinner() {
        XCTAssertEqual(kind("git branch -f"), "force")
        XCTAssertEqual(kind("git branch -f other"), "force")
        XCTAssertEqual(kind("git branch --force"), "force")
        XCTAssertEqual(kind("git reset --force"), "force")
        XCTAssertEqual(kind("git push"), "push")
        // A forced push says force, the more specific warning; a plain push
        // still says push.
        XCTAssertEqual(kind("git push -f"), "force")
        XCTAssertEqual(kind("git status"), "nil")
        XCTAssertEqual(kind("echo --force"), "nil")
        XCTAssertEqual(kind("git merge --ff"), "nil")
        XCTAssertEqual(kind("git diff --follow"), "nil")
        XCTAssertEqual(kind("git config -f repo.gitconfig user.name"), "nil")
        XCTAssertEqual(kind("git commit -m force"), "nil")
    }

    func testDeleteWinner() {
        XCTAssertEqual(
            ShellSafety.detectNetworkOrExternalEffect(command: "git branch --delete feature"),
            "branch deletion"
        )
        XCTAssertEqual(
            ShellSafety.detectNetworkOrExternalEffect(command: "git branch -d feature"),
            "branch deletion"
        )
        XCTAssertNil(ShellSafety.detectNetworkOrExternalEffect(command: "git branch"))
        XCTAssertNil(ShellSafety.detectNetworkOrExternalEffect(command: "git status"))
        XCTAssertNil(ShellSafety.detectNetworkOrExternalEffect(command: "echo delete"))
        XCTAssertEqual(kind("git push origin main"), "push")
    }

    /// A force rename or copy overwrites an existing branch. `-M` and `-C` are
    /// the forced `-m` and `-c`, so the case of the flag decides.
    func testForceRenameAndCopyWinner() {
        XCTAssertEqual(kind("git branch -M main"), "force")
        XCTAssertEqual(kind("git branch -M old main"), "force")
        XCTAssertEqual(kind("git branch -m -f old main"), "force")
        XCTAssertEqual(kind("git branch -mf old main"), "force")
        XCTAssertEqual(kind("git branch --move --force old main"), "force")
        XCTAssertEqual(kind("git branch -C main copy"), "force")
        XCTAssertEqual(kind("git -C repo branch -M main"), "force")
        XCTAssertEqual(kind("git branch -m new-name"), "nil")
        XCTAssertEqual(kind("git branch -m old new-name"), "nil")
        XCTAssertEqual(kind("git branch -c new-copy"), "nil")
        XCTAssertEqual(kind("git branch -m old new && git status"), "nil")
        XCTAssertEqual(kind("git commit -m Merge"), "nil")
    }

    /// A delete flag wins over a force flag: `-D` is itself a forced delete,
    /// so any branch command that deletes says so.
    func testCombinedDeleteFlagsWinner() {
        for cmd in ["git branch -Df feature", "git branch -vD feature", "git -C repo branch -D feature",
                    "git branch -vDf feature", "git branch -fd feature", "git branch -d --force feature",
                    "git branch --delete --force feature"] {
            XCTAssertEqual(ShellSafety.detectNetworkOrExternalEffect(command: cmd), "branch deletion", cmd)
        }
    }

    /// The 3.0 text net caught a force behind a global option; narrowing it to
    /// `git branch -f` dropped that (aggregate review of PR 34 against 3.0).
    /// Read past global options for push, fetch and tag, and keep `-f` that
    /// names a file or sits inside a quoted value unflagged.
    func testForceBehindGlobalOptionsAndOnPushFetchTag() {
        for cmd in ["git -C repo push -f origin main", "git --git-dir=x push --force", "git push origin +main",
                    "git tag -f v1", "git fetch -f", "git push --force-with-lease origin main",
                    "git -C repo push --force-with-lease=main origin main", "git --no-pager fetch --force origin",
                    "git -C repo tag --force v2", "cd x && git -C repo push -fu origin main",
                    "git fetch origin +main:main", "git -c a=b push -f origin main"] {
            XCTAssertEqual(kind(cmd), "force", cmd)
        }
        XCTAssertEqual(kind("git -C repo push origin main"), "push", "a push behind a global option is still a push")
        XCTAssertEqual(kind("git config -f repo.gitconfig user.name x"), "nil")
        XCTAssertEqual(kind("git commit -m \"fix -f flag\""), "nil")
        XCTAssertEqual(kind("git commit -m \"remove --force from the script\""), "nil")
        XCTAssertEqual(kind("git tag -m \"-f\" v1"), "nil", "a tag message is not a flag")
        XCTAssertEqual(kind("git fetch origin"), "nil")
        XCTAssertEqual(kind("git tag v1"), "nil")
    }

    /// Global options before `branch`, and a command split over two lines.
    func testGlobalOptionsAndContinuationWinner() {
        XCTAssertEqual(kind("git --git-dir=foo branch -M a b"), "force")
        XCTAssertEqual(kind("git --git-dir foo branch -M a b"), "force")
        XCTAssertEqual(kind("git --no-pager branch -M a b"), "force")
        XCTAssertEqual(kind("git branch \\\n-M old new"), "force")
        XCTAssertEqual(
            ShellSafety.detectNetworkOrExternalEffect(command: "git --work-tree=x branch -D y"), "branch deletion")
        XCTAssertEqual(
            ShellSafety.detectNetworkOrExternalEffect(command: "git --work-tree x branch -D y"), "branch deletion")
        XCTAssertEqual(kind("git --no-pager branch -m new-name"), "nil")
    }
}
