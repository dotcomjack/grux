# ship-ios

## What it does

Takes an iOS app from "the code is written" to "it is submitted", without you sitting over
it. It audits the project against your own release checklist, builds it, installs it on a
device so you can actually use it, generates App Store screenshots, walks you through what
it did, waits for you to say go, uploads the build, then checks back a day later to tell
you what Apple said.

## Host

**Workflows** (`CommandsV2`). It is the reference case for the engine, and the tree already
contains two variants of it (`CommandsV2/CommandV2Definitions.swift:176` for the re-ship
path, and the full path with its brainstorm and build swarm). It needs everything only
Workflows has: a swarm phase, approval gates, a scheduled resume that survives the app
being closed, and a branch on what Apple replied.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.appstoreconnect` | key | required | Registering the app, uploading the build, reading the review state. |
| `key.anthropic` | key | required | The build swarm, the fix pass, and the screenshot design pass. |
| `perm.automation` | perm | required | Driving the tools that do the registering and uploading. |
| `perm.notifications` | perm | required | The wait phase is 24 hours long, so the result has to find you. Pending CR-1: should be optional. |

## Config keys read

| key | why |
|---|---|
| `grux.asc.key_id` | App Store Connect key identifier. |
| `grux.asc.issuer_id` | App Store Connect issuer identifier. |
| `grux.asc.p8_path` | Path to the private key file. Permissions are checked. |
| `grux.portfolio.projects` | Resolving a project name to a checkout path. |
| `grux.model.provider` | Which provider runs the swarm and the design pass. |
| `grux.model.chat_id` | Which model runs them. |
| `grux.cost.daily_ceiling_usd` | This is the most expensive blueprint in the set by a wide margin. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

The App Store Connect key identifier and issuer identifier are **not secrets** and live in
the config file (contract 2.5). The `.p8` file is a file on disk whose permissions are
checked. Only genuinely secret values live in Keychain.

## The blueprint itself

Ten phases. Two of them stop and wait for you, and one of them waits for Apple.

| # | phase id | action | note |
|---|---|---|---|
| 1 | `verify-project` | `builtin` `verify-ios-project-ready` | Confirms a buildable project is on disk. |
| 2 | `audit` | `builtin` `convention-audit` | Your release checklist, informational. |
| 3 | `fix-blockers` | `claudeAgent` | Fixes what the audit found. |
| 4 | `re-audit` | `builtin` `convention-audit` | Proves the fixes landed. |
| 5 | `build` | `claudeAgentSwarm` | Parallel workers on the build and its failures. |
| 6 | `install` | `iosTool` `ios_install_to_device` | On your own device, which is not a deploy. |
| 7 | `screenshots` | `iosTool` then `claudeAgent` | Raw frames, then composed marketing frames. |
| 8 | `walkthrough` | `walkthrough` | Tells you what it did before it asks. |
| 9 | `approve` | `userApprovalGate` | The submission gate. Nothing reaches Apple before this. |
| 10 | `publish` then `wait` then `check` | `iosTool`, `speak` with `scheduledFollowup`, `branch` | Upload, sleep a day, report. |

```json
{
  "id": "ship-ios",
  "displayName": "ship the iOS app",
  "voiceTriggers": ["ship the {project}", "submit {project}", "publish {project}"],
  "description": "Audit, build, install, screenshot, review, submit, then check what Apple said a day later.",
  "category": "ship",
  "parameters": [
    { "name": "project", "kind": "projectPath", "prompt": "Which iOS project should I ship?" }
  ],
  "phases": [
    {
      "id": "verify-project",
      "displayName": "Verify the project is buildable",
      "userApprovalRequired": false,
      "action": {
        "kind": "builtin",
        "name": "verify-ios-project-ready",
        "args": { "project": "${param.project}" }
      }
    },
    {
      "id": "audit",
      "displayName": "Audit against your release checklist",
      "userApprovalRequired": false,
      "action": {
        "kind": "builtin",
        "name": "convention-audit",
        "args": {
          "projectDir": "${param.project}",
          "brand": "${param.project}",
          "conventionsPath": "<your-conventions-file-path>"
        }
      }
    },
    {
      "id": "fix-blockers",
      "displayName": "Fix what the audit found",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Read the audit report at ${state.audit_report_path}. For every check with status FAIL, apply the fix in code. Fix, do not propose.\n\nRules that keep this safe to run unattended:\n1. Change only files inside ${state.project_root}. Never touch anything outside it.\n2. Never change a version number, a bundle identifier, or a signing setting. Those are decisions, not fixes.\n3. Never delete a file. If a check wants something removed, comment it out and note it.\n4. After all fixes, regenerate the project if it uses a generator, then run a compile-only build. Warnings do not fail this phase, lines beginning 'error:' do.\n5. Anything you could not fix goes in ${state.project_root}/audits/deferred.md with the check name and why. Do not silently skip a check.\n\nPrint a tight summary listing every check you fixed and the files you touched. No em dashes, no en dashes.",
        "maxTokens": null
      }
    },
    {
      "id": "re-audit",
      "displayName": "Re-audit after the fixes",
      "userApprovalRequired": false,
      "action": {
        "kind": "builtin",
        "name": "convention-audit",
        "args": { "projectDir": "${param.project}", "brand": "${param.project}" }
      }
    },
    {
      "id": "build",
      "displayName": "Build",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgentSwarm",
        "sharedTools": ["fs_read", "fs_write", "shell"],
        "prompts": [
          "Build ${param.project} for a device destination and drive it to zero errors. Report the exact failing lines if you cannot. Do not change the version, the bundle identifier, or any signing setting.",
          "Run the unit test target of ${param.project} and report which tests fail with their assertion messages. Treat zero tests collected as a failure, not a pass. Fix only tests broken by the audit fixes in this run, never by weakening an assertion.",
          "Build ${param.project} for a simulator destination and confirm it launches without crashing on first screen. Capture the crash log if it does."
        ]
      }
    },
    {
      "id": "install",
      "displayName": "Install to your device",
      "userApprovalRequired": false,
      "action": {
        "kind": "iosTool",
        "name": "ios_install_to_device",
        "input": { "project": "${param.project}" }
      }
    },
    {
      "id": "screenshots-capture",
      "displayName": "Capture simulator frames",
      "userApprovalRequired": false,
      "action": {
        "kind": "iosTool",
        "name": "ios_generate_screenshots",
        "input": { "project": "${param.project}" }
      }
    },
    {
      "id": "screenshots-design",
      "displayName": "Compose the store screenshots",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Compose App Store screenshots for ${param.project}. Raw simulator frames are at ${state.screenshots_dir}.\n\nEach composite is a marketing frame, not a raw screen: a headline of 5 to 8 words, a sub-line of at most 14 words, the raw frame inside device chrome, and a background tinted from the app's own accent colour. Compose them at the size your store listing requires and write them to <project>/marketing/screenshots/composed/.\n\nAlso write <project>/marketing/store-copy.md carrying subtitle, promotional text, keywords, what is new in this build, and the per-screenshot copy mapped to filenames.\n\nUse only local image tools. Do not call an image generation service: these are compositions of frames you already have, and generating them would cost money and produce screenshots of an app that does not exist.\n\nExit when the composed folder has the same file count as the raw folder and store-copy.md exists. No em dashes, no en dashes.",
        "maxTokens": null
      }
    },
    {
      "id": "walkthrough",
      "displayName": "Walk through what happened",
      "userApprovalRequired": true,
      "action": {
        "kind": "walkthrough",
        "points": [
          { "title": "Audit", "body": "The checklist ran twice. ${state.audit_blockers} blockers and ${state.audit_warnings} warnings remained after the fix pass." },
          { "title": "Build", "body": "The build swarm finished. Success was ${state.last_swarm_success}." },
          { "title": "On your device", "body": "The build is installed. Open it and use it before you approve the submission." },
          { "title": "Screenshots", "body": "Composed frames and store copy are under marketing in the project folder. Look at them, they are what strangers see first." }
        ]
      }
    },
    {
      "id": "approve",
      "displayName": "Approve the submission",
      "userApprovalRequired": true,
      "action": {
        "kind": "userApprovalGate",
        "prompt": "Everything is staged for ${param.project}. This next step uploads a build to Apple and it is not reversible in the way a local build is. Say ship it to submit, or stop to leave it staged.",
        "expectedReplies": ["ship it", "stop"]
      }
    },
    {
      "id": "publish",
      "displayName": "Upload to App Store Connect",
      "userApprovalRequired": false,
      "action": {
        "kind": "iosTool",
        "name": "ios_publish_to_appstore",
        "input": { "project": "${param.project}" }
      }
    },
    {
      "id": "wait-for-review",
      "displayName": "Wait a day for review",
      "userApprovalRequired": false,
      "scheduledFollowup": { "nextPhaseId": "check-status", "interval": 86400, "interruptUserOnFire": false },
      "action": {
        "kind": "speak",
        "text": "${param.project} is submitted. I will check what Apple says in 24 hours."
      }
    },
    {
      "id": "check-status",
      "displayName": "Check the review state",
      "userApprovalRequired": false,
      "action": {
        "kind": "iosTool",
        "name": "ios_check_asc_status",
        "input": { "project": "${param.project}" }
      }
    },
    {
      "id": "decide-next",
      "displayName": "Branch on what Apple said",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": { "kind": "ascSubmissionState", "equals": "REJECTED" },
        "ifTrue": "rejected",
        "ifFalse": "still-waiting"
      }
    },
    {
      "id": "still-waiting",
      "displayName": "Not rejected",
      "userApprovalRequired": false,
      "scheduledFollowup": { "nextPhaseId": "check-status", "interval": 86400, "interruptUserOnFire": false },
      "action": {
        "kind": "speak",
        "text": "Apple says ${state.asc_state} for ${param.project}. I will check again tomorrow."
      }
    },
    {
      "id": "rejected",
      "displayName": "Rejected",
      "userApprovalRequired": false,
      "action": {
        "kind": "interruptOnNextActive",
        "message": "${param.project} was rejected. Apple's reason is in the review notes, and nothing has been changed or resubmitted.",
        "audioCue": { "kind": "warningChime", "postSpeakDelay": 0.4 }
      }
    }
  ]
}
```

Until CR-3 lands there is no on-disk install path for a workflow definition. Add the
equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and list it in
`registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or call
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- App Store Connect API key: "Add your App Store Connect key, issuer ID and .p8 file in Settings to let Grux publish builds."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Automation: "Grux needs Automation to control other apps. Approve the prompt macOS shows, or enable Grux under Privacy and Security, Automation."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

