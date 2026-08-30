# social-ops-cockpit

## What it does

The place you go when a social account has stopped working. It shows every account you have
connected, what state each one is in, and what is stuck. Then it offers you one action per
problem: retry the posts that failed, or walk you through re-authorising the account whose
token expired. Nothing happens to an account until you say so.

## Host

**Workflows** (`CommandsV2`). It is a gather, then a branch on what kind of problem exists,
then an action behind an approval gate. Re-authorising an account and re-sending posts are
both actions against a third party under your name, so both need `userApprovalGate`
(`CommandsV2/CommandV2Models.swift:170`), which only Workflows provides.

`social-health-grid` is the passive daily companion: it tells you a token died. This is
what you run afterwards.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `endpoint.social_accounts` | endpoint | required | The accounts to operate on. |
| `key.anthropic` | key | required | Reads the platform responses and explains what is wrong. |
| `perm.automation` | perm | required | Re-authorisation ends in a browser window that has to be driven. |
| `perm.notifications` | perm | required | Tells you when a retry finished. Pending CR-1: should be optional. |

## Config keys read

| key | why |
|---|---|
| `grux.social.accounts` | The accounts, their platforms and their handles. |
| `grux.model.provider` | Which provider does the diagnosis. |
| `grux.model.chat_id` | Which model does the diagnosis. |
| `grux.cost.daily_ceiling_usd` | Stops the run rather than overspending. |

## The blueprint itself

Eight phases. The branch splits the two failure modes that need different handling: a dead
token needs you in a browser, a failed post just needs another attempt.

| # | phase id | action | note |
|---|---|---|---|
| 1 | `gather` | `claudeAgent` | Reads live state for every account. |
| 2 | `stash-worst` | `setState` | The single worst problem drives the branch. |
| 3 | `triage` | `branch` | Auth problem or delivery problem. |
| 4 | `nothing-wrong` | `speak` | The common case, ends the run. |
| 5 | `auth-plan` | `speak` | Explains what re-authorisation will do. |
| 6 | `auth-approve` | `userApprovalGate` | |
| 7 | `auth-run` | `claudeAgent` | Opens the platform's own authorisation page. |
| 8 | `retry-approve` then `retry-run` | `userApprovalGate`, `claudeAgent` | Re-sends failed posts. |

