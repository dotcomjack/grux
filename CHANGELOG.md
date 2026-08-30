# Changelog

All notable changes to Grux are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.1] - 2026-08-29

The release where a stranger's first launch is quiet.

1.2.0 shipped a command line. Installing it on a Mac that had never run Grux
showed what launching it actually does to somebody, and the answer was too much.
Forty nine services start on a first launch. Twenty five of them did something
nobody had asked for, and auditing the launch path afterwards found eight more
the first pass had missed.

Nothing in this release is a feature. Every entry is Grux doing less, or doing
the same thing behind a switch you can find and that survives a restart.

### Fixed

- **The permission screens notice a grant instead of waiting to be asked.** The
  Automation step could never be satisfied: it read a stored answer that nothing
  in Grux ever wrote, so granting Automation in System Settings, toggling it off
  and on, and coming back all left the card exactly where it was. Grux now asks
  macOS what it has already decided, for the applications Grux actually drives,
  and every permission screen re-checks on a timer rather than only when you
  return to the app. A grant lands while you are still in System Settings.

- **An interrupted setup can be picked up again.** Quitting partway through and
  relaunching could land you in the app with setup silently marked finished.
  Grux decided you were already set up by checking whether a model key existed,
  and setup writes that key on its third screen, so anybody who got that far
  passed the test whether they finished or not. Deleting an app leaves Keychain
  items and removes its data, so a reinstall was the ordinary way to hit this.
  Grux now asks instead of guessing, and offers to run setup or to skip it.
  It also no longer records that you reviewed a captured frame you were never
  shown.
- **Settings tabs share one layout.** Two labels rendered outside the pane and
  over the sidebar, body text clipped on the right edge, the notification grid
  sat out of alignment, and panes opened halfway scrolled. All four came from
  the same cause: forms without a style demand more width than the pane has, and
  the overflow bled off both edges. Every tab now uses the same container, and
  Data & Security no longer sits at a different inset from the rest.
- **"Restart onboarding" is where you would look for it.** The control existed
  as "Run it again" in a section above the reset buttons, and was missed. It
  keeps everything already saved, and setup offers to keep your model key rather
  than asking you to paste it again.

- **Grux no longer talks out loud on a Mac you have not set up.** A spoken
  briefing fired at 07:00 and 21:00 with nothing configured, in the built-in
  macOS voice, and turning off "Speak Grux's replies aloud" did not stop it. It
  now reads that setting like every other scheduled speaker, and it does not
  start at all until Jax HQ has what it needs.
- **No permission dialog appears before Grux has explained itself.** A first
  launch could raise "Grux would like to record this computer's screen and
  audio", "Grux OS wants access to control Notes", and "Grux wants access to
  control Music", none of them asked for and none preceded by a word of
  explanation. The Screen Recording one is a ONE SHOT, so answering Deny to a
  dialog you could not place permanently spent the prompt that onboarding and
  the Terminal Focus card both depend on.
- **Terminal Focus no longer takes over four terminal windows on a machine that
  has never been told what it is.** It waits for the Terminal Sessions step,
  including when summoned by its keyboard shortcut, and it no longer opens
  Terminal.app in order to ask it a question.
- **Your workday log stays on your Mac.** Grux wrote a morning report of your
  project names, git branches and commit messages into iCloud Drive, in a folder
  it created, which Apple then synced to every device on your Apple ID. The
  copy is now off by default and Settings says where the file goes.
- **Screen capture waits for the frame you were promised.** The contract says
  "Grux will show you one frame, and the exact text it would send, before
  anything leaves your Mac". Capture could begin without that having happened,
  on a Screen Recording permission granted for meeting transcription. Worse, the
  step recorded itself as done for anyone who chose the shortest setup path,
  which never shows a frame at all.
- **Nothing writes to your Documents folder for a feature that is off.** Two
  empty folders appeared during the first launch because asking WHERE backups
  would go was what created them.
