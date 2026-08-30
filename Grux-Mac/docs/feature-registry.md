# Feature registry

Status: IMPLEMENTED. The 39 rows below are `FeatureRegistry` in `Sources/Grux`, and
`scripts/check-contract.py` fails the build when this document and that file disagree.

This page used to open with a banner saying the repository was private and that nothing in
it, including this registry, was to be published until the owner said so explicitly. He
did, and 1.2.1 is the release. "Open source build" throughout this document named a target
shape at the time it was written; it now names what shipped.

---

## 1. The governing document

`docs/contract.md` governs everything below it. It is **FROZEN**. Read it before you read
this file. Three facts from it decide most arguments, so they are repeated here for a
session that arrives with no context:

1. **The capability vocabulary is CLOSED.** A feature may name only ids that already exist
   in contract sections 1.1, 1.2, 1.3 and 3.1. Four classes: `key.`, `perm.`, `endpoint.`,
   `step.`. If a feature genuinely needs something with no id, the contract changes first.
   The correct move is a contract change request, never a new id invented at a call site.
   Section 8 of this file carries every request this registry raises.
2. **Four states, and a missing capability is never an error.** `ready`, `needs-setup`,
   `degraded`, `unavailable`. A `requires` capability that is absent puts the feature in
   `needs-setup` behind a setup card. An `optional` capability that is absent puts it in
   `degraded` with one inline note. A feature that throws, logs to the console, or renders
   an empty view instead is a defect, not a design choice.
3. **Cookbook is not a blueprint host.** `Sources/Grux/LocalModelCookbook/Cookbook.swift:3`
   describes itself as a "Static, curated catalog of local models worth running through
   Ollama, plus the fit-scoring math that matches them to a HardwareProfile. Pure logic, no
   IO". Verified again for this registry: `CookbookStore.swift:8-13` persists exactly four
   fields and there is no authoring surface anywhere in that directory. **Blueprints have
   three hosts: Skills, Schedules and Workflows.** Workflows is not a module called
   Workflows; the engine is `Sources/Grux/CommandsV2/`.

Everything in this file before the heading "8. Contract change requests" is **binding**:
`scripts/check-contract.py` fails the build if it names a capability id or a config key the
contract does not define. Everything after that heading is exempt, which is what makes it
safe to propose there.

---

## 2. How the registry is derived

**Ground truth is `SidebarIA.groups` in `Sources/Grux/DesignSystem/SidebarModel.swift:27`.**
Verified for this registry by reading the file, not by recalling it: **36 tabs across 5
groups**, command 11, workspace 7, intelligence 6, ambient 3, system 9.

### 2.1 The pruning rule

> Start from the 36 sidebar tabs. **Every tab becomes exactly one feature row, unless it is
> cut.** A tab is cut only when it is personal or harmful under section 6, never because it
> is rough. A tab contributes a *second* row only when a distinct sub-surface inside it
> carries its own capability profile and its own ship decision; three do. Nothing is minted
> that is not a real surface in the tree.

That yields 39 rows: **33 that ship** (24 `core`, 9 `labs`) and **6 that are cut**. The cut
rows are not in the registry tables in section 5, because contract section 6 defines `tier`
as `core | labs` and a third value would be an invention. They are enumerated in section 6
of this file instead, which keeps the decision recorded without widening the enum. Section
8 asks the contract to settle where cut rows should live.

The three sub-surface rows, and why each earns one:

| Row | Parent tab | Why it is its own row |
|---|---|---|
| `mailbox.compose` | Mailbox | Its only send path needs a credential the mail domain does not cover, so it ships at a different tier from the tab that hosts it. |
| `mailbox.support_triage` | Mailbox | Cut on its own while the tab ships. A per-tab verdict cannot express one shipping feature and one cut feature in one tab. |
| `integrations.webhooks` | Integrations | Separate store, separate tests, separate delivery machinery from the token-paste connectors above it. |

### 2.2 Id mapping, applied once so nobody guesses

Contract section 6 requires `Feature.id` to be lowercase and dotted. Eight sidebar
`applyTab` keys are camelCase and `SidebarModel.swift:9-11` forbids renaming them, because
the `--open-tab` automation depends on the strings verbatim. So the sidebar key cannot be
the id. **The rule applied throughout this file: lowercase the key, and every camelCase
hump becomes a dot.** The full mapping, so three tracks derive the same ids instead of
each guessing:

| Sidebar key | Feature id |
|---|---|
| `jaxHQ` | `jax.hq` |
| `jaxCommand` | `jax.command` |
| `cognitionMap` | `cognition.map` |
| `featureReview` | `feature.review` |
| `designStudio` | `design.studio` |
| `terminalFocus` | `terminal.focus` |
| `selfUpgrade` | `self.upgrade` |
| `metaAds` | `meta.ads` |

Every other id equals its sidebar key, which is already lowercase.

### 2.3 What "verified" means here

Every row was written from the code, with a file and line. Where the prior 161 feature
audit and the code disagreed, **the code won and the disagreement is recorded in section
9**. Two audit claims were re-checked directly for this document and are false: Cookbook
cannot host blueprints, and there is no Workflows module.

---

## 3. The Feature descriptor

Unchanged from contract section 6, repeated so this file is readable alone:

```
Feature
  id             String    stable, lowercase, dotted, never renamed
  label          String    human, title case, what the sidebar shows
  group          Enum      command | workspace | intelligence | ambient | system
  requires       [Capability.id]
  optional       [Capability.id]
  steps          [SetupStep.id]
  tier           Enum      core | labs
```

Reading the columns:

- **requires** is an AND list. Every id in it must resolve or the feature is `needs-setup`.
- **optional** means absence costs part of the surface and nothing else. The feature is
  `degraded` and still fully usable.
- **steps** are prerequisites that are not capabilities, per contract section 3.1. They
  render in the same setup card.
- **tier** `labs` means real but rough, shown behind a Labs section with an honest status
  line. Rough is never a reason to cut.

Two encoding rules this registry follows, both chosen deliberately:

**Over-declare `requires` rather than under-declare it.** A false `needs-setup` costs the
user one card they can dismiss by configuring something they did not strictly need. A false
`ready` costs them a feature that fails at the moment they use it, which contract section 3
calls a defect outright. Where the two were the only choices, this registry took the first.

**Do not declare another feature's capabilities.** A surface that can jump to another
surface does not inherit its requirements; the destination renders its own setup card. Left
unchecked that rule's absence makes every feature require every capability.

---

## 4. What ships and what does not

Cut is reserved for two things, and rough is neither of them:

- **Personal.** Its only purpose is operating one person's specific businesses, or it is
  wired to one person's private analytics project, or it is pinned to one machine on one
  private network with nothing generic underneath.
- **Harmful.** Voice-triggered cold outreach to a named person at a named company is a spam
  tool. An assistant persona that decides whether to disclose that a human did not write a
  message is impersonation.

Everything else ships. A feature that is pinned to one person's disk but whose *purpose* is
product is a portability defect, not a personal feature: it ships at `labs` and the pinning
becomes a change request. Feature Review and Self-Upgrade are both in that category.

---

## 5. THE REGISTRY

33 rows. `none` means an empty list.

### 5.1 Group `command`

| id | label | tier | requires | optional | steps (blocking) | optionalSteps (degrading) |
|---|---|---|---|---|---|---|
| `home` | Home | core | none | `perm.calendar`, `key.anthropic`, `key.elevenlabs` | none | none |
| `reactor` | Reactor | labs | none | `perm.microphone`, `perm.calendar`, `key.elevenlabs`, `endpoint.imap` | none | none |
| `chat` | Chat | core | 1 of {`key.anthropic`, `endpoint.ollama`} | `key.slack`, `key.notion`, `key.resend`, `key.brave`, `perm.microphone`, `key.elevenlabs`, `perm.screen_recording`, `perm.accessibility`, `perm.automation`, `perm.calendar`, `perm.contacts`, `endpoint.imap`, `key.replicate`, `endpoint.media_service` | none | `step.agent_cli_installed`, `step.youtube_transcripts_enabled`, `step.terminal_sessions_explained` |
| `jax.command` | Jax Command | labs | none | `key.anthropic`, `perm.full_disk_access` | `step.agent_cli_installed`, `step.corpus_sources_confirmed`, `step.terminal_sessions_explained` | none |
| `approvals` | Approvals | core | none | none | none | none |
| `cognition.map` | Cognition Map | core | none | `key.anthropic` | none | none |
| `feature.review` | Feature Review | labs | none | `key.anthropic` | none | none |
| `projects` | Projects | core | none | `endpoint.registry` | none | none |
| `tasks` | Task Stack | core | none | none | none | none |
| `agents` | Agents | labs | none | none | `step.agent_cli_installed`, `step.terminal_sessions_explained` | none |

**Notes.**

`approvals` is a NEW row, added 2026-08-10 resolving CR-25, and it is the only id in this
registry that does not correspond to an existing sidebar tab. Three shipping paths enqueue
into the decision gate (`Jax/JaxToolGate.swift:147`, `Jax/Autonomy/GoalPursuitEngine.swift:394`,
`Email/Imap/EmailTool.swift:200`, with a fourth documented at `Jax/CommsPersona.swift:145`) and
every renderer of that queue lives under `Jax/`, including the cut Jax HQ tab. So the queue
fills and nothing in the shipping build can show it, which is the "setting that silently goes
nowhere" CR-25 names. The alternative ruling, forbidding anything to enqueue, was refused
because it would mean deleting the safety gate that three call sites use to avoid acting
without asking, which is the wrong direction to resolve it.

It declares no capabilities deliberately. The queue is local and needs none, so the surface is
`ready` on a clean install and simply shows nothing, which is the honest state for an empty
inbox.

`home` renders on a clean install with an honest empty state (`Home/HomeView.swift:352-378`)
and every capability it touches degrades rather than blocks: no calendar yields a "connect a
calendar" line (`Home/HomeBriefingModel.swift:144-146`), no model key yields a deterministic
spoken brief (`Jax/BriefingEngine.swift:545-548`), no voice key yields the system voice.
`HomeBriefingModel.swift:168` defaults the greeting to a hardcoded first name and
`BriefingEngine.swift:520-530` folds a private ads line into the brief; both are strip work,
not capability work.

`reactor` is `labs` because half the instrument does not survive section 6. Three of its six
panels are private (`Reactor/ReactorView.swift:188`, `:199`, `:221`) and one of its four
rings goes with them: the spend ring is fed by a query that needs a personal analytics read
key (`Empire/LLMSpend.swift:573-590`), which no capability in the closed vocabulary can
name. `endpoint.imap` is declared because the mail ring and the mailbox panel read the IMAP
store (`Email/Imap/MailStore.swift:45`), and a dim ring at inbox zero is indistinguishable
from a ring with no mail server. Ship blocker: opening the tab calls `requestAccess()`
unprompted (`ReactorView.swift:118`), so a stranger gets an operating system dialog on tab
open instead of a setup card.

