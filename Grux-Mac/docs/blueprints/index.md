# Blueprints

Sixteen ready-made things to point Grux at, written so a stranger can install one and have
it working against their own life the same afternoon.

Status: specification only, and unlike the contract and the capability system beside it
that is still true: none of the sixteen below is implemented. This line is deliberately
not being upgraded with them, and `CredentialsOfferedTests` reads it, because blueprints
declaring a capability must never count as a feature claiming one. Everything below draws
its
capabilities from section 1 of `../contract.md` and its config keys from section 2.5, and
invents neither.

---

## The sixteen

| Blueprint | What it does | Host | Most important capability |
|---|---|---|---|
| [`portfolio-dashboard`](portfolio-dashboard.md) | One snapshot across every project you manage: what is up, what is waiting on you, how many installs | Workflows | `endpoint.registry` |
| [`mention-monitor`](mention-monitor.md) | A daily digest of App Store reviews and Reddit posts that mention your product | Schedules | `key.reddit` |
| [`pr-digest`](pr-digest.md) | Nightly note on open pull requests: what is waiting on your review, what is stale, what is failing | Schedules | `key.github` |
| [`test-digest`](test-digest.md) | Nightly typecheck and test run across your local checkouts, and what broke | Schedules | `endpoint.registry` |
| [`social-health-grid`](social-health-grid.md) | Daily check that every social login still works and the poster has not stalled | Schedules | `endpoint.social_accounts` |
| [`uptime-dashboard`](uptime-dashboard.md) | Probes the sites you care about and reports which are not answering | Schedules | `endpoint.uptime_targets` |
| [`workday-log`](workday-log.md) | A private record of your working day, read back at the end of it | Schedules | `perm.screen_recording` |
| [`project-registry`](project-registry.md) | Fetches your project list from a registry you run, validates it, falls back to an inline list | Workflows | `endpoint.registry` |
| [`webhook-inbox`](webhook-inbox.md) | A local listener so another machine can push updates into Grux | Workflows | `endpoint.webhook_inbox` |
| [`sandbox-tripwire`](sandbox-tripwire.md) | Finds files written outside the folder agents are supposed to stay inside | Workflows | `endpoint.sandbox_root` |
| [`smoke-test`](smoke-test.md) | Headless self-check of Grux itself, with a pass or fail report | Workflows | none |
| [`product-shot`](product-shot.md) | Composites a real product photo into a generated scene, label intact | Workflows | `key.replicate` |
| [`fact-grounding`](fact-grounding.md) | Stops the model inventing prices and specs by grounding it in a catalog you supply | Skills | `key.anthropic` |
| [`output-gates`](output-gates.md) | Rules outbound text must pass before it is sent | Skills | `key.anthropic` |
| [`ship-ios`](ship-ios.md) | Audit, build, install, screenshot, review, submit, then report what Apple said | Workflows | `key.appstoreconnect` |
| [`social-ops-cockpit`](social-ops-cockpit.md) | Per-account health with retry and re-authorisation behind approval gates | Workflows | `endpoint.social_accounts` |

Twelve of these are features whose only real entanglement was hardcoded configuration.
Four (`fact-grounding`, `output-gates`, `ship-ios`, `social-ops-cockpit`) are templates:
the mechanism was always general, and the content that made them look personal has been
moved out into a file or a config key you own.

---

## What a blueprint is

**Seed content for three systems that already work.** Not new architecture, not a plugin
format, not a runtime. Each blueprint is a piece of text you install into one of three
hosts that exist in the tree today.

| Host | What it actually is | Storage | Best for |
|---|---|---|---|
| **Skills** | A named trigger plus a markdown procedure, injected into the system prompt by `asSystemContext()` (`Memory/Hybrid/SkillStore.swift:14`, `:121`) | `~/Library/Application Support/Grux/skills.json`, mirrored to `skills/<name>/SKILL.md` (`Memory/Hybrid/SkillFolderBackend.swift:6`) | Standing rules that must apply without anyone invoking them |
| **Schedules** | A weekday set plus an hour and a minute plus one action, either a workflow id or a free-text agent prompt (`CommandsV2/UserCronStore.swift:22`, `:61`) | `~/Library/Application Support/Grux/user-cron.json` | Anything whose whole value is the cadence |
| **Workflows** | A phase list with state, branching, approval gates and scheduled resumes (`CommandsV2/CommandV2Models.swift:84`, `CommandsV2/CommandV2Engine.swift:136`) | Registered in memory, see CR-3 | Multi-step work, anything needing a human checkpoint |