- **Ordinary chat is no longer mistaken for a command.** Typing "translate this
  email into Spanish" started a week-long workflow, spoke a sentence about it
  out loud, and re-armed itself on every launch for the next seven days.
- **A commitment you mentioned once appears once.** Relaunching Grux on the same
  day added another reminder and another real Calendar event for the same
  sentence, every time.
- **The floating orb waits for you to finish setting up** instead of appearing
  over the setup flow.
- **Every background job that was running unasked now has an off switch, and the
  off survives a restart.** Domain renewal sweeps, Apple Music volume ducking,
  the meeting-app detector, the two nightly passes over your ambient transcript,
  the self-upgrade loop, the social digests, the workday log and the machine
  interfaces. Several had no switch of any kind and could only be stopped by
  quitting Grux.
- **The Watching / Paused control in the menu bar is remembered.** Pausing it
  and reopening Grux used to start it watching again with nothing saying so.
- **Grux does not adopt a credential you did not give it.** A registrar key left
  in your home folder by another tool was enough to make Grux write it into your
  login Keychain and start calling that registrar on your behalf.

### Changed

- **Media Studio generates through Replicate** rather than fal.ai, using a token
  you supply. Product-in-scene renders are unchanged. If you had a fal.ai key
  saved, it is left alone and no longer used.
- **`grux config` reaches sixteen more settings.** They were implemented all
  along under different internal names, so the command reported them as settings
  Grux does not read. Credentials are still not settable there and never will be.
- **The setup contract now says which of its keys are actually implemented**, and
  records in plain words that Grux has no model spend ceiling.

## [1.2.0] - 2026-08-29

Grux gets a command line. 45 of the 48 commands in `docs/cli-grammar.md` ship,
up from none, and the whole surface answers to one shape: six beats printed as a
rail, four exit codes, and a handoff you can paste into your own coding agent.

**The CLI is beta.** It is complete enough to drive Grux without opening a
window, and new enough that it has not been used in anger by anyone but its
author. Three commands stay unbuilt on purpose, with reasons rather than
apologies: `grux task` has no task store to write to, `grux search` would return
empty on a machine with nothing indexed, and `grux diff` needs `grux setup` to
start recording a baseline first.

### Added

- **45 commands, one grammar.** Reads answer with Grux closed, because they come
  from a document the app writes rather than from the app. Writes go over a Unix
  domain socket at 0600, so Grux still opens no network port. `grux intro` is the
  entry point and answers in full on a Mac that has never run Grux.

- **26 tools on the control plane**, up from 13. Every one is a thing an agent on
  your Mac can make Grux do, so the list grows by a decision written down and a
  test fails if a tool is advertised without a handler behind it.

- **`grux serve`**, an MCP bridge on stdio for an agent that cannot open a Unix
  socket. It carries messages closed, so it needs no teaching when a tool is
  added.

### Fixed

- **The support bundle carried what you said out loud.** It promised it held
  nothing from your notes, chat, meetings or ambient captures, and then copied
  `wake.log`, which is where Grux writes what it hears. 398 lines of verbatim
  speech on the machine this was found on. It now carries an allowlist of two
  logs, names `wake.log` as deliberately absent, and writes 0700 and 0600 rather
  than making a second world readable copy of an audit trail.

- **Confirmations were invisible when output was redirected.** Eleven of them
  printed the question to stdout, so `grux import setup.json | tee log` showed a
  cursor and nothing else while the question went into the file. Anything other
  than the exact token quietly takes the "left everything alone" path and exits
  0. Every question now goes to the terminal the person is actually at.

- **A first run on a clean Mac could never reach the CLI.** The launch write sat
  behind a Keychain migration that raises a macOS unlock dialog, so on a Mac
  whose login keychain password had diverged the setup document was never
  written and every command answered "open Grux once" to somebody who had.

- **`grux add project` wrote two things and then refused.** A name conflict was
  checked after the registry entry and the shell allowlist had already been
  written, so a refusal left the folder inside the shell sandbox while telling
  you nothing had changed.

