# The shared contract

**Phase 0. Both the capability system and the blueprint set consume this document, and
neither may invent anything outside it.** If a spec needs a capability, a config key or a
feature state that is not written down here, the contract changes first and the reconciler
in `docs/reconciliation.md` fails the build until it does.

Status: IMPLEMENTED and enforced. `scripts/check-contract.py` reads this document and
fails the build when the shipped tree drifts from it, and CI runs it on every push. It
currently reconciles 41 capabilities and 59 config keys against the live registry. This
line used to say the opposite, which was true when the contract was written and has not
been true for some time.

---

## 0. Findings that contradict the feature audit

The audit was one pass and was explicitly to be checked. Two of its claims do not survive
contact with the code, and one of them changes Track B's design.

**Cookbook is not a recipe system and cannot host blueprints.**
`Sources/Grux/LocalModelCookbook/Cookbook.swift:3` describes itself as "Static, curated
catalog of local models worth running through Ollama, plus the fit-scoring math that
matches them to a HardwareProfile." It is a hardware-matching model catalog. The audit
listed it as one of four systems that could carry seed content. It cannot. **Blueprints
have three hosts, not four.**

**Workflows exists but is not called Workflows.** There is no `Workflow*.swift`. The
engine is `Sources/Grux/CommandsV2/`, specifically `CommandV2Engine.swift`,
`CommandV2Definitions.swift` and `CommandV2Models.swift`. Blueprint authors must target
CommandsV2 and should not search for a Workflows module.

Confirmed as described:

| System | Evidence | Role for blueprints |
|---|---|---|
| Skills | `Memory/Hybrid/SkillStore.swift:1-12`, storage `~/Library/Application Support/Grux/skills.json`, injected via `asSystemContext()` | Prompt-shaped blueprints |
| Schedules | `CommandsV2/UserCronStore.swift`, `UserCronEditorView.swift`, covered by `Tests/GruxTests/UserCronTests.swift` | Recurring blueprints |
| Workflows | `CommandsV2/CommandV2Engine.swift` and siblings | Multi-step blueprints |

Also confirmed, and load-bearing for section 2:

- Config is a single `Codable` struct, `GruxConfig` at `Models.swift:563`, roughly 67 fields.
- Secret storage already exists: `KeychainStore.swift:14`, `kSecClassGenericPassword`,
  service `com.dcj.grux`.
- Environment variables are already read in 24 places, so precedence is real but informal.
- The transmitted artifact is a JPEG, `FocusWatcher.swift:213` via `ScreenCapturer.jpegData`.

**Unverified and inherited from the audit:** the readiness distribution (works 30,
needs-config 50, needs-work 53, personal 22, stub 6) and the per-feature scoring. These
specs depend on the shape of that distribution, not the exact counts.

---

## 1. Capability vocabulary

A **capability** is one thing a feature needs before it can run. The set is **closed**. A
feature may require capabilities only from this table.

Every entry has a stable `id`, a human `label`, and a `remediation` string. The remediation
string is the exact text the UI shows when the capability is missing. It is part of the
contract because a missing capability must never surface as an error, and a remediation
written at the call site is how inconsistent, blaming, or silent failures get in.

Rules for remediation strings: address the reader as "you", name the single next action,
never blame, never mention an internal symbol, and stay under 140 characters.

### 1.1 Keys (class `key`)

Secrets. Resolved from Keychain only. See section 2.4.

| id | label | remediation |
|---|---|---|
| `key.anthropic` | Anthropic API key | Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com. |
| `key.github` | GitHub token | Connect GitHub in Settings so Grux can read your repositories. A classic token with repo scope is enough. |
| `key.appstoreconnect` | App Store Connect API key | Add your App Store Connect key, issuer ID and .p8 file in Settings to let Grux publish builds. |
| `key.elevenlabs` | ElevenLabs API key | Optional. Add an ElevenLabs key for a natural voice. Grux uses the built-in macOS voice without one. |
| `key.reddit` | Reddit API credentials | Connect Reddit in Settings to read mentions of your product. |
| `key.replicate` | Replicate API token | Add a Replicate API token in Settings to generate images. |
| `key.brave` | Web search API key | Add a Brave Search API key in Settings so Grux can search the web. The free tier is enough. |
| `key.resend` | Email sending API key | Add your email provider API key in Settings so Grux can send mail. Grux has no SMTP client. |
| `key.slack` | Slack token | Connect Slack in Settings so Grux can read and post in your workspace. |
| `key.godaddy` | Domain registrar key | Add your registrar API key and secret in Settings so Grux can read your domains and DNS. |
| `key.notion` | Notion token | Paste your Notion integration secret in Settings, and the database you want Grux to write to. |
| `key.telegram` | Telegram bot token | Add a Telegram bot token and chat id in Settings so Grux can send alerts to your phone. Nothing is sent until you add both. |

**Amended 2026-08-28, CR-34. The OpenAI and OpenRouter scalar key capabilities are
DELETED.** Named in prose rather than as ids, following the analytics precedent below:
the ids no longer exist, and writing one in backticks here would make this very record
count as a declaration of it.

They described a shape the code does not have. A key for an OpenAI-compatible provider is
not a scalar slot on the app: `CustomEndpointStore` holds one key per user-added endpoint,
under its own Keychain account per endpoint id, and that is the only path any provider key
travels. CR-31 already removed both from `chat` on the finding that chat never read either
slot, and no feature and no blueprint has declared either since.

Same reasoning as the analytics deletion below, reached from the other direction: that one
was never a capability, these two stopped being capabilities when the per-endpoint store
replaced the scalar slots. The ABILITY to use an OpenAI-compatible provider is untouched
and still reached through `grux.model.custom_endpoints`.

