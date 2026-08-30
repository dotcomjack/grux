# project-registry

## What it does

Teaches Grux what your projects are. You point it at a small web service you run that lists
your projects and, for each one, where its code lives and where it is deployed. Grux
fetches that list, checks it makes sense, and keeps it as the shared answer to "what am I
working on" for every other blueprint that needs a project list.

## Host

**Workflows** (`CommandsV2`). It is a fetch, then a validation, then a real fork: registry
reachable, use it, registry unreachable, fall back to the inline list and say so. That fork
is `CommandV2Action.branch` with a `ConditionExpr`
(`CommandsV2/CommandV2Models.swift:171`, `:361`), which no other host has. A Skill has no
execution and a Schedule fires one action with no conditional.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `endpoint.registry` | endpoint | required | The registry URL, or the decision to list projects by hand. |
| `key.anthropic` | key | required | The validation phase explains what is wrong in plain language. Pending CR-1: should be optional, the fetch and the schema check work without a model. |

Nothing else. This blueprint is deliberately the cheapest one in the set, because
everything else depends on it and a dependency that needs five credentials is not a
foundation.

## Config keys read

| key | why |
|---|---|
| `grux.portfolio.registry_url` | Where to fetch the project list from. |
| `grux.portfolio.projects` | The inline list, used as the fallback when the registry is unreachable. |
| `grux.model.provider` | Which provider writes the validation report. |
| `grux.model.chat_id` | Which model writes the validation report. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |

## The blueprint itself

Six phases. The fetch writes a status code into state, a branch reads it, and the two arms
converge on the same write.

| # | phase id | action | note |
|---|---|---|---|
| 1 | `fetch` | `shell` | Writes the body and the status code. |
| 2 | `stash-status` | `setState` | Lifts the status code out of the shell output. |
| 3 | `decide-source` | `branch` | `stateMatches` on `registry_status` for `^2` |
| 4a | `use-registry` | `setState` | Marks the source as the registry. |
| 4b | `use-inline` | `setState` | Marks the source as the inline list. |
| 5 | `validate` | `claudeAgent` | Checks the shape, writes the resolved list. |
| 6 | `report` | `speak` | Says how many projects resolved and from where. |

```json
{
  "id": "project-registry",
  "displayName": "refresh the project registry",
  "voiceTriggers": ["refresh my projects", "reload the registry", "what projects do I have"],
  "description": "Fetch the list of projects you manage from your own registry, validate it, and fall back to the inline list when the registry is unreachable.",
  "category": "system",
  "parameters": [],
  "phases": [
    {
      "id": "fetch",
      "displayName": "Fetch the registry",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "body=$(curl -sS --max-time 20 -H 'Accept: application/json' -w '\\n%{http_code}' '<your-registry-url>/projects' 2>/dev/null || printf '\\n000'); printf '%s' \"$body\" > \"$HOME/Library/Application Support/Grux/registry-raw.txt\"; printf '%s' \"$body\" | tail -n 1"
      }
    },
    {
      "id": "stash-status",
      "displayName": "Stash the status code",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "registry_status",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "decide-source",
      "displayName": "Registry or inline list",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": { "kind": "stateMatches", "key": "registry_status", "regex": "^2[0-9][0-9]" },
        "ifTrue": "use-registry",
        "ifFalse": "use-inline"
      }
    },
    {
      "id": "use-inline",
      "displayName": "Fall back to the inline list",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "project_source",
        "valueExpr": { "kind": "literal", "value": "inline" }
      }
    },
    {
      "id": "use-registry",
      "displayName": "Use the registry response",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "project_source",
        "valueExpr": { "kind": "literal", "value": "registry" }
      }
    },
    {
      "id": "validate",
      "displayName": "Validate and write the resolved list",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Resolve the project list.\n\nSource chosen by the branch: ${state.project_source}\nHTTP status from the registry fetch: ${state.registry_status}\n\nIf the source is 'registry', read ~/Library/Application Support/Grux/registry-raw.txt. Everything except the final line is the JSON body, the final line is the status code. If the source is 'inline', read the 'grux.portfolio.projects' array from ~/Library/Application Support/Grux/config.json instead.\n\nValidate every entry against this shape. Each project must have:\n  name   a short unique identifier, lowercase, no spaces\n  path   an absolute path to a local checkout, or null if there is not one\n  repo   an owner/name string, or null\n  url    the deployed URL, or null\nAn entry missing 'name' is invalid. An entry where all of path, repo and url are null is valid but useless, and must be flagged.\n\nWrite the resolved list to ~/Library/Application Support/Grux/projects-resolved.json as a JSON array in that exact shape, sorted by name. Write nothing if validation finds a duplicate name: stop and report instead, because a duplicate name silently breaks every blueprint that looks a project up by name.\n\nAlso write ~/Library/Application Support/Grux/reports/registry-latest.md with:\n  A first line stating the source used and, when the registry failed, its status code and what that means in plain language, for example 'the registry did not answer within 20 seconds'.\n  A section 'Resolved' listing each project with its four fields.\n  A section 'Problems' listing every entry that failed validation, what is wrong with it, and the single change that fixes it. If there are none, write 'None.'\n  A section 'Useless entries' listing every valid entry with no path, no repo and no url.\n\nRules. Never invent a field to make an entry validate. Never silently drop an entry: an entry you cannot use goes under Problems. If both the registry and the inline list are empty, say exactly that, do not write an empty array and call it success. No em dashes, no en dashes.\n\nFinish by printing one line beginning 'REGISTRY: ' with the count resolved, the count with problems, and the source used.",
        "maxTokens": null
      }
    },
    {
      "id": "report",
      "displayName": "Report",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "${state.last_agent_output}",
        "audioCueAfter": { "kind": "successChime", "postSpeakDelay": 0.4 }
      }
    }
  ]
}
```