- **`grux shell` counterfeited reserved exit codes**, passing a wrapped
  command's 2 or 3 straight through, which are this surface's own codes for
  "waiting on you" and "run grux doctor".

- **"Is Grux running" was a file test.** Quitting Grux leaves its socket file
  behind, so fourteen screens including `doctor`, `status` and `setup` reported
  the app up when it was not.

- Counts that did not reconcile with the rows above them, a second run of a
  removal failing where the first succeeded, a mode change that could skip its
  own confirmation, and a machine surface that emitted prose where an agent was
  promised JSON.

### Notes

- Not notarized. `spctl` refuses an unnotarized Developer ID build, so a copy
  that arrives through a browser is still refused by Gatekeeper.
- One acceptance criterion stays open: a stranger reaching a working Grux on a
  clean profile is proven for the terminal, and not for the download.

## [1.1.0] - 2026-08-28

Two audits, run back to back, against one question: does a stranger who
downloads Grux get a working app, and does every screen tell them the truth?
Wave 1 read the published tree. Wave A took the first ten minutes of a cold
install. 124 files, 21 new test suites, and 27 of the fixes below were found by
review agents that had written none of the code and were told to refute, not
confirm.

The recurring defect had one shape, and it is worth naming because it explains
most of this list: the app knew a thing and the screen said something else.

### Added

- **A local model is now a real first run.** The README promised a model you pay
  for or a local one with no key at all. The first onboarding gate could not be
  left without a key, so that promise was false on the first screen a stranger
  saw. The local path now probes, routes, and never writes a Keychain entry.

- **A ceiling on how much the shell may be trusted.** The model chose its own
  trust level, per call, with nothing above it. That ceiling is now yours to
  set, and it binds at session start so a running session keeps its mode.

- **A model pull is refused before it starts if the disk cannot hold it.**
  Read purgeable-aware, one copy plus a 5 GB reserve, so it never refuses a pull
  that would have completed.

- **A corrupt saved file is quarantined instead of silently replaced.** Grux
  could not tell a missing file from a damaged one, so a damaged one became an
  empty default and was then overwritten across 81 load and 104 save sites.
  Grux now copies it aside, names the copy on screen, and refuses writes to that
  path until you say go ahead.

### Changed

- **Every panel that talks to a companion service explains itself in one voice.**
  Eight of them used to greet a fresh install with "no base URL reachable" or a
  raw error naming a loopback port. Each now says what the service does, why
  this install cannot reach it, and what to do. An unconfigured service is
  answered with zero network calls.

- **Cost is decided by where the request went, not by the model id.** Most
  OpenRouter traffic was billed at zero.

- **What Grux thinks your machine can run now follows the live machine.** The
  local model budget moves with thermal state, low power mode and memory
  pressure, none of which was read before. Session concurrency comes from cores
  and memory rather than the literals 2 and 8.

- **The README said 79 tools. There are 116**, and have been since the commit
  that wrote the number. A test now pins the count so the sentence and the code
  cannot drift apart in silence again.

### Fixed

- **Pinning a quality tier could route a Claude model id at a local server.**
  It answered 404. This hit exactly the install the provider sweep set out to
  fix, and it was invisible to the suite: dictation swallowed the 404 on every
  utterance, and the guarding test only ever asserted that a file contained a
  string. Both facts have real tests now, and neutering the backstop fails them.

- **Hosted providers validated green in Settings and then routed to Anthropic
  forever.** Model discovery never sent the endpoint key, so any provider that
  authenticates its model list failed the list quietly and fell back. A rejected
  key now says it was rejected instead of claiming no server answered.

- **Compaction and titling only worked if you held an Anthropic key**, so the
  local user, whose context window is the smallest of anybody's, was the only
  user who never got compaction.

- **A vision failure blamed your model.** Any 401, 403, 429 or 5xx read as "your
  model cannot see images". Only a genuine 400 or 422 keeps that message now;
  everything else keeps the real status and the provider's own sentence.

