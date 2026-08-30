# mention-monitor

## What it does

Tells you what strangers are saying about your product without you having to go looking.
Once a day it reads new App Store reviews and new Reddit posts and comments that mention
your product, and writes you a short digest: what people liked, what they complained
about, and anything that looks like it needs a reply today.

## Host

**Schedules** (`CommandsV2/UserCronStore.swift`). The entire value is the cadence. There is
one action, run one prompt, and nothing branches. `UserCronAction.agentPrompt`
(`CommandsV2/UserCronStore.swift:26`) spawns a single agent with the prompt below and
notifies you with the first 180 characters of its answer
(`CommandsV2/UserCronStore.swift:338`).

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.anthropic` | key | required | Reads and summarises the raw text. |
| `key.reddit` | key | required | Reddit search. Pending CR-1: should be optional, App Store reviews alone are still useful. |
| `key.appstoreconnect` | key | required | Customer reviews come from the App Store Connect API. Pending CR-1: should be optional. |
| `perm.notifications` | perm | required | How the digest reaches you. Pending CR-1: should be optional. |

## Config keys read

| key | why |
|---|---|
| `grux.mentions.sources` | The list of things to watch: App Store app identifiers and subreddits. |
| `grux.asc.key_id` | App Store Connect key identifier. |
| `grux.asc.issuer_id` | App Store Connect issuer identifier. |
| `grux.asc.p8_path` | Path to the App Store Connect private key file. |
| `grux.model.provider` | Which provider summarises. |
| `grux.model.chat_id` | Which model summarises. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

`grux.mentions.reddit_key` and `grux.model.anthropic_key` are secrets resolved from
Keychain by the capability layer, never read from the config file (contract 2.4).

## The blueprint itself

**Schedule**, in the fields `UserCronEditorView` actually asks for
(`CommandsV2/UserCronEditorView.swift:14-18`):

| field | value |
|---|---|
| title | Mention digest |
| weekdays | 1, 2, 3, 4, 5, 6, 7 (every day) |
| hour | 8 |
| minute | 30 |
| action | Agent prompt |
| notify on fire | on |

That lands at 8:30 AM local, every day. The equivalent standard cron expression, for
readers who think in cron, is `30 8 * * *`. The store does not parse cron strings, it
stores a weekday set plus an hour and a minute (`CommandsV2/UserCronStore.swift:61-73`).

**Agent prompt.** Paste this into the Agent prompt field. Replace every `<...>`.

```
Write today's mention digest for <your-product-name>.

Sources to check, in order:

1. App Store reviews. Use the App Store Connect API. Mint an ES256 JWT from the key
   at <your-p8-path> with key id <your-asc-key-id> and issuer <your-asc-issuer-id>,
   then GET
   https://api.appstoreconnect.apple.com/v1/apps/<your-app-id>/customerReviews?sort=-createdDate&limit=50
   with header 'Authorization: Bearer <jwt>'. Keep only reviews created in the last
   24 hours.

2. Reddit. Search these subreddits for the terms <your-search-terms-comma-separated>:
   <your-subreddits-comma-separated>. Use the Reddit API with the credentials already
   in the environment. Keep only posts and comments from the last 24 hours. Skip
   anything you posted yourself.

Then write the digest to
~/Library/Application Support/Grux/reports/mentions-$(date +%Y-%m-%d).md
with this exact structure:

  ## Needs a reply today
  Only items where someone asked a direct question, reported a bug with enough detail
  to act on, or is visibly angry. Each entry: one line of what they said, the source
  link, and one sentence on what a good reply would say. If there are none, write
  "Nothing today."

  ## What people liked
  At most three recurring positives, each with a count and one representative quote.

  ## What people complained about
  At most three recurring complaints, each with a count and one representative quote.
  Rank by count, not by how loud any one person was.

  ## Volume
  A single line: N App Store reviews, M Reddit mentions, average App Store rating for
  the day.

Rules. Quote people accurately, never paraphrase a quote and present it as one. Do not
invent a count. If a source failed or returned nothing, say which source and why under a
"Not checked" heading rather than leaving it out. One angry person is one person, do not
report a single complaint as a trend. No em dashes, no en dashes, use commas or full
stops. Write dollar amounts as $50, not fifty dollars.

Finish by printing one line beginning "DIGEST: " that states the count of items needing
a reply and the single most common complaint. That line is what gets read aloud, so it
must stand alone.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card carrying these exact strings.

- Reddit API credentials: "Connect Reddit in Settings to read mentions of your product."
- App Store Connect API key: "Add your App Store Connect key, issuer ID and .p8 file in Settings to let Grux publish builds."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

With `grux.mentions.sources` empty there is nothing to watch, and the same registry-shaped
remediation applies: the setup card lists the source list as the missing thing before it
lists anything else.

## Example, not a default

```
Example, not a default

Config:

  "grux.mentions.sources": [
    "appstore:1234567890",
    "reddit:r/productivity",
    "reddit:r/macapps"
  ]

Schedule: every day, 8:30 AM, Agent prompt, notify on.

Notification it produced:

  Schedule done: Mention digest
  DIGEST: 2 items need a reply. Most common complaint: sync stalls on large libraries.

Digest file, ~/Library/Application Support/Grux/reports/mentions-2026-08-09.md:

  ## Needs a reply today
  "Third time this week it dropped my whole library." (App Store, 1 star, US)
  A good reply names the sync stall, says it is being worked on, and asks for a
  diagnostics file.

  ## What people liked
  Speed, 4 mentions. "Opens instantly, which nothing else does."

  ## What people complained about
  Sync stalls on large libraries, 5 mentions.
  Price, 2 mentions.

  ## Volume
  6 App Store reviews, 9 Reddit mentions, average rating 3.8 for the day.

  ## Not checked
  r/macapps returned a rate limit error twice, so its mentions are missing.
```

## Honest limitations

- **It reads what the APIs will give it, which is less than you think.** The App Store
  Connect customer reviews endpoint returns reviews for territories you have sales in and
  can lag by hours. Reddit search misses posts in private subreddits and misses anything
  that describes your product without naming it.
- **It is not sentiment analysis, it is a model reading text.** The counts are the model's
  judgement of what clusters together. Two runs on the same data can group differently.
  Trust the quotes, treat the counts as approximate.
- **A single fire per day.** `UserCronJob` stores one hour and one minute
  (`CommandsV2/UserCronStore.swift:69-70`), so one job fires at most once a day. Wanting a
  morning and an evening digest means creating two jobs.
- **A missed fire is skipped, not replayed.** If the Mac is asleep or Grux is closed for
  more than 10 minutes past the scheduled time, the occurrence is dropped and the anchor
  rolls forward (`CommandsV2/UserCronStore.swift:253`, `:282`). You get no digest that day
  and no warning that you did not.
- **The notification is truncated to 180 characters**
  (`CommandsV2/UserCronStore.swift:341`). The `DIGEST:` line has to carry the whole
  headline, which is why the prompt insists it stand alone.
- **No deduplication across days.** A review that stays at the top of your App Store page
  will not reappear, because the prompt filters to the last 24 hours, but a Reddit thread
  that keeps getting comments will resurface every day it is active.
- **It costs a model call every single day**, whether anyone mentioned you or not. There is
  no cheap pre-check that skips the model when both sources are empty.