Two things this deliberately does NOT do. It does not remove
`KeychainStore.Key.openAIApiKey` or `.openRouterApiKey`: Settings offered all fourteen key
capabilities before CR-31, so somebody may have pasted a value into one, and deleting the
case would leave that credential unreachable in their login keychain rather than removed,
which is the failure mode `KeychainServiceMigrator` exists to prevent. The cases stay,
marked retired and read by nothing. And it does not touch `CredentialsOfferedTests`'s guard
on the other three unread slots (`key.github`, `key.appstoreconnect`, `key.reddit`), which
are still declared by blueprints and so are dead code paths rather than dead vocabulary.

There is deliberately **no analytics capability**. Analytics is a global privacy switch,
not a thing a feature requires, and section 2.5 expresses it completely with
`grux.analytics.enabled`, `grux.analytics.write_key` and `grux.analytics.host`. Every
placement as a capability is wrong: as `requires` a feature would sit in `needs-setup`
waiting on a switch that ships off, and as `optional` it would render a standing note
asking the user to add an analytics key, which inverts section 4 on the one surface where
the private tree already ships the opposite. Removed 2026-08-09 on that reasoning.

**Amended 2026-08-12, CR-9.** `key.godaddy` and `step.phone_paired` are added in the same amendment for a duller reason.
Both are already implemented and credential-gated in the private tree (`goDaddyApiKey` plus
`goDaddyApiSecret`, and `phonePairingSecret` in the Keychain), and the closed vocabulary had
no id for either, so they could not be expressed at all and would have kept a second,
bespoke setup mechanism alive beside the registry.

**Amended 2026-08-15, CR-10. The PostHog analytics read key added by CR-9 is REMOVED, and
CR-9 is superseded rather than reversed.** CR-9's reasoning was sound on its own terms: the READ side genuinely was a
different question from the WRITE side, and a feature whose entire job is reading may
require a read key.

What changed is not the argument but the subject. The whole analytics surface has been
removed from Grux, write and read together: the SDK is out of `Package.swift`,
`PostHogTelemetry` is deleted along with roughly a hundred call sites, and the read half
(`UsageQuery`, `LLMSpend`, `LLMSpendSection`, `EmpireData`) is deleted with the Usage tab
that hosted it. The app is going open source, and a stranger who downloads it must have no
connection point back to the author.

So the capability is not being argued down, it is being retired with the only feature that
ever consumed it. CR-9's distinction is still the right one and would apply again if an
analytics read surface ever returns.

**Amended 2026-08-15, CR-11. Three integrations reach the network with no capability at
all.** `key.telegram`, `endpoint.microsoft_graph` and `step.youtube_transcripts_enabled`
are added. Each was already implemented and already reaching outside the machine while the
closed vocabulary had no id for it, which is the same gap CR-9 closed for `key.godaddy`: a
capability the contract cannot name is a capability the registry cannot gate, and it keeps a
bespoke setup path alive beside the one this document exists to be.

Note two of the three carry a remediation naming a Settings control that does not exist yet
(`step.youtube_transcripts_enabled` says "Turn it on in Settings";
`endpoint.microsoft_graph` says to add a tenant and mailbox there, while the only real path
is a JSON file). That is recorded as a defect against the app, not against these rows: the
contract states the intended surface and the app has to catch up to it.

### 1.2 macOS permissions (class `perm`)

Granted by the operating system. Never guessed: resolved by asking the relevant API.

| id | label | remediation |
|---|---|---|
| `perm.screen_recording` | Screen Recording | Grux needs Screen Recording to see what you are working on. Open System Settings, Privacy and Security, Screen Recording, and enable Grux. |
| `perm.microphone` | Microphone | Grux needs the microphone to hear you. Open System Settings, Privacy and Security, Microphone, and enable Grux. |
| `perm.accessibility` | Accessibility | Grux needs Accessibility to read the active window title. Open System Settings, Privacy and Security, Accessibility, and enable Grux. |
| `perm.automation` | Automation | Grux needs Automation to control other apps. Approve the prompt macOS shows, or enable Grux under Privacy and Security, Automation. |
| `perm.calendar` | Calendar | Grux needs Calendar access to read and create events. Open System Settings, Privacy and Security, Calendars, and enable Grux. |
| `perm.contacts` | Contacts | Grux needs Contacts access to match people to conversations. Open System Settings, Privacy and Security, Contacts, and enable Grux. |
| `perm.notifications` | Notifications | Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on. |
| `perm.system_audio` | System audio capture | Grux needs system audio to transcribe meetings. Open System Settings, Privacy and Security, Screen Recording, and enable Grux. |
| `perm.full_disk_access` | Full Disk Access | Grux needs Full Disk Access to read your messages. Open System Settings, Privacy and Security, Full Disk Access, and enable Grux. |

`perm.system_audio` resolves to the same Screen Recording grant as `perm.screen_recording`,
which is why its remediation sends you to the same pane. **A feature declares at most one of
the pair.** Declaring both would print the same instruction twice on one setup card and read
like a bug. Resolved 2026-08-10, CR-10.

### 1.2.1 Why each permission is worth granting

`remediation` is capped at 140 characters and its job is to name the single next action.
That is correct for the setup card and useless at the moment of consent: macOS shows its own
modal, the only text Grux gets in it is one usage-description line, and a user deciding
whether to hand over a microphone needs to know what they get and what they lose, not which
pane to open.

So `why` is a separate field with its own budget. It is shown BEFORE the system prompt is
triggered, on a screen the user can read at their own pace. **Every `perm` capability must
have one, and it must name a consequence of declining**, because a permission screen that
only lists upside reads as a sales pitch and earns a reflexive no.

Rules: address the reader as "you" or name Grux, say what the permission buys, then say
plainly what stays off without it, and never imply the app is broken without it. Under 260
characters.

