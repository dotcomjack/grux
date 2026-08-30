# The Grux CLI grammar

Status: SHIPPED in 1.2.0. 45 of the 48 commands below are implemented and in the
release; the three that are not are called out where they appear. This began as a
specification written before any of it existed, and the header that used to sit here said
so in strong terms, including that the repository was private and none of these command
names were public. Both of those stopped being true when 1.2.1 was published.

An interactive prototype of `grux setup` is kept at `prototypes/cli-onboarding.html`. It
is a prototype of the design, not the implementation.

Read `docs/contract.md` first. The capability vocabulary is closed and this document
invents none of it.

---

## 0. The problem this solves, in one paragraph

Grux asks a person for 43 different things across 39 features, and today every one of those
asks lives in its own screen with its own wording and its own idea of what happens if you
say no. A CLI does not fix that by moving the asks to a terminal. It fixes it by making
every ask arrive in the same shape, in the same order, with the same escape hatches, so
that the twentieth time somebody adds something to Grux they already know what the next
screen is going to be and what it will not do to them. **The grammar is the product. The
commands are just where it shows up.**

---

## 1. The six beats

Every command runs these, in this order, and prints the rail at the top so the reader can
see where they are.

```
LOOK  ›  CHOOSE  ›  COST  ›  GRANT  ›  HAND OFF  ›  PROVE
```

| Beat | What it does | What it may never do |
|---|---|---|
| **LOOK** | States what is already true on this Mac. Detection only. | Ask for anything. Change anything. |
| **CHOOSE** | The person picks what they want. | Request a credential or raise a dialog. |
| **COST** | The complete bill for that choice, plus the list of things that will **never** be asked for because nothing chosen uses them. | Proceed without a confirm, or hide an item because it is awkward. |
| **GRANT** | The asks, cheapest to refuse first. Every one skippable, and skipping is recorded rather than forgotten. | Ask for anything that was not on the COST screen. |
| **HAND OFF** | A prompt for the person's own coding agent, covering only what an agent may do. | Include a consent step, a credential, or a permission. |
| **PROVE** | What is true now, what is still open, and the command to check it without trusting this output. | Report success for something it did not verify. |

**CHOOSE always precedes COST, and COST always precedes GRANT.** A command that asks first
and explains afterwards has broken the grammar even if every individual screen is well
written. That ordering is the entire promise and it is the one thing a reviewer should
check first in any new command.

Beats with nothing to do are printed and passed through, not skipped silently. A command
whose rail is missing COST looks like a command that has something to hide.

---

## 2. Every command has two front doors, and they must agree

```
  a person in a terminal                    a person in the Grux window
  $ grux add brand                          clicks "Add brand"
          │                                          │
          │                                  app runs `grux handoff add brand`
          │                                  and puts the result on the clipboard
          │                                          │
          │                                  pasted into their own coding agent
          │                                          │
          └──────────────► the same command ◄────────┘
                        with the same six beats
```

This is the whole architecture. The app never writes a bespoke instruction paragraph for a
feature. **`grux handoff <any command>` renders the prompt for that command without running
it**, and every "you will need to set this up in Settings" surface in the app becomes a
button that copies one.

Two consequences, both non negotiable:

1. **Every command must run non interactively.** `--json` on every read, flags for every
   choice, and no prompt when stdin is not a TTY. An agent that hangs on a hidden
   confirmation is worse than an agent that refuses.
2. **Every command must be idempotent.** An agent will run it twice. The second run reports
   what is already true and changes nothing.

---

## 3. The handoff document

Six headings, always these, always this order. `AgentHandoff.swift` already ships the split
this generalises; what is new is that every command emits one and a reader recognises the
shape on sight.

```
CONTEXT   What is being set up and what Grux is, in one paragraph, addressed to the agent.
YOURS     What the agent may do. Numbered, each with the remediation string from the contract.
MINE      What only the person can do, grouped: credentials, macOS permissions, in-app
          steps, and decisions. Four groups, four different actions, never one flat list.
NEVER     The prohibitions. Do not write a key into a dotfile. Do not tick a consent step.
          Do not install anything not named above.
VERIFY    One command: `grux status --json`. Every id named above appears in that output.
REPORT    What to tell the person at the end.
```

Rules the renderer enforces:

- **Wrapped to 76 columns.** It is pasted into a terminal. The prototype asserts this,
  because the hardcoded prose sat at 80 while the generated lines ran to 120 and only the
  generated ones looked wrong.
- **`YOURS` is derived from a list, never from `kind`.** `kind == .step` is not the
  question "can an agent do this". `AgentHandoff.delegable` holds exactly two ids today and
  the first draft of that list had five, three of them wrong.
- **The four consent steps are never delegable and are never merged with errands.** Fetching
  a speech model and deciding what Grux may read of your own writing are not the same kind
  of thing, and printing them under one heading taught an agent to refuse work it could
  have done.
- **`VERIFY` must be honest about what Grux can detect, and the numbers come from the
  resolver rather than from prose.** This used to say, flatly, that Grux "does not go
  looking to see whether you installed them". That stopped being true the day four steps
  became detected, and it stayed in the prompt for a whole phase afterwards. Telling an
  agent its work will not be noticed when it WILL is how somebody re-ticks a box that was
  already true. The paragraph now reads its counts out of
  `CapabilityResolver.detectedSteps` and `selfAttestedSteps`, so it cannot drift again, and
  `HandoffShapeTests.testVerifyCountsMatchTheResolver` fails if it does.

- **Scoping is what "every command emits a handoff" actually means.** The literal reading,
  every command printing the whole document, was rejected after looking at it: sixty lines
  of prompt after `grux which perm.microphone` is noise, and noise in the one document that
  gets pasted somewhere else is expensive. `grux handoff [features...]` renders the same
  six headings scoped to whatever you name, which is the question somebody actually has
  when they are adding one thing rather than setting up from scratch. A scoped handoff is
  asserted to be a strict subset of the unscoped one, because a narrower list that quietly
  widened would read as precise and not be.

---

## 4. Exit codes, because an agent reads these and a person does not

| Code | Meaning | What an agent should do |
|---|---|---|
| `0` | Everything this command asked for is satisfied. | Report done. |
| `2` | The command succeeded and something is still waiting on the human. | Stop, and name which items in `MINE` are outstanding. |
| `1` | The command failed. | Report the error verbatim. Do not retry. |

`2` is the one that matters and it is the one a naive design leaves out. Without it an
agent has to choose between calling a half finished setup a success and calling it a
failure, and both are wrong.

---

## 5. The command surface

Small on purpose at the top level, and deep only where the work is. A person should be able
to guess a command they have not read about, and an agent should be able to enumerate the
whole surface without reading this file.

**THIS TABLE IS THE SOURCE OF TRUTH, AND A TEST READS THIS FILE.**
`CommandSurfaceTests` parses the three tables below and asserts that the set of subcommands
registered in the binary equals the set of rows marked `shipped`, EXACTLY, both ways. A
command in the binary and not in this file fails. A row marked `shipped` with nothing
behind it fails. A row marked `planned` is the build queue, and moving one to `shipped`
without writing the command is caught immediately.

That is deliberate. Every command is a new thing an agent can make Grux do on somebody's
Mac, so the surface grows by a decision written down here, never by somebody adding a
struct and nobody noticing.

### Reads. Ask for nothing, change nothing, work with the app closed.

| Command | Built | What it answers |
|---|---|---|
| `grux doctor` | shipped | Is this Mac able to run Grux at all. The LOOK beat, standalone. |
| `grux status [--json]` | shipped | Every capability id and its state. The PROVE beat, standalone. |
| `grux list [features \| capabilities \| brands \| projects]` | shipped | The inventory, whatever is on or off. |
| `grux cost <feature>...` | shipped | What a selection would ask for, and what it never will. |
| `grux why <capability>` | shipped | Which chosen features want this, and what breaks without it. |
| `grux which <capability>` | shipped | The one line an agent greps: satisfied, needed, or never asked. |
| `grux next` | shipped | The single most useful thing to do now, and the command that does it. |
| `grux explain <topic>` | shipped | What a word means here, in the same words the app uses. |
| `grux permissions` | shipped | Only the macOS grants, their state, and who is asking. |
| `grux history` | shipped | What Grux has changed on this Mac, newest first. |
| `grux journal [--since]` | shipped | The workday log, read only. |
| `grux logs [--follow]` | shipped | The app's own log, tailed or dumped. |
| `grux diff` | planned | What changed since the last `grux setup`. |
| `grux spend [--since]` | shipped | What the model calls cost. Reads the ledger, never a vendor. |
| `grux search <text>` | planned | Across notes, transcripts and the journal. |
| `grux version` | shipped | Both versions, and whether they match. |
| `grux completion <shell>` | shipped | The shell completion script, on stdout. |
| `grux support-bundle` | shipped | A redacted archive for a bug report. Names every file first. |

