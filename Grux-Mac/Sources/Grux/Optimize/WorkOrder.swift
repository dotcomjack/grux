import Foundation

/// Optimize Grux: the person says what they want Grux to do differently, Grux
/// writes a work order, and their own coding agent carries it out.
///
/// ## Why Grux does not change itself here
///
/// Grux is open source and every person running it already has a coding agent
/// that can read the source, build it and prove the change. So Grux's job is
/// the part only Grux can do: measure this Mac (which build is installed,
/// where the source is, which settings files it reads) and hand the agent one
/// work order it can run end to end. The limit on what can be asked is the
/// agent's, never Grux's.
///
/// ## The line, and why it has three reviews
///
/// Twelve stations and three reviews, fifteen stops in the line. The
/// stations fall in four phases with a review by the person between them:
/// preflight, requirements and analysis; review the plan; design,
/// architecture and governance; review the design; build and validate;
/// review the result; install, verify, monitor and cleanup. The reviews are
/// where the person keeps control of their own app; everything between them
/// is the agent's.
///
/// ## The line ends at live, not at a commit
///
/// Measured 2026-09-27: an agent built a proposed setting in a side
/// worktree, committed, and stopped with "I haven't pushed it or merged it",
/// so nothing was live until the person asked again, and the worktree and
/// branch stayed behind. So install is required for any code change and
/// builds from the real checkout (a temporary branch is merged in first, so
/// the install records the checkout and not a folder about to be removed),
/// verify looks at the running app, and cleanup removes what was temporary.
/// Only then is the order `done`.
///
/// ## One line for every handoff
///
/// Every handoff Grux writes for a person's coding agent is one of these:
/// Copy work order, the Optimize card's proposed fix, and Self-Upgrade's
/// Copy handoff. What a proposal already knows (files, acceptance checks,
/// evidence) arrives as `detail` and goes into this template; nothing else
/// formats a handoff (OptimizeGruxTests scans for a second one).
///
/// ## Preflight, so a request cannot lose
///
/// Most people describe what they want in a sentence, and a sentence leaves
/// out the one or two things that change what gets built. So the first station
/// asks: AT MOST THREE questions, only ones whose answer changes the work, and
/// every one carries a recommended answer, so "go with your recommendations"
/// is always a complete reply and saying nothing is a valid answer too. A
/// request that needs nothing asked says so and carries straight on.
///
/// ## One template for every request
///
/// The work order never branches on what was asked. "Make the accent red" and
/// "add a timer to Today" get the same line; the agent decides at analysis
/// whether it is a setting or a change to the code. A test holds this.
enum WorkOrderStage: String, CaseIterable, Sendable {
    /// Grux wrote it; no agent has reported yet.
    case written
    case preflight
    case requirements
    case analysis
    case reviewPlan = "review-1"
    case design
    case architecture
    case governance
    case reviewDesign = "review-2"
    case build
    case validate
    case reviewResult = "review-3"
    case install
    case verify
    case monitor
    case cleanup
    case done
    case stopped

    /// The stations an agent reports, in the order it passes them.
    static let line: [WorkOrderStage] = [
        .preflight, .requirements, .analysis, .reviewPlan,
        .design, .architecture, .governance, .reviewDesign,
        .build, .validate, .reviewResult,
        .install, .verify, .monitor, .cleanup,
    ]

    var title: String {
        switch self {
        case .written: return "Waiting for your agent"
        case .preflight: return "Checking what you meant"
        case .requirements: return "Requirements"
        case .analysis: return "Analysis"
        case .reviewPlan: return "Your review: the plan"
        case .design: return "Design"
        case .architecture: return "Architecture"
        case .governance: return "Governance"
        case .reviewDesign: return "Your review: the design"
        case .build: return "Build"
        case .validate: return "Validate"
        case .reviewResult: return "Your review: the result"
        case .install: return "Install"
        case .verify: return "Verify"
        case .monitor: return "Monitor"
        case .cleanup: return "Cleanup"
        case .done: return "Done"
        case .stopped: return "Stopped"
        }
    }

    var isReview: Bool { self == .reviewPlan || self == .reviewDesign || self == .reviewResult }
    var isFinished: Bool { self == .done || self == .stopped }

    /// How far along the line, from 0 (nothing reported) to `line.count`.
    var position: Int {
        if self == .done { return Self.line.count }
        return (Self.line.firstIndex(of: self) ?? -1) + 1
    }
}

/// What the agent has reported, read from the order's `progress.log`.
///
/// One line per station, `<stage> | <note>`. Tolerant on purpose: an agent may
/// write a blank line, a comment, a word Grux does not know, or a note with a
/// pipe in it, and none of that may hide the last real report.
struct WorkOrderProgress: Equatable, Sendable {
    let stage: WorkOrderStage
    let note: String

    static let fresh = WorkOrderProgress(stage: .written, note: "")