`chat` carries thirteen optional capabilities because its surface is a bag of tools. The
tool surface is larger than one array: `ChatService.swift:657-1105` holds 36 inline
definitions, and `:943-948` plus `:982-995` append fourteen more bundles, which is where
calendar (`Calendar/CalendarTool.swift:80-97`), contacts
(`Contacts/ContactsService.swift:72`), mail (`Email/Imap/EmailTool.swift:31`) and image
generation (`Creative/CreativeEngine.swift:516`) live. `perm.accessibility` is declared
because `ChatService.swift:2157` puts the active window title in the prompt, which is
literally that capability's remediation text. `key.anthropic` stays required, and a
discovered local server does **not** replace it: `Backend/ModelRegistry.swift:40-41` gates
local routing on offline mode AND discovery, and offline mode ships false
(`Models.swift:712`, `:820`). Section 8 asks for a rule that a tool whose capability is
missing is simply not offered to the model, which would collapse thirteen inline notes into
zero and kill the call-site error strings at the same time.

`jax.command` defaults to a genuine no-op: `Jax/Autonomy/GoalPursuitEngine.swift:47-50`
simulates, and the only side-effecting path starts a swarm job (`:397-405`). It is `labs`
because live dispatch needs the coding agent CLI, now `step.agent_cli_installed` and declared blocking on this row, and because its memory panel
counts a corpus stored on a hardcoded private host on a fixed port
(`Memory/RAGClient.swift:82`), so the panel cannot populate for anyone else even with
consent in place. Its middle autonomy mode queues into an approvals gate whose only renderer
is cut; see section 6.

The eight ingesters behind that panel (`Jax/Corpus/`) are the same class of portability
defect as `feature.review`, not a second personal feature. Two string literals pin the Gmail
source to one person's account (`Jax/Corpus/GmailSentIngester.swift:21` and `:33`), so on
anyone else's machine it matches no account and silently indexes nothing, reporting success.
A third put that address in user-facing copy (`Jax/Corpus/CorpusIngester.swift:71`) and was
removed 2026-08-09. The fix is a configured address, not a cut.

Two things measured here that the row would otherwise be read as implying, both refuted.
Ingestion is NOT automatic: the only trigger is the `~/.grux/fire-jax-ingest` file
(`GruxApp.swift:2518-2526`), and launch runs `bootstrap()`, which calls `refreshPermissions()`
and nothing else (`Jax/Corpus/CorpusCoordinator.swift:149-151`), so probing a source reads
its permission rather than its content. A stranger who launches Grux does not have their
iMessage history, Notes or voice recordings read. That matters more than the hardcoded
address and is the thing to re-check if this subsystem is ever wired to a schedule.

`cognition.map` is the cheapest honest `core` row in the group. The confidence gate runs
heuristic-only on every turn with no network call and writes the trace before any request
goes out (`ChatService.swift:130-140`), so the map fills with no key, and it refuses to draw
the constellation when there are no real nodes (`Jax/Cognition/CognitionMapView.swift:57-77`).
Its retrieval is on-device (`SemanticMemory.swift:4-12`), not the private vector host.

`feature.review` is a portability defect, not a personal feature: its purpose is governing
what the app's own upgrade engine merges. Two absolute string literals pin it to one disk
(`Jax/Review/FeatureReviewEngine.swift:77`, `Jax/Review/PostMergeWatch.swift:44`), and its
pitch generator injects the owner persona verbatim as a system prompt (`:161`), which is a
ship blocker shared with `chat`. Approve deliberately writes a merge intent for a guarded
script rather than running git in process (`:228-235`).

`projects` is `core` because its local half needs nothing: `GruxShellCore/ProjectsIndex.swift:141-148`
scans three plain home-relative roots for a project marker file. `endpoint.registry` is
optional because absence costs the remote half only. One correction the registry must carry
into implementation: the tab is not read-only against the registry, `ProjectsView.swift:42-46`
POSTs a status change, while the capability's remediation reads as a read-only pointer.

`tasks` is entirely local and is the reference `ready` row. Its empty capability list once
carried a warning that analytics was not actually off, because the tree held a hardcoded write
token, a hardcoded personal address as the distinct id, and a switch defaulting to true in both
the initialiser and the decoder. **Corrected 2026-08-15:** the telemetry module is deleted, the
files named in that warning no longer exist, and contract section 4's end state is implemented
by removal rather than pending. The warning is kept as a record because an empty capability
list is still not on its own evidence that anything ships off.

`agents` has an empty `requires` because what it truly needs is a setup step and not a capability: `step.agent_cli_installed`, declared blocking on this row. The spawn path strips model keys before exec, so a key would be the wrong shape.
Everything it monitors depends on a coding agent CLI resolved from an environment variable,
then a fixed path list, then the bare name (`GruxAgentCore/SwarmWorker.swift:81-99`), and
the tab cannot start work by itself (`AgentTools.swift:19`, `AgentService.swift:115`). Its
crash recovery is careful (`AgentService.swift:50-70`) and its account rotation opens an
interactive terminal sign-in (`AccountSwitcher.swift:19-23`), which is the second reason it
is `labs`.

### 5.2 Group `workspace`

| id | label | tier | requires | optional | steps (blocking) | optionalSteps (degrading) |
|---|---|---|---|---|---|---|
| `mailbox` | Mailbox | core | `endpoint.imap` | `endpoint.microsoft_graph` | none | none |
| `mailbox.compose` | Compose and send | labs | `key.resend`, `endpoint.imap` | none | none | none |
| `calendar` | Calendar | core | `perm.calendar` | none | none | none |
| `notes` | Notes | core | none | none | none | none |
| `documents` | Documents | core | none | `key.anthropic` | none | none |
| `contacts` | Contacts | core | `perm.contacts` | none | none | none |
| `schedules` | Schedules | core | none | `perm.notifications` | none | `step.agent_cli_installed`, `step.terminal_sessions_explained` |
| `folders` | Folders | core | none | 1 of {`key.anthropic`, `endpoint.ollama`} | none | none |

**Notes.**

`mailbox` is a real multi-account IMAP client with its own socket layer and a unit-tested
parser: connect, login, SELECT, SEARCH UNSEEN, FETCH at
`Email/Imap/InboxSyncEngine.swift:104-124`, passwords in Keychain and never in the JSON
(`Email/Imap/EmailAccountStore.swift:130`, `:188-218`). A sweep of the module for other
network clients, model keys and permission APIs found none, so `endpoint.imap` alone is
right. With no account it renders an empty state rather than throwing
(`Email/Imap/MailboxView.swift:49-50`). Two house rule defects to fix before ship:
`MailboxView.swift:318` and `:325` format with a 24 hour clock, which must read `7:30 PM`,
and `:319` and `:326` pin one US timezone where the system locale belongs.

`mailbox.compose` has an empty `requires` **only because the vocabulary has no id for what
it needs**, and that is the whole reason it is `labs` rather than `core`. Its one send path
reads a hosted transactional email key from Keychain (`Email/ResendClient.swift:64-65`) and
the compose control is not gated on it in any way (`MailboxView.swift:117-119`), so today a
missing credential surfaces as a runtime failure instead of a setup card.

**RESOLVED 2026-08-09, see 7.2.** The row now requires `key.resend` and `endpoint.imap`.
Both are needed and declaring only the first was a defect: the send path guards on a
configured account and returns "No account configured." inline before the transport key is
ever used, so a user who pastes a send key and nothing else would resolve every declared
capability, render `ready`, and hit an error string.

**The SMTP rebase this paragraph used to recommend was refuted and must not be attempted on
its old reasoning.** There is no SMTP client in the tree, and the account model stores no
submission port, so rebasing on the credentials the account already holds would resolve
PRESENT for a user with inbound settings only and then fail at send. That is a worse
failure than the one it was meant to fix, because it converts a visible gap into a
confident wrong answer. Building a real SMTP client remains a legitimate future direction;
it needs its own capability id and its own request.

`calendar` is a working read and write surface over the system calendar database with ICS
import and export that is unit tested. `perm.calendar` is genuinely required, not optional:
`Calendar/CalendarView.swift:28-29` swaps the entire body when the grant is absent and every
read in `Calendar/CalendarService.swift` is guarded (`:81`, `:96`, `:109`). It already fails
soft; it needs to render the contract's setup card instead of its own bespoke one. Cleanup:
five sites hardcode one US city as the parsing and rendering timezone
(`Calendar/CalendarTool.swift:18`, `:225`, `:237`, `:255`, `:292`).

`notes` is the cleanest zero-capability row in the build: list, markdown editor, search,
pin, tags, one JSON file with debounced autosave (`Notes/NotesStore.swift:17-24`), covered
by tests. The one call that looks like a model dependency, `NotesStore.swift:129`, is a pure
static string helper. Do not add `key.anthropic` to this row. Cleanup: `Notes/NotesTool.swift:124`
hardcodes a timezone, and `:12`, `:18`, `:26`, `:41` carry the owner's name and a real brand
token as worked examples.

`documents` is the textbook `degraded` case. Library, editor, autosave, version history with
restore, PDF preview and form-field inspection all work unconfigured; only the assist
popover reads a key (`Documents/DocumentEditorView.swift:387-390`). Pre-ship blocker,
larger than it looks: `:423` post-vets every rewrite through a grounding gate, and
`Jax/Grounding/ProductCatalog.swift:111-119` seeds a real commercial catalog with prices
into the user's own data directory on first launch. Deleting the seed is necessary and not
sufficient, because `Jax/Grounding/FactGuard.swift:113-121` detects the brand from hardcoded
literal tokens rather than from catalog contents. Note also that
`grux.grounding.catalog_path` is read nowhere in the tree and the path is hardcoded at
`ProductCatalog.swift:104-109`, so wiring the key the contract already reserves is real work
rather than a rename.

`contacts` is a read and write directory over the system address book kept fresh by the
change notification. The grant gates the whole surface: `Contacts/ContactsView.swift:59-60`
swaps the list and `:94`, `:104` disable the controls. Speaker linking
(`Contacts/SpeakerContactLink.swift`) adds no capability; it has nothing to link until a
voice has been enrolled, which is a data dependency, and modelling it as optional would show
a degraded note to every user who has simply never recorded a meeting.

`schedules` is the recurring blueprint host contract section 0 names, so it has to ship.
Authoring, persistence and the ticking scheduler all work unconfigured and are unit tested.
`perm.notifications` is optional and the proof is tight: the banner wraps only the
notification (`CommandsV2/UserCronStore.swift:299-309`), so without the grant the job still
fires. What a job needs at fire time belongs to the thing it fires, which is why
`key.anthropic` is deliberately absent: the agent-prompt action spawns a local command line
binary and reads no key at all (`CommandsV2/CommandV2AgentBridge.swift:19-20`,
`GruxAgentCore/SwarmWorker.swift:81-99`), so that remediation would tell the user to paste a
key this path never reads.

`folders` organises meeting records, not files: `Folders/FoldersView.swift:387` says so and
`Folders/FolderStore.swift:121-135` reassigns member meetings on delete. Everything works
locally; only the auto-file button reads a key, and it already degrades visibly by design,
disabling itself and explaining why (`FoldersView.swift:402-403`).

