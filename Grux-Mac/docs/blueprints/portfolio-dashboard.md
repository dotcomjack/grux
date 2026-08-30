# portfolio-dashboard

## What it does

Gives you one screen that answers "how are all my projects doing right now" without
opening ten browser tabs. It reads your list of projects, checks which sites are
responding, counts the open pull requests waiting on you, pulls install numbers for any
app you publish, and writes a short plain-language summary at the top.

## Host

**Workflows** (`CommandsV2`). This is a fan-out then synthesise shape: several independent
reads followed by one pass that turns them into a paragraph. `CommandV2Definition.phases`
is a phase list with state carried between phases
(`CommandsV2/CommandV2Models.swift:84`), and `${state.key}` interpolation
(`CommandsV2/CommandV2Engine.swift:872`) is exactly how the last phase reads what the
earlier ones gathered. A Skill could not do this because a Skill is prompt text with no
execution, and a Schedule fires one action rather than a sequence.

Pair it with a Schedule if you want it every morning:
`UserCronAction.runCommand(definitionId: "portfolio-dashboard")`
(`CommandsV2/UserCronStore.swift:25`).

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.anthropic` | key | required | The synthesis phase calls a model. |
| `endpoint.registry` | endpoint | required | Where the project list comes from. Pending CR-2: `grux.portfolio.projects` should be an accepted alternative. |
| `key.github` | key | required | Open pull request counts. Pending CR-1: this should be optional, the dashboard is still useful without it. |
| `endpoint.uptime_targets` | endpoint | required | The sites to probe. Pending CR-1: should be optional. |
| `key.appstoreconnect` | key | required | Install counts. Pending CR-1: should be optional. |
| `perm.notifications` | perm | required | Delivers the summary when you are not looking at the app. Pending CR-1: should be optional. |

Revenue is deliberately absent. The contract has no revenue capability, so this blueprint
does not claim one. See CR-4 in `index.md`.

## Config keys read

| key | why |
|---|---|
| `grux.portfolio.registry_url` | The registry to fetch the project list from. |
| `grux.portfolio.projects` | Inline project list, used when there is no registry. |
| `grux.github.repos` | Which repositories to count pull requests in. |
| `grux.uptime.targets` | Which URLs to probe. |
| `grux.asc.key_id` | App Store Connect key identifier. |
| `grux.asc.issuer_id` | App Store Connect issuer identifier. |
| `grux.asc.p8_path` | Path to the App Store Connect private key file. |
| `grux.model.provider` | Which model provider does the synthesis. |
| `grux.model.chat_id` | Which model does the synthesis. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

Secrets (`grux.model.anthropic_key`, `grux.github.token`) are resolved through the
capability layer from Keychain and are never read out of the config file, per contract
section 2.4.

## The blueprint itself

A seven-phase workflow. Phases 2 through 5 each write into run state, phase 6 reads all of
it, phase 7 speaks the headline.

| # | phase id | action | writes to state |
|---|---|---|---|
| 1 | `announce` | `speak` | |
| 2 | `load-projects` | `shell` (fetch registry) | `last_shell_output` |
| 3 | `probe-uptime` | `shell` (probe each target) | `uptime_report` |
| 4 | `count-prs` | `shell` (GitHub search API) | `pr_report` |
| 5 | `read-installs` | `shell` (App Store Connect sales report) | `install_report` |
| 6 | `synthesise` | `claudeAgent` | `last_agent_output` |
| 7 | `report` | `speak` | |

The `CommandV2Definition` in the JSON shape its `Codable` conformance produces
(`CommandsV2/CommandV2Models.swift:84`). Replace every `<...>` placeholder.

```json
{
  "id": "portfolio-dashboard",
  "displayName": "portfolio dashboard",
  "voiceTriggers": ["portfolio", "how are my projects", "project snapshot"],
  "description": "One snapshot across every project you manage: what is up, what is waiting on you, how many installs.",
  "category": "observe",
  "parameters": [],
  "phases": [
    {
      "id": "announce",
      "displayName": "Announce",
      "userApprovalRequired": false,
      "action": { "kind": "speak", "text": "Building your portfolio snapshot." }
    },
    {
      "id": "load-projects",
      "displayName": "Load the project list",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "curl -sS --max-time 20 -H 'Accept: application/json' '<your-registry-url>/projects'"
      }
    },
    {
      "id": "stash-projects",
      "displayName": "Stash the project list",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "projects_json",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "probe-uptime",
      "displayName": "Probe every site",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "for u in <your-uptime-targets-space-separated>; do code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \"$u\" || echo 000); ms=$(curl -sS -o /dev/null -w '%{time_total}' --max-time 10 \"$u\" || echo 0); echo \"$u $code ${ms}s\"; done"
      }
    },
    {
      "id": "stash-uptime",
      "displayName": "Stash the uptime results",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "uptime_report",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "count-prs",
      "displayName": "Count open pull requests",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "for r in <your-repo-list-space-separated>; do n=$(curl -sS --max-time 20 -H \"Authorization: Bearer $GRUX_GITHUB_TOKEN\" -H 'Accept: application/vnd.github+json' \"https://api.github.com/repos/$r/pulls?state=open&per_page=100\" | grep -c '\"number\"' || echo 0); echo \"$r $n open\"; done"
      }
    },
    {
      "id": "stash-prs",
      "displayName": "Stash the pull request counts",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "pr_report",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "synthesise",
      "displayName": "Write the summary",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "You are writing one portfolio snapshot for the person who owns these projects.\n\nProject list (JSON):\n${state.projects_json}\n\nUptime probe, one line per URL as 'url status_code time':\n${state.uptime_report}\n\nOpen pull requests, one line per repository as 'repo N open':\n${state.pr_report}\n\nWrite the snapshot to ~/Library/Application Support/Grux/reports/portfolio-latest.md with this exact structure:\n\n1. A single opening sentence stating whether anything needs attention today, and if so what. If nothing does, say so plainly.\n2. A section 'Needs you' listing only items that are actually blocked or broken: any non-2xx status code, any repository with pull requests older than 7 days, any project missing from the registry that you expected. If the section would be empty, write 'Nothing.'\n3. A section 'Steady' with a one-line-per-project roll up: name, status, open pull request count.\n4. A section 'Not measured' naming every metric you could not gather and why, for example a probe that timed out or an empty repository list. Never silently omit a project.\n\nRules: no em dashes, no en dashes, use commas or full stops. Write dollar amounts as $50, not fifty dollars. Write distances in miles and feet. Write clock times as 7:30 PM, not 19:30. Do not invent a number you were not given. If a section has no data, say the data is missing rather than estimating.\n\nFinish by printing the first sentence of the report on its own line, prefixed with 'HEADLINE: '.",
        "maxTokens": null
      }
    },
    {
      "id": "report",
      "displayName": "Speak the headline",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "Portfolio snapshot ready. ${state.last_agent_output}",
        "audioCueAfter": { "kind": "successChime", "postSpeakDelay": 0.4 }
      }
    }
  ]
}
```

Until CR-3 lands there is no on-disk install path for a workflow definition. Install it by
adding the equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and listing it
in `registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or by calling
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

