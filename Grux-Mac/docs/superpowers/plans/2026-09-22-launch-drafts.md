# Grux 3.0: everything the word releases, drafted

> **STATUS: ACTIVE, NOTHING PUBLISHED.** Every draft below waits on the
> operator's one word. The order is his answer of 2026-09-22, unchanged.
> The build it describes is the staged candidate in
> `~/Downloads/Grux-3.0.0-candidate/` (24,260,401 bytes, sha256
> `6d2d1dd0d5951b1c85682545a1c7b9678da93c92102063849327413915c92d32`).

## The order, once the word comes

| # | Step | Who runs it | Note |
|---|---|---|---|
| 1 | Push the public tree | session | The MIT extract, after `oss-guarantee.sh` passes on the exact tree being pushed |
| 2 | Tag `v3.0.0` and cut the GitHub release | session | Both zip names plus the notes below; the local tag `v3.0.0-rc.2` marks the commit today |
| 3 | Bump the Homebrew cask | session | New version and sha256 from `SHA256SUMS.txt` |
| 4 | `npm publish` 3.0.0 | session | `@dotcomjack/grux`, the tarball already built and tested (11 of 11) |
| 5 | Re-sync and deploy gruxai.com | session | The site regenerates from the PUBLIC repo, so it runs after step 1 |
| 6 | Ping search engines | session | After the deploy, not before |
| 7 | The what-changed page | session | Draft below; ships with step 5 |
| 8 | The anchor post | operator approves, session posts | Draft below |
| 9 | X and LinkedIn | operator approves, session posts | Drafts below |
| 10 | Email the existing list | operator approves, session sends | **There is no list: the Resend audience has 0 contacts and the archive has 3 addresses. Recommend dropping this step and adding email capture to the site instead** |
| 11 | r/macapps and r/LocalLLaMA | operator approves, session posts | Drafts below, each written to that subreddit's rules |
| 12 | Newsletter and roundup submissions | session | Targets below |

**Nothing in 8 to 11 goes out on a schedule.** Each is one approval, one post.

## What every draft may and may not say

Verified today, and safe to quote:

- Native Mac app, MIT, notarized, Apple silicon, macOS 14 or later, 23 MB (the README's figure, same bytes).
- Works with no key: a local model through Ollama, or your own Anthropic or
  OpenRouter key. No Grux account, no subscription, no telemetry.
- Audio never leaves the Mac. Transcription is local.
- Listening is off until you turn it on, and it says so on the first screen.
- Decisions run on this Mac for free. A Decisions key (Jev) makes them faster
  and surer, and a busy day of 265 decisions measured $0.02.
- Idle and muted: 1.0% of a core, down from 33.3%.
- Mail counts what needs a reply, not what is unread: on one real inbox, 48 of
  245.
- 3,082 tests.

Not to be said, because it is not true:

- "Runs entirely offline." Chat needs a model, local or hosted.
- "Private by default" as a blanket claim. Say the specific true things: audio
  stays local, the decision ledger stays local, there is no telemetry.
- Anything about Laya shipping. It was measured on 2026-09-22 and is not in
  this build.
- Any user, download or revenue number. There are none worth quoting.
- "Ten years" or any figure under it. The house rule is "10+ years", "over a
  decade", or "since 2015", never less.

## 7. The what-changed page (gruxai.com)

**Title:** What changed in Grux 3.0

Grux 3.0 is the release where Grux decides quickly, says what it is doing, and
fits in one sidebar.

**One question to start.** The first thing a new install asks is what you want
to do with Grux. What you type picks the surfaces you get, and setup asks only
for what those need, one thing at a time, with what is already working shown as
done.

**One page for how it behaves.** Tuning holds everything Grux does for you: how
sure it has to be before acting, how it talks back, when it may interrupt, what
it does on its own, what it spends, what it remembers, and what always stops to
ask. Right click the orb, or open it from Today, the command palette, the menu
bar, or the top of Settings.

**Tell Grux what you want.** Nothing about Grux changes without your yes.
Say what you want changed, from an accent colour to a whole new surface, and
Grux writes a work order: it asks you at most three questions, each with a
recommendation, then analyses, designs, builds, tests, installs and verifies,
stopping three times for you to say yes.

**One listening control.** Always on, after "Hey Grux", or off. It is off until
you turn it on, macOS asks for the microphone only then, and audio never leaves
your Mac.

**One decision engine.** Every small judgment (was that meant for me, does this
email need a reply, is this command dangerous) runs through one engine with a
confidence you can see and a threshold you can set. On this Mac it is free. With
a Decisions key it is faster and surer: a busy day of 265 decisions measured
$0.02. Either way, nothing that sends, deletes or spends runs without you.

**The sidebar is twelve surfaces, two doors and Settings.** A new install shows
fourteen rows above Settings.

(Counted on a clean install 2026-09-22: Today, Chat, Mail, Calendar, Notes,
Documents, Contacts, Tasks, Meetings, Schedules, Integrations and Studio, then
the DEVELOPER and LABS doors, then Settings. The sidebar is the same set
whatever you answer; the answer decides what is set up first, not what appears.
"above Settings" added because the bare number read as fourteen including it.)

**And it is quiet.** Muted and idle, Grux uses 1.0% of a core, down from 33.3%.

[Download Grux 3.0](https://github.com/dotcomjack/grux/releases/latest) ·
`brew install --cask dotcomjack/tap/grux` · `npx @dotcomjack/grux`

## 8. The anchor post

Grux 3.0 is out. It is a native Mac assistant, MIT, and it runs on your own
model: a local one with no key, or your own API key.

The thing I care about most in this release: nothing about Grux changes
without your yes. Tell Grux what you want, in your words, and it writes a
work order your agent picks up. It asks you at most three questions, each with
a recommendation, then designs, builds, tests and installs, stopping three
times for you to approve. The only limit is your agent.

The rest of 3.0:

- First run is one question. What you type decides what you get.
- One page, Tuning, for how it behaves: how sure it must be before acting, when
  it may interrupt, what it spends, what it remembers.
- Listening is off until you turn it on, and audio never leaves the Mac.
- Every judgment runs through one decision engine with a confidence you can
  see. Free on your Mac; optional key makes it faster.
- Muted and idle it uses 1% of a core.

No account, no subscription, no telemetry.

github.com/dotcomjack/grux

## 9. X

Grux 3.0: a native Mac assistant that runs on your own model, local or your own
key. MIT.

Nothing about it changes without your yes: say what you want, Grux writes
the work order, your agent builds it, you approve three times.

No account. No telemetry. Audio stays on your Mac.

github.com/dotcomjack/grux

## 9b. LinkedIn

Grux 3.0 is out, and it is open source under MIT.

Grux is a Mac assistant that runs on a model you choose: a local one with no
key at all, or your own API key. There is no Grux account, no subscription and
no telemetry, and audio never leaves the machine.

What is new in 3.0:

- First run is one question, and your answer decides which surfaces you get and
  what setup asks for.
- Tuning: one page for how Grux behaves, from how sure it must be before acting
  to what it may spend.
- Tell Grux what you want: Grux writes a work order and your own coding agent
  carries it out, stopping three times for your approval.
- One decision engine behind every judgment, with a confidence you can see.

Over a decade of building things for myself taught me that the tools worth
keeping are the ones you can change. That is what this release is about.

github.com/dotcomjack/grux

## 10. Email to the list

**Subject:** Grux 3.0: one question, one page, and your own agent

Grux 3.0 is out.

If you have been running 2.x, the short version: first run is now one question
and the flow is built from your answer, everything about how Grux behaves is on
one page called Tuning, and you can now hand a change to your own coding agent
by telling Grux what you want.

Three things worth opening it for:

1. **Tell Grux what you want.** Grux writes the work order, your agent builds
   it, you approve the plan, the design and the result.
2. **Tuning.** How sure Grux has to be before it acts, when it may interrupt,
   what it may spend, what it remembers. One page, from the orb.
3. **It is quieter.** Muted and idle, 1% of a core, down from 33%.

It is still MIT, still runs on your own model (local with no key, or your own
API key), and there is still no account, no subscription and no telemetry.

Download: github.com/dotcomjack/grux/releases/latest
Or: brew install --cask dotcomjack/tap/grux

Jack

**ANSWERED 2026-09-22, and the answer is that there is no list.** Resend holds
exactly one audience, `General`, created 2026-01-11, with **zero contacts**. The
only Grux addresses that ever existed are **three** in the archived Supabase
waitlist (`_supabase-bench-backup-2026-06-23/gruxai-waitlist.dump`, table
`public.waitlist`, commented "gruxai.com landing page email signups"), one
gmail, one protonmail.ch and one sgsusi.com, captured before that project was
deleted. They are not in any mailable system and have not been contacted since
June.

**So step 10 has no recipients, and the bigger problem is forward-looking:
gruxai.com captures no addresses at all.** The live page (200, 41,141 bytes)
contains no form, no email input and no signup of any kind, only a
`mailto:security@gruxai.com`. Every visitor launch day sends there is
unrecoverable. Putting one capture field on the page, wired to the `General`
audience, is worth more than this email is.

## 11. r/macapps

**Title:** Grux 3.0: an open source Mac assistant that runs on your own model
(MIT, notarized)

I built Grux and this is the 3.0 release.

Grux is a native Mac app that listens, watches what you are working on if you
let it, and does things for you. It runs on a model you choose: a local one
through Ollama with no key at all, or your own Anthropic or OpenRouter key.
There is no Grux account, no subscription and no telemetry, and audio never
leaves the machine.

New in 3.0:

- First run is one question, and your answer picks what you get.
- Tuning: one page for how it behaves.
- Tell Grux what you want: Grux writes a work order and your own coding agent
  carries it out, with three approval stops.
- One decision engine behind every judgment, with a confidence you set.
- Muted and idle it uses 1% of a core, down from 33%.

MIT, notarized, Apple silicon, macOS 14+, 23 MB.
github.com/dotcomjack/grux

Happy to answer anything.

## 11b. r/LocalLLaMA

**Title:** Grux 3.0: a Mac assistant that runs entirely on a local model, and
what I measured trying to make its decision layer local too

I build Grux, an MIT Mac assistant. It runs on Ollama with no API key, and
transcription and audio never leave the machine.

The part this crowd may find useful is the decision layer. Grux makes a lot of
small typed judgments (was that sentence meant for me, does this email need a
reply, is this command dangerous). Those are not chat: they want a calibrated
probability back in under half a second, so a generative model is the wrong
tool.

Today they run one of two ways: a phrase matcher on device for free, or a typed
decision model behind an optional key. I measured whether Laya
(Apache 2.0, non-autoregressive typed decisions, runs locally) could replace the
paid one. On my own fixtures, against Grux's real question wording:

- Voice gate, 36 utterances: the paid model got 32 right and read 3 of 20
  room-talk lines as commands. Laya got 24 right and read 10 of 20 as commands.
- First-run feature selection, 54 answers: the paid model held 0.51 recall at
  0.69 precision at the shipped threshold. Laya's recall was 0 at that
  threshold: it says no to nearly everything.
- Laya is about 9 times faster (52 ms against 470 ms) and free.

Laya's own README predicts the second result: base checkpoints score near
chance on typed decisions zero-shot. Fine-tuning on our own gates is the next
step, and the bar is beating the paid model's false-fire rate, because an
always-listening app that reads the television as a command is worse than one
that asks.

Measuring that also found a bug in my own keyword fallback, which is the real
lesson: a command phrase found anywhere in a sentence counted as a command, so
"we should mute the group chat" muted the microphone. Fixed in 3.0.

github.com/dotcomjack/grux

## 12. Newsletter and roundup submissions

One line each, sent after the release is live:

- **Hacker News**, Show HN: "Show HN: Grux 3.0, an MIT Mac assistant that runs
  on your own local model". Post it myself, once, and answer comments.
- **Product Hunt**: only if the operator wants the day it costs. Not otherwise.
- **iOS Dev Weekly / Indie Mac newsletters**: the what-changed page link plus
  two lines.
- **Awesome-mac / awesome-macos-apps lists**: a pull request adding the entry,
  which is a contribution rather than a submission.
- **r/swift and r/SwiftUI**: only with something technical to say, for example
  the decision engine or the capability registry. A release announcement alone
  is off topic there.

**Rules that apply to all of them:** say I built it, every time. No cross
posting the same text within an hour. No claims from the "not to be said" list
above.
