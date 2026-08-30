# Grux-Mac (voice + dictation Mac app, paired with iPhone)

Native macOS voice and dictation app that pairs with an iPhone companion (GruxPhone) over the local network.

## Read these FIRST

Anything install-specific (the operator's own device ids, signing identity, clone
paths, and any private rule files they layer on top) lives OUTSIDE this repo in
`~/.grux/grux-mac-local.md`. Read it if it exists. It is deliberately not
tracked: this file is the half that is true for every install, and that file is
the half that is true for exactly one machine. An absent local file is a
supported state, not an error, and nothing here depends on it.

## ABSOLUTE: ONE active codebase + ONE canonical branch (LOCKED 2026-06-14)

Grux is developed and BUILT from ONE clone on branch **`main`**. That clone owns the `.worktrees/` (the `upgrade/*` autonomous-upgrade branches and the clean build worktree `grux-main`). Build + install ONLY from the build worktree, which is the checkout that holds `main`:

```
cd Grux-Mac && ./build.sh
```

`main` is the feature-complete tree: the section-grouped sidebar (COMMAND / WORKSPACE / INTELLIGENCE / System) with Home, Mailbox, Calendar, Notes, Documents, Contacts, Schedules, Research, Meta Ads, and the **Foundry / Self-Upgrade** engine.

**Do NOT work in or build from these (they are stale and WILL look like an old Grux):**
- Any iCloud Drive mirror of this repo. iCloud mirrors of code trees are read-only history as far as Grux is concerned; they are never the build source.
- Branch `feat/empire-dash` (an old base that `main` already merged on 2026-06-12 via `c031298`).
- Branch `gap/context-compression-rolling-summarization` (April 30 base for the upgrade worktrees).

**Why this lock exists (incident 2026-06-14):** a session worked in an iCloud mirror on `feat/empire-dash`, built it, and installed it over the real `main` build. The reorganized sidebar and the Self-Upgrade tab vanished from the running app and looked deleted. They were on `main` the entire time, and nothing had been lost. Before concluding any feature is "gone," confirm which clone and branch you are on (`git -C <path> rev-parse --abbrev-ref HEAD` should say `main`) and run `git log --all` / `git branch -a --contains <sha>` / `git worktree list`. A "missing" feature almost always means wrong checkout, not lost work.

Note the repo root is NOT expected to be on `main`: git allows a branch in exactly one worktree at a time, and the build worktree owns `main`, so checking `main` out at the root fails by design. Checking the root's branch instead of the build worktree's is the trap this rule is here to catch.

## Commit WIP features the moment they work (LOCKED 2026-06-14)

When a Grux feature reaches a working state, COMMIT IT THAT SESSION and push to `main` (the global "commit and push freely without asking" rule authorizes this, no permission needed). Do not leave a built feature sitting only in the working tree across sessions: untracked new files and modified tracked files are both at risk from a later `git checkout`/`reset`/`clean`. If a feature is reported "gone," FIRST check `git log --all`, `git branch -a --contains <sha>`, `git stash list`, `git reflog`, and `git fsck --lost-found` before assuming it is unrecoverable, and report honestly.

## Bundle id is `com.gruxai.grux` (RENAMED 2026-08-16). The phone is NOT renamed.

**The Mac app moved from `com.dcj.grux` to `com.gruxai.grux`** for the open source release:
the old prefix carried the original author's initials, and a bundle id is permanent once
strangers have installed it. Done before first release deliberately, when the cost was one
person re-granting three permissions rather than every user losing theirs. 69 occurrences
across 42 files, including `Info.plist`, `Grux.entitlements` and `build.sh`.

**This overrides the global `com.dcj.*` house default for this one app**, on the owner's explicit
call. Do not "restore" it.

**`com.dcj.gruxphone` is DELIBERATELY UNCHANGED**, all 7 occurrences. The never-change rule
below still holds, and the rename script excludes it with a negative lookahead
(`com\.dcj\.grux(?!phone)`) rather than by hand. A naive global replace turns
`com.dcj.gruxphone` into `com.gruxai.gruxphone` and orphans the pairing. Whether the phone
should follow later is the owner's call and has not been made.

