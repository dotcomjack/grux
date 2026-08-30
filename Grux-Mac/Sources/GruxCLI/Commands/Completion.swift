import ArgumentParser
import Foundation

// MARK: - grux completion

/// The shell completion script, on stdout, for the caller to put wherever they keep them.
///
/// It prints and does not install. Writing into somebody's shell configuration is a change
/// to their machine they did not ask this command to make, and the one line that installs it
/// is shorter than the paragraph explaining where it went.
struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Print the shell completion script. Does not install it.",
        discussion: """
            zsh    grux completion zsh  > "${fpath[1]}/_grux"
            bash   grux completion bash > /usr/local/etc/bash_completion.d/grux
            fish   grux completion fish > ~/.config/fish/completions/grux.fish
            """)

    @Argument(help: "zsh, bash or fish.")
    var shell: String?

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let known: [String: CompletionShell] = [
            "zsh": .zsh, "bash": .bash, "fish": .fish,
        ]
        let r = Frame().renderer
        // NOT EXIT 64. ArgumentParser's own missing-argument code is EX_USAGE, and this
        // surface documents 0, 1, 2 and 3, so an agent reading those four has nothing to do
        // with a fifth.
        guard let shell, !shell.isEmpty else {
            print(r.prose("Name your shell. The script goes to stdout, so redirect it "
                + "wherever your shell keeps them."))
            print("")
            for name in known.keys.sorted() {
                print("    " + r.style.ink(.accent, "grux completion " + name))
            }
            leave(.failed)
        }
        guard let s = known[shell.lowercased()] else {
            print(r.prose("No completion for \(shell). Try "
                          + r.list(known.keys.sorted()) + "."))
            leave(.failed)
        }
        // Straight to stdout with no frame and no rail. This output is redirected into a
        // file by definition, and a decorative header would land in the middle of it.
        print(Grux.completionScript(for: s))
        leave(.done)
    }
}