**Corrected 2026-08-10 under CR-6.** This row declared `key.anthropic` alone as optional,
which printed a "add your Anthropic key" note at a user whose auto-file button already
worked. `Folders/FolderClassifier.swift:28` refuses only when the local route is off AND the
key is empty, and `LocalLLM.swift:333-351` routes to a configured local server first, falling
back to the cloud only on error. Either capability is sufficient, so the edge is now a group
of 1 of 2 and the note fires only when neither is present. Two cleanups:
`LocalLLM.swift:333` reads a config default that `Models.swift:708` and `:816` hardcode to a
private host, and `LocalLLM.swift:351` reports to the hardcoded analytics token.

### 5.3 Group `intelligence`

| id | label | tier | requires | optional | steps (blocking) | optionalSteps (degrading) |
|---|---|---|---|---|---|---|
| `research` | Research | core | `key.brave`, `key.anthropic` | none | none | none |
| `skills` | Skills | core | none | none | none | none |
| `compare` | Compare | core | `key.anthropic`, `endpoint.ollama` | none | none | none |
| `cookbook` | Local Models | core | none | `endpoint.ollama` | none | none |
| `creative` | Media Studio | labs | `key.replicate` | `endpoint.media_service`, `endpoint.registry` | none | none |
| `design.studio` | Design Studio | core | `key.anthropic` | `endpoint.ollama`, `endpoint.registry` | none | `step.agent_cli_installed`, `step.terminal_sessions_explained` |

**Notes.**

`research` is a complete pipeline, not a stub: planner, parallel search and fetch, per angle
notes with citations, source dedupe and renumbering, one synthesis call, a persisted report
and a live UI, with prompt injection defence at `Research/DeepResearchEngine.swift:273` and
both prompts labelling fetched bodies as untrusted data. **RESOLVED 2026-08-09, see 7.2. The row now requires `key.brave`. The paragraph below is retained for its reasoning and no longer describes the row.** ~~This row is knowingly incomplete
and must not be treated as settled.** The pipeline's FIRST hard gate is a web search key
(`:68`, checked before the model key at `:72`) and the closed vocabulary has no id for it,
so as written this row renders `ready` for a user holding only a model key and their first
run fails with a text error, which contract section 3 forbids. The request in section 8 is
blocking for this row.

`skills` is one of the three blueprint hosts, and it needs nothing: local JSON CRUD
(`Memory/Hybrid/SkillStore.swift:36`) plus a human readable folder mirror
(`Memory/Hybrid/SkillFolderBackend.swift:1-22`), no network and no key anywhere in the view.
`key.anthropic` was deliberately **removed** from this row's optional list. The consumer at
`ChatService.swift:502` does not read that key; it calls `ModelRegistry.resolvedRouting`,
and `Backend/ModelRegistry.swift:39-47` resolves to a local backend when offline mode is on
and a server exists, with `apiKey()` returning a local placeholder. A user running entirely
on a local server consumes skills perfectly and would have carried a permanent degraded note
describing a lesser path they are not on. Naming one provider for a provider agnostic
consumer is a false `degraded`.

`compare` declares an AND that is not quite the truth, and the alternative was worse.
`Compare/ComparisonService.swift:37-62` yields exactly ONE contender from a model key plus
one per local model tag, and `:72-77` refuses below two. So a model key alone is a
permanently broken `ready`, which section 3 forbids, and the AND at least errs toward a
recoverable `needs-setup`. The tab's own copy is already this honest
(`Compare/CompareView.swift:105-108`). One residual hole named for the record: a model key
plus a reachable local server holding zero pulled models satisfies both declared
capabilities and still refuses, because reachability is not model availability.

`cookbook` is the clearest legitimate `degraded` example in the build. The catalog, the
hardware profile and the fit scores are pure local computation and render on a machine with
nothing installed: `LocalModelCookbook/CookbookView.swift:31-42` detects hardware
synchronously and only then kicks the server refresh. A missing binary is surfaced as UI
text (`:128`, `OllamaManager.swift:175-177`), never a throw, and the manager never kills a
server it did not start (`OllamaManager.swift:8-11`).

`creative` is `labs`, not cut, because its purpose is generic media generation and its
default path is a hosted provider behind a key the contract already owns:
`Creative/CreativeEngine.swift:1453-1474` routes every non product-in-scene request to that
provider first and treats the private service as the fallback. It is not `core` because the
private hosts (`:516-519`), a copy step from a named private machine (`:1019-1032`), a local
wrapper on a fixed port (`:508-509`) and four hardcoded owner brands (`:226-241`, `:310-336`)
all have to come out first. `endpoint.registry` is optional because stripping the curated
brands leaves the chip strip fed entirely by the registry (`:275-302`) with one untagged
bucket and everything still running. This is the only feature in the group that reaches the
hardcoded analytics token without going through a model backend, so contract section 4 has
to be applied by hand here.

`design.studio` is roughly 7,400 lines with five test files, and its missing-key path
already renders as guidance rather than an error (`DesignStudio/DesignStudioEngine.swift:369-372`),
which is what section 3 demands. `key.anthropic` is genuinely required rather than a
stand-in: `DesignStudio/DesignStudioModels.swift:126` pins the provider string and
`ModelRegistry.swift:78-79` maps that case straight to the key. `endpoint.registry` is
declared because `DesignStudio/DesignSystems/BrandSystemGenerator.swift:67` fetches a brand
roster through the private registry client and `DesignSystemTools.swift:86` calls it with no
injected roster, so once the private hosts and the seeded brands come out the generator
would silently produce nothing. Declaring it buys a remediation instead of a silent empty
result. It is optional rather than required because a hand written design document can be
imported (`DesignSystems/DesignSystemStore.swift:119-136`) and the core loop never touches
the registry. Its third execution route needs an external CLI binary, which is declared by
nothing on purpose, because the code already refuses cleanly and names the two alternatives
(`DesignStudio/DesignStudioIntegration.swift:203-208`).

### 5.4 Group `ambient`

| id | label | tier | requires | optional | steps (blocking) | optionalSteps (degrading) |
|---|---|---|---|---|---|---|
| `meetings` | Meetings | core | `perm.microphone`, `perm.system_audio` | `key.anthropic` | `step.recording_consent_acknowledged`, `step.speech_model_downloaded` | none |
| `speakers` | Speakers | core | none | none | none | none |

**Notes.**

`meetings` is a complete working loop: a system audio stream plus a separate microphone
capture, 16 kHz mono mixing, on-device transcription, speaker clustering, a crash safe audio
write-ahead log, and a large archive UI with folders, search and a tabbed detail pane. Both
permissions are hard gates resolved from the system rather than guessed
(`Meeting/MeetingCaptureService.swift:199-203` and `:213-220`, `MicController.swift:39-45`).
After the two grants it needs no key at all, because transcription is local; the model key
buys the summary, the action items and auto-filing, and the UI hides the filing action
rather than failing (`MeetingsView.swift:115`, `MeetingSummarizer.swift:26-29`).
`perm.screen_recording` is deliberately NOT declared alongside `perm.system_audio`, because
they resolve to the same operating system grant and its own remediation points at the same
pane, so declaring both prints the same instruction twice.

Three things this row does not encode and must not be read as endorsing. First, the very
first capture on a fresh machine downloads a speech model
(`Ambient/AmbientListener.swift:246-266`) and reports failure as a raw error string
(`MeetingCaptureService.swift:167-171`); that is a missing setup step, requested in section
8, not a reason to demote a loop that works every run after it. Second, recording a call
captures other people, and nothing in the closed step set lets the feature block until the
user acknowledges that; also requested. Third, `MeetingSummarizer.swift:36-40` hardcodes the
owner's first name three times inside the model system prompt, so a stranger's summaries are
written in and about the wrong person. Strip work, one line each: the private host
transcription offload (`WhisperQueueClient.swift:63-65`, called at
`MeetingCaptureService.swift:464-482`) is already fail-soft and gated on a flag, so deleting
it costs nothing. macOS 13 or older is `unavailable`, not `needs-setup`
(`MeetingCaptureService.swift:36-38`).

`speakers` binds one local JSON store (`SpeakerProfileStore.swift:39-44`) and computes cross
meeting statistics locally (`SpeakersView.swift:296-323`). A sweep of the view for keys,
model clients, network, contacts and telemetry returns nothing, so it can never be anything
but `ready`. It earns its own row over folding into `meetings` because it owns a distinct
store, its own rename and delete surface, and statistics no other tab renders. Enrollment is
not live-only: a second enroll strip is built from the frozen cluster snapshot on any stored
meeting (`ConversationDetailView.swift:114`, `:125-131`, writing at `:858`), which makes the
roster reachable after a call ends. Cleanup: `SpeakersView.swift:387-392` pins the date
formatter to one timezone, so every timestamp renders in someone else's clock. A tab that
can only ever be `ready` can still be wrong.

### 5.5 Group `system`

| id | label | tier | requires | optional | steps (blocking) | optionalSteps (degrading) |
|---|---|---|---|---|---|---|
| `commands` | Commands | core | none | `perm.automation`, `key.anthropic` | none | none |
| `workflows` | Workflows | labs | none | `perm.notifications` | none | `step.agent_cli_installed`, `step.terminal_sessions_explained` |
| `social` | Social | labs | none | `key.telegram` | none | none |
| `focus` | Focus log | core | `perm.screen_recording`, `key.anthropic` | `perm.accessibility`, `perm.notifications` | `step.first_frame_reviewed`, `step.capture_exclusions_confirmed` | none |
| `terminal.focus` | Terminal Focus | labs | `perm.screen_recording` | `perm.automation` | `step.terminal_focus_hook_installed` | none |
| `self.upgrade` | Self-Upgrade | labs | none | none | `step.agent_cli_installed`, `step.terminal_sessions_explained` | none |
| `integrations` | Integrations | core | none | none | none | none |
| `integrations.webhooks` | Outbound Webhooks | core | none | none | none | none |
| `jax.hq` | Jax HQ | labs | `endpoint.imap` | `key.anthropic`, `key.resend` | none | none |
| `meta.ads` | Meta Ads | labs | none | `key.anthropic`, `key.telegram` | none | none |
| `domains` | Domain monitor | labs | `key.godaddy` | none | none | none |
| `phone` | Phone companion | labs | none | `key.elevenlabs` | `step.phone_paired` | none |
| `settings` | Settings | core | none | none | none | none |

**Amended 2026-08-26, CR-33. `chat` requires one of the Anthropic key or a local
model, not the key specifically.**

The row said `requires: key.anthropic` with `endpoint.ollama` merely optional, so a user
running a local model and holding no key saw Chat permanently marked needs-setup and was
handed a setup card telling them to buy a credential they had decided not to buy. The app
already disagreed with its own registry about this: `Chat/ChatReadiness.swift` treats a
routed local model as ready, and its comments say at length why offering only "add a key"
would turn a free path into an invisible one. Two components answering the same question
differently is drift whichever one is right, and here the registry was the wrong one.

Filed alongside the onboarding change that made the disagreement reachable at all: gate 1
could not be left without an Anthropic key, so until now no user could arrive in the
local-only state this row describes. Fixing one without the other would have moved the wall
rather than removed it.

This is the first row to use the `anyof` relation from contract section 6, which the
contract checker has understood since it was written and which nothing had needed until
now. Both ids stay in the `requires` cell so the row-by-row comparison in
`FeatureRegistryContractTests` still sees them; the `min of` prefix carries the one thing
an id list cannot, which is how they combine. Writing the ids anywhere else would have put
them where that test cannot look, which is the exact drift it exists to catch.

