# iOS App Launch Workflow, `ship-ios-app`

**Status:** spec, ready to implement
**Author:** Claude (Opus 4.7)
**Date:** 2026-04-25
**Depends on:** `2026-04-25-grux-commands-v2.md` (the engine that runs this)

---

## What this is

A single Grux command, `ship the iOS app`, that takes a Mac-side project from "I have an idea" all the way to "live on the App Store" with at most three explicit user inputs from you:

1. The brainstorm conversation that defines the spec (existing `superpowers:brainstorming` skill, hosted in Grux chat).
2. The walkthrough approval on TestFlight install ("yes, this looks right, ship it").
3. (Optional) approval after Apple rejects, of the proposed fix.

Everything else, building, version bumping, signing, IPA export, ASC upload, ASC metadata, In-App Events, Custom Product Pages, localizations, privacy/accessibility audit, review-prompt code, the 24-hour-wait timers, the rejection-recovery loop, and the celebration, runs without intervention.

This is the first concrete consumer of Commands V2. It also exercises every V2 capability (phases, gates, scheduled resumes, branches, agent swarms, interrupt-on-active), making it a strong forcing function on V2's design.

---

## Why this exists

The workflow has to run hands-free. Anything that requires "open ASC and click submit" or "wait 24 hours and check again" is friction you shouldn't have to schedule your life around, and clicking through a web console is not an acceptable step in this pipeline. Today the Sample App launch worked because Claude held an unbroken session for hours. That doesn't scale to ten apps.

The workflow has to:

- Survive Grux restarts and Mac reboots (a 24-hour wait crosses both).
- Never actively poll the ASC API in a tight loop. Use the system scheduler.
- Wait for "the owner is actually here right now" before delivering celebrations or rejection news, instead of barking at an empty room.
- Be repeatable across all of the owner's apps (App Alpha, App Beta, App Gamma, App Delta, GruxAI, future ones).

---

## Reference implementation: Sample App

What just shipped (2026-04-24 → 2026-04-25):

- v2.1.0 → live on the App Store after a <1 hour Apple review.
- v2.2.0 (Pond redesign) → submitted, currently `WAITING_FOR_REVIEW`.
- 4 In-App Events seeded.
- 3 Custom Product Pages submitted for review.
- 6 AppInfoLocalizations created.
- App Privacy + Accessibility tightened.
- Featuring nomination text drafted.
- App Preview storyboard drafted.
- In-app review prompt code shipped.

The ASC Launch Toolkit scripts that drove this live alongside the app project:

- `asc-api.js`, JWT-signed REST wrapper
- `asc-status.js`, full state survey
- `asc-fix-02-create-version.js`, version create + metadata + build attach + review detail
- `asc-fix-04-submit-2.2.0.js`, generalized submission orchestrator with build polling
- `asc-fix-05-inapp-events.js`, In-App Events
- `asc-fix-06-custom-product-pages.js`, Custom Product Pages
- `asc-fix-07-version-localizations.js`, locale-native description/keyword translations (queued)
- `asc-fix-08-appinfo-localizations.js`, appInfoLocalizations
- `asc-fix-09-privacy-audit.js`, privacy declarations diff
- `asc-fix-10-accessibility.js`, accessibility declarations
- `asc-fix-11-reviews.js`, review responses (auto-thanks 4-5★, drafts 1-3★)
- `asc-fix-12-promo-codes.js`, promo code request (no-op for free apps)

These are the implementation backbone of the workflow. Generalizing them to "any project, not just Sample App" is one of the implementation tasks below.

---

## High-level state machine