- **Emergency Stop could be refused.** Routing every Meta Ads command through
  one gate handed the in-flight guard a veto over the kill switch: a force scale
  holds a request open for up to 12 seconds per host, and STOP ALL pressed in
  that window was answered "wait for it to finish, then try again". On a spend
  control that is the wrong answer. The halt now takes its own hold, and a halt
  that fails is no longer erased by an unrelated command that succeeds.

- **Six Meta Ads commands reported failure only to themselves.** Approve, veto,
  pause, scale, kill and spawn were called straight from their buttons, each
  holding a private error string, so a failed override was invisible to the rest
  of the app.

- **"All clear. The engine is running clean." over a snapshot Grux could not
  refresh.** Found by launching the app rather than reading it: the deck showed
  an outage banner naming the unset key and, directly beneath it, a green check
  claiming health. An empty queue is not a health verdict when the pull failed,
  and it now says the weaker, true thing.

- **A base URL that could not be parsed crashed the app.** A text field.

- **Three empty screens told you nothing or the wrong thing.** Settings blanked
  the whole pane on an unrecognised search, Notes told a reader with zero notes
  to "select a note", and the Cookbook cut its one actionable sentence off
  mid-instruction at the window floor. All twelve first-run empty states are now
  pinned by tests, with controls proving those tests can fail.

- **A filesystem denylist rule that could never match.** The entry named
  "firefox" did not match the real directory name, so as written that rule was
  dead. The list now matches what SECURITY.md documents, case insensitively.

- **A discrete GPU would have been budgeted as the model ceiling.** An 8 GB card
  in a 64 GB Mac Pro would have hidden every model above 4B.

### Security

- **A shared companion secret was sent to every host in the failover list,
  loopback included.** The service trusts loopback by peer address and never
  reads the header there, so the token went onto a socket any local process can
  bind whenever the companion is not running. It is now scoped to the hosts that
  actually need it.

- **Shell output re-entered the prompt unredacted.** Standard out and standard
  error now pass through the redactor, and shell reads are written to the audit
  log. The secret rule also could not match a quoted value, so
  `export NAME="value"`, the form that dominates .env files and shell profiles,
  passed through intact.

- **A safety check could take the app down instead of drawing a wrong caption.**
  The guard against an impossible classification was a `precondition`, which
  stays live in release builds. A crash is not a safer wrong answer than a bad
  banner.

- **SECURITY.md described a shell path that did not exist as written.** It
  claimed every byte the model reads passes through one file, then that it
  reaches disk through exactly two tools. Both were false. It now names which
  controls apply to each path, because a count goes stale and a control does not.

## [1.0.4] - 2026-08-24

Muting Grux is a promise that the machine is yours again, and the app was not
keeping it. Every item here came out of one reported bug: MUTED on screen, the
orange microphone dot still lit in the menu bar, and Voice Memos unable to
record. The first fix stopped two of the four microphone owners. Adversarial
review of that fix found seven more ways the device stayed held, and those are
what this release is.

### Fixed

- **Two ways to switch on listening never asked.** Ambient mode can be enabled
  from Settings, from the menu bar row, and from the capture pill in the ambient
  HUD. Only Settings showed the dialog explaining that the feature holds the
  microphone for as long as it runs, because the dialog lived in that one view.
  The test guarding it read that same view, so it reported full coverage of a
  feature with two open doors. The question is now asked inside `enable()`
  itself, which every door goes through.

- **An engine nobody could stop, holding the microphone until you quit.** Muting
  during a meeting starts a summariser that takes seconds. Unmuting inside that
  window built one audio engine; the summariser then finished and built a second
  one straight over it, because stopping the listener never cleared the reason it
  had been paused. The next mute stopped only the second. The first kept its tap
  on the input device for the life of the process.

- **Three listeners checked the mute, then waited, then took the microphone
  anyway.** Ambient capture, dictation and the wake word each read the mute flag
  and then awaited a permission prompt or a model download before touching
  hardware. A first-run model download is tens of seconds. Muting during one was
  simply overtaken.