**Amended 2026-08-17, CR-31. Three false capability claims removed, and `social` gains
the row it never had.**

Filed after measuring every `key.` capability against the code that would read it. Three
rows claimed a credential nothing loads, and because the Settings credentials list is
generated from the contract rather than hand written, each claim put a live paste field in
front of a stranger for a key that goes nowhere. A powerful token sitting unused in a
Keychain is risk with nothing on the other side of it.

- `chat` dropped both scalar provider keys, deleted from the contract by CR-34. There is no `api.openai.com` call
  anywhere in the tree and neither Keychain slot is read. OpenRouter IS reachable, through
  the generic custom-endpoint store, which keeps its own per-endpoint key, so the dedicated
  slot was a second place to type a credential that nothing would ever load.
- `workflows` dropped `key.appstoreconnect`. App Store Connect is genuinely used by
  `ASCStateMonitor`, but it mints its ES256 JWT from a keyId, issuerId and `.p8` path in a
  ship-config file, never from the Keychain slot this capability names.

`key.github` and `key.reddit` were already claimed by no row and are unchanged here.

**The capabilities themselves are NOT deleted, and that was the first plan.** All five are
declared by blueprints (`pr-digest`, `mention-monitor`, `ship-ios`, `portfolio-dashboard`),
which are the vocabulary for units a user can point Grux at. `blueprints/index.md` states
plainly that they are specification only and nothing there is implemented, so a capability
they name is honestly aspirational rather than dead. Deleting it from section 1 would break
ten specs to fix a Settings list. What was wrong was the REGISTRY claiming a shipping
feature needs it.

`social` is a NEW row. It is a real tab, wired to `SocialView` and `capabilityGated("social")`,
and it had no registry row at all, so the gate no-opped and it could not be marked labs.
`key.telegram` is the one credential the surface actually reads
(`SocialOps/SocialOpsCoordinator.swift:310`), and it is optional because the tab renders
without it.

**Notes.**

`commands` works unconfigured: the editor, persistence, search, drag reorder and the direct
test run path all execute without a key (`CommandsView.swift:589`), across fifteen action
kinds (`VoiceMacros.swift:17`). `perm.automation` and not `perm.accessibility` is the right
declaration, and the code comment that says otherwise is wrong: the window tiler's header
claims it positions windows through the Accessibility API while the implementation sets
bounds through AppleScript only, with no AXUIElement call in the file. `key.anthropic` is
optional because macros run from the UI without it and its absence costs only the
assistant-triggered path (`ChatService.swift:839`). `key.elevenlabs` is deliberately absent:
`grux.voice.tts_provider` already defaults to the system voice, so the built-in voice is the
default path and not a degradation. Two ship items: three seeded macros are personal
(`VoiceMacros.swift:837`), so reseed generically or ship empty, and two action kinds execute
arbitrary local commands with no approval gate, which deserves an honest line in the UI.

`workflows` is the multi-step blueprint host, and the engine is `CommandsV2/`, not a module
called Workflows. `perm.notifications` is declared because every milestone phase transition
posts a banner (`CommandsV2/CommandV2PhaseNotifier.swift:122`), so without it a run completes
silently while still running, which is exactly `degraded`. It is `labs` because six of its
eight shipped definitions are app pipeline flows, because the agent rail depends on an
external CLI, now `step.agent_cli_installed` and declared degrading on this row because 2 of the 8 shipped definitions carry no agent phase, and because several definitions cannot run for a stranger at all: a
capture definition queries a vector store on a hardcoded private host
(`CommandV2Engine.swift:835` into `Memory/IdeaQueue.swift:4`, fail-soft but pointed at a
machine nobody else can reach), an audit definition defaults its rubric to an absolute path
in the owner's cloud drive (`CommandV2Engine.swift:801`), one definition embeds the owner's
directories and real product names in an agent prompt (`CommandV2Definitions.swift:214`), and
one drives external scripts that do not exist in the repository. The hardcoded publishing
key fallback (`CommandsV2/IOSDispatcherV2.swift:121`) must be replaced by `grux.asc.p8_path`,
which the contract already owns.

`focus` is the feature contract section 5 was written for, so it is the only row carrying
setup steps, and it carries both. `perm.screen_recording` and `key.anthropic` are both truly
required because both judge paths capture a frame and both call the model with the key read
directly (`FocusWatcher.swift:213`, `:509`, `:533`). `perm.accessibility` is optional because
without it the window title is empty and classification falls back to the app name
(`ActiveApp.swift:24`); `perm.notifications` is optional because the loop still classifies
and logs, only the banner is lost (`FocusWatcher.swift:364`). The steps are not decorative:
`grux.capture.first_frame_reviewed` gates the whole loop regardless of every other
capability, per contract section 5.4. Known gap: the banner shows the user three settings
that have no key in the namespace, requested in section 8.

`terminal.focus` is real and polished inside its niche, a floating overlay with task list,
activity trail and stuck detection for up to four surrounding coding sessions.
`perm.screen_recording` is required because the corner mapping keys off window titles and
titles are gated behind that grant (`TerminalWindowMapper.swift:6`, `:49`,
`TerminalFocusState.swift:210`). `perm.automation` is optional, not required, because the
settings pane lets the user pin a session to a corner by hand off the file-based index, so
losing the scripted tty and title lookup (`TerminalWindowMapper.swift:442`,
`TerminalFocusState.swift:864`) degrades auto-detection rather than breaking the overlay. It
is `labs` because it works only for users of one specific coding CLI, is hardcoded to one
terminal app by process name, and earns its data by writing an executable hook into a third
party tool's directory and rewriting an entry in that tool's settings file
(`TerminalFocusState.swift:929`, `:943`). That write is consent-gated behind a button today
(`TerminalFocusSettingsView.swift:405`) and needs a real setup step; requested in section 8.
No image is ever captured, only window bounds and titles, so the capture privacy steps do
not apply here.

`self.upgrade` has the strongest test coverage in the build, ten dedicated test files, plus
genuine safety design: protected zones that refuse auto install (`Foundry/GruxUpdater.swift:204`),
a build green gate, a 24 hour crash watch with auto revert, and a quarantine tripwire.
`requires` is correctly empty: the only model key use in the whole subsystem is an audit
signal source that the live cycle never enables (`Foundry/SignalHarvester.swift:32`, called
at `Foundry/FoundryEngine.swift:187`), so declaring a key would show `needs-setup` for
something that never runs. It is `labs` because it cannot run without a source checkout and a
build toolchain the contract does not model, because two paths are pinned to one directory
layout (`FoundryEngine.swift:70`, `Foundry/LiveTreeTripwire.swift:21`), and because it starts
an autonomous self modifying scheduler at launch with no config gate (`GruxApp.swift:740`,
`Foundry/FoundryGovernor.swift:373`). That last one is the same class of decision as contract
section 4's analytics default and is requested in section 8.

`integrations` is the surface where credentials are entered, so it is never blocked by a
missing credential and is always `ready`. It is token paste rather than an OAuth redirect
that would need a shipped client secret, tokens go to Keychain and never to the config file
(`Integrations/SlackClient.swift:67`, `Integrations/NotionClient.swift:53`), and the copy
already names the exact scopes to create. The connectors behind it have no ids, so their
own `needs-setup` cannot be expressed anywhere and their chat tools
(`ChatService.swift:986`) fail at call time, which section 3 rules out. Requested in section
8.

`integrations.webhooks` is small, tested, signed and privacy conscious: HMAC over the
canonical body, exponential backoff, a per endpoint circuit breaker
(`Webhooks/WebhookManager.swift:40`), payloads carrying identifiers and display names only
and never prompts or run state (`:30`), and per webhook secrets in Keychain under dynamic
accounts rather than in the JSON (`Webhooks/WebhookStore.swift:111`). It needs nothing
beyond a URL the user types into its own UI, so it is `core` with no capabilities. Note the
mismatch it inherits: `endpoint.webhook_inbox` describes an inbound listener that
`WebhookManager.swift:34` states plainly is deliberately unbuilt, while the outbound
dispatcher that does exist has no id at all.

`settings` is chrome rather than a gated feature. It owns no capability, it is the
destination every remediation button jumps to, and it can never enter `needs-setup`, so its
state is pinned `ready`. It earns a row only so the sidebar has an entry. Two ship items live
here: the telemetry section whose copy names the owner's analytics project
(`SettingsView.swift:1034`) with the hardcoded token and personal distinct id behind it, and
a developer section (`SettingsView.swift:1001`) that writes two values into config with no
owning key in the namespace.

---

### 5.6 Feature dependencies

**Amended 2026-08-28, CR-35. `FeatureRow` gains `dependsOn`.**

A feature can be unusable because another feature is off, and no capability says so.
`speakers` is the case that forced this: it declares no requirement at all, because what it
needs is not a credential or a permission, it is Meetings actually running. With Meetings
off, Speakers is a working screen with nothing in it, and every capability-based check in
the app calls it `ready`. A person who picks Speakers and not Meetings has produced a
selection that cannot do the thing they asked for, and the four capability lists cannot
notice.

**Its own table, not a ninth column.** Section 6 of the contract already decided to keep the
section 5 table narrow, which is why an `anyOf` group is encoded inside the `requires` cell
rather than widening all thirty nine rows. These are FEATURE ids rather than capability ids,
so they could not share a capability cell even if that were wanted.

| feature | depends on | why |
|---|---|---|
| `speakers` | `meetings` | Speakers names the voices in a meeting. With Meetings off there is nothing to name, and no capability expresses that. |

Rules, enforced by `FeatureDependencyTests`:

1. Every id on either side is a real feature in this registry. A dependency on something
   that does not exist is a typo that would otherwise sit silently forever.
2. No cycles, including a feature depending on itself.
3. This table and the Swift `dependsOn` arrays match exactly, in both directions, which is
   the same row-by-row rule the rest of section 5 already lives under.

What a dependency MEANS to the user, per the settled onboarding decision: turning a feature
off whose dependents are still on must warn and offer to turn both off. It must never
silently disable the dependent, and it must never be impossible to express, because a person
is allowed to want a half-configured Grux while they think about it.


## 6. Cut from the open-source build

Six entries. Each is cut for one of the two reasons in section 4, and rough is neither.
Recorded here so the decisions are not relitigated, and so whoever executes the cut knows
what breaks.

### 6.1 `jax.hq`, Jax HQ, group `command`

**Cut: impersonation, and a brand-scoped autopilot for one person's businesses.** Two
independent rules land on it. The header states that the resolved assistant-versus-owner
comms persona is shown on each queued approval (`Jax/JaxHQView.swift:6-14`) and
`Jax/CommsPersona.swift:12-17` describes that disclosure split as locked behaviour. That is
the impersonation feature the open-source build removes. Its four lead sections are a brand
scoped support reply autopilot down to a hardcoded brand enum (`Jax/BrandFilter.swift:10`)
and a per brand live auto-send toggle (`Jax/JaxAutonomySection.swift:19`).