```
┌──────────────┐     ┌─────────┐     ┌────────┐     ┌─────────────┐     ┌─────────┐
│ brainstorm   │────▶│ build   │────▶│ install│────▶│ walkthrough │────▶│ publish │
│ (Claude+you) │     │ (swarm) │     │(device)│     │ (gate)      │     │ (ASC)   │
└──────────────┘     └─────────┘     └────────┘     └─────────────┘     └────┬────┘
                                                                              │
                                              ┌───────────────────────────────┘
                                              ▼
                                      ┌──────────────┐
                                      │ wait 24h     │  (no polling, scheduled wake)
                                      └──────┬───────┘
                                             │
                                             ▼
                                      ┌──────────────┐
                                      │ check status │
                                      └──────┬───────┘
                                             │
                       ┌─────────────────────┼─────────────────────┐
                       ▼                     ▼                     ▼
               ┌──────────────┐    ┌──────────────┐       ┌──────────────┐
               │ still pending│    │ rejected     │       │ approved     │
               │ → wait 24h   │    │ → recover    │       │ → celebrate  │
               └──────────────┘    └──────┬───────┘       └──────────────┘
                                          │
                                          ▼
                                  ┌──────────────┐
                                  │ read message │
                                  │ propose fix  │
                                  │ apply + push │
                                  │ resubmit     │
                                  │ → wait 24h   │
                                  └──────────────┘
```

---

## Phase-by-phase definition (Commands V2 JSON shape)

```jsonc
{
  "id": "ship-ios-app",
  "displayName": "ship the iOS app",
  "voiceTriggers": [
    "ship the iOS app",
    "ship {project}",
    "publish {project} to the app store",
    "release {project}"
  ],
  "category": "ship",
  "parameters": [
    {
      "name": "project",
      "kind": "projectPath",
      "prompt": "Which project should I ship? (path or known alias)"
    }
  ],
  "phases": [
    /* ... 9 phases follow ... */
  ]
}
```

---

### Phase 1 · `brainstorm`

**Action:** `claudeAgent`
**System prompt** invokes the existing `superpowers:brainstorming` skill, with the project's `CLAUDE.md` and `README.md` as opening context.
**Approval gate:** yes, phase ends only when the brainstorm produces a written spec and you type "approved" / "looks good" / "go" in chat (one of `expectedReplies`).
**State written:** `state[spec_path] = "<repo>/docs/superpowers/specs/<date>-<topic>-design.md"`

Notes:
- If the project already has a spec for the current iteration (passed via params), this phase is auto-skipped (`branch` checks `state[skip_brainstorm] == true`).
- Grux speaks: "Starting brainstorm with you on `<project>`. I'll be in chat."

---

### Phase 2 · `build`