| id | why |
|---|---|
| `perm.screen_recording` | Grux can see what you are working on, so it can keep you on the task you chose and answer questions about what is on screen. Decline and Grux is text only: focus tracking and screen questions stay off, everything else still works. |
| `perm.microphone` | You can talk to Grux instead of typing, and it can transcribe meetings on this Mac. Decline and voice and meeting notes stay off, everything else still works. Continuous listening is a separate switch that ships off. |
| `perm.accessibility` | Grux can read which app and window you are in, which is how it knows what you are working on and how it clicks things for you. Decline and focus tracking and app control stay off. |
| `perm.automation` | Grux can drive the apps you already have open instead of telling you which buttons to press. Decline and Grux can advise but not act. |
| `perm.calendar` | Grux can line your meetings up with what it heard and put events in for you. Decline and the workday log has no meetings in it. |
| `perm.contacts` | Grux can put names to the voices in a meeting and find an address without you typing it. Decline and speakers stay unnamed. |
| `perm.notifications` | Grux can tell you something happened without you watching the window. Decline and you only see updates when you go looking. |
| `perm.system_audio` | Grux can transcribe the other side of a call, not just your microphone. Decline and you get your half of the conversation. |
| `perm.full_disk_access` | Grux can read your Messages history and answer questions about past conversations. Decline and Messages stays unreadable, nothing else changes. |

**Amended 2026-08-16, CR-29. `why` is added for the `perm` class.** Filed after the operator
granted all nine permissions on a fresh install and reported that nothing explained what any
of them did. The copy existed; it could not be reached. Two causes, both real: `remediation`
at 140 characters cannot carry the how and the why together, and onboarding is the only
surface that ever showed it (`OnboardingModel.isPresenting` is `stage != .done`, with one
render site and no path back), so a grant revoked later re-prompts with nothing to say.

This amendment fixes the copy half. The reachability half is a defect against the app: the
explanation must be shown before the prompt is triggered, not only during first run.

### 1.3 External endpoints (class `endpoint`)

Something the user supplies: a host, a list, a service they run. **No endpoint has a
shipped default.** A default here would be a hole in someone else's network, which is the
same reasoning that keeps `URLGuard.trustedLANHosts` empty in `grux-kit`.

| id | label | remediation |
|---|---|---|
| `endpoint.registry` | Project registry | Point Grux at your project registry URL in Settings. Grux reads your projects from it and writes status changes back. |
| `endpoint.repo_list` | Repository list | Tell Grux which repositories to watch in Settings. Nothing is watched until you do. |
| `endpoint.uptime_targets` | Sites to monitor | Add the URLs you want Grux to check in Settings. |
| `endpoint.webhook_inbox` | Webhook inbox | Turn on the local webhook listener in Settings and choose a port to let other machines push updates in. |
| `endpoint.ollama` | Local model server | Install Ollama and start it, or point Grux at your Ollama host in Settings. |
| `endpoint.media_service` | Image generation service | Point Grux at your image generation service in Settings, or use a hosted provider key instead. |
| `endpoint.imap` | Mail server | Add a mail account, its server and an app password in Settings to let Grux read your inbox. |
| `endpoint.social_accounts` | Social accounts | List your posting service, one URL per line, in ~/.grux/social-ops-hosts.txt. Grux reads it at launch and when the Social Ops panel opens. |
| `endpoint.sandbox_root` | Watched folder | Choose the folder Grux should guard in Settings. |
| `endpoint.microsoft_graph` | Microsoft 365 mail | Add your Microsoft 365 tenant, app id and a mailbox in Settings to let Grux read that inbox. Nothing connects until you do. |

**`endpoint.webhook_inbox` and its three webhook config keys are RESERVED, not shipped.**
Resolved 2026-08-10, CR-13. `Webhooks/WebhookManager.swift:34` states the inbound listener is
deliberately unbuilt. The id and keys stay so the shape is settled before anything is written,
and no shipping feature declares them. The outbound dispatcher that does exist stores one HMAC
secret per endpoint under a dynamic Keychain account, which is the same N-secrets shape as
section 2.4 now describes for mail and model endpoints, and it gets an id when it ships.

### 1.4 Capability descriptor

```
Capability
  id           String    stable, dotted, class-prefixed, never renamed
  label        String    human, title case, shown in setup lists
  class        Enum      key | perm | endpoint
  remediation  String    exact UI text when missing, under 140 chars
  secret       Bool      true for every key, false otherwise
```

**There is deliberately no `optional` flag here. Optionality is a property of the EDGE
between a feature and a capability, not of the capability.** `endpoint.ollama` is the clean
case: `compare` cannot run without a local model server, while `chat` merely loses a menu
entry. `perm.calendar` is required by `calendar` and optional for `home`. One global flag
cannot express either.

**Amended 2026-08-09, CR-5.** This descriptor previously carried `optional: Bool` while
section 6 gave each feature its own `optional: [Capability.id]`. Both existed, they
disagreed, and 17 of 39 registry rows needed the second reading. The expected repair was to
demote the flag to a default that the per-feature list overrides. That does not work, and
deciding it deliberately is the point of this note. The feature manifest is two disjoint
sets, so a feature declares an edge by placing the id in `requires` or in `optional`, which
means **the act of declaring the edge is already the statement of optionality**. There is no
third state, "declared but unspecified", for a default to fill. A default that can never
apply is not a convenience, it is a second source of truth that silently disagrees with the
first. The state computation had already voted: it reads only the feature's two sets and
never consulted this flag, so the flag was decorative before it was removed.

---

## 2. Config key namespace

### 2.1 Shape

```
grux.<domain>.<name>
```

Lowercase, dotted, ASCII. `<domain>` is the owning subsystem and there is **exactly one
owner per key**. Two features may read a key; only one may define it. The reconciler
fails on a duplicate definition.