**KEYCHAIN SERVICE STRINGS MOVED TOO, AND THAT IS THE PART THAT COULD HAVE LOST DATA.** Four
services renamed: `com.dcj.grux` (every API key), plus `.webhooks`, `.graph` and `.vault`. A
service string is part of a Keychain item's primary key, so a rename with no migration does
not delete the credentials, it makes them permanently unreachable while they sit in the login
keychain. That is worse than deletion, because nothing surfaces to say where they went.

`Sources/Grux/KeychainServiceMigrator.swift` runs on every launch, before anything reads a
key. **Copy, verify the copy reads back, then delete. Never reorder those.** An interrupted
migration that has copied but not deleted is harmless and re-runs cleanly; one that deleted
first is data loss. Anything that fails to verify is left alone.

**macOS gotcha, load-bearing and caught only by a test:** a generic-password query combining
`kSecMatchLimitAll` with `kSecReturnData` does NOT return values on macOS the way it does on
iOS. It comes back empty and the migration silently reports nothing to do. The migrator does
two passes: list accounts with attributes only, then read each value with
`kSecMatchLimitOne`.

**Adding a future rename is one row in `KeychainServiceMigrator.renames`.**
`KeychainServiceMigratorTests` asserts every live service has a row, that no row is a no-op,
and that every target is a current name. `NoPersonalIdentityTests.knownRemaining` exempts
that one file, because holding the old strings is its whole job, and
`testKnownRemainingIsNotStale` fails the day it stops matching, which is the day the
migration can be deleted.

**After installing a build with the new id, macOS treats it as a different app**: microphone,
screen recording and accessibility all need granting once more.

## The author's name is out of everything we control. The certificate is not ours.

**Every mention of the author in this repo's shipping surface is gone** as of
2026-08-17: the LICENSE copyright line reads `DotcomJack`, and the four remaining
comments (`Grux.entitlements`, two in `GruxPhone/`, three in this file) are
neutralised. `NoPersonalIdentityTests` now scans `Sources/`, `Tests/` AND
`GruxPhone/`; it covered only `Sources/` before, which is exactly why the
GruxPhone ones survived a guard that reported the tree clean.

**ONE mention remains in the shipped binary and it is NOT ours to remove.**
Measured: exactly one occurrence, inside the `LC_CODE_SIGNATURE` blob, in the
`organizationName` (`O=`) field of the Apple-issued X.509 certificate.
Occurrences outside that region: **zero**.

**It is an account-level fact, not a build setting, and that is measurable rather
than assumed.** Every signing identity in the keychain carries the SAME `O=`
value, including ones whose Common Name is "Created via API", which is what rules
out a per-identity fix. Check your own with:

```bash
security find-identity -v -p codesigning        # the identities you hold
security find-certificate -c "Developer ID Application" -p \
  | openssl x509 -noout -subject                # the O= field on one of them
```

The concrete names and team id are per-account and deliberately not recorded
here: they belong to whoever built the binary, and this file ships to everyone.

So it cannot be changed by a build flag, a codesign argument, or re-issuing a
certificate. Apple populates `O=` from the Developer Program account's entity
name, and for an Individual account that is the holder's legal name. The
certificate is signed BY APPLE, so editing it invalidates the signature, and
shipping unsigned is not an option because Gatekeeper refuses it.

**To make it read `DOTCOMJACK`, the ACCOUNT has to change. Two routes, both
paperwork and both gated on the owner:**
1. Convert the Developer Program account to **Organization**, which needs a legal
   entity plus a D-U-N-S number. `O=` then becomes that entity's legal name, so
   the entity itself must be named DotcomJack.
2. Ask Apple Developer Support to enrol / re-enrol as a **sole proprietor with a
   DBA**, where the entity name may be a trade name.

**DO NOT reach for the existing LLC.** Using it as the account entity would print
it inside every signed binary and every notarization record, which directly
violates the LOCKED global rule that it is private and never shown publicly. A
certificate is about the least private place in the product.

**Until the account changes, the invariant to hold is the achievable one, and it
is enforced:** `ShippedBundleHygieneTests.testTheAuthorsNameAppearsNowhereWeControl`
reads the signature boundary out of the Mach-O with `otool` and asserts zero
occurrences before it. It fails if the name ever re-enters code or strings, and it
does not pretend the certificate is ours.

## ABSOLUTE: nothing ships OFF and undiscoverable (LOCKED 2026-08-16)

