# sandbox-tripwire

## What it does

Watches the folder you told Grux to work inside, and tells you when files have appeared
outside it. When an agent is doing work on your behalf, it should only be touching one
place. Files showing up somewhere else is the visible signature of an agent that has
escaped the boundary you set, and this is how you find out.

## Host

**Workflows** (`CommandsV2`). It is a sweep, then a decision, then an action that must not
happen without you: found strays get quarantined only after a `userApprovalGate`
(`CommandsV2/CommandV2Models.swift:170`). A Schedule fires one action and cannot pause for
approval. A Skill has no execution at all.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `endpoint.sandbox_root` | endpoint | required | The folder that defines "inside". Without it there is no boundary and nothing to check. |
| `perm.notifications` | perm | required | Tells you when something crossed the line. Pending CR-1: should be optional. |
| `key.anthropic` | key | required | Explains what the stray files look like. Pending CR-1: should be optional, the sweep is a `find` and needs no model. |

## Config keys read

| key | why |
|---|---|
| `grux.sandbox.watched_root` | The folder that is allowed to change. |
| `grux.sandbox.quarantine_dir` | Where strays are moved, after you approve. |
| `grux.model.provider` | Which provider writes the explanation. |
| `grux.model.chat_id` | Which model writes the explanation. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |

## The blueprint itself

Seven phases. The sweep is deliberately a plain `find`, because the detection must be
something you can read and reproduce by hand.

| # | phase id | action | note |
|---|---|---|---|
| 1 | `sweep` | `shell` | Finds files changed recently outside the watched root. |
| 2 | `stash-strays` | `setState` | Lifts the count out of the sweep. |
| 3 | `decide` | `branch` | Zero strays ends the run quietly. |
| 4 | `all-clear` | `speak` | The quiet ending. |
| 5 | `explain` | `claudeAgent` | Describes what appeared and where. |
| 6 | `approve` | `userApprovalGate` | Nothing moves without a yes. |
| 7 | `quarantine` | `shell` | Moves the strays, preserving their paths. |

```json
{
  "id": "sandbox-tripwire",
  "displayName": "sandbox tripwire sweep",
  "voiceTriggers": ["check the sandbox", "did anything escape", "tripwire sweep"],
  "description": "Find files written outside the folder agents are supposed to stay inside, and quarantine them after you approve.",
  "category": "system",
  "parameters": [
    { "name": "minutes", "kind": "freeText", "prompt": "Look at files changed in the last how many minutes?" }
  ],
  "phases": [
    {
      "id": "sweep",
      "displayName": "Sweep for files outside the watched root",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "root='<your-watched-root>'; out=\"$HOME/Library/Application Support/Grux/tripwire-strays.txt\"; mkdir -p \"$(dirname \"$out\")\"; find \"$HOME\" -type f -mmin -${param.minutes} -not -path \"$root/*\" -not -path \"$HOME/Library/*\" -not -path \"$HOME/.Trash/*\" -not -path \"*/.git/*\" -not -path \"$HOME/.cache/*\" -not -path \"$HOME/Downloads/*\" 2>/dev/null > \"$out\"; wc -l < \"$out\" | tr -d ' '"
      }
    },
    {
      "id": "stash-strays",
      "displayName": "Stash the stray count",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "stray_count",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "decide",
      "displayName": "Anything outside?",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": { "kind": "stateEquals", "key": "stray_count", "value": "0" },
        "ifTrue": "all-clear",
        "ifFalse": "explain"
      }
    },
    {
      "id": "all-clear",
      "displayName": "All clear",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "Sandbox sweep clean. Nothing was written outside the watched folder in the last ${param.minutes} minutes."
      }
    },
    {
      "id": "explain",
      "displayName": "Describe the strays",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "shell"],
        "systemPrompt": "Files were written outside the folder agents are supposed to stay inside.\n\nWatched root: <your-watched-root>\nStray count: ${state.stray_count}\nThe full list of paths is at ~/Library/Application Support/Grux/tripwire-strays.txt\n\nRead that list. Then, for at most the 20 most significant entries, look at each file's size and modification time, and read the first 20 lines of any file that is plain text and under 100 kilobytes. Do not read anything that looks like a key, a credential file, or a private key: record that you skipped it and why.\n\nWrite ~/Library/Application Support/Grux/reports/tripwire-latest.md with:\n\n  ## What appeared\n  Group the strays by parent directory, with a count per directory and the newest timestamp in each. Directories, not individual files, are what tell you what happened.\n\n  ## Most likely explanation\n  Two or three sentences. Distinguish honestly between the three cases that look identical from a file listing: an agent writing outside its boundary, an ordinary application saving a file, and your own work. If you cannot tell, say you cannot tell. Guessing 'an agent escaped' when someone saved a screenshot is the failure mode that makes a tripwire useless.\n\n  ## Recommend\n  Either 'quarantine' with the reason, or 'leave' with the reason. Recommend 'leave' whenever the strays look like ordinary application files.\n\n  ## Skipped\n  Every file you declined to read, and why.\n\nDo not move, delete, or modify any file. You have shell access to inspect, not to act: moving happens in a later phase after the owner approves. No em dashes, no en dashes.\n\nFinish with one line beginning 'TRIPWIRE: ' giving the count, the top directory, and your recommendation, under 150 characters.",
        "maxTokens": null
      }
    },
    {
      "id": "approve",
      "displayName": "Ask before moving anything",
      "userApprovalRequired": true,
      "action": {
        "kind": "userApprovalGate",
        "prompt": "${state.last_agent_output} Move these files to quarantine? Say quarantine to move them, or leave to do nothing.",
        "expectedReplies": ["quarantine", "leave"]
      }
    },
    {
      "id": "quarantine",
      "displayName": "Move the strays to quarantine",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "q='<your-quarantine-dir>'; stamp=$(date -u +%Y-%m-%dT%H%M%SZ); dest=\"$q/$stamp\"; mkdir -p \"$dest\"; while IFS= read -r f; do [ -f \"$f\" ] || continue; rel=\"${f#$HOME/}\"; mkdir -p \"$dest/$(dirname \"$rel\")\"; mv \"$f\" \"$dest/$rel\"; done < \"$HOME/Library/Application Support/Grux/tripwire-strays.txt\"; echo \"quarantined to $dest\""
      }
    }
  ]
}
```