**Cookbook is not a fourth host.** `LocalModelCookbook/Cookbook.swift:3` is a curated
catalog of local models with hardware fit-scoring. It cannot carry blueprints and nothing
here is assigned to it. Similarly, there is no `Workflow*.swift`: the workflow engine is
`CommandsV2/`, and looking for a Workflows module is a dead end.

**The three hosts compose.** A `UserCronJob` whose action is
`runCommand(definitionId:)` fires a Workflow on a cadence
(`CommandsV2/UserCronStore.swift:25`), which is the designed way to make a multi-step
blueprint recurring. Where that matters, the individual blueprint says so. It has one real
gap today: `runCommand` carries no parameters, so a scheduled workflow runs with empty
`${param.*}` values. `sandbox-tripwire` documents that as a defect rather than working
around it.

---

## Why blueprints exist

A stranger who installs Grux gets around 150 features and no idea which ones are for them.
That is worse than getting 20, because a long list of capabilities is not a suggestion
about what to do with your afternoon. The person does not need more surface, they need one
sentence that says "here is a useful thing you could have by dinner", and a complete
recipe under it.

**Blueprints are onboarding for intent, not permissions.** The capability system in
`../contract.md` answers "what does this need before it can run". Blueprints answer the
question that comes first: "what would I even want". Those are different problems and
conflating them produces a setup wizard that collects six API keys before showing you
anything worth having.

Three rules follow from that, and every file here is held to them.

1. **Complete, not sketched.** Every prompt is the full prompt, every schedule is the exact
   weekday set and time, every workflow is a phase list you could transcribe. A blueprint
   you have to finish yourself has not saved you anything.
2. **Pointed at your life, not the author's.** Every user-specific value is a placeholder.
   Where the original author's version teaches something, it appears inside a block headed
   "Example, not a default" with placeholder hostnames, keys and paths.
3. **Honest about what it does badly.** Every file ends with real limitations, including
   the ones that make the blueprint a poor choice. `uptime-dashboard` says outright that it
   is not uptime monitoring. `sandbox-tripwire` says the name oversells it. A seed set that
   only advertises is a brochure.

---

## Contract change requests

Six things the specs needed and the contract does not have. None of them were invented into
the blueprints. Each is written as the exact proposed entry.

### CR-1. Move `optional` from the capability to the requirement edge

**Problem.** Section 1.4 puts `optional: Bool` on the `Capability` descriptor, and section
1.4 states that `key.elevenlabs` and `key.analytics` are the only optional entries. That
makes optionality a global property of a capability, but it is a property of the
relationship between a feature and a capability. `key.github` is load bearing for
`pr-digest` and a nice-to-have for `portfolio-dashboard`, which is still useful without
pull request counts. Twelve of the sixteen blueprints hit this, and every one of them
currently has to over-declare a capability as required and note the discrepancy in prose.

**Proposed change.** Remove `optional` from `Capability`. Add a requirement edge:

```
Requirement
  capability   String    a capability id from section 1
  required     Bool      false when the feature degrades rather than blocks
  degradation  String    shown as the degraded note when required is false, under 140 chars
```

A feature declares `[Requirement]`. Section 3's `degraded` state then reads off the edge
rather than off the capability, and the worked ElevenLabs example still holds: the spoken
nudge feature declares `key.elevenlabs` with `required: false`.

### CR-2. Allow `anyOf` requirement groups

**Problem.** `product-shot` needs an image provider, satisfied by **either** `key.replicate`
**or** `endpoint.media_service`. `portfolio-dashboard` and `project-registry` need a
project list, satisfied by **either** `endpoint.registry` **or** a populated
`grux.portfolio.projects`. The contract's model is a flat required set, so both blueprints
currently declare both and the setup card will ask for two things when one will do.
Over-asking at setup is the specific failure blueprints exist to prevent.

**Proposed change.** Allow a requirement to be a group:

```
RequirementGroup
  anyOf        [String]  capability ids, satisfied when at least one resolves
  label        String    what the group provides, e.g. "An image provider"
  remediation  String    shown when none resolve, under 140 chars
```

Proposed group for `product-shot`, using the existing capability remediations as the
fallback text: label "An image provider", remediation "Add a fal.ai key in Settings, or
point Grux at your own image generation service. Either one works."

### CR-3. A definitions directory, so a workflow can be installed as a file