### 2.2 Versioning

`grux.schema.version` is an integer, currently `1`. It sits in the config file and is the
only key with no owning domain. A reader that finds a version higher than it understands
must refuse to write the file rather than silently dropping unknown keys.

### 2.3 Precedence

Highest wins:

1. **Environment variable.** `grux.focus.cadence_seconds` becomes `GRUX_FOCUS_CADENCE_SECONDS`.
   Uppercase, dots to underscores. This is already how 24 sites in the tree read config, so
   the rule formalises existing behaviour rather than inventing one.
2. **Config file.** `~/Library/Application Support/Grux/config.json`.
3. **Keychain.** Service `com.dcj.grux`, account equals the config key
   (`KeychainStore.swift:14`).

Precedence is intentionally the reverse of "most secure wins", because an operator running
Grux in a container or a CI job has to be able to override anything from the environment.
Secrets are protected by section 2.4, not by precedence.

### 2.4 Secrets live only in Keychain, and here is how that is enforced

A declaration, a runtime refusal and a build-time check, because a rule with only one of
those is a comment.

1. **Declared.** Every key descriptor carries `secret: Bool`. Every capability of class
   `key` maps to a secret config key. This is data, not convention.
2. **Refused on read.** The config loader never returns a secret-flagged value that came
   from the file or the environment. If one is present it is **ignored, not used**, and the
   app raises a one-time warning naming the key and telling the user to move it to Settings.
   Ignoring rather than using is the important half: a secret that works from a plaintext
   file will live there forever.
3. **Refused on write.** The config writer drops secret-flagged keys before serialising, so
   a round-trip of load, edit, save can never create a plaintext secret.
4. **Checked in CI.** `scripts/check-contract` fails if any secret-flagged key appears in
   the sample config, in any blueprint, or in any committed fixture.

**Two domains hold N secrets rather than one, and the namespace says so rather than
pretending otherwise.** Resolved 2026-08-10, CR-22 and CR-23. Mail is a multi-account store
and model endpoints are user-added, so each holds one secret PER ITEM, keyed in Keychain by
the item's own id. `grux.mail.accounts` and `grux.model.custom_endpoints` are therefore
non-secret lists of descriptors, and the secrets they imply never appear in the namespace at
all. The three singular mail keys and the two scalar provider keys that used to sit here
described a shape the code has never had: a reader implementing them faithfully would have
dropped every mail account after the first, and neither provider scalar is read anywhere in
the tree.

Point 2 has one deliberate exception. `GRUX_ANTHROPIC_API_KEY` and its siblings **are**
honoured from the environment, because headless and CI use is otherwise impossible. The
exception is narrow: environment yes, config file never. The warning still fires so the
behaviour is visible.

### 2.5 The namespace

Only keys listed here exist. `secret` keys have no file representation.

