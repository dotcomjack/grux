# The stranger run: what a new Mac actually goes through

> **STATUS: MEASURED 2026-09-22** on a second Mac (Mac16,10, macOS 26.3.1,
> 1920x1080), wiped to a first-run state: no app, no Application Support, no
> `~/.grux`, no preferences, no saved state, TCC reset, and zero Grux items in
> the login keychain. Build under test is the notarized 3.0.0 release built the
> same day (`Grux-release.zip`, 24,259,662 bytes, stapled, `spctl` accepted,
> `source=Notarized Developer ID`).

## All five are fixed, and walking it again found a sixth

Fixed the same day and verified on the same wiped Mac. The captures are in
`evidence/2026-09-22-stranger-run-fixed/`.

| # | What it was | What it is now | Held by |
|---|---|---|---|
| 1 | Continue below the fold, only a wheel event revealed it | Every screen publishes its action to a bar pinned under the scroll area, so content height cannot move it | `test_everyScreenOnTheStrangerPathPinsItsPrimaryAction`, `test_theFooterBarIsNotInsideTheScrollView` |
| 2 | Empty name field | Prefilled from the account's full name, and only when it looks like a name | `test_theSuggestedNameIsTheFirstWordOfARealName`, `test_aShortAccountNameIsNotOfferedAsAName` |
| 3 | Asked for a key without looking | Probes the loopback host on appear; with a model already running it leads with it and the pinned button becomes "Use the model on this Mac" | `test_theModelGateProbesBeforeItAsks` |
| 4 | The setup step silently did not happen | Two separate bugs, both fixed; the step now appears | `test_theSkipDecisionDoesNotGoThroughTheStateItJustWrote`, `test_theStepOnlyEndsWhenItHasRunOutOfScreens` |
| 5 | An ambiguous number in the launch copy | Reworded to "fourteen rows above Settings" | n/a, copy |
| 6 | **Return stopped working on the two screens with a field** | `onSubmit` on both, running the same action as the bar | `test_theTwoScreensWithAFieldStillSubmitOnReturn` |

**Number 6 is a regression the fix for number 1 introduced**, and it is the
reason this was walked twice rather than once: moving the button out of the
content moved it out of reach of a focused text field, which swallows Return.
Typing a name and pressing Return did nothing at all. Nothing in the suite
noticed, because every test of that screen asserted on the model, not on the
key path.

**Number 4 was two bugs wearing one symptom, and the first fix did not cure
it.** The skip decision was taken twice, once in the parent's `onAppear`
against a `@State` plan that had not propagated, and once in a child
`Color.clear.onAppear` whose only guard was that the plan existed by then. The
second one is what actually fired: SwiftUI builds the body, chooses the "no
screen here" branch because there is no plan yet, then runs the parent's
`onAppear` (which builds the plan) and the child's (which sees a plan and
concludes the step is over). Nine screens were waiting behind it. The index is
what tells "not ready" from "finished", and it is now what the guard reads.

The measurement that made it undeniable: eleven features were stored, and with
eleven rows an empty screen list is impossible on the merits, because a feature
is either ready and lands in `plan.ready` or it is not and lands in
`plan.required`. Either way there is a screen. `test_anyChosenFeatureProducesAtLeastOneScreen`
holds that property now.

## The wipe was wrong the first three times, and that is the first finding

**Over SSH the default keychain is `/Library/Keychains/System.keychain`, not the
user's login keychain.** So every keychain check made over SSH on that machine
was reading a store the app never writes to. Three separate "there is no key on
this Mac" readings were all false: `anthropicApiKey` was sitting in
`~/Library/Keychains/login.keychain-db` the whole time, which is exactly why the
app kept resolving to `welcomeBack` instead of the first-run question.

Query the login keychain by explicit path, never by default:

```
security find-generic-password -s com.gruxai.grux ~/Library/Keychains/login.keychain-db
```

`security show-keychain-info` on that path returns "User interaction is not
allowed" from an SSH session, which is useful: a delete fails cleanly instead of
hanging on a dialog nobody can click.