**Load-bearing consequence, not a footnote.** The approval queue's logic survives the cut
but its only user interface does not: a repository wide search finds it rendered at
`JaxHQView.swift:41` and nowhere else, while `Jax/Autonomy/GoalPursuitEngine.swift:394`, the
tool gate and the mail tool all enqueue into it. Cutting this tab strands the decision gate
with no human surface while three shipping paths still queue into it. The build needs a
neutral approvals surface, or those three paths must not queue. Section 8 asks the contract
to settle which.

### 6.2 `social`, Social, group `command`

**Cut: no feature underneath, and the service it fronts is posting automation for one
person's accounts.** The entire tab is 74 lines: one hardcoded private host URL
(`Social/SocialView.swift:16`) and a web view (`:20-43`). Off that host it renders a blank
page.

**Cut with it, and this half is the harmful one: voice-triggered cold outreach.**
`ColdEmail.swift:84-91` parses an instruction to draft outreach to a named person at a named
company out of speech, and `Ambient/AmbientListener.swift:622` fires it from the ambient
transcript. It drafts unsolicited mail to a named individual from overheard audio and sends
through a hosted transactional provider. **Remove the engine, not just the tab.**

### 6.3 `mailbox.support_triage`, Support triage and auto-draft, group `workspace`

**Cut: its only purpose is operating one person's specific businesses.** The inbox enum is
two literal commercial support addresses with per brand voices
(`EmailTriage/SupportDraft.swift:10-19`), and an account outside those two domains returns
nil and skips triage entirely (`Email/Imap/EmailAccountStore.swift:52-57`), so the whole path
is dead code for a stranger. The sync loop survives untouched: the hook is nil-safe by design
(`Email/Imap/InboxSyncEngine.swift:30`) and both call sites bail when the inbox is nil.

Three consequences for whoever executes it. The headless mail path written specifically to
read those two mailboxes goes too, and it has a second reference beyond the triage engine
(`GruxApp.swift:1223`), so both must be removed. Removing the module deletes three UI
affordances and not two: the triage pill (`Email/Imap/MailboxView.swift:208-222`), the draft
chips (`:291-307`) and the hide sender menu (`:276-283`). **Keep**
`EmailTriage/SenderSuppression.swift`, which is a generic mute list with no owner-specific
data; note that the menu is already a no-op in this tab because the message filter never
consults the suppression list (`MailboxView.swift:25-37`). A generic, user-configured
auto-draft feature could be built later. It would be a new feature, not this one.

### 6.4 `usage`, Usage, group `ambient`

**Cut: it is the read side of one person's private analytics project.** A hardcoded numeric
project id is pinned at `Usage/UsageQuery.swift:16` and every request path is built from it
(`:31`), against a personal read key held in Keychain (`:28-29`) that the vocabulary cannot
name. It is not a config seam away from working: a stranger who pastes their own key still
queries a project they do not own, the failure renders the status code and up to 400
characters of the response body straight into the UI (`Usage/UsageView.swift:41-42`), which
section 3 forbids outright, and the copy at `:93` tells the user their key will be used to
query someone else's named project. Even parameterised, analytics ships off by default, so
every counter would render empty for every user.

**Worth restoring later, from the other direction.** The genuinely reusable half is the cost
maths at `UsageQuery.swift:200-238`, which estimates spend from token counts against a rate
table. Source that from local call records instead of a hosted project and the key, the
endpoint and the privacy question all disappear at once. That is also what
`grux.cost.daily_ceiling_usd` needs in order to enforce its own state transition. Section 8
asks the contract to say so explicitly, so nobody reopens the hole from the read side.

### 6.5 `roadmap`, Roadmap, group `system`

**Cut: redundant when empty, personal when seeded.** The store is local JSON with zero
capabilities, so the cut is not about capabilities. Its seed hardcodes one person's build
plan and names his other products (`Roadmap/RoadmapStore.swift:206`, rewritten by `:191`).
De-seeded it is a second task store with nothing the Task Stack lacks
(`LaunchRootView.swift:393` already has projects, priorities, drag reorder and persistence),
and its only non-UI consumers are the personal clone surfaces. A fixable seed is not on its
own a cut reason; redundancy plus the coupling is.

**Whoever executes it must unpick four reads or the build breaks:**
`Jax/Autonomy/GoalPursuitEngine.swift:257`, `Jax/BriefingEngine.swift:426`,
`Jax/JaxHQView.swift:23` and `Jax/JaxCommandView.swift:40`. The mechanism is 264 lines and
revivable at zero cost if a generic roadmap is ever wanted.

### 6.6 `meta.ads`, Meta Ads, group `system`

**Cut: a client for a private always-on advertising engine that spends from one person's ad
accounts.** Three hardcoded base URLs, all private (`MetaAds/MetaAdsService.swift:16`), a
control plane that flips an account's autonomy mode (`:67`), a path that force scales a live
budget (`:109`), and comments naming the owner's brand and ad account
(`MetaAds/MetaAdsSnapshot.swift:7`). Every read and every write targets a host a stranger
cannot reach. 28 files, and nothing generic survives removing the hosts and the brands. The
kill switch and confirm gates are well built and worth remembering if ad tooling is ever
wanted, but that would be a rewrite against a provider API with user supplied credentials,
not a pruning job. There is no endpoint capability for it in the contract, which is
consistent with it not shipping.

---

## 7. Orphan resolution

`scripts/check-contract.py` reports a capability declared by zero features as dead
vocabulary. Seven capabilities had no feature declaring them before this file existed. Each
is resolved below in one of exactly two ways: a real feature declares it, or it should be
deleted. **No feature was invented to soak one up.**

| Capability | Resolution | Declared by | Evidence |
|---|---|---|---|
| The OpenAI scalar slot | **Deleted from the contract** | nobody, by design | Applied 2026-08-28, CR-34. This row's resolution was reversed by CR-31 and never updated: chat had stopped declaring it while this table still said it did. Named in prose rather than as an id, because the id no longer exists. |
| The OpenRouter scalar slot | **Deleted from the contract** | nobody, by design | Applied 2026-08-28, CR-34. This row's resolution was reversed by CR-31 and never updated: chat had stopped declaring it while this table still said it did. Named in prose rather than as an id, because the id no longer exists. |
| The analytics write key | **Deleted from the contract** | nobody, by design | Applied 2026-08-09. See section 7.1 for the reasoning. The id no longer exists in contract section 1.1, so it is named in prose here rather than as an id. |
| `endpoint.ollama` | Declared | `compare` (requires), `chat`, `cookbook`, `design.studio` (optional) | Local discovery and routing at `Backend/ModelRegistry.swift:39-47`; contender enumeration at `Compare/ComparisonService.swift:49-59`; pull and serve at `LocalModelCookbook/OllamaManager.swift`. |
| `endpoint.imap` | Declared | `mailbox` (requires), `chat`, `reactor` (optional) | `Email/Imap/InboxSyncEngine.swift:104-124` is the socket client; `Email/Imap/EmailTool.swift:31` is the chat tool; `Email/Imap/MailStore.swift:45` feeds the Reactor mail ring. |
| `step.first_frame_reviewed` | Declared | `focus` (steps) | Contract section 5.4 gates the loop on `grux.capture.first_frame_reviewed` regardless of every other capability. |
| `step.capture_exclusions_confirmed` | Declared | `focus` (steps) | Contract section 5.2 defines the two exclusion lists this step asks the user to confirm. |

Two honest caveats on the two provider keys, because "resolved" should not paper over them.
First, neither key is stored under the single scalar the namespace reserves for it: keys for
user added endpoints live in Keychain under a per endpoint account
(`CustomEndpointStore.swift:33`), so the two scalar provider keys that used to sit in the namespace
describe a shape the code does not have. Second, that route is reached only when the local
route is active (`ModelRegistry.swift:44-47`, `:75-93`), so today a user pointing at a hosted
compatible provider is travelling the path labelled local. Both are recorded as change
requests. Neither makes the declaration false: the capability is genuinely usable by `chat`
today, and its absence costs a routing option rather than blocking the feature, which is the
definition of optional.

### 7.1 Recommended contract deletions

**`key.analytics` should be deleted from contract section 1.1.**

No feature in this registry requires it and none optionally uses it, and that is not an
oversight to be fixed by finding it a home. Analytics is not a feature capability, it is a
global privacy switch, and contract section 2.5 already expresses it completely with
`grux.analytics.enabled`, `grux.analytics.write_key` and `grux.analytics.host`. Deleting the
capability changes nothing about a user's ability to opt in to their own project.

The reason not to park it on a feature instead is that the contract's own semantics make
every option wrong. As `requires` it would put a feature in `needs-setup` for a switch that
ships off by default, which is absurd. As `optional` it would render a permanent dismissible
note asking the user to add an analytics key, and contract section 3 says `degraded` exists
so a user knows they are getting the lesser path. Not reporting your usage to a third party
is not a lesser path. A nag would invert exactly the posture section 4 was written to
establish, on the one surface where the private tree already ships the opposite.

Two edits follow from the deletion, both in section 8: contract section 1.4 currently states
that `key.elevenlabs` and `key.analytics` are the only optional entries today, and that
sentence needs rewriting; and the note under section 1.1 explaining why `key.analytics`
exists moves to sit with the config keys.

**Mechanical note, so the green build is not mistaken for proof.** The reconciler counts a
capability as used when its id appears in the binding text of any document under `docs/`,
and the contract's own tables are such a text. Today the checker therefore reports clean
with all seven of these unresolved, and it will keep reporting clean after this file lands
whether or not the deletion is applied. **Naming `key.analytics` in the table above keeps the
build green; it does not remove the dead vocabulary.** The deletion has to be applied to
`docs/contract.md` by hand. Section 8 also asks for the orphan rule to count only feature
registry declarations, which is what everyone already believes it does.

---

## 7.2 Resolved change requests, 2026-08-09

CR-1 through CR-5 are RESOLVED and the contract is amended. Each was verified against the
code before acting, because prior work on this project was wrong repeatedly.

**CR-5, resolved AGAINST its own recommendation and against the stated expectation.**
CR-5 asked to delete the section 1.4 flag; the expectation was to demote it to a default the
per-feature list overrides. The amendment deletes it, and the reasoning is the deciding
factor rather than the preference: the manifest is two disjoint sets, so placing an id in
`requires` or in `optional` IS the statement of optionality, and no "declared but
unspecified" state exists for a default to fill. The state computation had already voted,
reading only the feature's two sets. CR-5's own premise was also stale, citing an analytics
capability deleted earlier the same day.

**CR-5 generalised, which CR-5 did not ask for.** `blocking: Bool` on `SetupStep` carried
the identical edge-versus-node defect and is removed the same way. Found while verifying
CR-3: `step.agent_cli_installed` genuinely blocks `agents`, and merely degrades `chat`,
which would otherwise render the default landing surface dimmed because 4 of roughly 50
tools cannot run. Steps now sit in `steps` when blocking or `optionalSteps` when degrading.

**CR-1, confirmed and adopted.** The web search key really is checked before the model key,
so a user holding only a model key computes `ready` and fails on first run, which contract
section 3 forbids. Added `key.brave` and `grux.research.brave_key`. One correction to CR-1:
the search key is the third gate, not the first, but the two before it default to pass, so
it is the first that fails on a default install and the conclusion is unchanged. Declared
required on `research` and optional on `chat`.

