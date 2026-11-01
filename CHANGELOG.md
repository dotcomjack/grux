# Changelog

All notable changes to Grux are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.2.0] - 2026-11-01

Private by default, and fast on the model made for your Mac. A Mac with Ollama gets
Grux Local, the model trained for Grux, in one click at first run and sized to its
memory; on a 16 GB Mac, Grux Local 2B answers in about 2 seconds (35 of 35 replies within 3.4 s, median 2.3 s) and its first reply after a ten-minute pause comes in 0.62 s, down from 6 s. Grux says when a new version is out,
and asks nothing about you to find out. Self-Upgrade runs end to end: it reads its own
source, proposes its next version, builds it, verifies it, and waits for your approval,
and the ways we found for that chain to claim more than it did are closed. And a
second stranger's five minutes: what still confused a person on a fresh Mac, in Now,
Settings, Approvals and the setup cards, is fixed.

### Added

- **Grux Local in one click at first run.** With Ollama running and no model yet, the
  model step offers the Grux Local made for this Mac's memory, "Use Grux Local 4B,
  recommended for this Mac (4.3 GB download)": 2B on an 8 GB Mac, 4B on 16 GB, 9B on
  24 GB and up. One press downloads it from gruxai.com through Ollama and points chat
  at it; nothing downloads before the press, and the screen says so. Without Ollama the
  step links to ollama.com, and Skip for now still works.
- **Grux tells you when a new version is out.** Once a day it asks GitHub's public
  release page, the same page anyone can open, and if a newer Grux AI exists, Now says
  so with Download (or the `brew upgrade --cask grux` command on a Homebrew install)
  and Not now. The request carries nothing about you, Grux never downloads or installs
  anything by itself, and Settings, General, Check for new versions turns it off; Check
  now asks once even when it is off.
- **Self-Upgrade says when it last looked and when it will look next.** Under the
  on/off line the pane reads, for example, "Last pass: today at 3:48 AM. Next: tomorrow
  at 2:00 AM, or sooner when your Mac is idle on power.", so a quiet schedule no longer
  looks like a broken one.
- **Compact tool signatures for a Grux Local v3 model.** When the local model is a
  Grux Local tag ending in `-v3`, each tool it was trained on goes out as a one-line
  signature instead of its full description, so a chat turn carries far fewer tokens.
  Every other model, and every tool a v3 was not trained on, gets the full description
  as before, and a test fails the build if a trained tool's shape changes.

### Changed

- **One local model on a Mac.** Chat on the shipped default model, file naming on Grux
  Local and the background model used to keep two or three models resident; measured
  on a 48 GB Mac, one grew to 13 GB and swap filled. Now a chat model nobody chose
  moves to an installed Grux Local when Grux looks at the Mac's models, file naming
  uses chat's Grux Local instead of loading a second size beside it, and the background
  model follows chat's Grux Local. A model you typed stands, Settings shows what an
  empty background field resolves to, and the rule applies only when Ollama runs on
  this Mac.
- **Grux recommends Grux Local, its own local model.** The Local Models list carries
  Grux Local 2B, 4B and 9B, trained on Grux's own jobs and to ignore instructions hidden
  in pasted text, and leads with the one made for this Mac's memory; it scores above
  every other local model on those jobs. Under memory pressure it steps down a size,
  then falls back to the measured score order. Pull downloads it from gruxai.com with
  no Ollama account.
- **The first local reply after a pause comes sooner.** Grux warms the part of the
  prompt that never changes when it opens and when you come back to it, so the first
  reply after a quiet stretch no longer waits for a full read of it. Measured on a 16 GB
  Mac: Grux Local 2B's first reply after a ten-minute pause went from 6 s to 0.62 s, and
  Grux Local 4B's from 16.7 s to 1.32 s. The warm-up skips
  a model that is not installed and a chat routed to a cloud provider, and only memory
  pressure stops it.
- **A model download that stalls tries again,** up to five times, and resumes where it
  stopped. A server answer that says the request itself is wrong ends the download
  instead of retrying it, and Try again revives a server that went away.
- **Self-Upgrade builds one upgrade at a time, and never on a nearly full disk.** A
  second build waits while one is running (a larger upgrade's build used to let the
  next one start beside it), and none starts with under 4 GB free; each other card
  reads "Waiting to build" and says why, in place of a Build it that did nothing.
- **Self-Upgrade builds on Claude Sonnet 5.5.** It was Sonnet 4.6, and its usage line
  now prices Sonnet 5.5 and Opus 5.5 at their own rates.
- **Self-Upgrade grades an upgrade's tests against your Mac's own numbers.** The pane
  says what an upgrade's full test run must meet and where that bar came from, and
  Measure on this Mac sets it from a full run on your unmodified source, so an upgrade
  is no longer refused (or let through) by a default that was never measured on your
  Mac.
- **Turning on self-upgrade no longer schedules a nightly pass you did not choose.** It
  runs when you ask ("Grux, upgrade yourself"), and by itself only on the schedule you
  pick in Self-Upgrade (nightly, Sundays, or when your Mac is idle on power), every one
  off until you turn it on. The pane says which.
- **A model Grux downloads for you is timed on your Mac before it becomes the
  default.** After first run or Settings, Connect a model downloads a model bigger than
  Qwen 3.5 4B, Grux times one dictation repair (3 seconds allowed) and one chat reply
  (8 seconds allowed) on your own Mac. If either is too slow, Grux keeps Qwen 3.5 4B as
  the default and the Local Models pane says which check missed and by how much.