**Action:** `claudeAgentSwarm`
**Behavior:** spin up N parallel Claude agents (typical N = 5, configurable per project), each owning a slice of the codebase, each given the spec from Phase 1. Pattern proven on the Sample App Pond redesign, Home / Player / Profile / Auth / secondary-screens-and-tabs.
**Iteration cap:** up to **6 iterations** (the owner's "v6"). Each iteration consists of: (a) agents make changes, (b) `ios_build_verify` runs, (c) tests run, (d) if green, exit; if red, agents read errors, fix, loop. Cap at 6 to avoid infinite loops.
**Approval gate:** no, this is the engine's job; you only see output if it fails to converge in 6 iterations, in which case the run pauses with `blockingReason = "build did not converge after 6 iterations"`.
**State written:** `state[build_iteration_count]`, `state[build_succeeded] = true`, `state[ios_build_verify_output]`

Per-project plumbing the engine inherits from existing infrastructure:
- `IOSDispatcher.dispatch("ios_build_verify", ...)` from `Sources/GruxShellCore/IOSDispatcher.swift`.
- Two-source-tree rsync (Sample App's `mobile/` ↔ `sample-app-build/`) is project-specific; the engine reads it from `<project>/.grux/ship-config.json` if present.

---

### Phase 3 · `install`

**Action:** `iosTool` → `ios_simulator_run` is wrong here; we want a real device install. Add a new tool to `IOSDispatcher`: `ios_install_to_device` that runs the project's `scripts/install-to-device.sh` (Sample App already has this) or, for projects without one, runs the canonical `xcodebuild` + `xcrun devicectl device install app` sequence.
**Pre-check:** the device must be paired (`xcrun devicectl list devices | grep "available (paired)"`); if not, run pauses with `blockingReason = "no paired iPhone available; connect device and resume"`.
**Approval gate:** no.
**State written:** `state[device_udid]`, `state[installed_app_path]`, `state[installed_at]`

If launch fails because phone is locked (the well-known `FBSOpenApplicationErrorDomain error 7`), the engine treats that as success of the install step, installation succeeded, the launch attempt is best-effort. The walkthrough phase will speak to you to unlock and tap.

---

### Phase 4 · `walkthrough`

**Action:** `walkthrough` (V2 native action)
**Behavior:** Grux opens chat and walks through one feature point at a time, each from the diff between the live App Store version and the just-built one. For each point: title + 2-3 sentence description + optional demo (e.g. fire a deep link to the iPhone, or open a screenshot in the chat panel).
**Approval gate:** YES, the entire phase ends only when you approve with a phrase like "ship it" / "approved" / "go". Chat-side typing OR voice-side speaking both count.
**State written:** `state[walkthrough_approved_at]`, `state[walkthrough_notes]` (any free-form text you typed during walkthrough)

The list of feature points is generated by a sub-`claudeAgent` step that reads the spec + the actual git diff and produces a `[WalkthroughPoint]` array. So this phase is technically two sub-actions: `claudeAgent` (to generate the points) → `walkthrough` (to deliver them).

---

### Phase 5 · `publish`

**Action:** `claudeAgent` with the `iosTool` and `shell` tools available.
**Behavior:** the agent runs the ASC Launch Toolkit scripts in dependency order:

1. Bump version + build number in `Info.plist` and any sub-target plists.
2. `xcodebuild archive` with manual distribution signing (per the lessons from the Sample App 2.2.0 archive, automatic signing in the project's .pbxproj is hardcoded to `Apple Development`, must be overridden).
3. `xcodebuild -exportArchive` with `signingStyle=manual` and explicit `provisioningProfiles` map.
4. `xcrun altool --upload-app` to App Store Connect.
5. `node asc-fix-04-submit-<version>.js` (the project's submission orchestrator), creates the appStoreVersion, copies localization, polls until VALID, attaches build, sets review detail, submits.
6. Run growth toolkit (`asc-fix-05` In-App Events, `06` Custom Product Pages, `08` AppInfoLocalizations, `09` Privacy audit, `10` Accessibility, `11` review responses), only the additive ones; DON'T re-run things that touched existing pages still in review.

**Approval gate:** no, this is fully automated.
**State written:** `state[asc_version_id]`, `state[asc_build_id]`, `state[asc_submission_id]`, `state[asc_submitted_at]`

Per-project plumbing the engine reads from `<project>/.grux/ship-config.json`:
```jsonc
{
  "ascAppId": "<your-asc-app-id>",
  "bundleId": "com.example.sampleapp",
  "teamId": "<your-team-id>",
  "ascApiKeyId": "<your-asc-key-id>",
  "ascApiKeyIssuerId": "<your-asc-issuer-id>",
  "ascApiKeyPath": "./mobile/AuthKey_<your-asc-key-id>.p8",
  "distSigningIdentity": "Apple Distribution: <your-name> (<your-team-id>)",
  "distProvisioningProfile": "Sample App EAS AppStore",
  "infoPlistPath": "ios/SampleApp/Info.plist",
  "subTargetPlists": ["widget/Info.plist", "watchapp/Info.plist", "targets/watch/Info.plist"],
  "twoSourceTreeRsync": {
    "from": "mobile",
    "to": "/Users/<your-username>/sample-app-build",
    "subdirs": ["app", "components", "lib", "contexts", "hooks", "plugins"]
  },
  "submissionOrchestrator": "asc-fix-04-submit-<version>.js",
  "growthToolkit": {
    "events": "asc-fix-05-inapp-events.js",
    "customProductPages": "asc-fix-06-custom-product-pages.js",
    "appInfoLocalizations": "asc-fix-08-appinfo-localizations.js",
    "privacy": "asc-fix-09-privacy-audit.js",
    "accessibility": "asc-fix-10-accessibility.js",
    "reviewResponses": "asc-fix-11-reviews.js"
  }
}
```

If a project doesn't have `ship-config.json`, Phase 5 pauses with `blockingReason = "ship-config.json missing, see template at <repo>/docs/templates/ship-config.json"`. The template ships with V2.

---

### Phase 6 · `wait-for-review`

**Action:** `scheduleResume` at `now + 24 hours`, target phase `check-status`.
**Behavior:** writes `nextWakeAt` on the run, persists, and exits the engine loop. `CommitmentScheduler` (`Sources/Grux/Reminders/CommitmentScheduler.swift`) holds the timer.
**On Mac restart:** Grux launch loads the run from disk and re-arms the timer with the remaining interval.
**Approval gate:** n/a, this phase is a no-op aside from scheduling.
**State written:** `state[next_check_at]`

Speak to the owner on entering this phase: "`<project>` is in Apple's review queue. I'll check back tomorrow at `<HH:MM>`."

---

### Phase 7 · `check-status`

**Action:** `iosTool` → new `ios_check_asc_status` (extends `IOSDispatcher`).
**Behavior:** queries ASC for the version's `appStoreState`. Branches via the V2 `branch` action:

```
state[asc_state] in [WAITING_FOR_REVIEW, IN_REVIEW]      → goto wait-for-review
state[asc_state] in [REJECTED, METADATA_REJECTED,
                     INVALID_BINARY, DEVELOPER_REJECTED] → goto rejection-recover
state[asc_state] in [READY_FOR_SALE, PROCESSING_FOR_DISTRIBUTION,
                     PENDING_DEVELOPER_RELEASE]          → goto celebrate
otherwise (unknown / new state)                          → pause, blockingReason
```

`ios_check_asc_status` reads the rejection MESSAGE if available, for the v1 ASC REST API, the actual reviewer feedback isn't always exposed via API (this was a hard-won lesson during the Sample App 2.0 → 2.1.0 rescue). Fallback: scrape the ASC web UI via existing `claude-in-chrome` MCP tools. The tool returns both `state` and a best-effort `feedbackText`.
**State written:** `state[asc_state]`, `state[asc_feedback_text]`, `state[asc_last_checked_at]`

---

### Phase 8a · `rejection-recover` (only entered when state == REJECTED)

**Action:** `claudeAgentSwarm` (variant: 1 reasoning agent + 1 implementation agent).
**Behavior:**

1. Reasoning agent reads `state[asc_feedback_text]`, the `CLAUDE.md`, and the project structure. Drafts a fix plan: "Apple flagged X. The fix is to do Y in files [a, b, c]."
2. The plan is presented to you via chat as a `userApprovalGate`, you confirm or reject the proposed fix.
3. On approval, an implementation agent (or a small swarm if the fix touches many files) applies the fix, runs `ios_build_verify`, ensures clean.
4. The publish phase is replayed (with version + build number bumped automatically, read the highest existing build number from ASC and increment).
5. Re-enter `wait-for-review`.

**Approval gate:** YES, you must approve the fix plan before code changes.
**State written:** appended to `state[rejection_history]` array; each entry has feedback text, fix plan, applied diff summary, new submission id.

This is where the owner's instruction to "copy the entire rejection message top/bottom" is automated: the agent gets the full feedback as context, not a summary. If the message comes from the ASC web UI (because the API didn't expose it), the screenshot itself is included as image context.

---

### Phase 8b · `celebrate` (only entered when state == READY_FOR_SALE / PENDING_RELEASE)

**Action:** `interruptOnNextActive` (the V2 native action).
**Behavior:** the engine arms a watcher on `AmbientState.lastVoiceActivity` and `ChatActivity.lastUserTyping`. When *both* show recent activity (within ~60s) AND `currentTask` indicates the owner isn't in a deep-focus block, the watcher fires:

1. Wait for any in-progress Grux speech to end (`SpeechEngine.idle`).
2. Speak (with the existing `SpeechEngine`):
   > "Also, good news, `<project>` is approved on the App Store. You shipped anotha one."
3. Play `AudioCue.djKhaledAnotherOne`, a 4-second clip of the canonical "ANOTHER ONE" yell, mixed at -3 dB so it doesn't blow the user's ears.
4. Mark the run `completed`, write `completedAt`, persist.

The clip lives at `Resources/audio/celebrations/dj-khaled-another-one.m4a` (ship a 4s clip with the build, short enough that no licensing question arises for personal-machine playback; if you want to vary the celebration audio per app, expose `state[celebration_audio]` to override).

**Approval gate:** n/a.
**State written:** `state[celebrated_at]`.

The "smooth manner" requirement is implemented by the active-detection watcher: Grux only celebrates when the owner is already engaged. If the owner is asleep, in a meeting (per `Meeting/AudioWAL`), or in a deep-focus block, the celebration waits.

---

### Phase 8c · `still-pending` (only entered when state == WAITING_FOR_REVIEW / IN_REVIEW)

**Action:** loops back to `wait-for-review` for another 24h. Speaks once: "Apple is still reviewing `<project>`. I'll check again tomorrow at `<HH:MM>`."

Cap at 7 cycles (one week), beyond that, pauses the run with `blockingReason = "Apple review pending > 7 days; consider expediting"`. Apple expedited review is a UI-only step.

---

## New `IOSDispatcher` tools to add

The existing dispatcher (`Sources/GruxShellCore/IOSDispatcher.swift`) currently handles `ios_doctor`, `ios_scaffold`, `ios_build_verify`, `ios_simulator_run`. This workflow needs three more:

| Tool | What it does |
|---|---|
| `ios_install_to_device` | Runs `scripts/install-to-device.sh` if present, else canonical `xcodebuild` + `devicectl device install app`. Reads `ship-config.json` for project specifics. |
| `ios_publish_to_appstore` | Bump version, archive, export, upload, run submission orchestrator. The big one. Drives steps 1-5 of Phase 5. |
| `ios_check_asc_status` | Query ASC for current `appStoreState` of the latest submission; pull rejection feedback if present (REST + web-UI fallback). |

All three follow the existing `IOSDispatcher` contract: take a `[String: Any]` input, return flat text suitable as an Anthropic tool result.

---

## ship-config.json template (ships at `<grux-mac>/docs/templates/ship-config.json`)

Single file per iOS project, lives at `<project-root>/.grux/ship-config.json`. The template documents every field with comments. Without it, Phase 5 refuses to publish.

Example provided in Phase 5 above. Sample App's instance is an explicit anchor reference; copy and edit per app.

---

## Voice triggers

```
"ship the iOS app"                          → asks which project (or uses focused project)
"ship the sample app"                       → resolves "sample app" to project
"ship <project>"                            → wildcard
"publish <project> to the App Store"        → same
"release <project>"                         → same
"what's the status of <project>"            → fires check-asc-status one-off (not the full ship workflow)
"cancel the sample app ship"                → cancels the active run
"what are you doing right now"              → lists active runs + current phase
```

---

## Edge cases the spec must handle

1. **Two ship runs for the same project active at once.** Engine refuses to start a second one; speaks: "There's already a ship run for `<project>` in progress, currently in phase `<phase>`."
2. **ASC API key expired or revoked.** Phase 5 publish step catches the 401, pauses the run with `blockingReason = "ASC API key invalid; rotate at <link>"`.
3. **xcodebuild archive fails repeatedly with same error.** Implementation agent gets 3 retries; on the 4th, run pauses with `blockingReason` containing the last 50 lines of `sample-app-archive.log` (or equivalent).
4. **Apple Search Ads / Featuring nomination steps.** These are intentionally NOT in the workflow, they're UI-only and require human judgment per app. The workflow's Phase 5 publish drops a markdown reminder into `<project>/marketing/post-launch-checklist.md` that lists these as 1-click follow-ups you can do at your leisure.
5. **Mac asleep during scheduled wake.** macOS suppresses timers in deep sleep. `CommitmentScheduler` already uses `NSBackgroundActivityScheduler` which wakes the Mac if AC-powered, otherwise fires on next wake. Acceptable: a 24h wake might fire at 26h instead. The check-status phase doesn't care about exact timing.
6. **Run interrupted mid-phase by Mac shutdown.** On next Grux launch, the run resumes from the last persisted phase boundary (not mid-phase). Side effects up to that boundary are assumed durable (git commit, ASC submission). Side effects within a phase that haven't reached the boundary are re-run; phase actions are designed to be idempotent.
7. **Project hasn't been published before (first launch).** A `state[is_first_launch]` flag is set if no existing `appStoreVersion` exists in ASC; Phase 5 takes a different path that creates the very first version (per `asc-fix-02-create-version.js`'s pattern) instead of bumping a previous one.
8. **App is rejected for content/policy reasons that need human + product decision.** If the rejection message contains keywords like "guideline 4.0", "policy violation", "objectionable content", the recover phase escalates: it speaks to the owner at next active session and pauses the run for full human handling rather than auto-applying a fix.

---

## Implementation order (rough plan, turn into writing-plans output before coding)

1. **`ship-config.json` template + reader**, cheapest win, unblocks everything else.
2. **Three new `IOSDispatcher` tools** (`ios_install_to_device`, `ios_publish_to_appstore`, `ios_check_asc_status`) with thin Swift wrappers around existing scripts.
3. **`ship-ios-app` definition JSON**, the static phase list.
4. **End-to-end dry run** of the workflow on a *throwaway* sample project (NOT a live app), verify all the wiring before pointing at real ASC.
5. **First real run on a low-stakes app** (e.g. one of the owner's smaller apps that hasn't shipped yet), catch real-world friction.
6. **Rollout to Sample App's next launch cycle** (when 2.2.0 ships and 2.3.0 is queued).
7. **Generalize ship-config to App Alpha, App Beta, etc.**, one config per app.

---

## Acceptance test

A fresh checkout of an iOS project, with only a `ship-config.json` populated, can be published to the App Store and have the celebration trigger correctly via the single voice command "`ship the iOS app`", with at most three owner interactions across the entire ~25-hour run:

1. Brainstorm conversation (Phase 1 gate)
2. Walkthrough approval (Phase 4 gate)
3. (If Apple rejects) fix-plan approval (Phase 8a gate)

The Mac can reboot during the 24-hour wait and the workflow still resumes correctly.

---

## Out of scope

- Anything Android (separate workflow, separate spec).
- App Preview video generation (storyboard exists; rendering is its own pipeline, see `marketing/app-preview-storyboard.md` from the Sample App launch).
- Apple Search Ads campaign management.
- Featuring nomination UI submission (manual paste, text drafted in workflow's Phase 5 marketing-checklist drop).
- Privacy nutrition labels web-UI declarations (manual, but binary manifest is correct).
- Accessibility DRAFT → PUBLISHED toggle (manual single-click attestation).

These five items remain the only manual steps after a successful run. Each takes < 60 seconds in the ASC web UI.

---

## Open questions

- **Should the `walkthrough` phase actually demo features ON the iPhone**, or just describe them in chat? If on-phone, we'd need a `sampleapp://` (or per-app) deep-link convention for "show me feature X." Best to start chat-only and add device-side demos in V2.1.
- **How aggressive is the rejection-recover agent allowed to be?** A truly autonomous agent could push 4 versions in 4 days if it keeps misreading rejections. Current spec says the fix-plan gate stops that. Revisit if the gate proves too noisy in practice.
- **Should there be a "shipped" Slack/email notification on top of the spoken celebration?** Probably not, the owner has explicitly said the celebration moment is what matters. Pure speech + audio cue. Out-of-band channels can be added if requested.