**CR-2, premise REFUTED, request adopted in a different form.** CR-2 proposed rebasing on
SMTP and called that a resolution needing no contract change. There is no SMTP client in the
tree, the compose path calls a hosted email API directly, and the account model stores no
submission port, so an SMTP rebase would resolve PRESENT for a user who supplied only inbound
settings and then fail at send. Added `key.resend` and `grux.mail.resend_key` instead, which
describes what the code actually does. Declared on BOTH surfaces CR-2 named: `mailbox.compose`
requires it, and `chat` carries it as optional because its `compose_email` tool calls the same
client. Compose also requires `endpoint.imap`, because the send path guards on a configured
account before the transport key matters.

**CR-3, confirmed, undercounted.** Six unhandled surfaces, not five: `jax.command` rides the
same rail, which this file already noted in its own narrative while omitting it from the
request. Absent tool produces exit 127 through a sandbox wrapper that always exists, so it is
a non-zero child exit rather than a thrown error. Modelled as a setup step and not a
capability, because the spawn path deliberately strips model keys before exec, so a key
remediation would ask for a credential that path removes. The remediation deliberately does
not say "on your PATH": PATH is the last resort in the resolver and a graphical app inherits
a bare launchd PATH.

**CR-4, confirmed, and the request understated it.** Added `grux.source.checkout_path`. The
verification found an absolute path containing a username, which is both a portability
blocker and a private-path leak, plus further hardcoded sites including a sandbox deny block
that the request missed entirely.

**CR-6, mechanism adopted, and BOTH of its examples were wrong in opposite directions.**
Resolved 2026-08-10. The contract gains `anyOf` and `optionalAnyOf`, two lists rather than
one flag because that is the shape CR-5 settled: optionality is a property of the edge,
expressed by which list the id sits in.

`folders` was right, and needed the relation on the OPTIONAL edge rather than the required
one. It declared `key.anthropic` alone, so a user with a local server configured saw a "add
your Anthropic key" note for a button that already worked. `FolderClassifier.swift:28`
refuses only when the local route is off AND the key is empty.

**`compare` was wrong and keeps its flat AND.** Its predicate is not a count of
capabilities: `ComparisonService.swift:37-62` yields one contender per model KEY plus one
per model TAG, and `:72-77` refuses below two, so the condition is
`(key ? 1 : 0) + tagCount >= 2`. A tag is not a capability. `min: 1` would permit a key
alone, which is the permanently broken `ready` section 3 forbids, and `min: 2` is the AND it
already has. Adopting CR-6 as filed would have made this row worse.

**The constraint is enforced, which is the part CR-6 did not ask for.** `1 <= min < count`
went into the contract with nothing checking it, so `scripts/check-contract.py` gained rule
8. Measured: `3 of {2 things}` and `2 of {2 things}` and `0 of {2 things}` all passed clean
before the rule and all fail after it.

## 7.3 Resolved change requests, 2026-08-10

CR-7 through CR-27 adjudicated. Every premise was checked against the code first, because
CR-1 through CR-5 had already been resolved while a work list still called them open.

**CR-9 was ALREADY DONE and would have been a day spent on nothing.** `declaring_files()` in
`scripts/check-contract.py` already excludes `contract.md` and `reconciliation.md` from the
usage scan, for exactly the reason CR-9 gives, and the checker prints "counted from the
feature registry".

**The dominant pattern: 15 of 21 requests were right about the problem and wrong about the
fix.** Filing a defect and designing its repair are different skills, and a change request is
evidence of the first only.

- **CR-7.** Refused the third `tier` value, took the second option. `tier` is a rendering
  property and a cut feature does not render, so `tier: cut` would force ids that must never
  be constructible into the closed FeatureID set. Cut rows live in the registry's own section.
- **CR-8.** Adopted the id mapping table into the contract verbatim.
- **CR-10.** One sentence: a feature declares at most one of `perm.screen_recording` and
  `perm.system_audio`, since both resolve to one macOS grant.
- **CR-11.** `degraded` now renders ONE note listing every missing optional item. `chat`
  carries seventeen optional capabilities, so the old per-item rule meant seventeen notes on a
  clean install.
- **CR-12.** Added `key.slack` and `key.notion`, three config keys, both optional on `chat`.
  Both clients throw at call time today and both are registered model tools.
- **CR-13.** `endpoint.webhook_inbox` and its three keys marked RESERVED. The listener is
  deliberately unbuilt.
- **CR-14, PARTIAL, and the request asked for two keys that do not exist.**
  `active_hours_start` and `active_hours_end` are real config fields and were added, defaults
  taken from `Models.swift:854-855`. `cooldown_minutes` is not a config field at all, it is
  `coachCooldownSeconds`, a per-mode constant. `use_vision` was DELETED from the app in an
  earlier round as a toggle that selected nothing. Adding either would have written fiction
  into a namespace whose whole promise is that only listed keys exist.
- **CR-15, CR-16, CR-17, CR-18.** Four setup steps added and declared. See section 7.4.
- **CR-19.** Added `grux.identity.user_name` and `grux.identity.assistant_name`.
  `HomeBriefingModel.swift:168` defaults a greeting argument to one person's first name.
- **CR-20.** Added `grux.foundry.enabled`, default false.
- **CR-21, and the request understated it.** Added the two developer keys. The code's default
  bundle prefix is the author's own reverse DNS root, a personal identifier compiled into a
  build meant for strangers, and it is NOT carried into the contract as the default.
- **CR-22 and CR-23.** Both were about singular keys describing plural storage, and both are
  resolved by deleting the scalars rather than annotating them. Mail is a multi-account store,
  so three singular keys became `grux.mail.accounts`. **Neither scalar provider key is read
  anywhere in the tree**: the only hit for those symbols is a redactor pattern in
  `Redaction.swift`, so they became `grux.model.custom_endpoints`. Section 2.4 now states that
  two domains hold one secret PER ITEM, keyed in Keychain by item id.
- **CR-24.** Ruled once: no analytics capability in either direction, read or write.
- **CR-25.** Added an `approvals` registry row, the only id here with no matching sidebar tab.
  Three paths enqueue into the decision gate and every renderer sits under the cut Jax HQ tab,
  so the queue fills and nothing shipping can show it.
- **CR-26.** `step.agent_cli_installed` added to `design.studio` optionalSteps. It degrades
  rather than blocks, because the code names two working alternatives.
- **CR-27.** Widened the `endpoint.registry` remediation to say the pointer is written to.

**One defect was introduced and caught by the checker while resolving these.** The CR-13 note
was first written directly under the `endpoint.webhook_inbox` row, which split the section 1.3
table in half and orphaned every endpoint below it. Sixteen unknown-capability findings, from
a prose insertion. Moved below the table.

## 7.4 The four consent steps, and what they are not

`step.recording_consent_acknowledged`, `step.speech_model_downloaded`,
`step.corpus_sources_confirmed` and `step.terminal_focus_hook_installed` were added together
because all four were filed as consent gaps, but they are not equally serious and the record
should say so.

**The recording one is real, and narrower than it first looked. Corrected 2026-08-10 after
checking intent rather than stopping at the mechanism.**

`start_meeting_capture` is a MODEL-CALLABLE tool (`ChatService.swift:982`, dispatch at
`:1530`) and `MeetingCaptureService.start()` gates only on not-already-capturing and macOS 14
or later. Read alone that looks alarming, and it was escalated that way. **It is deliberate
design and it is doing its job.** `MeetingTool.swift:4-6` says the adapter "keeps parity with
Grux's other tool adapters", and the tool description at `:13` instructs the model to act
proactively: "Call BEFORE the meeting starts or right at the top, we can't backfill audio that
already happened." Starting on the owner's spoken cue is the feature, not a leak in it.

The owner is also not kept in the dark. `MenuBarView.swift:201` fills the menu bar dot RED
for the duration, which is the same shape section 5.3 of the contract requires of the capture
loop, and it was already there.

So the remaining gap is not about the owner and not about who presses start. **It is that
every OTHER participant is captured and none of them is told, and nobody has ever been asked
to confirm they will say so.** `step.recording_consent_acknowledged` closes exactly that, once,
and deliberately does not touch the model's ability to start a capture. Removing the tool from
the model was considered and refused: it would delete the capability to buy a protection the
step already provides, and the people it protects are not the ones holding the mouse.

**Two were overstated when they were escalated.** Corpus ingestion is NOT automatic:
`CorpusCoordinator.bootstrap()` calls `refreshPermissions()` and nothing else, and ingestion
runs only from a deliberate `~/.grux/fire-jax-ingest` trigger. Terminal Focus is user
initiated: `installHook()` is reachable only from a button in Settings. Their real gaps are
narrower, that nothing confirms which corpus sources are included, and that a button reading
"Install Hook" does not mention it writes an executable and rewrites another tool's settings
file.

## 7.5 Resolved change requests, 2026-08-15

**CR-11, three integrations that were reaching the network with nothing declaring them.**
`key.telegram`, `endpoint.microsoft_graph` and `step.youtube_transcripts_enabled` are adopted
into the contract, and each is claimed by a row above. The full reasoning, including why the
class of each is what it is, lives in contract section 1.1 under CR-11 rather than being
retold here.

**What the three rows say, and the evidence for each.**

`meta.ads` gains `key.telegram` as optional. The daily digest posts to a bot
(`MetaAds/MetaAdsDigest.swift:243-250`) and reports "not configured, skipping send" when the
token is absent, which is degradation and not a block, so `optional` is the honest list. The
second consumer is the Social Ops down alert
(`SocialOps/SocialOpsCoordinator.swift:295-305`), which belongs to a feature cut under 6.2 and
therefore gets no row of its own.

`mailbox` gains `endpoint.microsoft_graph` as optional. It is a second way to read a mailbox
beside IMAP, reached today through the triage pill inside that tab
(`EmailTriage/EmailTriageEngine.swift:351-353`), and its absence costs that route rather than
the tab, which is the definition of optional in section 3 of the contract. It is NOT declared
on the same row as an `anyOf` with `endpoint.imap`: a group would say either transport
satisfies Mailbox, and the mail list, the sync loop and the store are IMAP only, so the group
would be a claim the code does not support.

`chat` gains `step.youtube_transcripts_enabled` as an optionalStep, beside the agent CLI step
that is already there for the same reason. The tool is registered unconditionally today
(`ChatService.swift:984`, fetch at `Research/YouTubeTranscript.swift:384`), so the step is what
turns registration into a decision.

**Two contingencies stated rather than left implicit, because both rows sit on features section
6 proposes to cut.** If `meta.ads` is executed as a cut under 6.6, `key.telegram` loses its only
shipping consumer and must be deleted in the SAME change rather than left as vocabulary
pointing at nothing. The same holds for `endpoint.microsoft_graph` if the headless mail path
goes with the support triage cut under 6.3. A capability outliving its feature is exactly the
dead vocabulary the checker's orphan rule exists to catch, and it is cheaper to say so now than
to rediscover it from a red build.

## 8. Contract change requests

Everything below this heading is exempt from the closed vocabulary rule, which is what makes
it safe to name things that do not exist yet. Nothing here is a licence to use these ids in
code or in a blueprint before the contract adopts them.