- **Grux recommends the local model that does Grux's jobs best on your Mac, measured,
  not the biggest one that fits.** The Local Models list ranks by a measured score on
  Grux's own jobs (chat, titles, triage, summaries, dictation repair) and by measured
  memory use, so among the stock models an 8 GB Mac gets Qwen 3.5 2B as a Great fit, a
  16 GB Mac Qwen 3.5 4B, a 32 GB Mac Gemma 4 12B and a 64 GB or larger Mac Gemma 4 26B.
- **Grux recommends only local models your Ollama can run.** Most local models now need
  Ollama 0.30 or newer, and Grux used to offer one your Ollama was too old for, so Pull
  failed. Grux now reads your Ollama's version, recommends the best model it runs, and
  lists the rest under "Needs a newer Ollama" with the version each needs and how to
  update.
- **Quitting Grux from Terminal is an ordinary quit.** `killall Grux` (or anything that
  sends it SIGTERM) used to end Grux mid-save, so edits from the last second or two
  could be lost, and with self-upgrade on, two such quits close together read as
  crashes and put the previous build back. Grux now saves and quits the way Quit does.

### Fixed: chat on a local model

- **The first word from a local model comes in 2 to 3 seconds instead of 14 to 20.**
  Every chat turn on a
  local model used to read the whole 5,000 to 6,000 token prompt again, because Grux
  sent its tools in a different order each time. Grux now sends what stays the same in
  the same order and the same bytes, so the model picks up where it left off; measured
  on a 16 GB Mac with Qwen 3.5 4B, the first word came 2.3 to 2.9 seconds after
  sending, down from 14 to 20.
- **Local models that think answer every job again, and faster.** Grux now tells an
  Ollama model with a thinking mode (qwen3, qwen3.5, qwen3-vl) not to think, so chat
  replies, thread titles, notification triage and meeting summaries come back with an
  answer instead of empty. This applies to an Ollama on this Mac or on your local
  network (localhost, a `.local` name, or a 10.x, 172.16 to 31.x or 192.168.x address);
  one reached over Tailscale or a public address is not recognized as Ollama and still
  gets the old request.
- **A question never opens YouTube or Chrome.** A small local model could answer "what
  is two plus two" by opening YouTube. Grux now offers the tools that open a page, an
  app, a video or a Google search in Chrome only when you ask to open, watch, play or
  look something up, or name a web address.
- **Grux no longer freezes while macOS asks whether it may control another app.** The
  first time Grux opens a page in Chrome or plays from Music, macOS asks whether to
  allow it, and Grux used to stop answering until someone did (up to 2 minutes). It now
  keeps working, and if the app has not answered within 20 seconds the reply says so;
  the request goes through once you allow it.
- **When Grux needs your OK, it says so.** A local model could answer "Got it. You're
  good to go." while what you asked for sat waiting in Approvals; now Grux adds, after
  the reply, "Not done yet:" and what is waiting for your OK.
- **Grux never says it started something it did not.** A local model could answer
  "Grux, upgrade yourself" with "The cycle's started; I'm waiting for your OK" when
  nothing had run or been queued; Grux now says it has not done that and offers to.
- **Grux answers when you ask whether something happened.** A local model's answer
  about your inbox, calendar or an earlier request ("Maria's sent you two emails",
  "it's queued for your approval") could be replaced with "I have not done that. Want
  me to?"; Grux now keeps the answer, and when it cannot be sure it adds one plain line
  saying it did not start, send or queue anything just now.
- **Grux says what really waits for your OK.** When a local model answered "Did the
  Foundry build start?" with "it's still waiting for your OK in the Approvals tray" and
  nothing like that was there, the answer stood; Grux now adds what Approvals holds
  right now, and that it did not start anything just now.
- **"Grux, upgrade yourself" works on the first ask.** A local model could answer it
  with only an offer; the exact ask now starts a self-upgrade cycle (or puts it in
  Approvals for your OK), and says plainly when self-upgrade is off.
- **Settings says what offline mode really does.** With offline mode on and no local
  model running, chat waits for one instead of using the cloud, and the switch stays on
  after a relaunch. The two lines under Offline mode used to say the opposite of both.
- **The offline mode caption matches where chat goes.** With offline mode on and a
  cloud provider picked under Models, Settings no longer says chat will not send; it
  says chat uses that provider.
- **Design Studio starts on a route your Mac can run.** With no Anthropic key and a
  local model running, it used to open on "API key", whose run could only fail; it now
  starts on Local model (a key still starts on the API), and the cost line names every
  other route, including the API.
