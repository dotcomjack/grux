# social-health-grid

## What it does

Checks, once a day, that every social account you have connected is still actually
connected and still actually posting. Tokens expire quietly, a scheduled post fails
silently, and you find out three weeks later that nothing has gone out. This tells you the
morning it happens.

## Host

**Schedules** (`CommandsV2/UserCronStore.swift`). One check on a cadence. It has no
branches and takes no decisions, it reports a grid of green and red.
`UserCronAction.agentPrompt` (`CommandsV2/UserCronStore.swift:26`) is the fit. When you
want to act on a red cell, `social-ops-cockpit` is the Workflows blueprint that handles
retry and re-auth.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `endpoint.social_accounts` | endpoint | required | The accounts to check. Nothing is checked until you connect some. |
| `key.anthropic` | key | required | Turns raw token and post state into the summary. |
| `perm.notifications` | perm | required | Tells you the morning a token dies. Pending CR-1: should be optional. |

## Config keys read

| key | why |
|---|---|
| `grux.social.accounts` | The list of platform plus handle pairs to check. |
| `grux.model.provider` | Which provider writes the summary. |
| `grux.model.chat_id` | Which model writes the summary. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

## The blueprint itself

**Schedule:**

| field | value |
|---|---|
| title | Social health check |
| weekdays | 1, 2, 3, 4, 5, 6, 7 (every day) |
| hour | 7 |
| minute | 45 |
| action | Agent prompt |
| notify on fire | on |

That is 7:45 AM local, every day. Equivalent standard cron expression: `45 7 * * *`.
Deliberately early: a dead token found before the working day starts costs you nothing,
found at 5:00 PM it has cost you a day of posts.

**Agent prompt:**

```
Check the health of every connected social account and report a grid.

Accounts to check, one per line as "platform<TAB>handle":
<your-accounts>

For each account, establish four things and nothing more:

1. AUTH. Call the platform's own "who am I" endpoint using the stored credentials
   (for example the token introspection or profile endpoint). Record: reachable and
   authorised, reachable and rejected, or unreachable. If the platform returns an
   expiry timestamp, record it and how many days remain.
2. LAST POST. Find the most recent post on that account and record its timestamp and
   how many days ago that was.
3. QUEUE. If the account has anything scheduled through the poster, record how many
   items are queued and the timestamp of the next one. If there is no queue, say so
   rather than reporting zero.
4. LAST FAILURE. Read the poster's own log at
   ~/Library/Application Support/Grux/logs/social-poster.log if it exists, and record
   the most recent failed attempt for this account with its error text.

Write the grid to
~/Library/Application Support/Grux/reports/social-health-$(date +%Y-%m-%d).md
with this exact structure:

  ## Broken
  Any account where AUTH is rejected, or a token expires within 7 days, or the last
  failure is more recent than the last successful post. One block each: platform,
  handle, what is wrong, and the single next action a person should take. If none,
  write "Nothing broken."

  ## Stalled
  Any account authorised but with no post in more than <your-expected-cadence-days>
  days and nothing queued. One line each.

  ## Healthy
  One line per account: platform, handle, last post N days ago, M queued, token
  expires in D days or "no expiry reported".

  ## Not checked
  Any account whose check failed for a reason other than a rejected token, with the
  status code or error. Never drop an account from the grid.

Finish with one line beginning "SOCIAL: " giving the broken count, the stalled count,
and the healthy count, under 150 characters.

Rules. Never post anything. Never refresh or rotate a token: that is a separate,
user-approved workflow. Do not report an account as healthy on the basis of a cached
value, only on a live response. If you could not reach a platform, that is "Not
checked", not "Healthy". No em dashes, no en dashes.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Social accounts: "Connect the social accounts you want Grux to watch in Settings."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

An empty `grux.social.accounts` is `needs-setup`, not a grid with no rows. A health grid
that shows nothing wrong because it is watching nothing is the exact failure this blueprint
exists to prevent.

## Example, not a default

```
Example, not a default

Config:

  "grux.social.accounts": [
    { "platform": "mastodon", "handle": "@acme@example.social" },
    { "platform": "bluesky",  "handle": "acme.example.com" },
    { "platform": "linkedin", "handle": "company/acme-widgets" }
  ]

Schedule: every day, 7:45 AM, Agent prompt, notify on.

Notification:

  Schedule done: Social health check
  SOCIAL: 1 broken, 1 stalled, 1 healthy.

Grid:

  ## Broken
  linkedin  company/acme-widgets
    Token rejected, 401 from the profile endpoint. Last successful post was 12 days ago,
    last failure was 20 minutes ago.
    Next action: re-authorise LinkedIn in Settings. The queued posts will retry on their
    own once the token is valid.

  ## Stalled
  bluesky  acme.example.com  authorised, last post 19 days ago, nothing queued

  ## Healthy
  mastodon  @acme@example.social  last post 1 day ago, 4 queued, no expiry reported

  ## Not checked
  Nothing, all three responded.
```

## Honest limitations

- **It cannot see a shadow ban or a reach collapse.** A platform can accept your token,
  accept your post, and show it to nobody. Every cell reads green while the account is
  effectively dead. This checks plumbing, not reach.
- **"Last post" comes from the platform, and platforms lie by omission.** A post filtered
  or held for review may not appear in your own timeline API for hours.
- **It never fixes anything.** By design: refreshing a token is an action against a third
  party account, and doing that unattended at 7:45 AM without your knowledge is not
  something a health check should do. `social-ops-cockpit` is where the fixing lives, with
  an approval gate in front of it.
- **The queue check depends on a poster that may not exist.** If you post by hand, the
  QUEUE and LAST FAILURE sections will be permanently empty, and the grid will report that
  rather than pretending.
- **Every platform is different and the prompt papers over that.** The instruction to "call
  the platform's own who am I endpoint" is doing a lot of work. Expect to specialise the
  prompt per platform once you have more than three.
- **One fire per day, and a missed fire is dropped**
  (`CommandsV2/UserCronStore.swift:69-70`, `:253`, `:282-289`). If your Mac sleeps through
  7:45 AM you get no grid and no warning that you got no grid.
- **The notification is truncated at 180 characters**
  (`CommandsV2/UserCronStore.swift:341`), so the `SOCIAL:` line carries the whole headline.
- **It costs a model call every day even when every cell is green.** The health data itself
  is cheap, the summarising is not.