**CR-1 through CR-27 are RESOLVED.** CR-28 closes itself. They are left in place because the reasoning in each is
the record of what was checked, and section 7.2 carries the rulings including the two
requests that were adopted against their own recommendation. Section 7.3 carries the 2026-08-10 rulings. Anyone reading this as a work list should read section 7.2
first, because two of the six resolved ones were resolved in the opposite direction to what
they asked for.

Ordered by whether they block a row in section 5.

### 8.1 Blocking

**CR-1. Add a web search key. Blocks `research`, and degrades `chat`.**
The research pipeline's first hard gate is a web search API key, checked before the model key
(`Research/DeepResearchEngine.swift:68` then `:72`), resolved from Keychain like every other
secret (`AppState.swift:127`) and written from Settings. Chat's research tool has the same
dependency and today returns a hand written `error: ...` string into the model's tool result
(`WebResearch.swift:69-71`), which is exactly the call-site remediation contract section 1
exists to prevent. Without an id, `research` renders `ready` for a user holding only a model
key and their first run fails. Suggested: `key.brave`, class key, secret true, remediation
"Add a Brave Search API key in Settings so Grux can search the web. The free tier is enough.
Get one at brave.com/search/api." Config key `grux.research.brave_key`, owner research,
secret yes.

**CR-2. Resolve the outbound mail sender. Blocks `mailbox.compose`, and `chat`'s send tool.**
Section 1.1 has no capability for a transactional email send key and section 2.5's mail
domain carries only read credentials. The one send path reads a hosted provider key from
Keychain (`Email/ResendClient.swift:64`), and its failure text names an internal symbol,
breaking the remediation rule as well (`:25`). **Preferred resolution needs no contract
change: rebase compose on SMTP using the credentials the account already stores**, after
which the row requires exactly `endpoint.imap` and the existing remediation is already
accurate. Fallback: add `key.email_sender` plus `grux.mail.send_key`, owner mail, secret yes.
Pick one before the row ships enabled.

**CR-3. Add a setup step for the coding agent CLI. Blocks `agents`, gates `workflows`,
`self.upgrade`, `schedules` and `chat`'s agent tools.**
Five surfaces depend on an external command line agent that the swarm resolves from an
environment variable, then a fixed candidate list, then the bare name
(`GruxAgentCore/SwarmWorker.swift:81-99`), and which authenticates itself against a
subscription rather than a metered key (`CommandsV2/CommandV2AgentBridge.swift:19-20`). It is
not a secret, not an operating system permission and not a host the user points at, so no
capability class fits, and mapping it to a model key would print a remediation telling the
user to paste a key the path never reads. **This is exactly the shape contract section 3.1
already defines**, a prerequisite resolved by reading app state. Suggested: `step.agent_cli_installed`,
label "Install the agent command line tool", remediation "Install the agent command line tool
so Grux can run agent jobs on your Mac. Grux looks for it on your PATH.", blocking true. Note
the seam already exists informally, since the resolver honours an environment variable first,
so this formalises rather than builds.

**CR-4. Add a config key for the source checkout, and delete the hardcoded paths. Blocks
`feature.review`, gates `self.upgrade`.**
Four absolute or home-relative string literals pin these features to one machine's directory
layout (`Jax/Review/FeatureReviewEngine.swift:77`, `Jax/Review/PostMergeWatch.swift:44` and
`:158`, `Foundry/FoundryEngine.swift:70`, `Foundry/LiveTreeTripwire.swift:21`). Suggested one
key, `grux.foundry.repo_root`, owner foundry, type path, default none, with the guarded script
locations derived from it rather than adding two more keys. Contract section 2.3 makes the
environment form free, which is what the existing environment variable was reaching for.

### 8.2 Structural, and they affect every group