Until CR-3 lands there is no on-disk install path for a workflow definition. Add the
equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and list it in
`registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or call
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

To run it as a daily backstop, create a Schedule with the action
`UserCronAction.runCommand(definitionId: "sandbox-tripwire")`
(`CommandsV2/UserCronStore.swift:25`). Note the parameter problem in the limitations below.

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Watched folder: "Choose the folder Grux should guard in Settings."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

There is no default watched folder, and there should not be one. A tripwire around a folder
you did not choose will fire constantly and you will learn to ignore it, which is worse
than not having it.

## Example, not a default

```
Example, not a default

Config:

  "grux.sandbox.watched_root": "/Users/you/code/acme-web",
  "grux.sandbox.quarantine_dir": "/Users/you/.grux-quarantine"

Run with minutes = 120.

Spoken:

  TRIPWIRE: 7 strays, mostly /Users/you/code/acme-api/src. Recommendation: quarantine.

Report:

  ## What appeared
  /Users/you/code/acme-api/src      5 files, newest 21 minutes ago
  /Users/you/code/acme-api          2 files, newest 21 minutes ago

  ## Most likely explanation
  All seven files were written within the same two minute window into a project that is
  not the watched root, and four of them are new source files with a shape matching the
  work described in the current task. That pattern is consistent with an agent working
  in the wrong directory rather than with ordinary application activity.

  ## Recommend
  Quarantine. Moving them is reversible and leaving them risks mixing generated work into
  a project nobody asked to change.

  ## Skipped
  /Users/you/code/acme-api/.env.local  looks like a credentials file, not read.
```

## Honest limitations

- **This is a sweep, not a tripwire, and the name oversells it.** There is no file system
  watcher host in Grux, so nothing fires the instant a file lands. It fires when you run it
  or when a Schedule fires it, and a Schedule fires at most once a day
  (`CommandsV2/UserCronStore.swift:69-70`). An agent that writes outside its boundary at
  9:00 AM and finishes by 9:05 AM is caught at the next sweep, not at 9:05 AM.
- **Passing `minutes` from a Schedule does not work today.**
  `UserCronAction.runCommand` carries only a definition id
  (`CommandsV2/UserCronStore.swift:25`) and no parameter dictionary, while
  `CommandV2Engine.start` accepts one (`CommandsV2/CommandV2Engine.swift:153`). A scheduled
  sweep therefore runs with an empty `${param.minutes}`, which breaks the `find`. Until
  that gap closes, either hard code the window into the sweep command or run this by hand.
  This is a real defect in the composition, not a footnote.
- **The exclusion list in the `find` is doing enormous work and is not principled.**
  Excluding `~/Library`, `~/Downloads`, `.git` and caches keeps the output readable, and
  every one of those is a place an escaped agent could write. A tripwire with a big blind
  spot will report clean while something is wrong.
- **It cannot see outside your home directory.** A write to `/tmp`, `/usr/local`, or an
  external drive is invisible.
- **It cannot tell who wrote a file.** Filesystem timestamps do not record a process. Every
  "most likely explanation" is an inference from timing and content, and the prompt is
  explicitly instructed to admit when it cannot tell, which means you will often get "I
  cannot tell". That is the honest answer, and it is less useful than you want.
- **Quarantine is a move, and moves break things.** Moving a file an application is
  actively using, or a file that is part of a project's build, will cause a failure
  somewhere else. The approval gate exists precisely because this step is not safe to
  automate, so do not remove it.
- **The quarantine shell loop is fragile with unusual filenames.** Paths containing
  newlines are not handled and will be skipped or mishandled.
- **The `explain` phase reads file contents.** It skips things that look like credentials,
  by pattern, which is a heuristic. Do not point this at a folder tree containing secrets
  you would mind a model seeing.