    static func parse(_ log: String) -> WorkOrderProgress {
        var latest = fresh
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let word = parts.first?.lowercased(),
                  let stage = WorkOrderStage(rawValue: word), stage != .written else { continue }
            latest = WorkOrderProgress(stage: stage, note: parts.count > 1 ? parts[1] : "")
        }
        return latest
    }
}

/// Where Grux's source is on this Mac, as `build.sh` recorded it when it
/// installed the running app. Absent for the downloaded release.
struct WorkOrderSource: Codable, Equatable, Sendable {
    let path: String
    let commit: String
    /// The installed binary's modification time when `build.sh` wrote this, so
    /// a later install of the download is not mistaken for this build.
    let binaryMtime: Double
}

/// What Grux measured about itself for the work order.
struct WorkOrderContext: Equatable, Sendable {
    enum Installed: Equatable, Sendable {
        /// Built on this Mac from `source` by `build.sh`.
        case localBuild(WorkOrderSource)
        /// The release from the website or Homebrew; `olderSource` is a checkout
        /// on this Mac that built an earlier install, if there is one.
        case release(olderSource: WorkOrderSource?)
    }

    let appPath: String
    let version: String
    let build: String
    let installed: Installed
    let supportDir: String
    let orderDir: String

    /// Which install this is, from the recorded source and the binary on disk.
    /// Pure: a test hands it both.
    static func installed(source: WorkOrderSource?, binaryMtime: Double?, sourceExists: Bool) -> Installed {
        guard let source, sourceExists else { return .release(olderSource: nil) }
        if let binaryMtime, abs(binaryMtime - source.binaryMtime) < 5 { return .localBuild(source) }
        return .release(olderSource: source)
    }
}

enum WorkOrderPrompt {

    /// Where a downloaded install finds its source. DELIBERATELY NOT THE
    /// REPOSITORY URL: that carries the author's handle, and the shipped binary
    /// must not (ShippedBundleHygieneTests, which caught it here, and the same
    /// call `OperatorTool.prompt` made). The site links the repository, and any
    /// coding agent can follow one link.
    static let sourceHome = "https://gruxai.com"

    /// The longest request kept, in characters. A work order is a sentence or a
    /// paragraph; anything longer is almost certainly a paste gone wrong.
    static let maxRequest = 2000