**CR-5. `optional` is defined twice, incompatibly, and the reconciler cannot accept both.**
Contract section 1.4 makes `optional` a property of the **capability** ("true when absence
degrades rather than blocks") and states that `key.elevenlabs` and `key.analytics` are the
only optional entries. Contract section 6 gives each **feature** its own `optional` array.
Both cannot be true, and this registry needed the second in 17 rows: `perm.calendar` is
required by `calendar` and optional for `home`, `perm.automation` is optional for `commands`
and for `terminal.focus` and required by nothing, `key.anthropic` is required by five rows and
optional on six. **Optionality is a property of the edge between a feature and a capability,
not of the capability**, because the same key is load-bearing for one surface and a nicety for
another. Recommend deleting `optional` from the section 1.4 descriptor and letting the Feature
arrays own it, leaving `secret` as the only Bool. This is also the sentence that has to change
when `key.analytics` is deleted per section 7.1.

**CR-6. Add an any-of relation, or state that the over-declaration is deliberate.**
`requires` is a flat AND and two rows cannot be encoded truthfully with it. `compare` needs at
least 2 backends drawn from the union of one cloud contender and N local model tags
(`Compare/ComparisonService.swift:37-62`, refusal at `:72-77`), so a cloud key alone always
fails and two local models alone always succeed; the AND shown in section 5.3 gives local-only
users a false `needs-setup`, which is the recoverable error, and the alternative was a
permanent broken `ready`. `folders` and the classifier below it are satisfied by either a local
endpoint or a cloud key (`Folders/FolderClassifier.swift:26-28`, `LocalLLM.swift:333-360`).
Minimal shape: an optional `anyOf: [{capabilities: [...], min: Int}]` alongside `requires`,
with `needs-setup` listing the whole group and the count. **If this is judged not worth the
complexity, say so in the contract explicitly**, so the next reader knows the over-declaration
is intentional and does not "fix" it into the unsafe direction. Note the AND does not fully
protect `compare` either: a cloud key plus a reachable local server with zero models pulled
satisfies both declared capabilities and still refuses, because reachability is not model
availability.

**CR-7. Add a third tier value, or say where cut rows live.**
Contract section 6 defines `tier` as `core | labs`, but a registry has to record what does
NOT ship or the cut decisions live nowhere and get relitigated. This file worked around it by
keeping cut rows out of the tables entirely and giving them section 6 in prose, which is
readable but means no machine can validate them. Either add `cut` with the rule that a cut
feature carries no capabilities and never renders, or state that cut rows live in a separate
decisions file with its own schema.

**CR-8. Own the id mapping table centrally.**
Contract section 6 requires `Feature.id` to be lowercase, and eight sidebar `applyTab` keys are
camelCase and cannot be renamed (`DesignSystem/SidebarModel.swift:9-11`). Section 2.2 of this
file applies one rule and publishes the whole mapping, but the contract should own it so three
tracks derive the same ids rather than each guessing. Adopt section 2.2's table verbatim, or
state a different rule once.

**CR-9. Fix the orphan rule so it measures what everyone believes it measures.**
`scripts/check-contract.py` counts a capability as used when its id appears in the binding text
of any document under `docs/`, and the contract's own capability tables are such a text.
Consequently the rule can never fire while the contract lists the capability, which is always,
and it reported clean before this registry existed with seven capabilities declared by zero
features. Recommend counting only declarations inside `docs/feature-registry.md`'s registry
tables, or excluding `docs/contract.md` from the used-set scan. Until then a green build is not
evidence that the vocabulary is alive.

**CR-10. Deduplicate the two ids that resolve to one operating system grant.**
`perm.screen_recording` and `perm.system_audio` are both satisfied by the single Screen
Recording grant, and the second one's own remediation sends the user to the first one's pane.
`meetings` touches both surfaces (`SystemAudioCapture.swift:34`, `MeetingCaptureService.swift:191`)
and declares only `perm.system_audio` for that reason. Contract section 3 should state that the
resolver dedupes by underlying grant, or that a feature declares at most one of the pair,
otherwise a setup card prints the same instruction twice and reads like a bug.

**CR-11. Let `degraded` collapse, or better, stop offering unusable tools.**
Contract section 3 renders `degraded` as one dismissible inline note per missing optional
capability. `chat` honestly carries thirteen, which is thirteen notes on a clean install.
Either allow one note listing them, or, better, add a rule that **a tool whose capability is
missing is not offered to the model at all**, so the feature stays `ready` and the tool simply
does not exist. The second is the honest design and it also kills the call-site error strings
CR-1 describes.

### 8.3 Missing capabilities and steps

**CR-12. Add capabilities for the two shipped connectors.** Slack needs a user OAuth token and
optionally an app level token (`Integrations/SlackClient.swift:67`); Notion needs a token plus a
target database id (`Integrations/NotionClient.swift:53`). Both are registered as model callable
tools (`ChatService.swift:986`) and both throw at call time when absent. Suggested `key.slack`
and `key.notion`, with `grux.slack.user_token`, `grux.slack.app_token` and `grux.notion.token`
secret, and `grux.notion.database_id` non-secret, since a database id is a pointer and not a
credential. Chat also registers arbitrary user configured tool servers (`ChatService.swift:1124`)
with no id at all; either add one or state that those bundles are not registered in this build.

**CR-13. Fix the webhook keys.** `endpoint.webhook_inbox` and its three keys describe an inbound
listener that `Webhooks/WebhookManager.swift:34` states is deliberately unbuilt, while the
outbound dispatcher that does exist has no id. Add an id for user supplied delivery targets, and
note that a single scalar shared secret cannot represent the implementation, which stores one
HMAC secret per endpoint under a dynamic Keychain account (`Webhooks/WebhookStore.swift:111`).
Either drop the inbound id and its keys or mark them explicitly reserved for something not
implemented.

**CR-14. Add the focus loop's missing config keys.** Contract section 2.5 says only listed keys
exist, but the running loop reads and the Focus log banner displays an active hours window, a per
app cooldown and a vision versus OCR toggle, none of which have keys (`Models.swift:573`, `:593`,
`:594`, rendered at `LaunchRootView.swift:860`). Suggested `grux.focus.active_hours_start`,
`grux.focus.active_hours_end`, `grux.focus.cooldown_minutes`, `grux.focus.use_vision`, owner
focus. `grux.model.vision_id` already covers the model itself.

**CR-15. Add a step for the first-run speech model download.** The first capture on a fresh
machine fetches an on-device model over the network (`Ambient/AmbientListener.swift:246-266`) and
`MeetingCaptureService.swift:167-171` reports failure as a raw error string, which section 3
forbids. Not a key, a permission or an endpoint. Suggested `step.speech_model_downloaded`,
blocking, remediation "Grux fetches a one time on-device speech model before it can transcribe.
Connect to the internet and open Meetings once to fetch it."

**CR-16. Add a recording consent step.** Meetings captures every participant on a call, not just
the operator, and the closed step set has nothing that lets the feature block until the user
acknowledges it. Section 5 covers the screen capture image only, so neither existing step
applies, and `meetings` therefore ships with no steps while doing the one thing in the app that
creates third party exposure. Suggested `step.recording_consent_acknowledged`, blocking,
remediation "Recording a call captures everyone in it, and some places require you to say so
first. Confirm you will, then Grux can record." Same cheap trade as the first frame review: one
screen converts the loudest objection into the most reassuring moment.

**CR-17. Add a step for the Terminal Focus hook.** `TerminalFocusState.swift:929` writes an
executable script into another tool's directory and `:943` rewrites an entry in that tool's
settings file. It is a consent-bearing prerequisite that is not a key, a permission or an
endpoint. Suggested `step.terminal_focus_hook_installed`, remediation naming the single next
action and stating that Grux adds one entry and removes nothing else.

**CR-18. Add Full Disk Access, and a corpus consent step.** Corpus ingestion reads local
messages, notes and sent mail into a searchable index, and the message database read needs Full
Disk Access at runtime (`Jax/Corpus/IMessageIngester.swift:11`, `:27`), which the code already
models as a permission state. Section 1.2 has no entry for it and section 5 covers screen
capture only. Suggested `perm.full_disk_access`, plus a blocking `step.corpus_sources_confirmed`
that shows which sources will be indexed and confirms none by default. This is at least as
sensitive as the capture loop that earned its own contract section.

**CR-19. Add identity keys so a stranger is not greeted by the wrong name.** Nothing in the
namespace carries the user's name or the assistant's name, so both are hardcoded: the Home
greeting takes a first name as a default argument (`Home/HomeBriefingModel.swift:168`) and the
chat system prompt header names one person, his city and his real brands
(`Jax/JaxProfile.swift:150-176`, loaded at `ChatService.swift:1724`). Suggested
`grux.identity.user_name` and `grux.identity.assistant_name`, non-secret, empty defaults, neutral
fallback.

**CR-20. Add a config gate for the self-upgrade loop.** `GruxApp.swift:740` activates the engine
on every launch and `Foundry/FoundryGovernor.swift:373` starts a 60 second scheduler tick
immediately, so an autonomous self modifying loop is on by default with no way to turn it off
from config. Suggested `grux.foundry.enabled`, owner foundry, bool, default false, matching the
shape section 2.5 already uses for the focus and workday switches. This is the same class of
decision as section 4's analytics default and belongs in the contract for the same reason.

**CR-21. Add the two developer keys Settings already writes.** `SettingsView.swift:1001` writes a
reverse DNS bundle prefix and a signing team id into config, and neither appears in section 2.5.
Suggested `grux.developer.bundle_prefix` and `grux.developer.team_id`, non-secret, or cut the pane
if app scaffolding does not ship.

**CR-22. Scope the mail namespace to multiple accounts.** Section 2.5 gives the mail domain one
host, one address and one password, but `Email/Imap/EmailAccountStore.swift:78-171` is a multi
account store keeping N accounts in JSON and N passwords in Keychain keyed by account id, so a
naive implementation would silently drop every account after the first. Either make the account
list a set of non-secret descriptors with per account secrets held outside the file, or state in
section 2.5 that `endpoint.imap` resolves to "at least one configured account" and the singular
keys are the first-run convenience form. The second is cheaper and matches the code.

**CR-23. Fix the provider key storage shape, or drop the two provider ids.** Section 2.5 reserves
`grux.model.openai_key` and `grux.model.openrouter_key` as single scalars, but the code stores a
key per user added endpoint (`Backend/CustomEndpointStore.swift:33`, `:225-227`) and reaches it
only through the local route (`Backend/ModelRegistry.swift:44-47`). Either restate the two keys as
a list of endpoint descriptors with per endpoint secrets, or narrow the two capabilities'
remediation to say plainly that they are entered when adding a compatible endpoint. Section 7
declares both against `chat` on the strength of the code path; this request is about the storage
shape, not about whether the path exists.

### 8.4 Rulings requested, no new vocabulary

**CR-24. Rule that cost and usage readouts come from a local ledger, and that no analytics read
capability will ever be minted.** Section 4 closes the write path only. The obvious rescue for the
cut Usage tab and for the Reactor spend ring is to ask for an analytics read key plus a project
id, which quietly reopens the hole from the other end. Saying no once in the contract is cheaper
than refusing the same request in every future review, and the local source is strictly better
anyway, because `grux.cost.daily_ceiling_usd` already needs a local spend counter to enforce its
own state transition. Note the current pre-send estimator (`Pricing/CostMeter.swift:20`) is not a
ledger.

**CR-25. Decide who owns the approvals surface, or forbid queueing.** The decision gate is a cross
feature safety primitive that three shipping paths write into
(`Jax/Autonomy/GoalPursuitEngine.swift:394`, the tool gate, the mail tool), and its only renderer
in the tree is the cut Jax HQ tab. Track A needs a closed FeatureID, so the registry needs either a
neutral feature id for a rebuilt approvals inbox, with no brand filter and no persona split, or an
explicit ruling that nothing may enqueue in this build. Shipping the middle autonomy mode without
one gives the user a setting that silently goes nowhere.

**CR-26. Say how an external CLI binary is modelled, or say it is not.** Design Studio's third
route needs a coding CLI on the machine (`DesignStudio/DesignStudioIntegration.swift:202-208`).
The contract models an analogous local binary as `endpoint.ollama` with an install remediation, so
a precedent exists. Not blocking: the code refuses cleanly and names the two alternatives, so
nothing is declared for it here. Preferred resolution is to drop that route from this build, after
which the request disappears. Do not add an id purely for symmetry.

**CR-27. State that the `endpoint.registry` remediation covers writes.** The Projects tab does not
only read the registry, it POSTs a status change (`ProjectsView.swift:42-46`). Either hide the
control when the registry is absent, or widen the remediation so the user knows the pointer is
written to.

**CR-28. No action needed on the group enum. Recorded so nobody re-files it.** The brief that
commissioned this registry states that contract section 6 lists the groups as
command, workspace, intelligence, system, labs, and asks for a change request. **The frozen file
has already been corrected**: `docs/contract.md:402` reads command, workspace, intelligence,
ambient, system, and `:415-420` carries a dated correction note diagnosing both original errors,
that it omitted `ambient` and that it listed `labs`, which is a tier. Verified independently
against `DesignSystem/SidebarModel.swift:27-75`. The brief is stale, not the contract, and
re-requesting a landed fix is the same failure the contract's own note describes: writing from
memory instead of from the file.

---

## 9. Audit contradictions

Where the prior 161 feature audit disagreed with the code, the code won. Recorded so the
disagreements are not rediscovered.

**Units do not line up, and a count comparison is not a discrepancy.** The audit scored 161
features. The sidebar has 36 tabs and this registry has 39 rows. The audit was scoring
components or capabilities, not tabs. Do not reconcile the two by count.

**Cookbook cannot host blueprints. Verified false, independently of the contract's own note.**
`Cookbook.swift:3-5` is a curated catalog plus fit scoring math, `CookbookStore.swift:8-13`
persists exactly four fields, and there is no authoring surface anywhere in the directory.
Blueprints have three hosts.

**Workflows is not a module. Verified false.** No `Workflow*.swift` exists. The sidebar item
keyed `workflows` renders the CommandsV2 view (`LaunchRootView.swift:82`) and the engine is
`CommandsV2/CommandV2Engine.swift`. The label is real and user facing; only the module name is
not. Blueprint authors searching for a Workflows module will find nothing.

**A per-feature "personal" flag produces the wrong answer for most of the tabs it touches.**
Personal wiring is per component, not per feature. Reactor is four generic panels plus two that
exist only to run one person's businesses. Chat is generic except that its system prompt header is
one person's identity. Projects is generic except for three private hosts and a hardcoded slug
list. Mailbox is one tab containing one shipping feature and one cut feature. Only Jax HQ, Social
and Meta Ads are personal all the way down. A binary flag would have cut real work in three cases
and leaked private data in two others.

**A portability defect is not a personal feature.** Feature Review is pinned to one absolute path
and would likely have scored personal. Its purpose is governing what the app's own upgrade engine
merges, which is product, and it becomes shippable the moment one config key exists. Cutting it as
personal would delete the human gate on the self-upgrade loop.

**Presence of a tidy setup prompt is not evidence a feature is one key away from working.** Usage
shows a friendly "paste your key" prompt and is the one row here that genuinely cannot ship, because
the project id is hardcoded and a stranger's own key authenticates fine and is then refused on
someone else's project. Meetings, by contrast, would score badly on a naive read because of a
private host offload and a telemetry call, and both are additive, fail-soft and free to delete.

**Chat's tool surface was undercounted, and that is where the undeclared capabilities were.** The
audit-derived row cited one array of 37 definitions; the array holds 36 and is not the tool
surface. Fourteen more bundles are appended at `ChatService.swift:943-948` and `:982-995`, plus
user configured servers at `:1124`, which is where calendar, contacts, mail, creative and agent
tools live.

**A discovered local server does not replace the cloud key.** `ModelRegistry.offlineReady` requires
offline mode AND discovery (`:40-41`) and offline mode ships false (`Models.swift:712`, `:820`), so
discovery alone routes nothing.

**Skills is not degraded without a cloud key.** Its consumer routes through `resolvedRouting`
(`ChatService.swift:502`), which resolves to a local backend with a placeholder key
(`ModelRegistry.swift:39-47`, `:61-69`). Declaring a provider key would show a permanent degraded
note describing a lesser path the user is not on.

**Compare is not satisfied by a model key.** One key yields exactly one contender and the service
refuses below two, so the single-key state is a permanently broken `ready`. The tab's own copy is
more honest than the audit was.

**Media Studio is not a private-service-only pipeline.** The default route for every non
product-in-scene request is a hosted provider behind a key the contract already owns, with the
private service as the fallback (`CreativeEngine.swift:1453-1474`). That inversion is what makes it
salvageable as `labs` rather than a cut.

**The Roadmap store is not read only by its own view.** Four other subsystems read it, so cutting
the tab without unpicking them breaks the build.

**The empire dashboard macro action does not silently do nothing.** It opens the launch window on a
tab key that exists in neither the tab resolver nor the sidebar, so the user is yanked to the wrong
tab. Still a delete, different reason.

**Two citations in the audit's system group did not survive checking.** The terminal bundle
identifier it attributed to `TerminalFocusState.swift` appears in a different file; the real
hardcoding there is a process-name match in six places. And the self-upgrade subsystem has ten
dedicated test files, not eight. Both conclusions held; the anchors did not.

**Analytics is on by default in the shipped tree, which several rows would otherwise imply is
already fixed.** The write token is a hardcoded literal, the distinct id is a hardcoded personal
address, and the switch defaults to true in both the initialiser and the decoder, so an existing
config file with no such key still opts the user in. Contract section 4 states the correct end
state and nothing implements it yet, which is the strongest argument for treating section 4 as a
build gate rather than a policy note.

**Comment-versus-code disagreements found while writing this registry, all resolved toward the
code.** The sidebar's own header comment says five blueprint groups and then names four before
adding System separately, which is where the contract's original wrong enum came from. The window
tiler claims it uses the Accessibility API and uses AppleScript only. The Agents view header claims
read-only while the code ships cancel, retry, delete and resume. The speaker store's doc comment
claims a smaller embedding than the code computes.

**Removed 2026-08-15.** The `usage` row is gone with the Usage tab. Its only requirement was an
analytics read key, and the whole analytics surface was removed from Grux, write and read
together, so the app can go open source with no connection point back to the author. The
write side went first, which left this feature querying for events the app can no longer
produce, so it was dead on arrival for anyone but the original author. See CR-10 in
`contract.md` for the full reasoning.