- **Pressing Start on a muted meeting silently created an empty one.** The
  record was written to disk before microphone authorization, before screen
  capture, and before the mute re-check, so every one of those failures left a
  permanent zero-length meeting with no summary, no audio and no explanation.
  The Meetings tab was also the one caller that discarded the error, so the junk
  row was the only feedback there was. The record is now written once capture is
  actually running, and the failure says why.

- **The microphone status file reported the state from before the change.** It
  is there so a caller can assert instead of sleeping and hoping, which matters
  because this app's owner cannot click an orb to check. It was written the
  instant mute returned, while the meeting it had just asked to stop was still
  stopping, so it reported a live capture after every successful mute. It also
  answered "is ambient turned on" with "is ambient running right now", which are
  different questions that differ precisely while muted, and it truncated the
  file on every write so a reader polling it could catch a half-written one.

- **Stopping dictation that was never running still reached for the
  microphone.** Reading an audio engine's input node is what creates it, so
  muting on an install where dictation had never once run built the node in
  order to stop something that did not exist.

- **A meeting lookup could never report a missing meeting.** `get(id:)` compared
  what it loaded against a fallback carrying the id it was asked for, so an id
  that had never been saved came back as a phantom empty record instead of
  nothing. Found by a test written for a different defect.

### Changed

- Turning ambient mode or the wake word on now asks once, and remembers. Turning
  either off is never gated: nobody needs permission to stop being listened to.
  The two dialogs are separate because the promises differ. Ambient transcribes
  with Whisper on your Mac and the audio does not leave it; the wake word uses
  Apple's speech recognition, which can send short audio to Apple, and says so.
- `~/.grux/mic-status.json` now reports every microphone owner separately, and
  distinguishes the saved preference from what is running.
- New CLI trigger `~/.grux/fire-ambient-enable`, so the consent path can be
  driven and verified without a mouse.

## [1.0.3] - 2026-08-24

Built, notarized and then superseded before it reached anyone: the microphone
work in 1.0.4 landed the same day, and shipping twice in an hour is worse for a
user than shipping once. There is no 1.0.3 download. Everything below is in
1.0.4.

A week of asking what the app does when things go wrong, and finding it mostly
lied. Every item below was a real failure on a real machine, several of them
found by adversarial review of the fix for the item above it.

### Fixed

- **Chat sent requests it already knew would fail.** With no key and no local
  model, routing still resolved to Anthropic with an EMPTY key, so every turn
  went to the network and came back a provider error the user could retry
  forever. The wording blamed the conversation's length. Chat now refuses before
  the request, names which of the two credentials is missing, and says that a
  local model needs neither.

- **563 calls into an exhausted account, and 190 of them read aloud.** When the
  API credit balance hit zero, four autonomous loops kept firing: 253 replies,
  184 ambient extractions, 64 briefings, 62 stuck-detector composes. Each failure
  was then announced through a paid voice API, so a dead balance on one vendor
  spent credit on another to complain about it, eleven times as raw JSON. A
  breaker now latches on that one non-transient signal, stands background work
  down, and never blocks a person pressing a button.

- **Chat told users to switch accounts, which could not help and broke something
  else.** The affordance ran `claude auth logout` on the agent CLI. It cannot
  change the API key chat spends, and it destroyed a working terminal session on
  the way past. Chat now offers only the key field and a local model, and the
  copy explains that a Claude subscription and API credit are billed separately.

- **The local model returned nothing after a minute.** The shipped default,
  qwen3:8b, is a reasoning model: asked to say hi in three words it produced 1351
  characters of thinking, 12 of answer, and took 49 seconds. At ordinary budgets
  it returns EMPTY content. Default is now llama3.2:3b, which answers in 0.1
  seconds, and existing installs are migrated because a default only applies on
  first launch. Six concurrent prompts against one GPU were also turning 0.38
  seconds of work into 102 seconds of queueing; local calls are serialised now.

