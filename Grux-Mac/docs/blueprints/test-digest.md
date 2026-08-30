# test-digest

## What it does

Every night it runs the type checker and the test suite in each of your local project
checkouts, and writes you one note saying what broke and roughly when it started breaking.
Instead of discovering a red suite when you sit down to add a feature, you find out the
night before.

## Host

**Schedules** (`CommandsV2/UserCronStore.swift`). The value is entirely in the cadence, and
the work is one prompt: walk a list of directories, run each project's own commands, report.
`UserCronAction.agentPrompt` (`CommandsV2/UserCronStore.swift:26`) spawns one agent with
shell access to do it.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.anthropic` | key | required | Runs the sweep and writes the report. |
| `endpoint.registry` | endpoint | required | Supplies the list of projects and their local checkout paths. See CR-5, the entry schema is not specified. |
| `perm.notifications` | perm | required | How the result reaches you. Pending CR-1: should be optional. |

No GitHub capability. This blueprint runs against what is already on your disk, so it
needs no network credentials at all.

## Config keys read

| key | why |
|---|---|
| `grux.portfolio.projects` | Inline list of projects, each carrying a local checkout path. |
| `grux.portfolio.registry_url` | Alternative source for the same list. |
| `grux.model.provider` | Which provider writes the report. |
| `grux.model.chat_id` | Which model writes the report. |
| `grux.model.ollama_host` | Only if you set `grux.model.provider` to `ollama` to keep this run free. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

## The blueprint itself

**Schedule:**

| field | value |
|---|---|
| title | Nightly test sweep |
| weekdays | 2, 3, 4, 5, 6 (Monday through Friday) |
| hour | 22 |
| minute | 30 |
| action | Agent prompt |
| notify on fire | on |

That is 10:30 PM local on weekdays. Equivalent standard cron expression: `30 22 * * 1-5`.
It runs after `pr-digest` deliberately, so a long test run cannot delay the faster report.

**Agent prompt:**

```
Run tonight's test sweep.

Projects, one per line, as "name<TAB>absolute-path":
<your-project-list>

For each project, in order, working inside that directory:

1. Detect the runner. Look for, in this priority order:
   package.json with a "test" script, pyproject.toml or pytest.ini, Cargo.toml,
   go.mod, a *.xcodeproj or project.yml, a Makefile with a "test" target.
   If none of these exist, record the project as "no runner detected" and move on.
   Do not guess a command.
2. Detect the type check. package.json with typescript in devDependencies means
   run the typecheck script if one exists, otherwise `npx tsc --noEmit`. Python with
   mypy configured means `mypy .`. Skip this step where it does not apply.
3. Run the type check first, then the tests, each with a hard timeout of 600 seconds.
   Capture the exit status, the count of tests that actually ran, and the last 40
   lines of output.
4. Treat "zero tests collected" as a FAILURE, not a pass. A suite that ran nothing
   has told you nothing.
5. If a project fails, run `git log --oneline -5` and `git log -1 --format=%cd` in it
   so the report can say what changed most recently. Do not check out anything, do not
   stash, do not reset, do not pull. Read only.

Write the report to
~/Library/Application Support/Grux/reports/test-digest-$(date +%Y-%m-%d).md
with this exact structure:

  ## Broken
  One block per failing project: name, which step failed (typecheck or tests), the
  exit status, the number of tests that ran, the last 5 commits with dates, and the
  three most relevant lines of the failure output. If nothing is broken, write
  "Everything passed."

  ## Passed
  One line each: name, tests run, seconds taken.

  ## Skipped
  One line each with the reason: no runner detected, path missing, timed out, or
  zero tests collected.

Then print one final line beginning "TESTS: " giving passed count, failed count, and
skipped count, under 150 characters.

Rules. Never modify a repository. Never install a dependency to make a suite run: if
the install is missing, that is a "skipped" with the reason. Report the count of tests
that actually executed, never the count the config claims. No em dashes, no en dashes.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Project registry: "Point Grux at your project registry URL in Settings, or add projects by hand."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

An empty project list is `needs-setup`, not a run that reports zero projects. A sweep of
nothing that says "all green" is worse than no sweep, because it looks like a pass.

## Example, not a default

```
Example, not a default

Config:

  "grux.portfolio.projects": [
    { "name": "acme-web", "path": "/Users/you/code/acme-web" },
    { "name": "acme-api", "path": "/Users/you/code/acme-api" },
    { "name": "acme-ios", "path": "/Users/you/code/acme-ios" }
  ]

Schedule: Monday through Friday, 10:30 PM, Agent prompt, notify on.

Notification:

  Schedule done: Nightly test sweep
  TESTS: 1 passed, 1 failed, 1 skipped.

Report:

  ## Broken
  acme-api
    Step: tests
    Exit status: 1
    Tests run: 214 of an expected 214, 3 failed
    Recent commits:
      a1b2c3d  Cache the settings lookup   Aug 9
      d4e5f6a  Bump the client library     Aug 8
    Failure:
      FAIL  src/settings.test.ts
        expected 2 calls, received 1
        at settingsCache.test.ts:44

  ## Passed
  acme-web   318 tests, 41s

  ## Skipped
  acme-ios   no runner detected, project.yml present but no test scheme
```

The entry shape shown above (`name` plus `path`) is what this blueprint needs. The
contract does not define the shape of a `grux.portfolio.projects` entry, so this is a
proposal, not a settled format. See CR-5.

## Honest limitations

- **There is a hard 30 minute ceiling on the whole sweep.** The scheduler calls
  `CommandV2AgentBridge.runSingleAgent` without a lifetime argument
  (`CommandsV2/UserCronStore.swift:332`), so it takes the default `ttlSeconds: 1800`
  (`CommandsV2/CommandV2AgentBridge.swift:39`). The workflow engine raises that to 5400 for
  long phases (`CommandsV2/CommandV2Engine.swift:602`), but the Schedules path has no such
  escape. A three-project sweep with real suites can exceed 30 minutes, and when it does
  the agent is cut off mid-run and you get partial results with no marker saying so. If
  your suites are long, split them across several schedules rather than one.
- **It cannot install anything.** A checkout with stale dependencies reports as skipped
  every night until you fix it by hand. That is deliberate: a nightly job that runs
  package installs unattended is a supply-chain hazard, not a convenience.
- **It runs your project's commands with your permissions.** A test suite that writes to a
  database, sends an email, or hits a paid API will do exactly that, at 10:30 PM, every
  weeknight. Point this only at suites you are confident are hermetic.
- **"When it started breaking" is a guess from git log, not bisection.** It shows you the
  recent commits, it does not prove which one broke the build.
- **Zero tests collected is treated as a failure, which will occasionally be wrong.** A
  project that genuinely has no tests yet will be reported as broken every night. Remove it
  from the list rather than weakening the check.
- **One fire per night, and a missed fire is dropped.** Same scheduler constraints as every
  Schedules blueprint (`CommandsV2/UserCronStore.swift:69-70`, `:253`, `:282-289`).
- **No trend.** Each night overwrites nothing and adds a dated file, but nothing reads
  yesterday's file. "This has been failing for six days" is not something it can tell you.