| key | owner | type | secret | default | notes |
|---|---|---|---|---|---|
| `grux.schema.version` | core | int | no | `1` | see 2.2 |
| `grux.model.provider` | model | enum | no | `anthropic` | **not implemented**, anthropic, openai, openrouter, ollama |
| `grux.model.chat_id` | model | string | no | provider default | |
| `grux.model.vision_id` | model | string | no | provider default | used by the focus loop |
| `grux.model.anthropic_key` | model | string | **yes** | none | `key.anthropic` |
| `grux.model.custom_endpoints` | model | list | no | `[]` | CR-23, CR-34, name and base URL per endpoint, key in Keychain per endpoint id, never a scalar provider slot |
| `grux.model.ollama_host` | model | url | no | none | `endpoint.ollama` |
| `grux.cost.daily_ceiling_usd` | cost | decimal | no | `2.00` | **not implemented**, see the note below this table, hard stop, see section 3 |
| `grux.cost.warn_at_fraction` | cost | decimal | no | `0.8` | **not implemented** |
| `grux.focus.enabled` | focus | bool | no | `false` | off until onboarding completes |
| `grux.focus.cadence_seconds` | focus | int | no | tier default | **not implemented**, the tier's cadence governs, see section 5 |
| `grux.focus.nudge_after_strikes` | focus | int | no | `2` | |
| `grux.focus.active_hours_start` | focus | int | no | `6` | CR-14, `Models.swift:854` |
| `grux.focus.active_hours_end` | focus | int | no | `23` | CR-14, `Models.swift:855` |
| `grux.capture.excluded_bundle_ids` | capture | list | no | seeded, see 5.2 | |
| `grux.capture.excluded_window_titles` | capture | list | no | seeded, see 5.2 | |
| `grux.capture.indicator_enabled` | capture | bool | no | `true` | cannot be disabled in v1, see 5.3 |
| `grux.capture.first_frame_reviewed` | capture | bool | no | `false` | gates the whole loop, see 5.4 |
| `grux.voice.tts_provider` | voice | enum | no | `system` | system, elevenlabs |
| `grux.voice.elevenlabs_key` | voice | string | **yes** | none | `key.elevenlabs`, optional |
| `grux.github.token` | github | string | **yes** | none | `key.github` |
| `grux.github.repos` | github | list | no | `[]` | `endpoint.repo_list` |
| `grux.asc.key_id` | asc | string | no | none | not itself a secret |
| `grux.asc.issuer_id` | asc | string | no | none | |
| `grux.asc.p8_path` | asc | path | no | none | file on disk, permissions checked |
| `grux.portfolio.registry_url` | portfolio | url | no | none | `endpoint.registry` |
| `grux.portfolio.projects` | portfolio | list | no | `[]` | **not implemented**, inline alternative to the registry |
| `grux.uptime.targets` | uptime | list | no | `[]` | `endpoint.uptime_targets` |
| `grux.mentions.sources` | mentions | list | no | `[]` | **not implemented**, app store ids, subreddits |
| `grux.mentions.reddit_key` | mentions | string | **yes** | none | `key.reddit` |
| `grux.webhook.enabled` | webhook | bool | no | `false` | |
| `grux.webhook.inbox_port` | webhook | int | no | `0` | `endpoint.webhook_inbox`, 0 means pick a free port |
| `grux.webhook.shared_secret` | webhook | string | **yes** | none | required when enabled |
| `grux.media.service_url` | media | url | no | none | `endpoint.media_service` |
| `grux.media.replicate_token` | media | string | **yes** | none | `key.replicate` |
| `grux.slack.user_token` | slack | string | **yes** | none | `key.slack` |
| `grux.notion.token` | notion | string | **yes** | none | `key.notion` |
| `grux.notion.database_id` | notion | string | no | none | a pointer, not a credential |
| `grux.mail.accounts` | mail | list | no | `[]` | `endpoint.imap`, CR-22, one descriptor per account, host and address, no secret |
| `grux.mail.graph_accounts` | mail | list | no | `[]` | `endpoint.microsoft_graph`, one descriptor per account |
| `grux.mail.resend_key` | mail | string | **yes** | none | `key.resend`, the only outbound path |
| `grux.research.brave_key` | research | string | **yes** | none | `key.brave` |
| `grux.source.checkout_path` | source | path | no | none | **not implemented**, CR-4, replaces hardcoded absolute paths |
| `grux.social.accounts` | social | list | no | `[]` | `endpoint.social_accounts` |
| `grux.sandbox.watched_root` | sandbox | path | no | none | `endpoint.sandbox_root` |
| `grux.services.rag_base_url` | services | url | no | none | the companion RAG host, no default: you stand it up. **stored under a camelCase spelling**, see the note below |
| `grux.shell.trust_ceiling` | shell | enum | no | see `ShellTrustCeiling` | the most authority a model may ask for |
| `grux.sandbox.quarantine_dir` | sandbox | path | no | none | |
| `grux.grounding.catalog_path` | grounding | path | no | none | **not implemented**, user's own facts |
| `grux.gates.rules_path` | gates | path | no | none | **not implemented**, user's own output rules |
| `grux.workday.enabled` | workday | bool | no | `false` | |
| `grux.foundry.enabled` | foundry | bool | no | `false` | CR-20, the self-upgrade loop, off by default |
| `grux.identity.user_name` | identity | string | no | none | CR-19, empty renders a greeting with no name |
| `grux.identity.assistant_name` | identity | string | no | `Jax` | CR-19, CR-30, what the assistant calls itself, not the app's name |
| `grux.developer.bundle_prefix` | developer | string | no | none | CR-21, reverse DNS root for scaffolded apps |
| `grux.developer.team_id` | developer | string | no | none | CR-21, not itself a secret, same as `grux.asc.key_id` |
| `grux.analytics.enabled` | analytics | bool | no | `false` | **off, and no default endpoint** |
| `grux.analytics.write_key` | analytics | string | **yes** | none | opt-in only, no capability, see 1.1 |
| `grux.analytics.host` | analytics | url | no | none | user supplies both or neither |

**Amended 2026-08-29. Every key is now marked with whether Grux actually implements it, and
two were declared under the wrong name.**

The table and `grux config` had drifted apart in BOTH directions, and the drift was doing
real harm in both. The command refused keys the app implements under a different Swift name,
and the table offered keys that were only ever a heading.

`grux.capture.excluded_bundle_ids` is the case that makes the point. It reads as dead to a
grep for the literal string and it is `GruxConfig.captureExcludedBundleIds`, live in four
files including the window-title privacy gate, which reads it on every capture. It was a
naming mismatch, not a dead feature, and fifteen keys were in that state. They are now
reachable from `grux config` through `ConfigBridge`.

Two were CORRECTED, because the implementation was right and the declaration was wrong.
the webhook inbox port is now declared as `grux.webhook.inbox_port`, the name the resolver
has always used, rather than under the shorter name that never existed in code,
and `grux.mail.graph_accounts` is added: settable all along, never written down.

Ten are MARKED `not implemented` rather than deleted. Deleting them was the plan and it was
wrong: `docs/capability-system.md` builds on three of them as specified design, so removing
the rows would have left that document referring to keys the contract no longer declares,
and `check-contract.py` says so. A key that describes intended design is not the same thing
as a key nobody wrote down, and the honest fix is to say which is which rather than to make
the second one disappear.

One of the ten deserves its own sentence rather than a marker.

**One key is declared here in snake_case and stored in camelCase, on purpose.**
`grux.services.rag_base_url` is written to the defaults domain under a camelCase spelling
of its last segment (`RAGClient.baseURLDefaultsKey`). Renaming the stored key would orphan anybody who has
already set it, and declaring it here in its stored spelling would put a capital letter in a
namespace this document says is lowercase, where `check-contract.py` would not recognise it
as a key at all and would stop checking it. So the row carries the contract's spelling and
this paragraph carries the truth. It is the only one; every other key matches.

**GRUX HAS NO MODEL SPEND CEILING.** `grux.cost.daily_ceiling_usd` and
`grux.cost.warn_at_fraction` describe one, `capability-system.md` describes a lease that is
refused past it, and nothing in `Sources` implements either. The only spend ceiling in the
tree is `grux.shell.trust_ceiling`, which is about shell authority and not about money.

---

**Amended 2026-08-17, CR-30. `grux.identity.assistant_name` defaults to `Jax`, not `Grux`.**
CR-19 recorded `Grux`, and no code path ever produced it. The shipped persona
(`Jax/JaxProfile.swift`) hardcoded "You are Jax" and nothing read the config key at
all, so the documented default described a value the app could not reach and the
setting changed nothing.