- **Muted did not mean the microphone was free.** Mute released two of the app's
  four input taps, and the two it missed could take the device straight back
  because they never consulted the mute flag at all. Both halves are fixed, and a
  sweep now fails the build if a fifth microphone owner is added without either.

### Added

- **Listening features say what they cost before they start.** Ambient capture
  and the wake word both ship off and both hold the microphone continuously.
  Turning either on now explains that, including the part people actually notice:
  system audio drops to a call codec while anything listens, so music goes tinny.
  Turning either off is never gated.

- **`fire-mic-mute` and `fire-mic-unmute`**, with a status file. A mute reachable
  only by clicking an orb cannot be verified without a person.

### Changed

- The tagline, and the copy under it. The hero promised three things while the
  app shipped thirty nine features, so it read as a menu bar utility.

## [1.0.2] - 2026-08-23

A licence compliance fix, found by asking a question rather than by anything
failing.

### Fixed

- **Grux shipped eight third-party dependencies and credited none of them.** Six
  are Apache 2.0, whose section 4(d) asks that any NOTICE file be reproduced when
  the software is redistributed, and two of those ship one. The app bundle
  redistributes them and carried no licence text at all, while this project's own
  page told people the licence text was in the bundle. MIT is permissive about
  what you may do with code and not about the notice: retaining it is the whole
  of the obligation, and Grux was not holding up its end of anybody else's.
  `THIRD-PARTY-NOTICES.md` now carries every licence in full, plus the NOTICE
  files verbatim, and ships inside `Grux.app` as well as in the repository.

### Changed

- The notices file is GENERATED from `Package.resolved` rather than maintained by
  hand, because a hand-written credits list is correct on the day it is written
  and silently wrong the first time somebody adds a dependency. A test regenerates
  it and fails if the committed copy has drifted, so a new dependency cannot ship
  uncredited.
- The README credits every dependency by name with a link, and says which licence
  each one carries.

## [1.0.1] - 2026-08-23

The week after the first release, spent using Grux the way a stranger would
instead of the way its author does.

That distinction turned out to matter more than expected. Grux had been one
person's daily driver for months, and a tool you use every day stops showing you
its own first five minutes. Every fix below came from opening the app with no
key, no tasks, no projects and no history, and writing down what actually
happened. Most of them are not crashes. They are the app saying something untrue
and nothing failing loudly enough to notice.

### Fixed

- **A message that had run out of credit was reported as a malformed request.**
  Anthropic returns HTTP 400 when an account's credit balance is empty, and the
  handler answered every 400 with a guess: that the conversation had grown too
  long, and to start a new chat. So the one thing that could not help was the
  only thing suggested, the Retry button could only fail again, and the real
  reason was sitting in the response body the app was discarding. The provider's
  own sentence is now shown, because it is written for a person.
- **The first three things Grux offered a new user could not work.** Chat's empty
  state suggested roasting a task stack that was empty, ranking projects that did
  not exist, and planning a day from a calendar it had no permission to read. The
  most inviting thing on screen was the thing most likely to disappoint.
- **Grux did not know what Grux can do.** The system prompt described the
  assistant's character at length and never once listed its features, so the
  likeliest first question a person types had nothing behind it. It is now
  generated from the same registry the sidebar reads, split into what works right
  now and what is one step away, and it says where a feature lives when it is not
  a tab of its own.
- **Onboarding asked for your name on the second screen and the chat never
  learned it.** The function that puts a name into the prompt existed, and its
  only caller was the cold email composer.
- **The app told you to say a wake phrase it cannot hear.** Two screens described
  the wake word using the assistant's name, which is renameable and defaults to
  something the listener does not match. The phrase belongs to the app's name,
  and the copy is now checked against the real matcher rather than against
  somebody's memory of it.
- **Renaming the assistant only worked where you could not see it.** The setting
  changed how the assistant referred to itself in the model prompt, while 28
  pieces of interface text went on using the default name. Tab names deliberately
  do not rename, and that distinction is now enforced rather than assumed.
