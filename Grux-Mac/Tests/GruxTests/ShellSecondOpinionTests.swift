import XCTest
@testable import Grux
@testable import GruxShellCore

/// THE TEXT GUARD IS THE FLOOR. A MODEL MAY ONLY RAISE IT.
///
/// The whole value of a text guard is that it does not depend on a provider
/// being right, being reachable, or being honest. The moment a confident
/// answer can clear `rm -rf ~`, the guard has been replaced rather than
/// supplemented.
final class ShellSecondOpinionTests: XCTestCase {

    func test_aCertainProviderCannotClearACommandTheTextGuardFlagged() {
        for command in ["rm -rf ~", "git reset --hard", "drop database users", "dd if=/dev/zero of=/dev/disk0"] {
            XCTAssertTrue(ShellSafety.looksDestructive(command: command), "\(command) is not flagged at all")
            // A provider certain it is harmless.
            XCTAssertTrue(ShellSecondOpinion.isDestructive(textGuardSaysYes: true,
                                                           secondOpinion: 0.0, threshold: 0.70),
                          "a provider cleared \(command)")
            // And one certain it is harmful, which changes nothing either.
            XCTAssertTrue(ShellSecondOpinion.isDestructive(textGuardSaysYes: true,
                                                           secondOpinion: 0.99, threshold: 0.70))
        }
    }

    func test_aProviderMayRaiseSomethingTheTextGuardMissed() {
        // A project script the text patterns know nothing about. Only a model
        // reading its name could say anything about it, so this is the case a
        // provider exists to raise.
        XCTAssertFalse(ShellSafety.looksDestructive(command: "./scripts/tidy.sh"))
        XCTAssertTrue(ShellSecondOpinion.isDestructive(textGuardSaysYes: false,
                                                       secondOpinion: 0.92, threshold: 0.70))
    }

    /// A keyless install has no provider opinion (the on-device one answers
    /// 0.50), so the floor alone decides there. Every command that deletes or
    /// overwrites what is already on disk has to be on the floor, or it runs
    /// without anybody being asked (ledger A23b, operator ruling 2026-09-27).
    func test_theFloorFlagsDeletingAndOverwritingWithoutAProvider() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("b\na\n".utf8).write(to: dir.appendingPathComponent("sorted.txt"))

        for command in ["find . -name '*.swift' -delete", "find . -type f -exec rm {} +",
                        "rm -r build", "sort -o data.txt data.txt", "sort -uo data.txt data.txt",
                        "sort --output=data.txt data.txt", "git branch -D main",
                        "git branch --delete main", "git branch -d main", "git branch -M main",
                        "ls && find . -delete", "find . -print | sort -o data.txt data.txt"] {
            XCTAssertTrue(ShellSafety.looksDestructive(command: command, cwd: dir.path),
                          "\(command) is not on the floor")
            XCTAssertTrue(ShellSecondOpinion.isDestructive(
                textGuardSaysYes: ShellSafety.looksDestructive(command: command, cwd: dir.path),
                secondOpinion: nil, threshold: 0.70), "\(command) runs unasked keyless")
        }
        // Over a file that is already there: the old contents are gone.
        XCTAssertTrue(ShellSafety.looksDestructive(command: "sort -o sorted.txt other.txt", cwd: dir.path))
        XCTAssertTrue(ShellSafety.looksDestructive(command: "sort -osorted.txt other.txt", cwd: dir.path))
        XCTAssertTrue(ShellSafety.looksDestructive(command: "sort --output sorted.txt other.txt", cwd: dir.path))