**`welcomeBack` itself is correct and well built.** It says plainly that Grux
found a saved model key and none of the rest, that a reinstall and an
interrupted first run look identical from inside, and that it would rather ask
than assume. Both exits work: "Run setup" calls `reset()`, which applies
`State.initial`, so a reinstaller lands on the new one-question flow rather than
the old list. Nothing to fix.

## Install and launch, before any of our UI

| What | Measured |
|---|---|
| Gatekeeper before first launch | `accepted`, `source=Notarized Developer ID` |
| Notarization ticket | stapled, `stapler validate` passes, so no network needed |
| Quarantine survives the download | yes, `0081;...;Safari;...` through zip, ditto and install |
| Gatekeeper dialog on first launch | **none observed** |
| macOS permission prompts during the whole first run | **zero** |

**A shell copy into `/Applications` runs translocated.** Installed with `ditto`
(preserving quarantine, as a download does), the app ran from
`/private/var/folders/.../AppTranslocation/<uuid>/d/Grux.app`, not from
`/Applications`. Finder's drag clears translocation; `cp`, `ditto` and `mv` do
not. This matters for anyone scripting an install, and for the Homebrew cask,
which should land the app unquarantined.

**The translocation mount can wedge the install path.** A stale nullfs mount
whose SOURCE was `/Applications/Grux.app` made `open` fail with
`NSPOSIXErrorDomain Code=16 "Resource busy"`, a message that tells the user
nothing. Force-unmounting it then left that exact path unable to launch anything
at all: both the 3.0.0 build and the previous candidate wedged at `_dyld_start`
with 32 KB resident and zero libraries loaded, while the same two bundles ran
normally from `/tmp` and from `/Applications/GruxProbe.app`. A third-party
control app (Maccy) launched from `/Applications` throughout, so this was one
poisoned vnode rather than a machine-wide or product fault.

**That last part is my own damage, not a product defect, and it needs a reboot
to clear.** That Mac currently cannot run an app at `/Applications/Grux.app`.
Everything below was therefore walked from a working copy; the install path does
not affect the onboarding flow.

## The first run, screen by screen

Answer used: "run my inbox and help me ship code". Keyless (no Anthropic key).

| # | Stage | What happened |
|---|---|---|
| 1 | `prompt` | "What do you want to do with Grux?" one field, mic, arrow, and an honest paragraph that listening is off until you turn it on |
| 2 | `yourGrux` | 8 features chosen in **1.3 seconds**: Chat, Task Stack, Agents, Mailbox, Calendar, Notes, Commands, Terminal Focus |
| 3 | `identity` | "What should Grux call you?" empty field, Skip and Continue |
| 4 | `modelKey` | "Connect a model": paste a key, use a local model, or use an OpenRouter key |
| 5 | `howItWorks` | TIER 0/1/2, what stays local, what it costs, what is off until you say so |
| 6 | `setup` | **skipped entirely**, see below |
| 7 | `update` | "What Grux found on this Mac" |
| 8 | `done` | Today, 12 surfaces, listening off, no name in the greeting |

About **6 interactions** end to end. The feature pick is good: "run my inbox"
produced Mailbox and "help me ship code" produced Agents and Terminal Focus.

## Friction worth fixing

**1. The Continue button starts below the fold.** At the default window
(1040x732) with 8 features, `yourGrux` is clipped mid-sentence and Continue is
off-screen. The screen does scroll, but only with a real wheel or trackpad
event: Page Down, End and the arrow keys all leave the capture byte-identical,
and there is no scrollbar, fade or other hint that anything is below. At 902px
tall the button is visible. A shorter answer picks fewer features and fits, so
whether a person hits this depends on what they typed. Cheapest fix is a pinned
footer for the primary action, so it never depends on content height.

**2. Grux asks for a name macOS already told it.** The identity field ships
empty. `NSFullUserName()` appears nowhere in the codebase. Prefilling the
account's first name turns a typing step into a confirming step, and it is still
skippable and still editable.

**3. The model screen never looks before it asks.** `ModelKeyStep` has no
`.onAppear` and no `.task`, so it never probes for a local model. Someone who
already runs Ollama is shown a screen headed "Paste an Anthropic API key" with
the local option as secondary text. A probe against localhost costs nothing and
would let the screen lead with what is already true on that Mac.