Note the phase order in the JSON: `use-inline` is listed before `use-registry` because a
branch jumps to a named phase and execution then continues in file order. Putting the
false arm first means the true arm falls through to `validate` without needing a jump, and
the false arm reaching `use-registry` would be a bug. If you reorder these phases, add an
explicit branch at the end of the false arm.

Until CR-3 lands there is no on-disk install path for a workflow definition. Add the
equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and list it in
`registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or call
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Project registry: "Point Grux at your project registry URL in Settings, or add projects by hand."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."

The registry remediation is the one that matters, and its wording is deliberate: it offers
you two ways out, run a registry or type the list in. Most people should type the list in.
A registry is worth running when you have more projects than you can remember, not before.

**There is no shipped default registry, and there never will be.** A default endpoint here
would be a hole in someone else's network (contract 1.3), which is the same reasoning that
keeps the trusted host list empty.

## Example, not a default

```
Example, not a default

The inline route, which is what most people should use:

  "grux.portfolio.projects": [
    { "name": "acme-web", "path": "/Users/you/code/acme-web", "repo": "yourname/acme-web", "url": "https://acme.example.com" },
    { "name": "acme-api", "path": "/Users/you/code/acme-api", "repo": "yourname/acme-api", "url": "https://api.acme.example.com" },
    { "name": "acme-ios", "path": "/Users/you/code/acme-ios", "repo": "yourname/acme-ios", "url": null }
  ]

The registry route:

  "grux.portfolio.registry_url": "https://registry.example.com/api"

and that service answers GET /projects with the same array.

Spoken result:

  REGISTRY: 3 resolved, 1 with problems, source registry.

Report:

  Source: registry, HTTP 200.

  ## Resolved
  acme-api  /Users/you/code/acme-api  yourname/acme-api  https://api.acme.example.com
  acme-ios  /Users/you/code/acme-ios  yourname/acme-ios  (no url)
  acme-web  /Users/you/code/acme-web  yourname/acme-web  https://acme.example.com

  ## Problems
  Entry 4 has no 'name'. Add a short lowercase identifier, for example "acme-docs".

  ## Useless entries
  None.
```

The owner of Grux runs a registry service on a machine on his own network. That is
instructive only in that a registry can be anything that returns JSON, so the example uses
a placeholder public hostname and never his.

## Honest limitations

- **The entry shape above is a proposal, not a contract.** Section 2.5 says
  `grux.portfolio.projects` is a list and stops there. Until CR-5 settles the entry schema,
  every blueprint that reads this list is guessing at the same shape, and a mismatch will
  show up as "Problems" rather than as an error anyone can fix confidently.
- **A registry is a single point of failure you chose to add.** The fallback covers a dead
  registry, it does not cover a registry that answers 200 with a wrong or stale list. That
  case validates cleanly and silently propagates bad data everywhere.
- **The status code is parsed out of shell output.** It works, and it is brittle: a `curl`
  that writes something unexpected to stdout will shift the last line and the branch will
  take the wrong arm. It fails toward the inline list, which is the safe direction.
- **No authentication on the registry fetch.** As written the request sends no credentials,
  so your registry must be either public or reachable only from your own network. There is
  no capability in the contract for a registry token, so adding one is a contract change,
  not a prompt edit.
- **It does not verify that a path exists or a repository is reachable.** It validates
  shape, not truth. A `path` pointing at a folder you deleted last month validates fine.
- **Nothing runs this automatically.** It is a workflow, so it runs when you start it or
  when a Schedule fires it. A registry edited this morning is not picked up until the next
  run.
