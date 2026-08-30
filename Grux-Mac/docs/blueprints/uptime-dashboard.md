# uptime-dashboard

## What it does

Checks that the sites you care about are actually answering, and tells you which ones are
not. You give it a list of URLs, it asks each one for a response, and it reports status
codes and how long each took, with the broken ones at the top.

## Host

**Schedules** (`CommandsV2/UserCronStore.swift`). A repeated probe of a fixed list, with no
decisions in it. `UserCronAction.agentPrompt` (`CommandsV2/UserCronStore.swift:26`) does
the probing and the write up in one pass.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `endpoint.uptime_targets` | endpoint | required | The URLs to probe. Nothing is checked until you add some. |
| `key.anthropic` | key | required | Writes the summary. Pending CR-1: should be optional, the raw probe table is useful on its own. |
| `perm.notifications` | perm | required | How a red result reaches you. Pending CR-1: should be optional. |

## Config keys read

| key | why |
|---|---|
| `grux.uptime.targets` | The list of URLs to probe. |
| `grux.model.provider` | Which provider writes the summary. |
| `grux.model.chat_id` | Which model writes the summary. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

## The blueprint itself

Because a `UserCronJob` fires at most once a day (`CommandsV2/UserCronStore.swift:69-70`),
a useful uptime check needs several jobs. Create three identical jobs at different times.
Three is the smallest number that distinguishes "it was down once" from "it is down".

**Schedule, job 1 of 3:**

| field | value |
|---|---|
| title | Uptime check, morning |
| weekdays | 1, 2, 3, 4, 5, 6, 7 (every day) |
| hour | 7 |
| minute | 0 |
| action | Agent prompt |
| notify on fire | on |

Jobs 2 and 3 are the same job with `hour` set to 13 and 19 and the title changed to
"Uptime check, midday" and "Uptime check, evening". Those are 7:00 AM, 1:00 PM and
7:00 PM local. Equivalent standard cron expression for all three as one line, if the host
ever gains a cron parser: `0 7,13,19 * * *`.

**Agent prompt** (identical in all three jobs):

```
Probe every monitored URL once and report.

URLs, one per line:
<your-uptime-targets>

For each URL:

1. Issue a single GET with a 10 second timeout, following up to 3 redirects. Record
   the final status code, the total time in seconds to two decimal places, the final
   URL after redirects, and the TLS certificate expiry date if the scheme is https.
2. If the status code is not in the 200 to 299 range, retry exactly once after
   waiting 5 seconds, and record both attempts. One failure is noise, two is a signal.
3. Do not follow a redirect that leaves the original hostname without recording it.
   A hostname that 301s everything caches its own redirects and can look healthy while
   the origin behind it is unreachable, so always report the final URL, never just the
   status.

Append one line per URL to the running log at
~/Library/Application Support/Grux/reports/uptime-log.tsv in the format
timestamp<TAB>url<TAB>status<TAB>seconds<TAB>final_url
creating the file with that header row if it does not exist. Appending, not
overwriting, is what makes the next run able to say "second failure in a row".

Then write
~/Library/Application Support/Grux/reports/uptime-latest.md with this structure:

  ## Down
  Any URL that failed both attempts. One block each: URL, both status codes, the
  final URL, and whether the previous run in uptime-log.tsv also failed. If none,
  write "Everything responded."

  ## Slow
  Any URL that responded but took more than 2.00 seconds. One line each with the time.

  ## Certificates expiring
  Any https URL whose certificate expires within 21 days, with the date and day count.

  ## Up
  One line each: URL, status, seconds.

Finish with one line beginning "UPTIME: " giving the down count, slow count, and the
name of the first down host if there is one, under 150 characters.

Rules. A 200 response is not proof the page works, it is proof something answered, so
never write that a site is "fine", write that it responded. Report the number you
measured, never a rounded impression. No em dashes, no en dashes.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Sites to monitor: "Add the URLs you want Grux to check in Settings."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

An empty `grux.uptime.targets` is `needs-setup`. A dashboard that reports "0 down" while
watching nothing is the worst possible output, so it is not an output this blueprint can
produce.

## Example, not a default

```
Example, not a default

Config:

  "grux.uptime.targets": [
    "https://acme.example.com",
    "https://api.acme.example.com/health",
    "https://docs.acme.example.com"
  ]

Three schedules: every day at 7:00 AM, 1:00 PM and 7:00 PM, Agent prompt, notify on.

Notification from the 1:00 PM run:

  Schedule done: Uptime check, midday
  UPTIME: 1 down, 1 slow. First down host: api.acme.example.com.

Report:

  ## Down
  https://api.acme.example.com/health
    Attempt 1: 502.  Attempt 2 after 5s: 502.
    Final URL: https://api.acme.example.com/health
    The 7:00 AM run also failed. This is the second consecutive failure.

  ## Slow
  https://docs.acme.example.com  3.412s

  ## Certificates expiring
  https://docs.acme.example.com  expires 2026-08-24, 15 days

  ## Up
  https://acme.example.com        200  0.284s
  https://docs.acme.example.com   200  3.412s
```

## Honest limitations

- **This is not uptime monitoring and should not be sold to you as such.** Three probes a
  day from one machine sitting in one place on one network gives you roughly 0.2% sampling
  of the day. A real monitor probes from several regions every minute and pages you. If
  something depends on knowing within minutes, use a monitoring service and point this
  blueprint at its API instead.
- **It only runs when your Mac is awake and Grux is open.** A laptop closed at 7:00 PM
  simply misses that check, and a missed fire is skipped rather than caught up
  (`CommandsV2/UserCronStore.swift:253`, `:282-289`). Your quietest hours are exactly the
  hours it is least likely to be watching.
- **A status code is not health.** A page returning 200 with a stack trace in the body
  reads as up. The prompt refuses to call anything "fine" for this reason, but it cannot
  detect the problem.
- **Your own network is a confound.** When your internet drops, every target reports down.
  The report cannot tell the difference between "the site is down" and "you are offline".
- **Three schedules mean three model calls a day** for what is fundamentally a `curl` loop.
  If cost matters more than prose, set `grux.model.provider` to a local model, or drop the
  summary and read `uptime-log.tsv` yourself.
- **The log grows without bound.** `uptime-log.tsv` is appended to forever and nothing
  prunes it. At three runs a day across ten URLs that is around 11,000 lines a year, which
  is small, but it is never zero and nothing cleans it up.
- **No alerting escalation.** A notification you dismiss is gone. There is no repeat, no
  acknowledgement, and no paging.