- **Projects told a stranger to start a server.** With no project registry
  configured, which is the normal state, the tab reported an internal component
  as unreachable and suggested starting a service on a port. It now explains what
  a project is: any folder holding a `.grux/project.json`.
- **The Task Stack rendered nothing at all** to anybody who had no tasks, because
  its default grouping is by project and a person with no tasks has no projects.
- **The one screen that asks for an API key had a system blue link on it**, the
  only blue in an otherwise violet interface, because SwiftUI's `Link` ignores
  the app's tint.

### Fixed after review

An adversarial review of everything above, before any of it reached a stranger.
Nine defects, and the pattern in them is worth stating: none crashed, none failed
a test, and the worst one could not fail loudly even in principle.

- **Grux could read the wrong window entirely, and had no way to notice.** When
  you were looking at Grux itself, "the app behind it" was whichever application
  happened to sit first in a list that has no defined order, usually the Finder.
  It always returned an app, so a wrong answer looked exactly like a right one,
  and every coordinate and every click that followed was confidently aimed at a
  window nobody was looking at. It now asks the window server what is actually in
  front of what, which also stops a minimised app being mistaken for the one
  behind you. Naming an app explicitly is more careful too: "Mail" now means the
  application called Mail rather than the first one whose name happens to contain
  it.
- **Reading the controls in a window froze the interface while it worked.** The
  scan can touch several thousand elements, each one a blocking request into
  another application, and all of it ran on the thread that draws. On a large
  window, or against an application that had stopped responding, that was a
  multi-second freeze.
- **Asking Grux to press "+" pressed "=" instead.** They are the same physical
  key, and the shift that tells them apart was missing, so every zoom-in did
  nothing at all.
- **The chat offered the wake word while nothing was listening.** Turning on
  ambient mode, or muting the microphone, stops the wake word listener without
  changing the setting, so Grux went on telling people to say a phrase that
  nothing could hear.
- **The setup prompt told your coding agent that five ordinary errands were
  decisions it must not make for you.** Fetching a speech model is not consent.
  Only the four questions that are genuinely yours carry that framing now, and
  the rest are named as what they are: things to do inside the app.
- **Turning on screen control never offered the permission it needs.** The switch
  wrote a setting and left you to find System Settings on your own, even though
  the moment you turn it on is exactly when macOS is willing to ask.
- **A message about a switch being off named an internal variable** in a sentence
  written to be read aloud to you.

### Added

- **A setup prompt you can hand to your own coding agent.** Settings will write a
  paragraph describing exactly what this Mac still needs and copy it to the
  clipboard. It never asks that agent for a credential or a permission, because
  it cannot get either, and it will not let it answer the consent questions on
  your behalf: whether Grux may read your own writing, and whether you will tell
  people when a call is being recorded. Those are yours.
- **Grux now tells the model what it can do**, generated from the feature
  registry, so it cannot describe a Grux that does not exist.
- **A way to ask the running app what it thinks it can see.** Touching
  `~/.grux/fire-screen-check` writes a small JSON file naming the permission
  state, the window stack, and which application screen control would act on. It
  exists because the test suite runs in a different binary with different
  permissions, so it can prove the logic and never the shipped app.

### Changed

- Onboarding names the two voice features that ship switched off, says Grux is
  not listening until you turn one on, and says where they live. A feature that
  is off and unfindable is a deleted feature with dead code behind it.

### A note on the tests

Seven new test suites, and the ones worth mentioning are guards rather than
examples: a feature that ships off must be named at first run or the suite fails,
no interface text may hardcode the assistant's name while that name is
renameable, and the wake phrase in the copy is fed to the real matcher.

Two guards were written and then deleted rather than shipped, because both fired
on correct code. A test that cries wolf gets muted within a month and is worse
than none. The reasoning is kept in the files where the next person will look for
it.

## [1.0.0] - 2026-08-22

First public release. Grux was built in private and this is the point it becomes
something a stranger can clone, build and run.