    static func clean(_ request: String) -> String? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxRequest))
    }

    static func sourceLines(_ context: WorkOrderContext) -> [String] {
        switch context.installed {
        case .localBuild(let s):
            return ["- Installed: \(context.appPath), version \(context.version) (build \(context.build)), built on this Mac from the source below.",
                    "- Source: `\(s.path)` at commit `\(s.commit)`. Work there."]
        case .release(let older):
            var out = ["- Installed: \(context.appPath), version \(context.version) (build \(context.build)), the downloaded release.",
                       "- Source: the open source Grux repository is linked from \(sourceHome). Clone it at the installed version, `git clone --branch v\(context.version) <that repository>`, and work in its `Grux-Mac` folder."]
            if let older {
                out.append("- There is also a checkout at `\(older.path)` (commit `\(older.commit)`) from an earlier build. Use it only if it is at v\(context.version).")
            }
            return out
        }
    }

    /// The longest detail kept. A proposal's files, checks and evidence run
    /// to a few thousand characters; the cap only stops a runaway paste.
    static let maxDetail = 20_000

    /// `images` are the paths of screenshots the person attached, already
    /// written beside the order. With none, the text is what it always was.
    static func build(id: String, request: String, detail: String? = nil, images: [String] = [],
                      context: WorkOrderContext) -> String {
        let progress = "\(context.orderDir)/progress.log"
        var lines: [String] = []
        lines += [
            "# Grux work order \(id)",
            "",
            "**What the person asked Grux for:**",
            "",
            request.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"),
            "",
        ]
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            lines += [
                "**What Grux already worked out about it.** Use it at analysis and design; where it disagrees with the code, the code wins and you say so at review-1.",
                "",
                String(detail.prefix(maxDetail)),
                "",
            ]
        }
        if !images.isEmpty {
            lines += ["**Screenshots the person attached** (open each one at analysis):", ""]
            lines += images.map { "- `\($0)`" }
            lines += [""]
        }
        lines += [
            "You are this person's coding agent. Grux is an open source (MIT) macOS app. Nothing about it changes without the person's yes, and the only limits are theirs. Carry this work order along the line below, station by station. Stop at each of the three reviews and wait for the person to say yes.",
            "",
            "## What Grux measured on this Mac, just now",
            "",
        ]
        lines += sourceLines(context)
        lines += [
            "- Settings: `\(context.supportDir)/config.json` and `\(context.supportDir)/theme.json` (accent colour, appearance). Grux watches both and applies an edit the moment the file changes, so edit them while Grux runs. Grux's own data is in `~/.grux`. The log is `\(context.supportDir)/wake.log`.",
            "- Build, sign, install and relaunch: `./build.sh` inside `Grux-Mac`. Tests: `swift test` inside `Grux-Mac`.",
            "- Report EVERY station, the reviews included, the moment you reach it, by appending one line `<stage> | <note>` to `\(progress)`, for example `echo \"analysis | it is a setting in theme.json\" >> \"\(progress)\"`. Grux shows it live under Optimize Grux. The words, in order: \(WorkOrderStage.line.map(\.rawValue).joined(separator: ", ")), then done or stopped.",
            "",
            "## Rules that come with Grux",
            "",
            "- Read `CLAUDE.md` in `Grux-Mac` and `CONTRIBUTING.md` in the repository first. Where they disagree with this order, they win.",
            "- The smallest change that does it. If a setting already does what was asked, changing the setting IS the work: no code.",
            "- Colours, type, spacing and radii come from `Sources/Grux/DesignSystem`. Never hard code one in a view.",
            "- No em dash (U+2014) and no en dash (U+2013) anywhere: code, comments, copy, tests or the commit message. Use a comma, a colon or parentheses.",
            "- Nothing new leaves the Mac: no telemetry, no new network calls, no key, token or password in any file (Grux reads credentials from the Keychain only). Audio never leaves the machine.",
            "- Anything that sends, deletes or spends still goes through Approvals.",
            "- Every existing test keeps passing. If behaviour changed, add a test and show it failing without the change.",
            "- The person's yes at review-3 covers committing the change on the source checkout's current branch and installing it. Push only if they ask, or if `CLAUDE.md` says to.",
            "",
            "## The line",
            "",
            "### Preflight. Ask, then carry on.",
            "0. **preflight**: before anything else, ask AT MOST THREE questions, and only ones whose answer changes what you build (how far it goes, where it applies, what it replaces). Give every question a recommended answer, marked, so \"go with your recommendations\" is a complete reply. Never ask about implementation: which file, which pattern, how to test, those are yours. If they do not answer, or say just do it, take your own recommendations and say which you took. If nothing needs asking, append `preflight | none needed` and carry on.",
            "",
            "### Analyze",
            "1. **requirements**: say back, in one sentence, what they asked for and what they will see when it is done.",
            "2. **analysis**: find where it lives. Check the settings files and Grux's Settings before the code. Name the setting, or the files you would touch.",
            "",
            "### review-1: the plan. Stop here.",
            "Show the one-sentence goal, whether it is a setting or code, the files, what could break, and how to undo it. If it is code: the rebuilt app is signed on this Mac, so if Grux is the downloaded release, or `build.sh` says it fell back to ad-hoc signing, macOS asks for the microphone and the other permissions again. Wait for yes. A settings-only change goes from yes straight to station 8.",
            "",
            "### Design",
            "3. **design**: the change in its smallest form, the way Grux already does similar things.",
            "4. **architecture**: one source of truth; reuse what exists; nothing duplicated.",
            "5. **governance**: check it against the rules above, one by one.",
            "",
            "### review-2: the design. Stop here if the change touches more than one file or adds anything new; otherwise say you are going on.",
            "",
            "### Build and test",
            "6. **build**: make the change.",
            "7. **validate**: `swift build`, then `swift test`, then `python3 scripts/design-ratchet.py --check`. Read the whole result: zero failures, the test count does not drop, a run that collects zero tests is a failure, and the ratchet exits 0.",
            "",
            "### review-3: the result. Stop here.",
            "Show what changed, briefly, and how it will look. Wait for yes. Yes means go all the way to live: commit, install, verify and clean up, with no further question.",
            "",
            "### Deploy and operate",
            "8. **install**: required for every code change, never skipped. Commit the change on the source checkout's current branch. If you made it in a temporary worktree or branch, merge that commit into the source checkout's current branch first, so the install is built from, and records, the real checkout. Then run `./build.sh` inside that checkout's `Grux-Mac`: it builds, signs, installs and relaunches Grux. A settings-only change is an edit to the file in place, with no build: Grux applies it live, with no quit and no relaunch.",
            "9. **verify**: on the running app. Confirm the running Grux started after its binary was written, and that the change shows in it. `swift tools/winid.swift` lists Grux's windows; `screencapture -o -x -l<id> shot.png` captures one.",
            "10. **monitor**: read the end of the log for errors, and tell the person exactly how to undo it.",
            "11. **cleanup**: leave nothing of yours behind. If you made a temporary worktree or branch, confirm its commit was merged into the source checkout's current branch (`git branch --contains <commit>`), then `git worktree remove <path>` and delete the temporary branch (`git branch -d <branch>`). Delete any scratch files, captures or logs you made. `git status` in the source checkout shows nothing of yours.",
            "",
            "Finish by appending `done | <one line on what changed>` to the progress file, and only then: done means installed (built and relaunched, or for a settings-only change the file edited), verified on the running app, and cleaned up. A change that stops at a commit is not done. If you stop anywhere, append `stopped | <why>`.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