Two things are being separated here, and conflating them is what produced the drift.
The APP is Grux. The ASSISTANT it runs is Jax. `assistant_name` is the second one, so
a user renaming their assistant does not rename the application, its bundle id, its
support directory, or the `Jax HQ` and `Jax Command` feature tabs, which are feature
names rather than the assistant's self-reference.

The default is `Jax` rather than `Grux` on purpose: it is the name the persona already
used, so wiring the key up changes nothing for an existing install. Making a setting
work must not silently rename somebody's assistant.

## 3. Feature state machine

Four states. A feature is in exactly one at any moment.

```
                 all required capabilities present
     needs-setup ────────────────────────────────► ready
          ▲                                          │
          │ a required capability is revoked         │ an optional
          │                                          │ capability
          │                                          ▼ is missing
    unavailable ◄─── platform or build cannot     degraded
                     ever satisfy it
```

| State | Meaning | Sidebar | Surface | Actions |
|---|---|---|---|---|
| `ready` | Every required capability resolved | Normal label, no badge | Full UI | All enabled |
| `needs-setup` | At least one required capability missing, and the user can fix it | Normal label, small dot badge | The feature's own UI, dimmed and non-interactive, with a setup card overlaid listing each missing capability by `label` and its `remediation`, each with a button that goes straight to the relevant Settings pane | Only the setup actions |
| `degraded` | Every required capability and blocking step satisfied, and an optional capability, an optional step, or the cost ceiling is producing the lesser path | Normal label, no badge | Full UI, plus ONE dismissible inline note listing every missing optional item by `label` with its `remediation` | All enabled |
| `unavailable` | Cannot be satisfied on this machine or build | Hidden by default; visible with a struck-through label under Settings, Show unavailable features | A single sentence explaining why, no setup card | None |

**Amended 2026-08-28, CR-36. A fifth state, `not-chosen`.**

A feature can be off because the owner said so, and none of the four states above can say
that. `unavailable` is the closest and it is wrong: it means impossibility, and telling
somebody that Meta Ads cannot be satisfied on this machine when the truth is that they
declined it is a different sentence with a different remedy.

| State | Meaning | Sidebar | Surface | Actions |
|---|---|---|---|---|
| `not-chosen` | The owner did not select this feature | Hidden | Not mounted | None, except turning it on |

**Absence of a selection means EVERYTHING IS ON.** An install that predates this amendment
has no stored selection and must not silently lose thirty nine features on upgrade. Only an
explicit choice can turn anything off.

**This state does not weaken "nothing ships off and undiscoverable", it is the reason that
rule now has teeth.** All three conditions still hold and are now the harder half of the
work: every feature is NAMED at first run, because the CHOOSE screen lists all thirty nine
rather than a curated subset; every feature keeps a PERMANENT HOME in Settings and in
`grux list features`, whether or not it was chosen; and its OFF STATE IS EXPLAINED, which is
what the COST screen does from the other direction when it names what will never be asked
for and why.

Hidden from the sidebar rather than struck through, unlike `unavailable`. A stranger who
chose twelve features should see twelve rows, not thirty nine with twenty seven crossed out,
and the complete list is one command and one Settings pane away.

Rules that make the table binding:

**A missing capability never surfaces as an error.** No alert, no thrown exception, no
empty view, no console-only failure. A feature that cannot resolve a capability renders
`needs-setup`. Anything else is a defect.

**`degraded` is never silent.** The distinction from `ready` exists so a user knows they
are getting the lesser path. The spoken-nudge feature is the worked example: without
`key.elevenlabs` it falls back to `AVSpeechSynthesizer` (`SpeechEngine.swift:91`), which is
genuinely fine, so it is `degraded` and not `needs-setup`, and the note says so once.

**`unavailable` is for impossibility, not absence.** A missing key is `needs-setup`. An
unsupported macOS version is `unavailable`. Hiding by default is deliberate: a stranger
should not scroll past features they can never use.

**The cost ceiling is a state transition, not a silent pause.** When
`grux.cost.daily_ceiling_usd` is reached, any feature that spends moves to `degraded` with
the note "Paused for today. You have reached your $2.00 ceiling. Raise it in Settings or
wait until tomorrow." It does not fail, and it does not keep spending.

---

### 3.1 Setup steps that are not capabilities

Raised as CR-2 by Track A while consuming this contract, and correct. Section 5.4 puts the
focus loop in `needs-setup` while `grux.capture.first_frame_reviewed` is `false`, but the
`needs-setup` rendering above is defined entirely in terms of missing capabilities. An
unreviewed first frame is not a key, a permission or an endpoint. It has no `label` and no
`remediation`, so section 3 as originally written could not render the state section 5.4
required. The two did not compose.

A **setup step** closes that gap. It is a prerequisite that is not a capability, and it
carries the same fields so it renders in the same card with no special case:

```
SetupStep
  id           String    stable, dotted, prefixed `step.`
  label        String    human, title case
  remediation  String    exact UI text, under 140 chars
  satisfied    Bool      resolved by reading config or app state, never guessed
```

**`blocking` was removed in the same amendment, for the same reason.** It had the identical
edge-versus-node defect and it was found while resolving CR-3. `step.agent_cli_installed`
genuinely blocks `agents`, whose entire purpose is that tool, and merely degrades `chat`,
which loses 4 of roughly 50 tools and would otherwise render its default landing surface
dimmed and non-interactive. A step is therefore listed on a feature in `steps` when it
blocks, or in `optionalSteps` when its absence only degrades, exactly mirroring how
capabilities work.

A feature's requirements are therefore capabilities **plus** setup steps, and
`needs-setup` lists both, sorted capabilities first because those usually gate the steps.
Optionality for both lives on the feature, never on the capability or the step.