### Writes. Every one goes through the control socket, so the app is the only thing that
### ever touches real state, and every one has a matching tool the app declares.

| Command | Built | What it changes |
|---|---|---|
| `grux setup` | shipped | The whole six beats. The only command that runs all of them. |
| `grux enable <feature>` | shipped | One feature on, and only its capabilities become askable. |
| `grux disable <feature>` | shipped | One feature off. Never revokes a permission by itself. |
| `grux use <brand>` | shipped | Which brand the next command is about. |
| `grux connect <service>` | shipped | One credential. TTY prompt, echo off, straight to the Keychain. |
| `grux disconnect <service>` | shipped | Forgets one credential. Names what stops working first. |
| `grux add <noun> [name]` | shipped | The workhorse. See the nouns below. |
| `grux remove <noun> <name>` | shipped | The inverse, with a typed confirmation. |
| `grux config <key> [value]` | shipped | One setting, read or written. Never a secret. |
| `grux approvals` | shipped | What the agent may do without asking. |
| `grux model [name]` | shipped | Which model a surface uses. |
| `grux keys` | shipped | Credential NAMES and their state. Never a value, ever. |
| `grux note <text>` | shipped | Straight into the notes store. |
| `grux task <text>` | planned | Straight into the reminders store. |
| `grux repair` | shipped | Fixes what `doctor` found and can fix, one thing at a time. |
| `grux reset <scope>` | shipped | Back to never-asked. Typed confirmation, scope is required. |
| `grux import <file>` | shipped | A setup another Mac exported. Shows the diff before applying. |
| `grux export [--out]` | shipped | This Mac's choices, with every secret left behind. |
| `grux undo [--list]` | shipped | Restores a shell session from the shadow git. Never the real one. |

### Runs. These make Grux do a thing rather than change what it is.

| Command | Built | What it does |
|---|---|---|
| `grux run <command>` | shipped | One of the app's own commands, by id. |
| `grux ask <text>` | shipped | One question to the chat surface, answer on stdout. |
| `grux agent <text>` | shipped | Hands the agent a task and streams what it does. |
| `grux open [surface]` | shipped | Brings a window forward. The one command that needs the app. |
| `grux meeting <start \| stop \| list>` | shipped | The meeting recorder. |
| `grux transcribe <file>` | shipped | On the GPU, locally. Never uploads. |
| `grux shell <text>` | shipped | A shell command through the trust ceiling, snapshotted first. |
| `grux watch <path>` | shipped | Follows a file or a folder and reports what changes. |
| `grux serve` | shipped | The MCP control plane on stdio, for an agent that cannot use the socket. |
| `grux handoff [command...]` | shipped | Renders any command's prompt without running it. |
| `grux intro` | shipped | What Grux is, what it will ask for, and how to stop it. |

### Nouns for `add` and `remove`

| Noun | What it bundles |
|---|---|
| `feature <id>` | One row from the registry. The atom everything else is built from. |
| `project <path>` | A code root, its registry entry, and the shell safety allowlist. |
| `brand <name>` | A composite. This is the interesting one, worked below. |
| `mailbox <address>` | An account, its endpoint, and the surfaces that read it. |
| `repo <path>` | A git root the digest and the PR inbox watch. |
| `domain <host>` | Uptime and expiry monitoring for one hostname. |
| `schedule <when>` | A recurring command. |
| `skill <path>` | A folder of instructions the agent may load. |

### Two rules that keep this from becoming fifty unrelated programs

**Every command prints the rail, including the ones with one beat to run.** A command whose
rail is missing COST looks like a command with something to hide. A beat with nothing to do
prints and passes through.

**Every command works with `--no-input` in a pipe, or says why it cannot.** One sentence
naming the flag that would have answered it, and exit **1**, not 2. A command that hangs
waiting for a person who is not there is the single worst thing a CLI can do to an agent
driving it.

