# pr-digest

## What it does

Every night it looks at the pull requests still open across the repositories you told it
about, and writes you one short note: what is waiting on your review, what has gone stale,
and what is failing checks. You wake up knowing what to look at first instead of scrolling
a notifications page.

## Host

**Schedules** (`CommandsV2/UserCronStore.swift`). One action on a cadence, no branching, no
approval gate. `UserCronAction.agentPrompt` (`CommandsV2/UserCronStore.swift:26`) is the
right case: the agent does the fetching and the writing in one pass, and the scheduler
notifies you with the tail of its output (`CommandsV2/UserCronStore.swift:338`).

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.github` | key | required | Reads pull requests and check runs. |
| `key.anthropic` | key | required | Writes the digest. |
| `endpoint.repo_list` | endpoint | required | Nothing is watched until you name repositories. |
| `perm.notifications` | perm | required | How the digest reaches you overnight. Pending CR-1: should be optional. |

## Config keys read

| key | why |
|---|---|
| `grux.github.repos` | The repositories to sweep. |
| `grux.model.provider` | Which provider writes the digest. |
| `grux.model.chat_id` | Which model writes the digest. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

`grux.github.token` and `grux.model.anthropic_key` are secrets held in Keychain and
resolved by the capability layer (contract 2.4).

## The blueprint itself

**Schedule:**

| field | value |
|---|---|
| title | Nightly pull request digest |
| weekdays | 2, 3, 4, 5, 6 (Monday through Friday) |
| hour | 21 |
| minute | 0 |
| action | Agent prompt |
| notify on fire | on |

That is 9:00 PM local on weekdays. Equivalent standard cron expression: `0 21 * * 1-5`.
The weekday numbers are `Calendar.component(.weekday)` values, where 1 is Sunday and 7 is
Saturday (`CommandsV2/UserCronStore.swift:65-66`).

**Agent prompt:**

```
Write tonight's open pull request digest.

Repositories to sweep:
<your-repo-list-one-per-line-as-owner/name>

For each repository, using the GitHub REST API with the token already in the
environment as GRUX_GITHUB_TOKEN:

1. GET /repos/{owner}/{repo}/pulls?state=open&per_page=100 and paginate until the
   response is short. Never stop at the first page and call it complete.
2. For every open pull request record: number, title, author, created date, updated
   date, draft flag, requested reviewers, and mergeable state.
3. GET /repos/{owner}/{repo}/commits/{head_sha}/check-runs for each one and record
   whether any check concluded failure, cancelled, or timed_out.

Then write the digest to
~/Library/Application Support/Grux/reports/pr-digest-$(date +%Y-%m-%d).md
with this exact structure:

  ## Waiting on you
  Pull requests where you are a requested reviewer and no review has been submitted.
  One line each: repo #number, title, author, days open. Sort oldest first.
  If none, write "Nothing waiting on you."

  ## Failing
  Open pull requests with at least one failed check. One line each, naming which check
  failed. Sort by repository.

  ## Stale
  Open, not draft, and not updated in more than 7 days. One line each with the day count.

  ## Everything else
  A single count line per repository: "owner/name: N open, M draft".

  ## Not swept
  Any repository whose API call failed, and the status code. Never silently drop a
  repository from the sweep.

Then write one headline line at the very end, beginning "PRS: ", stating the number
waiting on you, the number failing, and the number stale, in that order. Keep it under
150 characters, it is read aloud on its own.

Rules. Use only numbers you actually fetched, never estimate. A draft pull request is
never "waiting on you". Count days from the created date in whole days. No em dashes,
no en dashes, use commas or full stops.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- GitHub token: "Connect GitHub in Settings so Grux can read your repositories. A classic token with repo scope is enough."
- Repository list: "Tell Grux which repositories to watch in Settings. Nothing is watched until you do."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

The repository list is the one most people miss, which is why its remediation says
outright that nothing is watched until you fill it in. An empty `grux.github.repos` is not
an error and not an empty digest, it is `needs-setup`.

## Example, not a default

```
Example, not a default

Config:

  "grux.github.repos": [
    "yourname/acme-web",
    "yourname/acme-ios",
    "acme-org/shared-components"
  ]

Schedule: Monday through Friday, 9:00 PM, Agent prompt, notify on.

Notification:

  Schedule done: Nightly pull request digest
  PRS: 2 waiting on you, 1 failing, 4 stale.

Digest file:

  ## Waiting on you
  acme-org/shared-components #212  Bump the token scale       alex     6 days open
  yourname/acme-web #88            Fix the empty state copy   sam      2 days open

  ## Failing
  yourname/acme-ios #41  UI tests failed on the iPhone 16 destination

  ## Stale
  yourname/acme-web #61   19 days
  yourname/acme-ios #34   14 days
  acme-org/shared-components #180  31 days
  acme-org/shared-components #177  33 days

  ## Everything else
  yourname/acme-web: 5 open, 1 draft
  yourname/acme-ios: 3 open, 0 draft
  acme-org/shared-components: 9 open, 2 draft

  ## Not swept
  Nothing, all three responded.
```

## Honest limitations

- **"Waiting on you" is only as good as your review requests.** If your team assigns
  reviews by mentioning people in comments rather than requesting a reviewer, this section
  will be empty while your queue is full.
- **Check runs are the head commit only.** A pull request whose latest push is green but
  whose merge would fail against a changed base will read as healthy.
- **Rate limits are real.** A sweep across many repositories with a check-run call per pull
  request can exhaust a personal token's hourly budget. The digest will report the failure
  under "Not swept", but you still lose that night's data for those repositories.
- **One fire per night.** `UserCronJob` holds a single hour and minute, so one job is one
  daily run (`CommandsV2/UserCronStore.swift:69-70`).
- **A missed run is dropped, not caught up.** More than 10 minutes late and the occurrence
  is skipped and the anchor rolled forward
  (`CommandsV2/UserCronStore.swift:253`, `:282-289`). If your Mac sleeps at 9:00 PM you
  will simply not get a digest, and nothing tells you that.
- **The notification body is truncated at 180 characters**
  (`CommandsV2/UserCronStore.swift:341`), which is why the `PRS:` line is capped at 150.
- **It reads, it never acts.** No approving, no nudging authors, no closing stale work. It
  is a report.
- **Private repositories need the token to have access.** A repository the token cannot see
  returns 404, which looks identical to a repository that does not exist. The digest
  reports both the same way.