**An unsatisfied `anyOf` group renders as one entry, not as one per capability.** The card
shows the group's `min`, then every capability in it by `label` with its own `remediation`
and its own button, under a single line naming the count: "Any 1 of these". Listing them
separately would read as though all were required, which is the exact misreading the
relation exists to prevent. An `optionalAnyOf` group that is short renders the same way as
one `degraded` note rather than one note per member.

| id | label | remediation |
|---|---|---|
| `step.first_frame_reviewed` | Review the first capture | Grux will show you one frame, and the exact text it would send, before anything leaves your Mac. Nothing is sent until you approve. |
| `step.agent_cli_installed` | Install the agent command line tool | Install the coding agent command line tool, then restart Grux. It was not found at any location Grux checks. |
| `step.capture_exclusions_confirmed` | Confirm what stays private | Check the list of apps Grux will never look at. Password managers and banking apps are excluded by default. |
| `step.recording_consent_acknowledged` | Confirm you will tell people | Recording a call captures everyone on it, and some places require you to say so first. Confirm you will, then Grux can record. |
| `step.speech_model_downloaded` | Fetch the speech model | Grux fetches a one time on-device speech model before it can transcribe. Connect to the internet and open Meetings once. |
| `step.corpus_sources_confirmed` | Choose what gets indexed | Pick which of your messages, notes and sent mail Grux may index. Nothing is indexed until you choose. |
| `step.terminal_focus_hook_installed` | Install the terminal hook | Grux adds one entry to your coding tool's settings and one script beside it. It removes nothing else. |
| `step.terminal_sessions_explained` | Understand terminal sessions | Read what a headless session runs and which credential it spends, then turn terminal sessions on in Settings. |
| `step.phone_paired` | Pair your iPhone | Open Pair iPhone in Settings and scan the code with the Grux phone app. The pairing secret never leaves your Mac and your phone. |
| `step.youtube_transcripts_enabled` | Turn on YouTube transcripts | Grux reads YouTube captions with yt-dlp when you paste a video link. Turn it on in Settings, and off there whenever you want. |

`step.` ids share the capability namespace rules: closed set, stable, never renamed. The
reconciler treats an unknown `step.` id exactly as it treats an unknown capability id.

## 4. Analytics, stated once so no spec has to decide it

Grux ships with **analytics off, no write key, and no endpoint**. `grux.analytics.enabled`
defaults to `false`, and both `grux.analytics.write_key` and `grux.analytics.host` default
to none. Turning it on requires the user to supply a project they own.

**No analytics capability will be minted in either direction, read or write.** Resolved
2026-08-10, CR-24. The obvious rescue for a usage readout or a spend ring is to ask for an
analytics READ key plus a project id, which reopens the same hole from the other end. Cost
and usage readouts are computed from a local record of Grux's own calls, which the app needs
anyway, because `grux.cost.daily_ceiling_usd` cannot enforce its own state transition in
section 3 without one. Saying this once is cheaper than refusing the same request in every
future review.

This exists in the contract, rather than in a code comment, because the private tree ships
the opposite: a hardcoded write token on by default, reporting to the owner's own project.
Shipping that unchanged would send every stranger's usage to one person's analytics.

---

## 5. The capture privacy layer

Specified here rather than in Track A because both tracks depend on it and it is
non-negotiable. Track A owns the mechanism, section 1.3 owns its capability, section 2.5
owns its keys.

**Verified gap:** grep for `excludeApp|excludedBundle|blocklistApp|excludedApps` across
`Sources/Grux` returns zero matches. Nothing currently stops Grux photographing a password
manager or a banking tab.

### 5.1 What is protected

The JPEG produced at `FocusWatcher.swift:213` and any OCR text derived from it. Redaction
already runs on the outgoing body (`FocusWatcher.swift:498`) and the OCR is fenced
(`FocusWatcher.swift:530`), both via `grux-kit`. **Exclusion is a layer above redaction:
redaction cleans what is sent, exclusion decides whether to look at all.** A password
manager should never reach the redactor.

### 5.2 Exclusion, seeded

Two lists, matched before capture, never after:

- `grux.capture.excluded_bundle_ids`, seeded with password managers, banking and finance
  apps, Messages, Mail, FaceTime, Keychain Access, and any app in the user's own list.
- `grux.capture.excluded_window_titles`, seeded with case-insensitive substrings covering
  private browsing, and common bank and password-manager window titles.

When the frontmost app or window matches, **no capture occurs**. Not captured then
discarded: not captured. The frame never exists in memory, so it cannot leak through a
crash log, a cache, or a later refactor.

### 5.3 The transmission indicator

A visible indicator whenever a frame is **actually transmitted**, not whenever the loop is
running. The distinction matters, because `ScreenPrescreen` deliberately suppresses most
frames, so an always-on indicator would train the user to ignore it while a per-send one
tells the truth.

`grux.capture.indicator_enabled` defaults to `true` and **cannot be set to false in v1**.
The key exists so the decision is visible and reversible later, not so it can be turned
off now. A capture loop with a defeatable indicator is worse than one with no indicator,
because it looks accountable.

### 5.4 First-frame review, which gates the loop

`grux.capture.first_frame_reviewed` defaults to `false`, and while it is false the focus
loop is `needs-setup` regardless of every other capability.

The first time capture is enabled, Grux takes one frame, shows the user **the exact image
and the exact redacted text that would be sent**, and asks for confirmation. Nothing is
transmitted until they confirm. Declining leaves the flag false and the feature in
`needs-setup`.

This is the highest-leverage screen in the product. It converts the loudest objection to
an always-on vision loop into the single most reassuring moment, and it costs one screen.

---

## 6. Feature registry