        // Reading, or writing a file that does not exist yet, destroys nothing.
        for command in ["find . -name '*.swift' -type f", "sort -n data.txt", "sort -o fresh.txt other.txt",
                        "git branch", "git branch -a", "git branch feature", "find . -name delete"] {
            XCTAssertFalse(ShellSafety.looksDestructive(command: command, cwd: dir.path),
                           "\(command) was flagged")
        }
    }

    /// The floor reads the program that actually runs, not the first word.
    /// `sudo find . -delete` is a find command, and so is every other wrapper
    /// form here (review RV5): each ran unasked on a keyless install.
    func test_theFloorLooksPastWrappersAndGitGlobalOptions() {
        for command in ["sudo find . -delete", "sudo -u root find . -delete",
                        "env X=1 find . -delete", "env -i X=1 Y=2 find . -delete",
                        "nice find . -delete", "nice -n 10 find . -delete",
                        "time find . -delete", "command find . -delete",
                        "ls | xargs -n 1 find -delete", "echo . | xargs -I {} find {} -delete",
                        "X=1 find . -delete", "A=1 B=2 git branch -D x",
                        "git -C repo branch -D x", "git -c core.pager=cat branch -D x",
                        "git --git-dir .git branch --delete x", "git --no-pager branch -d x",
                        "sudo env X=1 nice -n 5 find . -delete", "sudo -- find . -delete",
                        "/usr/bin/sudo /usr/bin/find . -delete"] {
            XCTAssertTrue(ShellSafety.looksDestructive(command: command), "\(command) is not on the floor")
        }
        // The same wrappers around a harmless command stay harmless.
        for command in ["sudo find . -name x", "env X=1 git branch", "git -C repo branch -a",
                        "nice -n 10 sort data.txt", "ls | xargs -n 1 echo", "command -v find",
                        "X=1 git branch feature"] {
            XCTAssertFalse(ShellSafety.looksDestructive(command: command), "\(command) was flagged")
        }
    }

    func test_noAnswerIsNotAYes() {
        // The on-device provider answers 0.5 to any yes or no question, which
        // means it cannot judge. Treating that as an opinion would gate every
        // ordinary write for everyone without a key.
        XCTAssertFalse(ShellSecondOpinion.isDestructive(textGuardSaysYes: false,
                                                        secondOpinion: nil, threshold: 0.70))
        XCTAssertFalse(ShellSecondOpinion.isDestructive(textGuardSaysYes: false,
                                                        secondOpinion: 0.5, threshold: 0.70))
    }

    // MARK: - What is worth paying a decision for

    func test_aReadOnlyCommandIsNeverWorthADecision() {
        for command in ["ls -la", "cat README.md", "grep -rn foo .", "git status", "git log --oneline -5",
                        "pwd", "wc -l file.txt", "find . -name '*.swift'"] {
            XCTAssertTrue(ShellSafety.isPlainlyReadOnly(command: command), "\(command) reads as writable")
            XCTAssertFalse(ShellSecondOpinion.worthAsking(command: command, textGuardSaysYes: false),
                           "paid for a decision on \(command)")
        }
    }

    /// The second half of `ls > /etc/passwd` is the half that matters, so any
    /// redirect, pipe, chain or substitution disqualifies the one-token read.
    func test_aRedirectOrAChainIsNotReadOnlyHoweverItStarts() {
        for command in ["ls > /etc/passwd", "cat a | tee b", "pwd; rm -rf .", "echo `rm -rf .`",
                        "grep x y && rm y", "echo $(rm -rf .)"] {
            XCTAssertFalse(ShellSafety.isPlainlyReadOnly(command: command),
                           "\(command) was treated as read-only")
        }
    }

    /// A binary is read-only only if it is read-only with every flag. `find`
    /// deletes and runs commands, `sort` and `tree` write files, `env` runs a
    /// command, so each is read-only only without the argument that writes.
    /// `find . -delete` is the case the second opinion exists for, and a
    /// read-only verdict meant it was never asked.
    func test_aReadOnlyBinaryWithAWritingArgumentIsWorthADecision() {
        for command in ["find . -name '*.swift' -delete", "find . -exec rm {} +",
                        "find . -execdir sh wipe.sh {} +", "find . -ok rm {} +", "find . -okdir rm {} +",
                        "find . -fprint out.txt", "find . -fls out.txt",
                        "sort -o data.txt data.txt", "sort -uo data.txt data.txt",
                        "sort --output=data.txt data.txt", "tree -o out.txt", "env rm -rf build",
                        "rg --pre ./wipe.sh foo", "rg --pre=./wipe.sh foo", "uniq in.txt out.txt",
                        "file -C -m magic", "git branch -D main", "git branch --delete main",
                        "git branch -m old new", "git diff --output=patch.diff", "git log --output=log.txt"] {
            XCTAssertFalse(ShellSafety.isPlainlyReadOnly(command: command), "\(command) was treated as read-only")
            XCTAssertTrue(ShellSecondOpinion.worthAsking(command: command, textGuardSaysYes: false),
                          "never asked about \(command)")
        }
        for command in ["find . -name '*.swift' -type f", "sort -n data.txt", "env", "tree -L 2",
                        "rg -n foo", "uniq data.txt", "git branch", "git branch -a", "git diff --stat"] {
            XCTAssertTrue(ShellSafety.isPlainlyReadOnly(command: command), "\(command) reads as writable")
        }
    }

    /// `git` as a whole is not read-only: `git reset --hard` is a git command.
    func test_gitIsNotReadOnlyAsAWholeBinary() {
        XCTAssertFalse(ShellSafety.isPlainlyReadOnly(command: "git reset --hard"))
        XCTAssertFalse(ShellSafety.isPlainlyReadOnly(command: "git clean -fd"))
        XCTAssertTrue(ShellSafety.isPlainlyReadOnly(command: "git diff HEAD~1"))
    }

    func test_aFlaggedCommandIsNotWorthADecisionEither() {
        // There is nothing left to raise, so asking is pure spend.
        XCTAssertFalse(ShellSecondOpinion.worthAsking(command: "rm -rf ~", textGuardSaysYes: true))
    }

    func test_anUnknownWritingCommandIsWorthAsking() {
        XCTAssertTrue(ShellSecondOpinion.worthAsking(command: "./scripts/wipe-staging-db.sh",
                                                     textGuardSaysYes: false))
    }

    func test_theQuestionNamesWhatCountsAsDestroying() {
        let q = ShellSecondOpinion.instructions.lowercased()
        XCTAssertTrue(q.contains("delet"))
        XCTAssertTrue(q.contains("overwrit"))
        XCTAssertTrue(q.contains("low for"), "nothing tells it what a safe command looks like")
    }
}