Exit 1 rather than 2 is deliberate, and the distinction is the whole value of exit 2. Exit
2 means *no invocation of this command can succeed until a person does something on this
Mac*: a permission to click, a key to paste. A missing `--preset` is not that. It succeeds
immediately on a better invocation, so an agent should fix its own call rather than stop
and wake somebody. Collapsing the two would make exit 2 useless for the only decision it
exists to inform.

## 6. What has to be true before any of this is written

These are ordered. Each one blocks the ones under it.

1. **Settle the TCC question.** macOS attributes a permission request to the responsible
   process, so a prompt raised by a `grux` binary run from a terminal would grant the
   permission to the terminal. `docs/adr/0001` says the same thing from the other side:
   permissions flow per signed bundle id. **Unverified for Grux specifically.** Build a
   trivial signed helper, call `CGRequestScreenCaptureAccess()` from a Terminal invocation,
   and read which bundle id appears in System Settings. If it holds, the CLI never grants
   anything: it hands the queue to `Grux.app`, which asks under its own signature, and the
   GRANT screen says so out loud because a person watching a dialog arrive from a different
   application deserves the reason.
2. **Give a feature an off state.** `CapabilityGate` renders four states and none of them
   is "the owner did not choose this". That is a contract change and the contract is
   FROZEN: file it under "Contract change requests", do not invent a state at a call site.
   Without this, CHOOSE has nothing to choose.
3. **Derive the permission queue from the selection.** `CapabilityRequest.onboardingOrder`
   is a hardcoded list of 8, offered identically to everyone. Keep it as the **sort key**,
   which is good and hard won, and stop using it as the list. The single test that matters:
   choose nothing and the flow asks for zero permissions.
4. **Make steps detectable.** Eight of the ten `step.*` ids are `UserDefaults` booleans
   with no detection behind them. `step.phone_paired` reads the Keychain and
   `endpoint.ollama` probes the endpoint, so the shape already exists twice. Until the rest
   follow, `VERIFY` cannot honestly close the loop.
5. **Build the machine surface before the binary.** `setup-status.json`, atomic, versioned,
   all 43 ids. `MicController` already writes `mic-status.json` and its bug history is the
   specification: it reported the state from before the change, and it truncated on write
   so a reader could catch a half written file.
6. **Then the binary**, as a thin front end over a new platform free `GruxSetupCore`.
   `GruxShellCore` and `GruxAgentCore` are the precedent for why it does not depend on the
   app target.

---

## 7. CHOOSE is what makes off-by-default honest

`CLAUDE.md` locks this: **nothing ships off and undiscoverable.** A feature that is off and
unfindable is a deleted feature with dead code behind it, and off by default is only
defensible when the user knows what they turned down. Three things must be true, all three:
named at first run, a permanent home, and its off state explained.

Giving a feature an off state (section 6, item 2) is the single change most likely to
violate that rule, because it creates 39 new ways to end up with something switched off. The
grammar answers all three by construction, and a new command has to keep answering them:

1. **Named at first run.** CHOOSE lists **every** feature, all 39, grouped in sidebar order,
   with the BETA badge on the 14 labs rows. Not the popular ones, not a curated subset.
   Somebody who picks four has still read the names of the other thirty five. Presets are
   offered as a shortcut and never as a filter over what is shown.
2. **A permanent home.** PROVE always ends by naming `grux add <feature>`, and the Settings
   pane keeps its row for every feature whether or not it was chosen. First run happens
   once; discovery has to keep working afterwards.
3. **Its off state explained.** The COST screen is where this lands, and it is the reason
   COST prints the never-asked list by name rather than as a count. A person who did not
   pick Meetings can see that Microphone and System audio are therefore never requested,
   which is the same sentence read from the other end.

**The test, restated for this surface:** after `grux setup`, a person can answer "what can
this app do that it is not doing right now, and how do I turn it on" without reading source.
If a future command hides a feature to keep a list short, it has failed that test even if
every screen in it is well written.

---

## 8. Things this grammar deliberately refuses

- **No `curl | sh` install.** An app whose entire pitch is that it phones nobody does not
  open by asking you to pipe a stranger's script into your shell.
- **No progress bar over a fixed flow.** The flow is not fixed. It is a function of what
  was chosen, and a bar implies a length the command does not know.
- **No `--force`.** There is nothing to force. Every ask is already skippable, and a flag
  that means "stop asking" is a flag that means "assume consent".
- **No silent success.** PROVE always prints, even when nothing changed, and always names
  the command that checks it independently.