```json
{
  "id": "social-ops-cockpit",
  "displayName": "social operations",
  "voiceTriggers": ["social cockpit", "fix my social accounts", "what is wrong with my accounts"],
  "description": "Show the state of every connected social account and fix what is stuck, with your approval before anything touches an account.",
  "category": "observe",
  "parameters": [],
  "phases": [
    {
      "id": "gather",
      "displayName": "Read the state of every account",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Read the live state of every connected social account.\n\nAccounts, one per line as 'platform<TAB>handle':\n<your-accounts>\n\nFor each account, using the stored credentials, establish:\n  auth      authorised, rejected, or unreachable, plus the status code\n  expires   the token expiry if the platform reports one, else 'not reported'\n  lastpost  the timestamp of the most recent post\n  queued    how many items are waiting to send, and the oldest one's timestamp\n  failed    how many send attempts failed in the last 7 days, with the most recent\n            error text verbatim\n\nWrite ~/Library/Application Support/Grux/reports/social-ops.md as a table with one row per account and those six columns, then a short section per problem account explaining in plain language what is wrong and what the single fix is.\n\nThen decide the single worst problem across all accounts, using this order: a rejected token beats a token expiring within 7 days, which beats failed sends, which beats a stalled queue. Print the last line as exactly one of these three words and nothing else on that line:\n  AUTH      if any account's token is rejected or expires within 7 days\n  RETRY     if no auth problem exists but some sends failed\n  CLEAR     if neither\n\nDo not post anything. Do not refresh, rotate, or revoke any token. This phase reads. No em dashes, no en dashes.",
        "maxTokens": null
      }
    },
    {
      "id": "stash-worst",
      "displayName": "Stash the worst problem",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "worst",
        "valueExpr": { "kind": "fromAgentOutput" }
      }
    },
    {
      "id": "triage",
      "displayName": "Which problem are we solving?",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": { "kind": "stateMatches", "key": "worst", "regex": "AUTH\\s*$" },
        "ifTrue": "auth-plan",
        "ifFalse": "delivery-triage"
      }
    },
    {
      "id": "delivery-triage",
      "displayName": "Failed sends or nothing?",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": { "kind": "stateMatches", "key": "worst", "regex": "RETRY\\s*$" },
        "ifTrue": "retry-approve",
        "ifFalse": "nothing-wrong"
      }
    },
    {
      "id": "nothing-wrong",
      "displayName": "Nothing to fix",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "Every connected account is authorised and nothing failed to send. The full table is in the social operations report.",
        "audioCueAfter": { "kind": "successChime", "postSpeakDelay": 0.4 }
      }
    },
    {
      "id": "auth-plan",
      "displayName": "Explain the re-authorisation",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "An account needs re-authorising. That opens the platform's own sign in page in your browser, you approve it there, and the new token replaces the old one. Nothing is posted, and no other account is touched."
      }
    },
    {
      "id": "auth-approve",
      "displayName": "Approve the re-authorisation",
      "userApprovalRequired": true,
      "action": {
        "kind": "userApprovalGate",
        "prompt": "Open the sign in page and re-authorise the account named in the report? Say re-auth to proceed, or stop to leave it alone.",
        "expectedReplies": ["re-auth", "stop"]
      }
    },
    {
      "id": "auth-run",
      "displayName": "Run the re-authorisation",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Re-authorise the one account identified as AUTH in ~/Library/Application Support/Grux/reports/social-ops.md.\n\nSteps:\n1. Open that platform's own authorisation URL in the browser. Use the platform's documented OAuth start URL with the client identifier already configured. Never construct a sign in page yourself and never ask the owner to type a password anywhere except the platform's own domain.\n2. Stop and wait. The owner completes the sign in. You do not fill in credentials, you do not click through a consent screen on their behalf, and you do not proceed past a two-factor prompt.\n3. When the callback returns, store the new token through the same mechanism the old one used, which is the Keychain. Never write a token to a file, a log, or a report.\n4. Verify by calling the platform's profile endpoint once and confirming it returns the expected handle. If it returns a different handle, stop immediately and say so: you have authorised the wrong account.\n5. Append one line to the report saying which account was re-authorised, at what time, and the new expiry if one is reported. Never include the token.\n\nTouch exactly one account. If the report names more than one, do the first and say the others still need doing. No em dashes, no en dashes.",
        "maxTokens": null
      }
    },
    {
      "id": "retry-approve",
      "displayName": "Approve the retry",
      "userApprovalRequired": true,
      "action": {
        "kind": "userApprovalGate",
        "prompt": "Some posts failed to send. Retrying will publish them now, under your name, to a live audience. Check the report for what they are first. Say retry to send them, or skip to leave them.",
        "expectedReplies": ["retry", "skip"]
      }
    },
    {
      "id": "retry-run",
      "displayName": "Retry the failed sends",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Retry the failed sends listed in ~/Library/Application Support/Grux/reports/social-ops.md.\n\nRules, all of them load bearing because this publishes to a live audience:\n1. Retry only items that previously FAILED. Never send anything that succeeded, and never send anything not already in the queue.\n2. Re-send the exact stored content. Do not rewrite it, improve it, shorten it, or add anything.\n3. Send at most one item per account per 30 seconds.\n4. Stop the whole retry immediately on the first authorisation error, and report it. An auth error mid-retry means the token died again and continuing will fail loudly on every remaining item.\n5. Skip any item older than 7 days and list it as skipped. A post written for last Tuesday should not appear today without someone reading it first.\n6. Append the outcome per item to the report: sent with a timestamp, failed with the error, or skipped with the reason.\n\nFinish with one line beginning 'RETRY: ' giving sent, failed and skipped counts, under 150 characters. No em dashes, no en dashes.",
        "maxTokens": null
      }
    }
  ]
}
```

