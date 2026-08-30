# workday-log

## What it does

Keeps a private record of how your working day actually went, then reads it back to you at
the end of the day: which apps you were in and for how long, what pulled you away, when
your Mac went to sleep, and where the long uninterrupted stretches were. It is a diary you
do not have to write.

## Host

**Schedules** (`CommandsV2/UserCronStore.swift`). The capture itself is a Track A concern
governed by `grux.workday.enabled` and the focus loop. What this blueprint installs is the
end-of-day read back, which is one action on a cadence, so
`UserCronAction.agentPrompt` (`CommandsV2/UserCronStore.swift:26`) is the right host.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `perm.screen_recording` | perm | required | Without it there is no frame and no window context. |
| `perm.accessibility` | perm | required | Reading the active window title. |
| `key.anthropic` | key | required | Reads the raw log and writes the day back to you. |
| `perm.notifications` | perm | required | Delivers the end-of-day summary. Pending CR-1: should be optional. |
| `key.elevenlabs` | key | **optional** | A natural voice for the spoken summary. Without it macOS speaks it, which is genuinely fine. |

`key.elevenlabs` is one of only two capabilities the contract marks optional
(contract 1.4). Its absence puts this feature in `degraded`, not `needs-setup`.

## Config keys read

| key | why |
|---|---|
| `grux.workday.enabled` | The master switch. Off by default. |
| `grux.focus.enabled` | The capture loop this log is built from. Off until onboarding completes. |
| `grux.focus.cadence_seconds` | How often a sample is taken, which sets the resolution of the log. |
| `grux.capture.excluded_bundle_ids` | Apps that are never captured. |
| `grux.capture.excluded_window_titles` | Window title substrings that are never captured. |
| `grux.capture.indicator_enabled` | The visible indicator shown whenever a frame is transmitted. |
| `grux.capture.first_frame_reviewed` | Gates the whole loop until you have seen exactly what would be sent. |
| `grux.model.vision_id` | The model the focus loop uses. |
| `grux.model.provider` | Which provider writes the summary. |
| `grux.model.chat_id` | Which model writes the summary. |
| `grux.voice.tts_provider` | System voice or ElevenLabs. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |

## The blueprint itself

**Schedule:**

| field | value |
|---|---|
| title | End of day |
| weekdays | 2, 3, 4, 5, 6 (Monday through Friday) |
| hour | 17 |
| minute | 45 |
| action | Agent prompt |
| notify on fire | on |

That is 5:45 PM local on weekdays. Equivalent standard cron expression: `45 17 * * 1-5`.

**Agent prompt:**

```
Read back today's working day.

Read the local workday log for today at
~/Library/Application Support/Grux/workday/$(date +%Y-%m-%d).jsonl
Each line is one sample carrying at least a timestamp, the frontmost application
bundle identifier, the window title where one was captured, and a sleep or wake
marker where the machine changed state.

If the file does not exist, say exactly that and stop. Do not reconstruct a day from
anything else, and do not guess.

Produce, in this order:

  ## Where the time went
  The top 6 applications by total minutes, longest first, as "App, N minutes". Compute
  minutes by counting samples and multiplying by the sample interval, and state the
  interval you used so the numbers can be checked. Group everything below the top 6
  into a single "Everything else, N minutes" line.

  ## Longest uninterrupted stretch
  The longest run of consecutive samples in a single application, with its start time,
  end time and duration. Write times as 4:15 PM, never as 16:15.

  ## What interrupted you
  Every switch away from an application you had been in for more than 20 minutes, with
  the time, what you left, and what you went to. Cap this at the 8 most disruptive.

  ## Asleep
  Every sleep and wake pair with times and duration, and the total time the machine
  was asleep during working hours.

  ## Gaps
  Any stretch of more than 15 minutes with no samples at all and no sleep marker.
  These are real and must be reported, not smoothed over: an excluded application, a
  permission that lapsed, or Grux not running all look identical here.

Finish with one line beginning "DAY: " naming the top application with its minutes and
the count of interruptions, under 150 characters.

Rules. This log is private, so quote no window titles that contain what looks like a
person's name, an account number, or a URL with a query string: describe them instead,
for example "a banking site" or "a document". Never estimate a duration you did not
measure. Do not editorialise about productivity, do not score the day, do not suggest
the person should have done something differently. Report what happened. No em dashes,
no en dashes. Write clock times as 4:15 PM, never 16:15.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Screen Recording: "Grux needs Screen Recording to see what you are working on. Open System Settings, Privacy and Security, Screen Recording, and enable Grux."
- Accessibility: "Grux needs Accessibility to read the active window title. Open System Settings, Privacy and Security, Accessibility, and enable Grux."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

There is one more gate that is not a capability. While `grux.capture.first_frame_reviewed`
is `false` the focus loop is `needs-setup` regardless of every other capability
(contract 5.4). The first time capture is enabled, Grux takes one frame and shows you the
exact image and the exact redacted text that would be sent, and nothing is transmitted
until you confirm. Declining leaves the flag false and this blueprint unavailable to run,
which is the correct outcome.

If everything resolves but `key.elevenlabs` is absent, the feature is `degraded`, with one
dismissible note carrying: "Optional. Add an ElevenLabs key for a natural voice. Grux uses
the built-in macOS voice without one."

## Example, not a default

```
Example, not a default