> **A feature that is off and unfindable is not a conservative default. It is a deleted
> feature with dead code behind it.**

It ships the whole cost, binary size, attack surface, maintenance, review burden, and
delivers none of the value. To the person using the app it is indistinguishable from our
never having built it. **Off by default is only defensible when the user KNOWS what they
turned down.**

**This applies to every feature in Grux, not just new ones**, and it is the rule that makes
an off-by-default posture honest instead of a way to hide unfinished work.

**Three things must be true. All three, not two:**

1. **NAMED AT FIRST RUN.** The onboarding flow tells the user it exists, before they ever
   open a settings screen. Not a changelog, not a doc, not a tooltip on hover.
2. **A PERMANENT HOME.** A Settings control that is still there in six months when they
   finally want it. First run happens once; discovery has to keep working afterwards.
3. **ITS OFF STATE EXPLAINED.** What it does, why it ships off, what turning it on costs in
   privacy, money or permissions, and what it will not do.

**Each one fails differently on its own, which is why two is not enough.** Settings-only is
never discovered. Onboarding-only is seen once, forgotten, then unfindable. Named with no
explanation is a checkbox nobody can evaluate.

**THE TEST, and it is measurable:** a user who has finished onboarding can answer *"what can
this app do that it is not doing right now, and how do I turn it on."* If answering requires
reading source, the feature is not shipped, it is buried.

**Enforce it in the suite, not in review.** A feature that ships off with no onboarding
mention and no Settings writer must FAIL a test. Skipping this rule produces no build error
and no crash, which is exactly why it needs a test rather than good intentions.

**The worst case in the tree today, as the reference for how bad this gets:** `Clone`
(`Clone/CloneExtractor.swift`) reads chat threads, the ambient buffer and meeting captures
and writes a voice-seed JSONL. It appears in four files and **not one of them is a view.** No
tab, no Settings section, no menu item. It is not hidden on a page, it is on no page.

**Do not read this rule as "default everything on".** It is the opposite: default to off,
then earn the right to ship it off by making it findable and explained.

## Deploy freely (Grux exception)

Per global rule: "Never deploy to production without explicit ask" applies to every brand EXCEPT GruxAI. Build, sign, install to iPhone, push Mac app, rotate tunnels, all routine. No "ship it" confirmation needed.

## Build + deploy

- **Mac:** `./build.sh` from the build worktree's `Grux-Mac` (releases to `/Applications/Grux.app`). build.sh quits + relaunches Grux. It pins a TCC-stable signing identity: that pin is load-bearing, because macOS keys every TCC permission grant to the signing identity, so signing with a different one silently revokes microphone, accessibility, automation and screen-recording access on the next launch. The concrete identity hash is per-machine and lives in `~/.grux/grux-mac-local.md`.
- **Open a specific tab for verification:** `/Applications/Grux.app/Contents/MacOS/Grux --open-tab=metaAds`. Full key list (35 tabs, LOCKED strings): home, reactor, chat, jaxHQ, jaxCommand, cognitionMap, featureReview, projects, tasks, agents, meetings, calendar, documents, creative (Media Studio), designStudio (alias: design), compare, cookbook, folders, notes, research, skills, schedules, speakers, contacts, mailbox, roadmap, commands, workflows, metaAds, social, focus, terminalFocus, selfUpgrade (alias: foundry), integrations, settings.

The list above is the enum at `Sources/Grux/LaunchRootView.swift:33`, which is the only source of truth; this file said 35 and omitted `social` until 2026-08-11. Count it there before trusting a number here. Unknown keys silently fall back to chat, so verify the tab you actually got.
- **iOS (GruxPhone):** the xcodegen project reads your Apple team id from the environment, so export it once before generating: `export GRUX_TEAM_ID=<your 10-char Apple team id> && cd GruxPhone && xcodegen`. With it unset, xcodegen still succeeds and the project carries no team id, so signing fails with Xcode's own no-team error rather than silently signing under somebody else's account. Then `xcodebuild ... -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic` (a `DEVELOPMENT_TEAM=...` argument here overrides the generated value either way), and install via `xcrun devicectl device install app`.

## Physical device

Every `devicectl` command below takes a device id, and that id identifies one
person's hardware, so do not paste a concrete id into this file, into `Sources/`
or into `Tests/`. Find your own each time:

```bash
xcrun devicectl list devices      # UDID column, for devicectl
xcrun xctrace list devices        # same devices, plus the ECID xcodebuild wants
```

The phone target signs under your own Apple Developer team id with bundle
`com.dcj.gruxphone`. **Never change that bundle id**: it is the shipping
identifier, and changing it revokes every macOS and iOS permission grant the
paired app holds and orphans the existing pairing.

## Auto-pair from CLI

```bash
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  --payload-url "grux-pair://v2?secret=<b64url>&wss=<wss>&name=<name>&autostart=1&chat=<url-enc>"
```

The `chat=` param is a CLI-only e2e hook. Phone must be UNLOCKED for `devicectl` launch (iOS policy, no bypass).

## Phone pairing (same network only, no tunnel, OFF by default)

**The companion is gated OFF by default** (`config.phoneCompanionEnabled`, Settings → Data & Security → Grux Phone companion). With it off, `PhoneReceiverService.start()` is skipped at the single launch call site and no listener opens. Turn it on only to pair a phone; it takes effect on next launch.

**There is no tunnel. `CloudflareTunnelManager` is an inert shell** as of 2026-08-12. It spawns no process, locates no binary, publishes no URL, and never retries. `start(forwardingTo:)` logs and returns; `stop()` does nothing. Pairing works when the phone is on the same network as the Mac and does not work from cellular or another network, and the pairing window says so in the `Reach` row rather than showing a spinner that never resolves.

`PhoneReceiverService` binds **all interfaces**, not loopback. This half is easy to lose and losing it kills the feature silently: the QR advertises the Mac's Bonjour `.local` name, so a loopback listener refuses every connection the QR can produce, with no crash and nothing failing. Verified on 2026-08-12 by `lsof`: `Grux ... TCP *:61497 (LISTEN)`. `PhoneTunnelInertTests` guards both halves and both were red-proven by planting.

Net exposure went DOWN with this change, which is the opposite of how the old loopback comment read. Before: a public `*.trycloudflare.com` ingress meant anyone holding the ephemeral URL could open a TCP connection. Now: only devices on the same network can. What guards the socket is unchanged, a 32B pairing secret, a constant-time HMAC before any audio is accepted, one connection at a time, and growing delays on repeated AUTH_FAIL.

Before this, the manager spawned an ephemeral quick tunnel (`cloudflared tunnel --no-autoupdate --url http://localhost:<port>`) and scraped a random `wss://<sub>.trycloudflare.com` host from stderr. An older version of this section instead described a named tunnel `grux` on a fixed `wss://grux.gruxai.com` that reaped stale connectors. **None of that was ever true in this file's code**: `git log -S "tunnel run grux"` on `CloudflareTunnelManager.swift` returns nothing. The claim was written in `5eba83f` and believed for months.

`applicationWillTerminate` still calls `CloudflareTunnelManager.shared.stop()`, but **that call is now a no-op and reaps nothing**, because nothing spawns a child to reap. The bug it was written for was real: nothing used to stop the child, so every quit reparented it to launchd and the next launch spawned another, and 30 orphans had accumulated by 2026-08-12, each holding a public ingress to a dead loopback port. Removing the spawn is the stronger fix, since a child you never create cannot be orphaned. The call stays so that re-enabling spawn cannot ship without its matching stop. Measured after the change: `pgrep -alx cloudflared` returns nothing.

To re-dump the current pair URL (the secret rotates; the host is now a stable `ws://<mac>.local:<port>`, and only the kernel-assigned port moves between launches):

```bash
touch ~/.grux/fire-phone-pair-dump && sleep 1 && cat ~/.grux/phone-pair-url.txt
```

Writes a fresh `grux-pair://v2?secret=…&wss=…` URL to `~/.grux/phone-pair-url.txt`, auto-shredded after 30s. Append `&autostart=1&chat=…` for CLI-driven flows.

## CLI triggers (file-watcher in GruxApp.swift)

All under `~/.grux/`:

| Touch file | Effect |
|---|---|
| `fire-phone-pair-dump` | Write current pair URL to `phone-pair-url.txt` |
| `fire-phone-status` | Dump `phone-receiver-status.json` with isConnected/frames/listenerPort |
| `fire-pair-iphone` | Open the Pair iPhone window on Mac |
| `fire-rotate-secret` | Kill active session + regenerate 32B secret (inside Grux's Keychain ACL) |
| `fire-speak` (contents = text) | `SpeechEngine.speak()` then TTS also streams to phone |
| `fire-tts-tone` | Direct synthetic 2s warble through TTSBroadcaster (bypasses ElevenLabs, proves phone TTS pipeline) |
| `fire-mic-mute` / `fire-mic-unmute` | Release or reclaim the microphone, then write `mic-status.json` |
| `fire-mic-status` | Write `mic-status.json` with no side effects |
| `fire-ambient-enable` / `fire-wake-enable` | Turn a listening feature on, which presents its consent dialog, then write `mic-status.json` |

**Why the listening triggers exist.** Enabling ambient mode or the wake word puts
up a modal consent dialog, and a modal is a mouse gesture by construction. This
app's owner has limited mobility, so a gate whose only path is a click is a gate
that can never be verified. Each trigger writes `mic-status.json` after the
dialog closes, so the ANSWER is assertable rather than assumed: declining leaves
`ambientEnabledPreference` where it was and records nothing.

`mic-status.json` reports the saved preference and what is actually running as
SEPARATE fields, because they differ exactly when it matters. Muting pulls
`ambientListening` down while `ambientEnabledPreference` deliberately survives,
since that is what unmute restores from. It is written atomically, and only
after any work the triggering action started has finished.

## Phone diag log

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.dcj.gruxphone \
  --user mobile --source Documents/diag.log \
  --destination /tmp/gruxphone-diag.log
```

Wiped on every app launch; secrets are redacted to `***REDACTED***` before write.

## Wire protocol

v3 = WebSocket + X25519 ECDHE + ChaCha20-Poly1305 AEAD + HMAC-SHA256. Receiver code: `Sources/Grux/iPhone/`.

## Named tunnel setup (NOT done, despite what this said)

Half done, and the half that is missing is the half that matters. **The account side IS real** (verified 2026-08-12): `cloudflared tunnel list` shows a named tunnel `grux`, id `8adc3c13-5425-4842-b696-c1c2e9f53e52`, created 2026-06-08, and `~/.cloudflared` holds both its credential JSON and `cert.pem`. So `tunnel login` and `tunnel create` genuinely happened.

**The code switch never did.** `CloudflareTunnelManager.swift` only ever passed `--url`, so the `grux` tunnel has sat at zero connectors since the day it was created while the app spawned throwaway quick tunnels beside it. That is why the doc read as true to whoever wrote it and was false in the running app.

**As of 2026-08-12 there is no spawn at all to switch.** The manager is inert (see Phone pairing above), so finishing the named tunnel is now a build, not an edit: teach the manager to run `tunnel run grux`, publish the fixed host, restore a matching reap in `applicationWillTerminate` before shipping any spawn, and confirm the DNS route (`cloudflared tunnel route dns grux grux.gruxai.com`, still unverified). `PhoneTunnelInertTests` will go red the moment a spawn returns, which is intended: it is the prompt to restore the reap in the same change.

Note the hostname is contested. `grux.gruxai.com` currently returns 530 from this connector-less tunnel, and the OSS launch site is slated to take that hostname. Pick a different one for the phone (`phone.gruxai.com`) or the site and the tunnel will fight over the same record.

The lesson worth keeping: this file asserted a stable, reaping, named tunnel while the code ran an ephemeral one that leaked a process per launch, and the gap survived because nobody diffed the doc against `CloudflareTunnelManager.swift`. Verify a runbook claim against the source before relying on it.

## UI refresh rule: the Chat tab is the face (LOCKED 2026-06-14)

Chat is the DEFAULT landing tab and the first surface seen on every launch. A GruxTheme refresh once styled the other tabs dramatically but left Chat as a light pass, so the app still looked old on open and read as "the update got reverted" even though it was fully deployed.

Rules for any Grux UI work:
1. Always give the Chat tab the FULL design-language treatment, not a light pass. It is the face of the app; if Chat looks old, the whole app looks old regardless of what the other tabs got.
2. Before claiming a visual change shipped, confirm the DEPLOYED and RUNNING app match: the running Grux pid's start time should equal the freshly built `/Applications/Grux.app` binary mtime. build.sh quits + relaunches, but verify.
3. When showing a UI change, capture the tab that actually changed (or Chat), not whatever tab happens to be open. Use the verification harness below: window-id capture bypasses the macOS Zoom magnifier, and screen-region capture does not.

## UI verification harness (`tools/`)

Three scripts that screenshot a LIVE Grux, one per tab, and prove each capture is the tab it claims to be. They lived in `/tmp` for one session and did not survive; they are in the repo now because a verification tool that evaporates on reboot gets rewritten from memory, and the memory loses the traps.

```bash
GRUX_SWEEP_OUT=/tmp/shots tools/grux-sweep.sh floor home chat mailbox calendar
```

- **`winid.swift`** prints `<id>\t<W>x<H>\t<owner>\t<title>` for each real window, so `screencapture -o -x -l<id>` grabs exactly that window. It filters windows under 200x200 (every AppKit app carries 1x1 helpers) and reports size in POINTS.
- **`framediff.py`** returns the COUNT of changed pixels, not a percentage, comparing only the DETAIL PANE. The nav rail is identical between tabs, so including it only dilutes the signal. A count rather than a percentage because a percentage divides by pane area and is therefore scale dependent: the same Speakers to Contacts switch measures 104,963 changed pixels (8%) at the 840pt floor and 168,950 (2%) at 2400pt, so it changes MORE pixels and scores LOWER. Pass the rail fraction explicitly at non-default window sizes; `grux-sweep.sh` derives it from the measured window width, because the 0.32 that is right at the 840pt floor discards a third of the pane at 2400pt.
- **`grux-sweep.sh`** drives the running app through `~/.grux/fire-open-tab`, roughly 0.6s per tab.

**Three traps, all of which have already produced a confidently mislabelled screenshot:**
1. The ack file fires when `requestedTab` is set, which is BEFORE SwiftUI repaints. Waiting on the ack alone hands you the previous tab's pixels.
2. "Did the bytes change" is not enough. A ticking timestamp or a blinking cursor changes bytes while the old tab is still on screen; this produced a `jaxHQ` capture that was really Chat. The sweep requires a SUBSTANTIAL diff (`THRESH=20000` changed pixels; a stale frame measures exactly 0 and every real switch observed at either window size exceeds 100,000, so the threshold sits an order of magnitude clear of both).
3. The first tab has nothing to compare against, so it captures instantly and returns whatever was already on screen. The sweep bootstraps onto a different tab first and takes a baseline. Do not remove that step: without it the run still prints a confident line for a tab it never opened.

Grux is a menu-bar app, so it can be running with its window minimized, hidden, or closed, and `winid.swift` only sees ON-SCREEN windows. The sweep therefore fires the bootstrap trigger BEFORE it is allowed to fail on a missing window: it looks for a window without aborting, snapshots the screen only if there is something to snapshot, fires, and only then resolves for real. Getting that order wrong shipped once, and the sweep exited "no Grux window found" before ever writing the trigger.

**Firing the trigger is not enough on its own, and this is the part that is easy to get wrong twice.** With Grux running and no window, the trigger arrives, `openLaunchWindow` runs, and a window IS created: `CGWindowList` with `.optionAll` lists it at 1040x732 titled "Grux OS". It never becomes ON-SCREEN. It is neither hidden nor minimized, so unhiding and deminiaturizing do nothing; the cause is macOS activation policy, because a background app cannot pull itself to the front and `NSApp.activate` does not grant that. The sweep therefore runs `open -b com.gruxai.grux` as its last resort, which an external tool may do and the app may not. Verified: from a genuinely windowless Grux the sweep now resolves the window, prints `baseline on chat (switched)`, and captures every tab.

## Meta Ads tab (ported to main 2026-06-14)

`Sources/Grux/MetaAds/` renders the autonomous Meta ads engine snapshot (engine on port 3857, reads `~/.grux/meta-ads-snapshot.json`): Winners / Contenders / Graveyard lineage forest, spend pacing vs the $16/day and $140/week caps, mode control (SIMULATE / OBSERVE / live), kill switch, and the Qwen decision journal. Wired as the `metaAds` tab in the System sidebar group and as `MetaAdsOpsSection()` in the Empire dashboard. With no ad account configured the tab renders the snapshot in a posture that spends nothing, which is the correct unconfigured state and never an error.