If you have hit `grux.cost.daily_ceiling_usd`, the feature is `degraded` with the note
"Paused for today. You have reached your $2.00 ceiling. Raise it in Settings or wait until
tomorrow." A default $2.00 ceiling will not fund a full run of this workflow, and that is
deliberate: it means a stranger cannot accidentally start a multi-hour spend on their first
day.

## Example, not a default

```
Example, not a default

Config:

  "grux.asc.key_id": "<your-asc-key-id>",
  "grux.asc.issuer_id": "<your-asc-issuer-id>",
  "grux.asc.p8_path": "/Users/you/.appstoreconnect/private_keys/AuthKey_<your-key-id>.p8",
  "grux.cost.daily_ceiling_usd": 25.00

Started with:

  project = acme-ios

Timeline of a real-shaped run:

  0:00   verify-project    ok, project.yml found
  0:01   audit             31 of 38 checks passed, 3 blockers, 4 warnings
  0:14   fix-blockers      fixed 3 blockers, 2 warnings, 2 deferred to audits/deferred.md
  0:16   re-audit          36 of 38 passed, 0 blockers
  0:52   build             3 workers, success
  0:55   install           installed to your device
  1:09   screenshots       8 raw frames, 8 composed, store-copy.md written
  1:10   walkthrough       waiting on you
  1:41   approve           you said ship it
  1:58   publish           build uploaded, processing
  25:58  check-status      WAITING_FOR_REVIEW
  49:58  check-status      READY_FOR_SALE

The key identifier and issuer identifier above are placeholders. Real ones belong in your
own config and are worth treating as sensitive even though the contract correctly notes
they are not secrets.
```