**4. The setup step can silently not happen.** `SetupStep` auto-finishes when
its plan yields no screens. On this walk four of the eight chosen features
reported "Needs 1 thing" or "Needs 2 things" on the previous screen, and then
nothing was ever asked, because inbox, Graph, social and agent-CLI requirements
are deliberately deferred to point of use. The design is defensible and the
deferral is right. The mismatch is that the screen before it counts those needs
out loud, so the person is told about work that then never appears. Either do
not count deferred items on `yourGrux`, or have `setup` say in one line that the
rest is asked the first time you open each surface.

**5. One launch-copy number is ambiguous, not wrong.** The what-changed draft
says "twelve surfaces, two doors and Settings" and then "A new install shows
fourteen rows". Counted on this install, the composition is exactly right:
twelve surfaces, then the DEVELOPER and LABS doors, then Settings. Fourteen is
correct only if Settings is not one of the rows, which the sentence before it
implies but does not say. Changed to "fourteen rows above Settings". The
sidebar is the same set whatever you answer, so the number itself is safe to
quote.

## What I checked and found sound

Recording these so nobody re-opens them.

- **The launch-hang fix holds.** On a genuinely pristine Mac the app reached
  `windows: 1` and wrote a full state directory. Before the fix, the same
  machine showed no window at all.
- **`~/Documents/Grux` was not created by this run.** It exists on that Mac,
  born 2026-08-30 and last modified 11:48 today, which is before the fixed build
  ran. The three sibling getters that used to create directories on read are
  still pure.
- **An empty answer degrades well.** Submitting nothing gives 5 basics under
  honest copy, "Grux starts with the basics", rather than an error.
- **The model gate refuses an empty key.** Continue is disabled and dimmed, and
  Return does nothing, five presses running.
- **The keyless path works in one click** where Ollama is present: it found the
  server, set the route and advanced.
- **No accessibility defect was found.** An earlier reading that every control
  was unlabelled was my AppleScript, not the app: the same script reports zero
  labelled elements for Finder and System Settings too.
- **The empty-name greeting reads as a finished sentence**, as the code comment
  promised: "Good afternoon".
- **BETA is said once, at the Labs door, and nowhere else.** No feature row
  carried a pill, which is what `LaunchRootView` promises in two comments and
  what the Phase F gate asks for.
- **The sidebar is not answer-derived.** It shows the same twelve surfaces
  whatever you type; the answer decides what is set up first. Worth knowing
  before writing copy about it.

## Not measured, and why

- **The no-Ollama keyless path.** That Mac has Ollama at
  `/opt/homebrew/bin/ollama` serving on 11434, so the "nothing answered where
  Grux looks for Ollama" branch could not be exercised live. Its copy is good on
  reading and it names ollama.com, but it has not been seen on screen.
- **The Gatekeeper first-launch dialog.** Never appeared on this machine, which
  has run Grux builds before. A Mac that has never seen this developer may still
  show it.
- **VoiceOver.** Not run. The AX finding above was withdrawn, not confirmed
  either way.
- **The third Phase F gate criterion.** "Open my calendar" spoken aloud with no
  wake word, under 1 second, was never said out loud to that Mac: there is no
  way to drive real microphone input over SSH. The decision-latency table from
  P-R-10 measures the gate given a transcript, which is not the same claim. The
  G-F row now says so rather than implying the whole gate was walked.

## The captures

`docs/superpowers/evidence/2026-09-22-stranger-run/` (excluded from publishing
by `oss-exclude.txt`, so these never ship). Window captures by window id, so
nothing else on that screen could pollute them.

| File | Screen |
|---|---|
| `01-first-screen.png` | "What do you want to do with Grux?" at stage `prompt` |
| `02-your-grux.png` | 8 features, clipped at the default window height |
| `03-identity.png` | the empty name field |
| `05-model-gate.png` | "Connect a model", Continue disabled with no key |
| `06-local-model-attempt.png` | "How Grux works", reached by one click on the local-model path |
| `09-eight-at-default.png` | 8 features at 1040x732, before scrolling |
| `11-after-real-scroll.png` | the same screen after a real wheel event, Continue now visible |
| `13-setup.png` | Today, first run complete |