## What you see when it is not set up

The feature renders `needs-setup`: its own UI, dimmed and non-interactive, with a setup
card listing every missing capability. The card shows these exact strings.

- Project registry: "Point Grux at your project registry URL in Settings, or add projects by hand."
- GitHub token: "Connect GitHub in Settings so Grux can read your repositories. A classic token with repo scope is enough."
- Sites to monitor: "Add the URLs you want Grux to check in Settings."
- App Store Connect API key: "Add your App Store Connect key, issuer ID and .p8 file in Settings to let Grux publish builds."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

If everything resolves but you have hit `grux.cost.daily_ceiling_usd`, the feature is
`degraded` instead, with the note "Paused for today. You have reached your $2.00 ceiling.
Raise it in Settings or wait until tomorrow."

## Example, not a default

```
Example, not a default

Config, ~/Library/Application Support/Grux/config.json:

  "grux.portfolio.registry_url": "https://registry.example.com/api",
  "grux.github.repos": ["yourname/acme-web", "yourname/acme-ios", "yourname/acme-api"],
  "grux.uptime.targets": ["https://acme.example.com", "https://api.acme.example.com/health"],
  "grux.cost.daily_ceiling_usd": 2.00

Headline it produced:

  Two things need you: api.acme.example.com returned 502 for the last two probes,
  and acme-ios has 3 pull requests open for more than a week.

Needs you
  api.acme.example.com  502  probed 2 times, both failed
  yourname/acme-ios     3 open, oldest 11 days

Steady
  acme-web   200 in 0.31s   1 open
  acme-api   502            0 open

Not measured
  Install counts. No App Store Connect key is configured, so nothing was read.
```

The owner of Grux runs this against a registry he hosts himself on a machine on his own
network. That detail teaches nothing except that the registry can be anything that returns
JSON, so the example above uses a public placeholder host instead.

## Honest limitations

- **It is a snapshot, not a monitor.** One run tells you the state at that instant. Two
  probes a day will miss an outage that starts and ends between them. If you need real
  uptime monitoring, use a service built for it and let this blueprint report what that
  service says.
- **Revenue is not in it.** The contract has no revenue capability, so the description
  "revenue, installs, open PRs, infra health" is only three quarters delivered. See CR-4.
- **The uptime probe is a status code, nothing more.** A page that returns 200 while
  rendering an error is reported as healthy. It does not check content, certificates,
  or response bodies.
- **Pull request counting is coarse.** Counting `"number"` occurrences in the API response
  breaks if GitHub changes its response shape, and it caps at 100 per repository because
  it does not paginate. Repositories with more than 100 open pull requests will report 100.
- **The synthesis costs money on every run.** A daily schedule is roughly 30 model calls a
  month. Watch `grux.cost.daily_ceiling_usd`.
- **Shell quoting is fragile.** The probe loops build shell strings from your config. A URL
  or repository name containing a space or a quote will break the command rather than fail
  gracefully.
- **No history.** Each run overwrites `portfolio-latest.md`. There is no trend, no
  "compared to yesterday", and no chart. Adding history means adding storage the contract
  does not describe.
