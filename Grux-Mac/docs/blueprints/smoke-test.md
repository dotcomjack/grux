# smoke-test

## What it does

Proves Grux itself is working. It runs a short sequence that touches every moving part in
turn, speaking, remembering a value, running something, making a decision based on what it
remembered, and reporting, then tells you pass or fail. When something feels off, run this
first: it takes seconds and it tells you whether the problem is Grux or the thing you were
pointing it at.

## Host

**Workflows** (`CommandsV2`). It has to be, because the thing being tested is the workflow
engine. The tree already contains exactly this idea as `smoke-hello-world`
(`CommandsV2/CommandV2Definitions.swift:15`), which chains speak, setState, builtin echo,
branch, speak and exists so that "if this passes, the engine substrate is healthy". This
blueprint is that idea extended into something a stranger can read the result of.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| (none) | | | The core sequence uses `speak`, `setState`, `builtin` and `branch`, none of which touch a network or a credential. |

That is the point. A self-check that needs an API key cannot tell you whether your API key
is the problem. There is an optional extension below that adds one model call, and it is
deliberately the last phase, so a failure there is unambiguous.

If you install the extension, it requires `key.anthropic`, with the remediation "Add your
Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."

## Config keys read

| key | why |
|---|---|
| (none for the core) | The core sequence reads no configuration at all. |
| `grux.model.provider` | Extension only: which provider to reach. |
| `grux.model.chat_id` | Extension only: which model to reach. |
| `grux.cost.daily_ceiling_usd` | Extension only: the extension is one small call, but it is still a call. |

## The blueprint itself

Eight phases. Every phase that can fail writes a marker into state, and the final phase
branches on whether every marker is present, so a partial pass reports as a fail rather
than as a pass with a gap.

```json
{
  "id": "smoke-test",
  "displayName": "smoke test",
  "voiceTriggers": ["smoke test", "self check", "is grux working"],
  "description": "Headless self-check. Exercises speech, state, a builtin, the shell, a branch, and the filesystem, then reports pass or fail.",
  "category": "system",
  "parameters": [],
  "phases": [
    {
      "id": "start",
      "displayName": "Start",
      "userApprovalRequired": false,
      "action": { "kind": "speak", "text": "Running the Grux self check." }
    },
    {
      "id": "check-state",
      "displayName": "Write a value into run state",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "probe",
        "valueExpr": { "kind": "literal", "value": "alive" }
      }
    },
    {
      "id": "check-builtin",
      "displayName": "Run a builtin",
      "userApprovalRequired": false,
      "action": {
        "kind": "builtin",
        "name": "echo",
        "args": { "text": "builtin reached" }
      }
    },
    {
      "id": "check-shell",
      "displayName": "Run a shell command and write a file",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "d=\"$HOME/Library/Application Support/Grux/reports\"; mkdir -p \"$d\"; printf 'smoke %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > \"$d/smoke-latest.txt\"; test -s \"$d/smoke-latest.txt\" && echo shell-ok || echo shell-failed"
      }
    },
    {
      "id": "stash-shell",
      "displayName": "Stash the shell result",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "shell_result",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "verdict",
      "displayName": "Decide pass or fail",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": {
          "kind": "allOf",
          "conditions": [
            { "kind": "stateEquals", "key": "probe", "value": "alive" },
            { "kind": "stateEquals", "key": "last_echo", "value": "builtin reached" },
            { "kind": "stateMatches", "key": "shell_result", "regex": "shell-ok" }
          ]
        },
        "ifTrue": "pass",
        "ifFalse": "fail"
      }
    },
    {
      "id": "fail",
      "displayName": "Fail",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "Self check failed. State probe was ${state.probe}, builtin echo was ${state.last_echo}, shell result was ${state.shell_result}. The first of those that is empty or wrong is where it broke.",
        "audioCueAfter": { "kind": "warningChime", "postSpeakDelay": 0.4 }
      }
    },
    {
      "id": "pass",
      "displayName": "Pass",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "Self check passed. Speech, state, builtins, shell, branching and the filesystem all responded.",
        "audioCueAfter": { "kind": "successChime", "postSpeakDelay": 0.4 }
      }
    }
  ]
}
```

`fail` is listed before `pass` so the true arm falls through to the end of the run and the
false arm does not accidentally continue into the pass message.

**Optional extension, one model call.** Append this phase after `pass` and change `pass` to
a `setState` writing `verdict = ok` if you want the model check inside the same verdict.
Kept separate here so the core stays credential free.

```json
{
  "id": "check-model",
  "displayName": "Reach the model once",
  "userApprovalRequired": false,
  "action": {
    "kind": "claudeAgent",
    "tools": [],
    "maxTokens": 64,
    "systemPrompt": "Reply with exactly the word ROUNDTRIP and nothing else. No punctuation, no explanation, no greeting."
  }
}
```

Until CR-3 lands there is no on-disk install path for a workflow definition. Add the
equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and list it in
`registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or call
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

## What you see when it is not set up

Nothing, and that is the design. The core has no required capabilities, so it is never
`needs-setup`. A self-check that refuses to run until you have configured something cannot
help you diagnose a machine where nothing is configured.

If you install the optional model phase and no key is present, that feature shows the
`needs-setup` card with: "Add your Anthropic API key in Settings to let Grux think. Get one
at console.anthropic.com." The core still runs and still reports.

## Example, not a default

```
Example, not a default

Passing run, spoken:

  Running the Grux self check.
  Self check passed. Speech, state, builtins, shell, branching and the filesystem all
  responded.

Failing run, spoken:

  Running the Grux self check.
  Self check failed. State probe was alive, builtin echo was builtin reached, shell
  result was shell-failed. The first of those that is empty or wrong is where it broke.

The file it writes:

  ~/Library/Application Support/Grux/reports/smoke-latest.txt
  smoke 2026-08-09T21:40:11Z
```

## Honest limitations

- **A pass means the engine is alive, not that Grux is working.** It exercises the
  substrate: phases, state, branching, builtins, shell and speech. It says nothing about
  whether your keys are valid, your schedules are firing, your permissions are granted, or
  any given feature does what you want.
- **It cannot test the scheduler.** Proving that a cron job fires requires waiting for a
  fire, and this runs in seconds. The scheduler ticks every 30 seconds
  (`CommandsV2/UserCronStore.swift:259`) and there is no way to ask it to fire now, so
  "my schedules stopped running" is outside what this can diagnose.
- **It cannot test permissions.** Screen Recording, Accessibility, Microphone and the rest
  are granted by the operating system and must be resolved by asking the relevant API
  (contract 1.2), which the workflow engine has no action for.
- **The speech phases make it not headless.** Despite the description, `speak` produces
  audio. Running this on a machine where sound matters will make noise. Replacing the
  `speak` actions with `builtin` `log` makes it genuinely silent and also makes the result
  invisible unless you read the run log.
- **It writes a file to prove the filesystem works**, which means it always leaves a trace
  and always touches disk. That is the test, and it does mean the smoke test is not
  read-only.
- **A failing branch tells you which marker is wrong, not why.** "shell-failed" narrows it
  to the shell phase and stops there. You still have to read the run's phase history.
- **The optional model phase costs money every run.** Small, and not zero. If you run the
  self check reflexively, keep the core and leave the extension off.