Phase order matters here. `nothing-wrong` sits before the auth arm so the clear case ends
the run, and `retry-approve` sits after the auth arm so an AUTH run does not fall through
into a retry with a token that was just replaced.

Until CR-3 lands there is no on-disk install path for a workflow definition. Add the
equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and list it in
`registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or call
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- Social accounts: "Connect the social accounts you want Grux to watch in Settings."
- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."
- Automation: "Grux needs Automation to control other apps. Approve the prompt macOS shows, or enable Grux under Privacy and Security, Automation."
- Notifications: "Allow notifications so Grux can nudge you. Open System Settings, Notifications, Grux, and turn them on."

## Example, not a default

```
Example, not a default

Config:

  "grux.social.accounts": [
    { "platform": "mastodon", "handle": "@acme@example.social" },
    { "platform": "bluesky",  "handle": "acme.example.com" },
    { "platform": "linkedin", "handle": "company/acme-widgets" }
  ]

Report:

  platform  handle                 auth        expires    lastpost   queued  failed
  mastodon  @acme@example.social   authorised  none        1 day ago  4       0
  bluesky   acme.example.com       authorised  in 4 days   3 days ago 0       0
  linkedin  company/acme-widgets   rejected    expired     12 days    2       6

  linkedin, company/acme-widgets
  The token is rejected with 401 from the profile endpoint, and it expired 12 days ago.
  Six sends failed since then, the most recent 20 minutes ago with
  "REVOKED_ACCESS_TOKEN". Fix: re-authorise. The two queued posts will go out on the
  next retry once the token is valid.

  bluesky, acme.example.com
  Authorised, but the token expires in 4 days. Re-authorise before it does.

  AUTH

Spoken:

  An account needs re-authorising. That opens the platform's own sign in page in your
  browser, you approve it there, and the new token replaces the old one. Nothing is
  posted, and no other account is touched.

  Re-authorise the account named in the report? Say re-auth to proceed, or stop.
```

## Honest limitations

- **Retrying publishes to real people, and that is the sharpest edge in this whole set.**
  A queue of six posts retried at once floods a timeline. The 30 second spacing and the 7
  day staleness skip reduce that, and neither is a substitute for reading the queue before
  you say retry. The approval prompt says "to a live audience" for exactly this reason.
- **Re-authorisation is only partly automatable, and the parts that are not are the
  security-relevant parts.** The agent opens the platform's own page and then stops. It
  does not enter credentials and it does not pass a two-factor prompt, deliberately. Anyone
  extending this to "handle" a sign in is building a credential-entering robot, which is a
  different and much worse product.
- **One account per run.** The auth arm fixes the first account and tells you the others
  still need doing, because a loop that re-authorises three accounts unattended is a loop
  that can authorise the wrong one three times.
- **The verification step is one profile call.** It catches "you signed into the wrong
  account", it does not catch a token granted with fewer scopes than before. A
  re-authorisation that succeeds but drops the posting scope will look fine here and fail
  at the next send.
- **The branch reads the last line of agent output.** That is a real coupling: if the
  gather phase's model adds a trailing sentence after `AUTH`, the regex misses and the run
  takes the wrong arm. It fails toward doing nothing, which is the safe direction, and it
  is still fragile.
- **Every platform is different and the prompts abstract over that.** "Use the platform's
  documented OAuth start URL" is a large instruction. Expect to write a per-platform
  variant once you pass three accounts.
- **It never composes or schedules anything.** This is an operations panel for accounts
  that already have a posting pipeline. If you have no pipeline, the queue and failure
  columns will be permanently empty and this blueprint reduces to a token expiry checker.
- **The state of an account is read at that moment.** Between the gather phase and the
  retry phase a token can die, which is why rule 4 stops the whole retry on the first
  authorisation error.