**Problem.** `CommandV2Definition` is `Codable` (`CommandsV2/CommandV2Models.swift:84`),
but `CommandV2Engine.load()` only loads runs and re-registers the built-in definitions
(`CommandsV2/CommandV2Engine.swift:56`). Definitions are never read from or written to
disk. So a Workflow blueprint can only be installed by editing Swift and rebuilding, while
a Skill blueprint installs by dropping a `SKILL.md` folder in
(`Memory/Hybrid/SkillFolderBackend.swift:130`). Eight of the sixteen blueprints are
Workflows, and all eight currently ship with the same paragraph explaining that you have to
recompile. That is not a seed set a stranger can use.

**Proposed change.** Add one config key:

| key | owner | type | secret | default | notes |
|---|---|---|---|---|---|
| `grux.workflows.definitions_dir` | workflows | path | no | `~/Library/Application Support/Grux/workflows` | JSON workflow definitions loaded at startup, alongside the built-ins |

Loading mirrors `SkillStore.importFromFolders()`: read every `*.json`, decode as
`CommandV2Definition`, and pass each to `CommandV2Engine.register(_:)`
(`CommandsV2/CommandV2Engine.swift:136`), which already upserts by id. A definition that
fails to decode is reported by filename and skipped, never silently dropped.

### CR-4. A revenue capability

**Problem.** `portfolio-dashboard` was specified as covering revenue, installs, open pull
requests and infra health. There is no revenue capability in section 1 and no revenue
domain in section 2.5, so the blueprint ships covering three of the four and says so in its
limitations. That is the honest outcome and it is a visible hole in the flagship blueprint.

**Proposed change.** Add one capability:

| id | label | remediation |
|---|---|---|
| `key.revenue` | Revenue provider key | Connect your payment or subscription provider in Settings so Grux can read revenue. |

and two config keys:

| key | owner | type | secret | default | notes |
|---|---|---|---|---|---|
| `grux.revenue.provider` | revenue | enum | no | none | the provider name, no default |
| `grux.revenue.key` | revenue | string | **yes** | none | `key.revenue` |

Deliberately provider-agnostic and with no shipped default, for the same reason section 1.3
gives about endpoints.

### CR-5. Define the entry shape of `grux.portfolio.projects`

**Problem.** Section 2.5 types the key as `list` and stops. Four blueprints read it
(`portfolio-dashboard`, `test-digest`, `project-registry`, `ship-ios`) and each needs a
local checkout path, which the contract never says an entry has. All four currently guess
at the same shape, which means they will agree until one of them changes.

**Proposed change.** Specify the entry in section 2.5's notes column:

```
Each entry is an object:
  name  String   short, lowercase, unique within the list, required
  path  String?  absolute path to a local checkout, or null
  repo  String?  owner/name, or null
  url   String?  the deployed URL, or null
An entry with a duplicate name is invalid: the list fails to load rather than
silently shadowing, because every blueprint looks a project up by name.
```

### CR-6. A capability for authenticating to a project registry

**Problem.** `endpoint.registry` describes a URL Grux fetches, and nothing in the contract
carries a credential for it. `project-registry` therefore fetches unauthenticated, which
means the registry must be public or reachable only from your own network. A private
registry is the normal case for the people this blueprint is for.

**Proposed change.** Add one capability and one config key:

| id | label | remediation |
|---|---|---|
| `key.registry` | Project registry token | Optional. Add a token if your project registry needs one. Grux fetches without one otherwise. |

| key | owner | type | secret | default | notes |
|---|---|---|---|---|---|
| `grux.portfolio.registry_token` | portfolio | string | **yes** | none | `key.registry` |

This one is genuinely optional under CR-1's model: absence degrades a private registry to
unreachable and leaves a public one working.

---

## Host limitations, raised but not contract changes

Three constraints that shaped these blueprints and belong to Track A rather than the
contract. Recorded here so they are not rediscovered sixteen times.

1. **A schedule fires at most once a day.** `UserCronJob` stores one `hour` and one
   `minute` (`CommandsV2/UserCronStore.swift:69-70`). Several fires a day means several
   jobs, which is why `uptime-dashboard` ships as three identical schedules.
2. **A missed fire is skipped, not replayed, after a 10 minute grace period**
   (`CommandsV2/UserCronStore.swift:253`, `:282-289`). A closed laptop means no digest and
   no notice that there was no digest.
3. **A scheduled agent prompt gets 30 minutes and no more.** The scheduler calls
   `runSingleAgent` without a lifetime, taking the `ttlSeconds: 1800` default
   (`CommandsV2/UserCronStore.swift:332`, `CommandsV2/CommandV2AgentBridge.swift:39`),
   while the workflow engine raises the same call to 5400 for long phases
   (`CommandsV2/CommandV2Engine.swift:602`). `test-digest` is the blueprint most likely to
   hit this and it says so.