- **Design Studio's cost line reads one way.** It said "$0.0418 estimated, API key |
  subscription, $0 metered (" and stopped; it now names the route you picked, lists the
  other routes after "Other routes:", and wraps instead of being cut off.
- **Research runs on a local model.** With a web search key and a local model, Research
  said it needed 2 more things, one of them an Anthropic key it never uses; it now asks
  for the web search key and either the key or a local model, as Chat does.
- **Grux no longer says it needs an Anthropic key to think.** The key's line in
  Settings and in `grux why` now says the key is for Claude, and that chat also runs on
  a local model with no key.
- **`grux next` and `grux doctor` name a missing model.** With Chat, Research or Design
  Studio on and neither an Anthropic key nor a local model, `grux next` said there was
  nothing to do and `grux doctor` said everything was in order; both now say to set up
  one of the two, and when one key would also unblock another feature, they name that
  key for both.

### Fixed: Self-Upgrade

- **A self-upgrade can install.** Approving an upgrade Grux built and verified used to
  fail every time, because Grux looked for its build script in the wrong folder.
- **Build it works on a Mac that built Grux from source.** Every proposal said Grux
  could not build it here, because Grux looked for its source one folder too deep.
- **"Grux, upgrade yourself" now finds upgrades.** A self-upgrade pass used to look over
  how Grux was doing and then file nothing, so the Self-Upgrade pane stayed empty. Each
  pass now files what it found as proposals you can read, build or turn down, at most
  five at a time, and never files the same one twice. With self-upgrade off, Grux says
  so instead of claiming it started.
- **A self-upgrade only installs what its reviewer read.** An edit left uncommitted, a
  file never added, a change hidden as binary, a branch moved onto an older commit, or
  a diff too long to read in one pass is now refused with that reason, and what an
  upgrade changed is read from the files themselves, so no git setting hides a file
  from the safety check.
- **Self-upgrade never installs a change to Grux's own safety checks by itself.** What
  an upgrade actually changed is now checked, not only what it set out to change, and
  the shell's safety checks (the command gate, the trust limit, the headless guard)
  count as protected. Such a build is not offered for install; Grux says which files it
  touched and leaves the change on its branch for you to review.
- **Self-upgrade no longer passes an upgrade whose test run ran zero tests.** On a Mac
  where `swift test` finds no tests and exits cleanly, the check used to read that as a
  green suite. It now fails with "ran zero tests" and says how to fix it: name the
  command that runs your suite in `config.json` (`foundrySuiteCommand`).
- **Self-upgrade refuses an upgrade whose test run crashed, or that failed a
  swift-testing test.** A test process killed partway, or a swift-testing failure, used
  to be able to hide behind the known XCTest failures the baseline allows.
- **A medium self-upgrade can finish on a Mac with a slow test suite.** Its builder runs
  only the tests for what it touched, leaves the full run to Grux's own check, and gets
  an hour instead of being cut off at 30 minutes.
- **Self-Upgrade proposes fixes for problems you hit, not for its own test runs.**
  Running Grux's test suite no longer writes into your audit logs.
- **Self-Upgrade no longer files its own failed builds as problems to fix.** A build
  that could not finish (an expired Claude sign-in, a red test run) used to come back as
  a new proposal, which failed the same way.
- **Self-Upgrade never offers to build a fix for an expired sign-in.** An agent job that
  failed only because Claude's sign-in had expired became a Self-Upgrade proposal to
  spend money on code; signing in fixes it, and Now already says so.
- **Self-Upgrade never proposes building something because nothing happened.** A quiet
  filesystem log (nobody used the filesystem tools that week) became a Self-Upgrade
  proposal; it no longer does.
- **A self-upgrade that fails no longer writes into your chat.** A failed build posted
  "UNPROCESSED FAILED SWARM - HANDLE THIS FIRST" into the open chat as if you had typed
  it, and Grux asked you to choose retry or abandon for a build Self-Upgrade had already
  closed; its builds now report on the Self-Upgrade pane only.
- **A self-upgrade that could not start says why.** When Claude's sign-in on your Mac
  has expired, the build's reason now says to sign in again and build it again, and
  chat is told the same, instead of "ended failed; nothing to verify".
- **A self-upgrade build or agent job no longer sits on "building" after its worker
  finished.** Grux could miss the moment the Claude CLI exited and wait forever; it now
  always notices.
- **Self-Upgrade cards redraw when a build leaves the rail.** A card kept "Waiting to
  build" after a failed build because nothing redrew; a held Build it now says why, and
  stored approval wording is rewritten in place.
- **Self-Upgrade's "Next" time is one Grux will keep.** If self-upgrade was turned on
  after Grux opened, it says the schedule starts once Grux relaunches; while a pass runs
  it says the next comes after it; and while a Claude session limit holds passes it
  says until when.
- **A paused self-upgrade says why and has a Resume button.** After Grux crashed twice at
  launch, self-upgrade paused itself with only a file to clear it; the Self-Upgrade pane
  now says when it paused, what happened and whether it went back to the last build
  that worked, with Resume self-upgrade beside it.
- **A rollback never takes a headless Mac's screen.** When Grux restores the previous
  build after a bad upgrade, it reopens hidden and in the background on a Mac set to
  headless, and it now really starts the restored build.
- **Self-Upgrade's cost reads as usage, not a price:** "About $8 worth of usage, counted
  against your subscription".

### Fixed: everything else a stranger hit

- **A link to a Settings pane opens that pane.** Opening Settings at a named pane
  (Models, Presets, a setup card's field) when no other pane was open landed on
  General, and a fresh link was dropped as a stale handback.
- **Every pointer to Settings names a place you can find.** Help and error lines sent
  people to "Settings, Offline mode", "Settings, Upgrades" and other places Settings
  does not have; each now names its pane, the Integrations page or macOS System
  Settings, and the README says to turn on Offline mode in Settings, Models to use a
  local model.
- **A setup card says when Claude needs signing in again.** Jax Command (and any
  feature that hands work to an agent) said "Everything else is ready" while Claude's
  sign-in had expired and no agent could run; the card now lists "Claude sign-in
  expired" with a Sign in button, and the row stays in Now until a run works or you
  sign in.
- **A feature you did not pick at setup says what it needs when you open it.** Opening
  Meetings (or any feature left out at first run) from Recent or search showed it ready
  to use, with Start enabled and the microphone refused; it now shows the same setup
  card a chosen feature shows, naming each missing permission with a way to allow it.
- **Setup cards say why, and say it once.** Focus log's card listed the Anthropic key
  with Chat's line; it now says Focus log checks your screen with Claude and that no
  local model can. The line under a headline no longer repeats the count four ways;
  the headline carries it and the line reads "Everything else is ready." or "Nothing
  else is needed." "Run setup again" is now "Restart onboarding" and asks right on the
  card.
- **A failed agent job is told in chat in plain words.** A job you started that could
  not run used to appear as a message from you ("UNPROCESSED FAILED SWARM ...") and come
  back as "the solo worker's OAuth session expired"; Grux now says itself that Claude's
  sign-in has expired and to sign in again, or that the job stopped and Agents shows
  why.
- **An agent worker never waits forever for a child that exited.**
- **Approvals asks once, and says why.** Asking for the same thing twice no longer
  leaves two cards waiting, and a held action says "This waits for your OK before it
  runs." instead of "Not clearly routine and reversible."
- **Approvals and every popup read in Light.** With Grux set to Light (or Auto on a
  light Mac), the Approvals tray, Optimize Grux, the chat threads list and every sheet
  showed near-white titles on a near-white background. They now sit on Grux's own dark
  surface in every appearance.
- **Deleting asks first, everywhere.** A trash icon deleted a calendar event, a note, a
  schedule or a webhook on one click, and Chat's trash icon wiped the whole
  conversation; each one, and deleting a conversation, roadmap item, agent job, voice,
  MCP server, custom endpoint, skill, comparison, ambient memory or mail account, now
  asks first and names what goes, in the window you clicked in (Settings included).
- **Grux asks before it puts anything on your calendar.** A time Grux heard while
  listening ("I'll call the dentist in 2 hours") used to go straight onto your
  calendar, overheard fragments included. It now waits in Approvals as "Add ... to
  your calendar, <time>?" and goes on only when you say yes.
- **Calendar offers delete only where it can delete.** An event from a read-only
  calendar (US Holidays, a subscribed calendar) showed a delete button that could only
  fail; it no longer does.
- **The Reactor's Calendar card says Today, not "11h ago".** On a holiday or any day
  with an all-day event, the card counted from the event's midnight start and read like
  it was over; it now reads Today (Now for a meeting underway, Tomorrow, the weekday
  within six days or the date for one coming up), and a meeting still ahead today is
  shown before the all-day event.
- **The Reactor no longer says "Inbox zero" when no mailbox is set up.** Its Mailbox
  card says "Not set up" until you add one, and its Meta Ads card says "Not set up"
  instead of "$0.00" when no ad account is connected.
- **Meta Ads no longer offers KILL when nothing is connected.** It showed a live KILL
  button beside "Not connected"; it appears once Grux has reached an ad engine.
- **`grux doctor` names what is still missing.** It said "Everything this command can
  check is in order." while `grux next` said Mail server was blocking Mailbox; doctor
  now says the same thing next does, and each command's step bar only moves forward.
- **Jax Command shows only plans grounded in what Grux sees.** A local model could fill
  a Goal Pursuit card with a command and ids it made up and say approvals were "stuck";
  a plan must now advance one of the real signals word for word and name nothing they
  do not, or Grux shows its own plain next step instead. A plan that strays into
  Approvals keeps its own goal, and what waits in Approvals is left to you: Jax never
  plans to pay an agent to answer your approvals.
- **A yes in Approvals starts Jax's plan, and the card says what it may spend.** A
  goal-pursuit plan queued for your approval was marked Approved and nothing ran;
  saying yes now starts the Claude Code session it planned, and the card reads "Run a
  Claude Code session: <plan>. It may spend up to $5.00."
- **Jax Command stops repeating itself.** A stretch of idle cycles is one card that
  counts them, a cycle with no plan carries no badge, and a planned one says in words
  whether it was only simulated or sent to Approvals.
- **Agents shows money like money.** The Agents pane read "$0.0000 of $5.00"; every
  amount there now reads "$0.00", "under $0.01" or "$1.23", the same as Settings,
  Usage; a job that went over its budget reads "$5.00, over the $5.00 budget"; and
  asked what a job spent, Grux quotes it the way the Agents pane does.
- **Settings, Usage and the menu bar say when the last decision was.** They showed a
  last decision from days ago beside "Decisions today: None yet"; both now name that
  day, and the year when it differs, and show what was decided.
- **Grux no longer says a Decisions key makes it faster.** Setup, Tuning and the setup
  list said a TypeSafe key makes decisions faster; measured, deciding on your Mac is
  faster. They now say what the key adds, judging what you meant when your words do
  not match a phrase exactly, and Integrations quotes today's measured typical speed
  instead of "about half a second".
- **Settings fields name what they hold.** In Settings, Models (custom endpoints, MCP
  servers), Voice (ElevenLabs) and Security (the Always allow and Always deny hosts),
  fields were labelled with an example; each now names the setting, with the example
  as a hint inside the field, and the MCP Env field shows its format by example
  ("KEY=value, OTHER=value") instead of asking for newlines a one-line field cannot
  take.
- **A key's row in Settings says what it unlocks.** Settings, Data & Capabilities read
  "Add your Anthropic API key in Settings to use Claude." right above the field; each
  row now says only what the key is for, and Credentials says how many keys are set
  instead of saying they are all empty on a Mac that has one.
- **Integrations says what really leaves your Mac.** It said "Nothing is sent to a
  server" above Slack, Notion and webhooks; it now says your tokens stay in the
  Keychain and Grux talks to each service you connect straight from your Mac, with no
  Grux server in between.
- **The contrast line under the accent slider tells the truth.** Settings, Appearance
  said "Passes WCAG AA" while the small chip labels sat at 4.2:1, under the 4.5:1 AA
  asks of text that size; it now names the pair and its bar, says those labels are
  below AA with an amber mark, and calls an accent a pass only when every pair meets
  AA.
- **Settings, Voice says why it lists no microphone,** and offers a built-in
  microphone only on a Mac that has one. It said "No input devices detected. Connect a
  microphone" on a Mac that has one, because Grux reads no microphone until macOS lets
  it use one; it now says that, or that access is off in System Settings, or that none
  is connected, whichever is true. "Revert to MacBook built-in mic" is "Use this Mac's
  built-in mic", and only where there is one.
- **Settings, Voice no longer says the same thing twice,** and no longer says the
  microphone is open before you agreed: with listening chosen but not yet allowed, it
  says the microphone stays closed until you agree and offers Allow listening, the same
  as Home.
- **Today never says Watching while it is not.** Without screen recording, while
  paused, or while Focus is off, Today names the task and the reason instead of
  "Focusing on", the Focus log says "Needs screen access" with Grant and that nothing
  is sampled until macOS allows it, and the nudge sentence reads plainly: "After 2
  checks in a row that read off task, Grux nudges you." Outside your active hours, or
  with no key for the check, the Focus log and the rail said "Watching" above "Nothing
  is sampled right now"; they now say "Not sampling now".
- **Every action button reads whole.** In Settings, Presets the buttons read
  "APPLY...", "DUPLI..." and "DELE..." at the default window, so Delete was a guess; on
  a narrow pane the Local Models Pull and Use buttons and a Self-Upgrade card's handoff
  button were cut the same way. Buttons now sit beside their title only when every one
  fits, and otherwise under it, and the Now list's instructions wrap the same way
  instead of reading "Agents cannot run until you si...".
- **A macro or workflow step that starts something in the background now finishes.** A
  shell step like `start-server &` used to hold the step until the background job
  ended, and a step with a lot of output stalled until its 30 second limit. Both now
  finish when the command does.
- **Grux never scripts or opens another app in headless mode, and asking for a video in
  silent mode is refused like music.** A small local model could answer a question by
  opening YouTube in Chrome and bringing it to the front; on a Mac set to headless that
  can no longer happen through a chat tool, a shell command (`grux shell` says so and
  exits 2), a workflow step or an agent, and on a Mac set to silent a video is refused.
- **A Mac running Grux headless never gets a Keychain dialog.** With `~/.grux/HEADLESS`
  present, a key Grux could only read through a macOS dialog now reads as not set,
  instead of a dialog sitting on a screen nobody is watching.
- **A copied Approvals line is cut whole,** full stops and all, and replaced wherever it
  sits.
- **The README says what still needs Claude.** It promised you could run "the whole
  thing" on a local model; it now says Chat and Design Studio run locally, Focus log and
  Compare need an Anthropic API key, and Agents and Self-Upgrade use the Claude Code CLI
  with your own sign-in.

## [3.1.0] - 2026-10-17

The first five minutes. A stranger installed 3.0, used it for five minutes and
wrote down everything that confused them; this release fixes those ten things.
The app is now called Grux AI.

### Changed

- **The app is named Grux AI** in the menu bar, Cmd-Tab, the window title, the
  panel and Today, About, permission prompts and the System Settings paths
  Grux tells you to open. Nothing you installed moves: the app is still
  Grux.app, and your permissions carry over.
- **About** says what Grux is in one line, shows the version, and credits
  its builder with a link.
- **Listening says one thing everywhere.** When listening is chosen in Tuning
  but you have not agreed to it yet, the panel, Today, Chat and Tuning all say
  it is waiting for your OK, with an Allow listening button, instead of Tuning
  saying Always on while everything else said OFF.
- **First run** opens with the orb and the name, says how listening starts in
  one line with the full explanation under How listening works, and makes
  "I would rather pick from a list" a real button.
- **Today** keeps Start my day on screen in a short window: the picture at the
  top gets shorter when the window does.
- **Mail with no account** shows only the setup card, and no longer says
  everything else is ready when nothing else is set up.
- **Settings** no longer breaks words in half in a narrow pane, says
  Self-Upgrade instead of Foundry, names no AI model in its text, and uses the
  same background as every other pane.
- **Notes, Documents, Labs and Tuning** no longer print their title twice in
  a pane.
- **The panel**: Optimize Grux is a row like the others instead of the biggest
  thing on screen.
- **Tuning** sizes each column to its own cards, and says how sure Grux must
  be in words ("when it is sure"), with the number on the dial.
- **Chat**: the box you type in opens two lines tall and grows, the status
  chips say what they are about ("LISTENING OFF", "REPLIES MUTED"), and messages
  fade out under the header instead of being cut off.

### Fixed

- **Return no longer sends a message Chat cannot deliver.** With no model
  attached, the Send button was disabled but Return still sent, and the turn
  came back as a provider error. Return now follows the same rule as the
  button, and the box says why nothing was sent.
- **Home draws faster.** It no longer rebuilds Today seven times before the
  first frame, and it opens on the greeting with the chat box one line tall.
- **Settings opens without waiting** on memory, and its tabs use the Grux
  accent.
- **Safer shell.** Grux asks before any `git branch` force or delete form,
  including `-M`, `-C`, `-D`, combined flags and options placed before
  `branch`, and before any forced push, fetch or tag, including
  `git -C repo push -f` and `+refspec`.

### First run on a new Mac

3.1 was installed on a Mac that had never seen Grux, and everything that got
in the way is fixed:

- **No microphone request until you ask for one.** macOS now asks only when
  you press a mic control or turn listening on. Before, starting Grux built an
  audio engine that made macOS ask right away, and on a Mac whose audio device
  also has inputs (a headset, a virtual machine) any sound Grux played did the
  same. Until you answer, a reply read aloud plays outside Grux, chimes play as
  system sounds, music plays in the Music app and a clip plays without sound.
- **The setup window fits every step**, and Continue is always on screen.
- **No sample task.** A new install starts with no current task.
- **No model yet? Skip for now.** Setup finishes without a model, the panel
  keeps a Connect a model row until one works, and Settings, Models
  downloads the best model for this Mac with live progress
  ("0.6 of 2.0 GB, 31%"). A download no longer reports failure while it is
  still running.
- **Faster local replies.** A local turn sends a prompt and context sized to
  the Mac's memory. Measured on a 16 GB Mac, the same
  question went from 131.6 s to 40.0 s. The wait says how long it has been.
- **Nothing you type is lost.** With no model connected, text typed in the
  panel stays put and says what to connect, and typing never toggles mute.
- **Voice Control:** every panel control has its own name, so "click
  Microphone" acts instead of asking which one.
- **Settings** has Settings… on Cmd-comma, and links into Settings scroll to
  the section they name.
- **Skipping the listening step leaves listening Off**, and Tuning says so.
- **Honest screens:** setup lists Chat as needing a model when it does,
  screen watching says it needs screen access until you grant it, and no
  recap pops up before setup is done.

## [3.0.0] - 2026-09-29

The release where Grux decides quickly, says what it is doing, and opens on
one Command Panel.

Every small judgment Grux makes on your behalf (was that sentence meant for
me, does this email need you, is this command dangerous, is now a bad moment to
interrupt) used to be a keyword list, a hand-written rule, or a full language
model call. In 3.0 they all go through one decision engine. With a TypeSafe key
it asks Jev, a typed decision model, and gets a calibrated probability back in
about 400 ms, except for a command you said outright, which it answers on this
Mac in about 1 ms without asking anyone. Without a key it answers on this Mac
for everything, exactly as before, and asks nobody anything. Either way the old rule stays underneath as the floor: the
engine can hold something back or confirm it, and nothing destructive ever runs
on its say alone.

First run is one question, "What do you want to do with Grux?", and the flow
after it is built from your answer: what Grux picked, shown before anything is
asked, then your name, a model, how Grux works, and setup one thing at a time.
Everything Grux does for you is on one page, Tuning, opened from the orb.

### Added

- **One decision engine for every gate**, recorded in a local ledger at
  `~/Library/Application Support/Grux/decisions.jsonl` that never leaves your
  Mac. Today shows how many decisions ran, how long they took and what they
  cost; the orb shows the same on hover, and Settings has a Usage card.
- **One Listening control**: Always on, After "Hey Grux", or Off. The orb, the
  menu bar, the HUD and the sidebar foot all say the same word (ARMED, MUTED,
  SPEAKING, THINKING, OFF), and NOT HEARING when the microphone is open but
  sending no sound. Listening waits for your consent before it opens the
  microphone, and a fresh install says OFF until then.
- **The approvals tray** in the sidebar foot: what is waiting for you, one tap
  from anywhere.
- **Known out-of-credit.** When a provider says your balance is empty, Grux
  tells you once and says which features stop, instead of failing quietly.
- **Add a brand** from setup or Settings, which brings its Meta Ads and Social
  rows with it.
- **A switch for the Developer door** in Settings, General. Commands, Agents,
  Local Models and Compare live behind it.
- **Tuning**: one page for what Grux does for you. Seven cards, named for what
  they do rather than for a subsystem, each opening to its own dials: how sure
  it must be before acting, how it talks back, when it may interrupt, what it
  does on its own, what it spends, what it remembers, and what always asks
  first. Opened from the orb, from Today, from the command palette, from the
  menu bar and from the top of Settings.
- **Tell Grux what you want.** Say what you want changed, from a colour to a
  whole new surface, and Grux writes a work order your own coding agent picks
  up: it asks you at most three questions (each with a recommendation), then
  analyses, designs, builds, tests, installs and verifies, stopping three times
  for you to say yes. Nothing about Grux changes without your yes.
- **Labs is a shelf.** The Labs door opens on eight cards with one line each,
  so what is still being built says what it is for before you open it.
- **A daily cap on decisions.** Past it Grux decides on this Mac until
  midnight, for free. Off by default, in Tuning.
- **A ceiling on what Grux may do by itself.** Self-upgrade never goes past
  what you allow, whatever it has earned. New installs start at "proposes
  only".
- **Dry runs for workflows.** Start any workflow as a dry run, or every
  workflow on this Mac while `~/.grux/DRY-RUN-WORKFLOWS` exists. A dry run
  goes end to end, including the App Store workflows: it runs the steps that
  only touch the run itself, records what every other step would have done,
  skips its waits, and changes nothing outside Grux. No tool call, shell
  command, agent, webhook, notification banner or phone push. Every line it
  says starts with "Dry run".
- **Headless and silent.** With `~/.grux/HEADLESS` present, Grux runs on a Mac
  whose screen belongs to someone else: it shows no window, takes no focus,
  and keeps its own record of its windows under `~/.grux/headless-workspace`.
  With `~/.grux/SILENT` present, it makes no sound. Show earlier, Latest,
  scrolling Chat, the pane width and opening a workflow run each have a file
  trigger under `~/.grux` that writes what the screen now shows.

### Changed

- **The shell is a 420pt Command Panel**: one input, a Now list of what needs
  you, Optimize Grux as a card with four doors (Tune it, Change it, Hand it
  over, Let it improve itself), and any surface as one pane beside it. The
  sidebar is gone as the default frame; `legacyShell` in config.json keeps
  it for one release, switched by Classic sidebar in Settings, General, which
  switches right away. New: the handoff bundle under ~/.grux/handoff, a local
  opens.jsonl, and a design token ratchet in CI.
- **Under the Classic sidebar, the sidebar is twelve surfaces, two doors and
  Settings.** A new install shows fourteen rows. Nine surfaces folded into the
  one they belonged to: Speakers into Meetings, Workflows into Schedules,
  Outbound Webhooks into Integrations, Compose into Mail, Projects into Tasks,
  Folders into Settings, Skills into Chat, Approvals into the tray, the Focus
  log into Today. Every old tab key still opens the right place.
- **Home is Today**, and it leads with what needs you: your next task, the
  mail that needs you, what Grux is watching, and one line on the day's
  decisions and their cost.
- **Mail counts what needs you, not what is unread.** Measured on a real
  inbox: 245 unread, 48 that need you.
- **Labs is badged once**, at the Labs door, instead of a pill on every row.
- **Vendor names sit one size smaller** behind a small "ai" mark that expands
  on hover, and status codes, raw model ids and internal names are gone from
  every screen you use day to day.
- **Grux is quiet when idle.** Muted and idle it used 33.3% of a core; it now
  uses 1.0%. Listening and idle, 38.2% down to 12.9%.
- **Grux stops asking permission to do nothing.** 72 of its 116 tools had no
  safety classification, so reading a list of files, checking an agent's
  status or opening an app all queued up as "unclassified side effect" and
  waited for you. A spoken "open Chrome" could return an answer about
  something else entirely while the real request sat in the queue. Every tool
  is now classified, and the 44 that actually change something, spend money or
  record are the only ones that ask.
- **Background listening never takes the microphone from another app.** Grux
  used to switch on Apple's voice processing while it listened, and that stops
  any other app that is RECORDING dead: a call, a screen capture, a browser
  holding the mic. Measured with a second recorder running, it lost its audio
  11 seconds in and never got it back; it now records for the full take with
  nothing dropped. Grux does not need voice processing to listen, because it
  closes the microphone whenever it speaks and so has no echo to cancel.
- **Your music and video were never the problem, and we said they were.**
  Earlier notes, the Settings copy and the consent dialog all said voice
  processing drops system output to a narrow-band call codec and makes Music,
  Safari and YouTube go tinny. That was never measured. It was measured on
  2026-09-23 and it is false: a 12 kHz tone came back 73 dB above the noise
  floor while voice processing ran, the output device stayed 48000 Hz 2ch
  32bit, and an app that was only playing sound saw no disruption at all. The
  claim is gone from every surface that carried it.
- **Grux notices when it goes deaf.** It could previously lose its audio feed
  mid-session and keep reporting itself as listening, with every indicator
  saying it was fine. Found on a real machine after 1 hour 40 minutes of it.
  Eight seconds with no audio now restarts the capture and says NOT HEARING.

- **Only you answer a workflow's question.** A workflow waiting on you takes
  its answer from a message you send in Chat after it asked, within 30
  minutes, in one of the words it asked for. An older reply makes it ask
  again, and an agent's message never answers it.
- **Workflow run records read as sentences.** Each step is titled by its own
  name and says what it did in plain words. What a tool, a command or an
  agent printed sits under Details, which starts closed.
- **Chat opens on your newest message and keeps your place.** A long thread
  lays out its newest 16 messages, with Show earlier for the rest. Show
  earlier and resizing the window keep the message you were reading at the
  top, and Latest lands at the end.
- **Web views recover.** The Design Studio preview, the Social dashboard and
  the draft reply preview write a line to Grux's log and reload once when
  their page process is lost, instead of staying blank. Design Studio says
  "Loading the preview" until the first page has drawn.

### Fixed

- A long Chat thread could open on a blank transcript.
- Latest could stop 33 points short of the newest message, with following
  off and the Latest chip still up.
- Resizing the window moved the message you were reading by about three
  messages.
- Design Studio's preview could stay blank for up to about 8 seconds on the
  first open after launch, with nothing saying it was loading.
- A workflow run that failed read "Workflow finished" in the status line.
- A dry run sent real webhooks for every step, and its milestones could post
  a real banner and phone push once the run had left the recent runs.

### Removed

- **The Domain monitor** and the registrar key it asked for.
- **The tunnel manager**, which had been inert since 2026-08-12. Phone pairing
  works on the same network, as it has since then.
- **Terminal Focus.** The BETA floating overlay that showed context from
  surrounding Claude Code sessions is gone, with its sidebar key, its Terminal
  sub-pane in Settings, its global hotkey, its menu bar item, its two macro
  actions and the coding agent hook it offered to install. A saved macro that
  still carries one of those two actions keeps every other step. The workspace
  Focus card and the Sessions pane stay. The first launch of this build
  uninstalls the Claude Code hook it installed: only its own entry leaves your
  Claude Code settings, and the script goes only if Grux wrote it.

### Decision latency, per gate

Measured with `scripts/decision-latency-table.py` over one install's ledger
(before: every decision before 2026-09-21 2:33 PM UTC; after: every decision
from 2:50 PM UTC to 9:31 PM UTC), or from the calibration runs where a gate has
no live rows yet. p50 is the median.

| Gate | Before | After, with a key | Source of the after figure |
|---|---|---|---|
| Voice: was that meant for Grux | Jev 441 ms, 4,460 input tokens (742 calls); on device 4 ms | Jev 387 ms, 2,200 input tokens (159 calls) | ledger |
| Voice: a command you said outright | Jev, 368 ms median (p90 872 ms) over 603 decisions | **1 ms**, answered on this Mac, no network | ledger + live |
| A spoken request that reaches Chat | two calls in a row, 728 to 912 ms | one call, 341 ms | ledger, 1 call |
| Which app a spoken request means | keyword match on device, under 5 ms | 404 ms, on the same call as the voice judgment | ledger, 2 calls |
| Mail that needs you | heuristic on device, under 5 ms | 364 ms, once per message | ledger, 56 calls |
| Approvals risk | rules on device, under 5 ms | 447 ms | ledger, 1 call |
| Project attribution | none (new) | 439 ms | ledger, 4 calls |
| Jax gate | Jev 414 ms (17 calls); on device 0 ms | unchanged on the wire | ledger, before window |
| Notification triage | rules on device | 412 ms | calibration, 14 calls |
| Email classify | a text model call that also drafted | 392 ms, drafting stays on the text model | calibration, 10 calls |
| Focus drift and a good moment to interrupt | cooldown rule on device | 365 ms, one call for both | calibration, 12 calls |
| Shell destructive, second opinion | rule list on device | no live calls yet; the rule list still decides alone without a key | none |
| First-run answer to features | none (new) | 358 ms; not wired until the first-run screens land | calibration, 24 calls |

**Slower, said plainly:** every gate that used to be a keyword or a rule on
this Mac now takes about 350 to 450 ms when a key is present, where it took
under 5 ms. It is slower because it is now judging what was said rather than
matching a word. With no key, every gate answers on device exactly as fast as
before.

**Three things got faster.** A spoken request into Chat went from two calls to
one. The voice judgment's prompt halved. And a command you say outright no
longer waits on the network at all: the engine used to send every decision to
Jev whenever a key was present, so a command took a 368 ms median round trip to
be told what the device already knew. It now answers on this Mac in about 1 ms
when it is certain, and still asks Jev for anything it is not certain about, so
a paraphrase is judged on meaning exactly as before.

**End to end, a spoken command reaches execution in about 1.5 seconds**, down
from 3.1. That is not the 600 ms we were aiming at, and the reason is worth
stating rather than burying: transcription has a floor of about 750 ms on the
model Grux uses, and the pause Grux waits out before it will act is another
600 ms. Trimming the audio was measured and changed nothing. Reaching 600 ms
needs recognition that runs while you are still speaking, which is a build, not
a setting.

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

- **Grux no longer acts on a command it overhears in the room.** Without a
  Decisions key, a command phrase found anywhere in a sentence counted as a
  command, so "we should mute the group chat" muted the microphone and a
  television line advertising "mute the ads" muted it too. A phrase now has to
  cover at least half of what was said.
- **Half-heard reversible commands are ignored rather than queued.** Grux used
  to put an approval in front of you for a tab switch it half heard in room
  talk. Said to Grux by name, or right after it spoke, it still asks.
- **Design Studio no longer asks for an Anthropic key it never uses.** It
  routes like chat does, so a local model or a hosted endpoint serves it.

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

[Unreleased]: https://github.com/dotcomjack/grux/compare/v3.2.0...HEAD
[3.2.0]: https://github.com/dotcomjack/grux/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/dotcomjack/grux/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/dotcomjack/grux/compare/v1.2.1...v3.0.0
[1.2.1]: https://github.com/dotcomjack/grux/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/dotcomjack/grux/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/dotcomjack/grux/compare/v1.0.4...v1.1.0
[1.0.4]: https://github.com/dotcomjack/grux/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/dotcomjack/grux/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/dotcomjack/grux/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/dotcomjack/grux/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dotcomjack/grux/releases/tag/v1.0.0