Raised as CR-1 by Track A, and correct. The contract closed the capability vocabulary and
the config namespace but never defined what a **feature** is, while defining four states a
feature can be in. Track A needs a closed `FeatureID` so a feature cannot be minted at a
call site, and Track B needs the same ids to say which feature a blueprint targets. Two
tracks minting ids independently guarantees divergence, and the reconciler cannot catch
divergence in a vocabulary the contract does not own.

```
Feature
  id             String    stable, lowercase, dotted, never renamed
  label          String    human, title case, what the sidebar shows
  group          Enum      command | workspace | intelligence | ambient | system
  requires       [Capability.id]    absence produces needs-setup
  optional       [Capability.id]    absence produces degraded
  anyOf          [Group]            fewer than min present produces needs-setup
  optionalAnyOf  [Group]            fewer than min present produces degraded
  steps          [SetupStep.id]     absence produces needs-setup
  optionalSteps  [SetupStep.id]     absence produces degraded
  tier           Enum      core | labs

Group
  capabilities   [Capability.id]    two or more, all from section 1
  min            Int                1 <= min < capabilities.count
```

A group is written in the registry as `min of {id, id}`, in the same cell as the flat list
it sits beside, so the ids stay scannable by the reconciler without widening every table.

**Amended 2026-08-10, CR-6.** `requires` is a flat AND, and a feature satisfied by either of
two capabilities had to over-declare, which renders a user who has one of them
`needs-setup` for something that already works. There are two lists rather than one flag
because that is the shape CR-5 settled: optionality is a property of the edge, expressed by
which list the id sits in, and a `degrades: Bool` on the group would be the same
second-source-of-truth defect CR-5 removed.

`min < capabilities.count` is a constraint, not a suggestion. A group whose `min` equals its
count is a flat AND wearing a costume, and one with `min` of zero declares nothing. Either
is a sign the author wanted `requires` and should say so.

**Both examples CR-6 offered were checked against the code and only one of them survived,
which is the more useful half of this amendment.**

`folders` was right and is now `optionalAnyOf: [{[key.anthropic, endpoint.ollama], min: 1}]`.
Its auto-file button routes to a local server when one is configured and falls back to the
cloud key (`Folders/FolderClassifier.swift:28`, `LocalLLM.swift:333-351`), so declaring only
the key printed a "add your key" note at a user whose button already worked.

**`compare` was wrong and deliberately keeps its flat AND.** Its predicate is not a count of
capabilities. `Compare/ComparisonService.swift:37-62` yields one contender from a model key
plus one per local model TAG, and `:72-77` refuses below two, so the real condition is
`(key ? 1 : 0) + tagCount >= 2`. A tag is not a capability and no relation over section 1
can express it. `min: 1` would permit a key alone, which is the permanently broken `ready`
section 3 forbids, and `min: 2` is the AND it already has. The AND errs toward a recoverable
`needs-setup` and that remains the least wrong option available.

The residual hole is named rather than papered over: a key plus a reachable server holding
zero pulled models satisfies every declared capability and still refuses, because
reachability is not model availability. Closing that needs a capability whose resolver
counts models, which is a larger change than this one and is not made here.

**Ids are derived from the sidebar key, and the contract owns the rule so three tracks do
not each guess.** `Feature.id` is lowercase and dotted, and eight sidebar `applyTab` keys are
camelCase and cannot be renamed, because the `--open-tab` automation depends on those strings
verbatim (`DesignSystem/SidebarModel.swift:9-11`, `LaunchRootView.swift:250-256`). So the
sidebar key is not the id. **Lowercase the key, and every camelCase hump becomes a dot.**

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

Every other id equals its sidebar key, which is already lowercase. Adopted from the registry
2026-08-10, CR-8, unchanged.

`group` mirrors the existing sidebar information architecture, so the OSS set is a pruning
of something real rather than a new taxonomy. The five values are verified against
`DesignSystem/SidebarModel.swift`, where `SidebarIA.groups` enumerates 36 tabs across
exactly these five: command (11 tabs), workspace (7), intelligence (6), ambient (3),
system (9).

**Corrected 2026-08-09.** This enum previously read
`command | workspace | intelligence | system | labs`, which was wrong twice over: it
omitted `ambient`, which really exists and holds Meetings, Speakers and Usage, and it
listed `labs`, which is a **tier** and not a sidebar group. The error came from writing the
enum from memory rather than from the file. It is exactly the class of mistake the
reconciler cannot catch, because a plausible wrong enum parses just as well as a right one.

`tier` carries the core versus labs split: `labs` features render behind a Labs section and
carry an honest status line. Shipping something as `labs` is a deliberate statement that it
works roughly and is open to contribution, which is why rough is never a reason to cut.
Personal or harmful is.

**A cut feature is not a registry row and carries no `tier`.** Resolved 2026-08-10, CR-7,
which asked for either a third `tier` value or a statement of where cut rows live. The third
value is refused: `tier` is a RENDERING property of a feature that exists, since `labs` is
defined above purely as where it renders and what status line it carries, and a cut feature
does not render at all. `tier: cut` would overload a render enum with a ship decision and
force ids that must never be constructible into the closed `FeatureID` set. The ship-or-cut
decision and its reasoning live in the registry's own "Cut from the open-source build"
section, where an entry declares no capabilities, no steps, and no id usable at a call site.

The full registry is derived during implementation by pruning the existing sidebar groups
to what the open-source build ships. **It is not enumerated here**, deliberately: the
contract owns the *shape* and the rules, and enumerating 150 rows in a specification
document would guarantee it goes stale against the code. The reconciler enforces that every
blueprint targets a registered feature id once the registry file exists.

## 7. What the contract does not cover

Named so no spec assumes them: model routing and fallback order, the approval tier system
(green, yellow, red) which is orthogonal and needs its own contract, the swarm
orchestrator's concurrency model, and anything about `grux-kit`'s internals, which is a
separate audited package consumed as a dependency.