## Honest limitations

- **This is the most expensive and least reversible blueprint here.** A build swarm is
  several agents running for a long time, and the publish phase puts a binary in front of
  Apple under your developer account. The approval gate is the only thing standing between
  a run and a submission, so never remove it and never lower its `expectedReplies` to
  something a passing comment could match.
- **"Hands off" is the goal, not the reality.** It stops for you twice by design, and it
  will stop unexpectedly more often than that: a signing prompt, a two-factor challenge, a
  provisioning profile that needs regenerating. Expect to be present for the first few runs
  of any new project.
- **The fix pass edits your source unattended.** The prompt fences it to the project root
  and forbids version, identifier, signing and deletion changes, and those fences are
  instructions to a model, not enforced permissions. Run it on a branch with everything
  committed, so the diff is reviewable and the undo is a `git checkout`.
- **The audit is only as good as your checklist file.** Point
  `conventionsPath` at a file you wrote. There is no shipped checklist, and a checklist you
  did not write will pass things you care about and fail things you do not.
- **Apple's review state is the only thing it checks after submission.** It does not read
  the rejection reason, and the rejected branch deliberately does nothing except tell you.
  Automatically responding to a rejection is a decision, not a step.
- **The 24 hour wait depends on the app surviving.** `scheduledFollowup` re-arms on launch
  (`CommandsV2/CommandV2Engine.swift:120`), so a closed Grux resumes when reopened, and a
  Grux that stays closed for three days checks late by three days.
- **Screenshot composition is a model composing images with local tools.** Results vary run
  to run, and a bad set of composed frames is worse than raw screenshots. Look at them
  during the walkthrough, that is what the walkthrough is for.
- **One ship run per project at a time.** The engine refuses a second concurrent ship run
  for the same project (`CommandsV2/CommandV2Engine.swift:157-169`), which is correct and
  means a stuck run must be cancelled before you can retry.