Config:

  "grux.workday.enabled": true,
  "grux.focus.enabled": true,
  "grux.focus.cadence_seconds": 60,
  "grux.capture.first_frame_reviewed": true,
  "grux.capture.excluded_bundle_ids": [
    "com.example.passwordmanager",
    "com.apple.MobileSMS",
    "com.apple.mail",
    "com.example.bankingapp"
  ],
  "grux.capture.excluded_window_titles": ["private browsing", "incognito", "sign in"]

Schedule: Monday through Friday, 5:45 PM, Agent prompt, notify on.

Notification:

  Schedule done: End of day
  DAY: Editor, 214 minutes. 6 interruptions.

Summary:

  ## Where the time went
  Sample interval 60 seconds, 431 samples.
  Editor            214 minutes
  Browser            88 minutes
  Terminal           61 minutes
  Chat               34 minutes
  Notes              18 minutes
  Music               9 minutes
  Everything else     7 minutes

  ## Longest uninterrupted stretch
  Editor, 9:12 AM to 10:47 AM, 95 minutes.

  ## What interrupted you
  10:47 AM  left Editor after 95 minutes, went to Chat
  1:31 PM   left Editor after 42 minutes, went to Browser

  ## Asleep
  12:04 PM to 12:51 PM, 47 minutes.

  ## Gaps
  3:10 PM to 3:38 PM, 28 minutes, no samples and no sleep marker. An excluded
  application was probably frontmost.
```

## Honest limitations

- **The gaps are the honest part and they will be large.** Every excluded application
  produces a hole, and the exclusion list is seeded with password managers, banking apps,
  Messages and Mail (contract 5.2). That is correct behaviour and it means the log is
  structurally incomplete. Any total you read is a floor, not a measurement.
- **Time is inferred from samples, not measured.** At a 60 second cadence, an application
  you touched for 20 seconds may not appear at all, and one you left after 70 seconds may
  be credited with two minutes. Lowering `grux.focus.cadence_seconds` improves resolution
  and costs proportionally more.
- **It is a surveillance log of you, kept on your machine.** That is the whole point, and
  it is also the risk. It sits in plain files under Application Support. Anyone with your
  unlocked Mac can read your day. There is no encryption of the log itself in this
  blueprint.
- **The prompt's privacy rule is a request, not a mechanism.** Asking a model not to quote
  a window title containing a name is weaker than never capturing it. The real protection
  is the exclusion list, which runs before capture (contract 5.2). Put anything sensitive
  in the exclusion list, do not rely on the summarising step to be discreet.
- **"What was playing" is not in this blueprint.** Now-playing state is not a capability in
  the contract, so this reports the music application as an application, not the track.
  Adding tracks would need a capability that does not exist.
- **One fire per day, weekdays only as written, and a missed fire is dropped**
  (`CommandsV2/UserCronStore.swift:69-70`, `:253`, `:282-289`). If you close the lid at
  5:40 PM, the day is never summarised.
- **It deliberately does not score you.** If you want a productivity grade, this is the
  wrong blueprint, and the prompt will refuse to produce one.
