import ArgumentParser
import Foundation
import GruxSetupCore

/// Whether there is anybody here to ask.
///
/// ## Why every command carries this, including the ones that never ask
///
/// An agent driving forty five commands should not have to know which eleven of them can
/// prompt. Before this, `--no-input` was declared by seven commands and rejected by the
/// other thirty eight, so a caller passing it uniformly got `Unknown option '--no-input'`
/// and exit 64 from thirty eight of them. Measured on the shipped binary: `grux doctor
/// --no-input`, `grux status --no-input` and thirty six more all failed that way, on a
/// surface whose documented exit codes are 0, 1, 2 and 3.
///
/// So the flag is accepted everywhere and means one thing everywhere: THERE IS NOBODY TO
/// ASK. On a command that never asks, that is vacuously true and changes nothing, and
/// saying so in the help is more useful than refusing the flag.
///
/// ## It is not just the flag
///
/// `canAsk` is the question every prompting command actually has, and it has two halves.
/// A terminal with nobody watching it is the same problem as an explicit `--no-input`, and
/// a command that checks only one of them still hangs, or still refuses when it could have
/// asked. Both live here so neither can be forgotten at a call site.
struct InputPolicy: ParsableArguments {

    @Flag(name: .long,
          help: ArgumentHelp("Never wait for a person. Accepted by every command; on one "
                             + "that asks for nothing it changes nothing."))
    var noInput = false

    /// True when somebody could actually answer a question right now.
    var canAsk: Bool { !noInput && RawMode.isSupported }

    /// Ask a question and read the answer, putting the question WHERE THE PERSON IS.
    ///
    /// ## The bug this exists to close
    ///
    /// Every confirmation printed its question with `print`, which writes to stdout. With
    /// stdout redirected and stdin still a terminal, the question goes into the FILE and the
    /// person is prompted blind. Measured on the shipped binary:
    ///
    ///     printf 'no\n' | script -q /dev/null sh -c 'grux import x.json > out.txt'
    ///
    /// The terminal showed the typed `no` and nothing else. "Type the number of changes, or
    /// the file's name, to confirm" and the token to type both landed in out.txt. Anything
    /// other than the token takes the "Left everything alone" path and exits 0, so a person
    /// who cannot see the question reliably answers wrong and reads it as success.
    ///
    /// Line buffering stdout does NOT fix this, which is worth saying because it is the
    /// obvious move: it corrects the ORDER inside the file and leaves the question in the
    /// file. The question has to leave stdout altogether.
    ///
    /// ## Where it goes
    ///
    /// stdout when stdout is a terminal, so an ordinary run is unchanged and the question
    /// sits inline with the screen it belongs to. Otherwise `/dev/tty`, which is the
    /// person's terminal whatever stdout and stderr were pointed at, the same door `sudo`
    /// knocks on. Otherwise stderr. The screen still goes to stdout: somebody redirecting
    /// output asked for the output, and what they must still SEE is the question.
    ///
    /// FLUSHED FIRST, ALWAYS. `print` is block buffered off a terminal and this writes with
    /// `write(2)`, so without the flush the question would overtake the screen it belongs
    /// under and the log would record the answer before the thing it answered.
    /// STATIC, because where the person is has nothing to do with the flag. Five commands
    /// declare their own `--no-input` rather than composing this group, and a prompt that
    /// only the composers could reach would have left those five, which include every
    /// destructive one, still prompting into a redirect.
    static func ask(_ lines: [String], cursor: String = "  > ") -> String {
        fflush(stdout)
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + cursor
        Self.showToThePerson(text)
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Write something a person has to read, wherever they actually are.
    static func showToThePerson(_ text: String) {
        let data = Data(text.utf8)
        if isatty(STDOUT_FILENO) == 1 {
            FileHandle.standardOutput.write(data)
            return
        }
        // O_WRONLY and no controlling terminal is a real state: cron, a launchd job, a
        // container. It falls through rather than failing, because stderr is still better
        // than dropping the question on the floor.
        let fd = open("/dev/tty", O_WRONLY)
        if fd >= 0 {
            defer { close(fd) }
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            return
        }
        FileHandle.standardError.write(data)
    }

    /// The one sentence a command prints when it needed an answer and there was nobody.
    ///
    /// Takes the flag that WOULD have answered it, because "cannot prompt" tells a caller
    /// nothing they can act on and the whole point of exit 1 is that a better invocation
    /// succeeds immediately.
    func nobodyHere(_ flagThatWouldAnswer: String) -> String {
        noInput
            ? "This needs an answer and --no-input says there is nobody to give one. "
            + "Pass \(flagThatWouldAnswer) instead."
            : "Nothing is attached to this terminal, so there is nobody to ask. "
            + "Pass \(flagThatWouldAnswer) if you are sure."
    }
}