### Added

- **The macOS app**, 39 features across one window. 25 core surfaces (Chat,
  Mailbox, Calendar, Contacts, Notes, Documents, Projects, Task Stack, Research,
  Meetings, Local Models, Approvals and the rest) and 14 labs surfaces, each
  labelled BETA in the sidebar.
- **Local model support** through Ollama, so the app can run without sending a
  token to a hosted provider.
- **On-device meeting transcription** via WhisperKit, capturing microphone and
  system audio. Audio does not leave the machine.
- **A gated shell**, with a path allowlist, a command denylist, a rate limit,
  snapshot rollback, and an audit log at
  `~/Library/Application Support/Grux/fs-audit.log`.
- **Grux Phone**, an iOS companion that pairs over the local network as a remote
  microphone and control surface, using Curve25519 key exchange,
  ChaCha20-Poly1305 and HMAC authentication. Opt in; no socket opens until you
  pair one.
- **A frozen setup contract** covering every credential, permission, endpoint and
  setup step the app can ask for, with a checker that fails the build when a
  requirement changes meaning without a dated amendment.
- **Project documentation** for people who did not write the code: a README, this
  changelog, contributing guidelines, a code of conduct, and a full threat model
  in `Grux-Mac/SECURITY.md` including a section on what Grux does not defend
  against.

### Fixed ahead of release

These were found while preparing the repository for other people to read, and are
listed because each was a promise the app made and did not keep.

- **Onboarding asked for five credentials nothing read.** Chat requested OpenAI
  and OpenRouter keys that no code path ever loaded, and Workflows requested an
  App Store Connect key on the same terms. Removed under contract amendment
  CR-31.
- **The local model check read the wrong field**, so following the setup
  instructions to the letter still left the feature reporting itself
  unconfigured.
- **Labs features were not labelled.** Onboarding described a beta tier that the
  interface never showed, so a rough surface was indistinguishable from a
  finished one. They now carry a BETA badge, and a test asserts the badge tracks
  the tier.
- **Grux Phone declared background location it never used.** The manifest asked
  for the `location` background mode and both location usage descriptions while
  nothing in the app requested authorization. That is an App Store rejection
  trigger, and worse, it told every reader the app tracked them when it did not.
  The declaration is gone and a bidirectional test now keeps the manifest and the
  code in agreement in whichever direction the code moves.
- **The release signing path had never been run.** It signed with an Apple
  Development certificate and uploaded that to Apple for notarization, which
  Apple rejects outright. Release builds now use a Developer ID identity, and the
  notarize flag refuses rather than wasting the round trip when it cannot
  succeed.
- **The build embedded the builder's home directory** in the shipped binary
  through a SwiftPM generated fallback path that never executes. It is redacted
  before signing.

### Known limitations

- Apple silicon only, macOS 14 or later.
- Grux is not sandboxed. ScreenCaptureKit, AppleEvents and cross app microphone
  access are unavailable inside the App Sandbox, so the filesystem boundary is
  enforced in Swift rather than by the OS. The reasoning, and the limits of that
  approach, are in `Grux-Mac/SECURITY.md`.
- Nine permission capabilities are declared in the setup contract and surfaced in
  onboarding, but are not yet checked in code immediately before the matching
  system call. The permissions themselves are still enforced by macOS; what is
  missing is Grux explaining the failure rather than the call simply returning
  nothing.
- The phone companion's location frame exists in the wire protocol and is
  deliberately unwired. It is declared as unused rather than removed, because it
  is a half-built feature and not a false claim.

[Unreleased]: https://github.com/dotcomjack/grux/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/dotcomjack/grux/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/dotcomjack/grux/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/dotcomjack/grux/compare/v1.0.4...v1.1.0
[1.0.4]: https://github.com/dotcomjack/grux/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/dotcomjack/grux/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/dotcomjack/grux/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/dotcomjack/grux/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dotcomjack/grux/releases/tag/v1.0.0
