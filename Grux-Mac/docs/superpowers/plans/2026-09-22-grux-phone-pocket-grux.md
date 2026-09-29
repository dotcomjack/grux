# Grux Phone: the pocket Grux, and what the rename costs

> **STATUS: ACTIVE**, written 2026-09-22. The rename is DONE in this commit.
> Everything under "The refresh" is a plan and is NOT built.

## What changed now

`com.dcj.gruxphone` became `com.gruxai.gruxphone`, on the operator's call, for
the same reason the Mac app moved in August: the old prefix carries the
original author's initials and a bundle id is permanent once strangers have
installed it. Three occurrences: `project.yml`
(`PRODUCT_BUNDLE_IDENTIFIER`), the phone's Keychain service, and a dispatch
queue label.

**This is a re-pair, and it cannot be a migration.** The Mac's rename shipped
`KeychainServiceMigrator` because a macOS login keychain keeps items across a
service rename, so they had to be copied before they became unreachable. iOS
does not work that way: a bundle id change moves the app into a different
keychain access group, so items written by the old app are unreachable to the
new one whatever the service string says. There is nothing to migrate and no
code that could do it.

So the once-only cost, for the one person who has this paired today:

1. Delete the old app from the phone. Its Keychain items go with it.
2. `cd GruxPhone && xcodegen` with `GRUX_TEAM_ID` exported, build, install.
3. Pair again from the Mac (`touch ~/.grux/fire-pair-iphone`). The Mac's own
   pairing secret is in the Mac's Keychain and is untouched; the phone gets a
   fresh one.
4. Grant the microphone on the phone once more, for the same reason the Mac
   needed re-granting in August: macOS and iOS key every permission to the
   app's identity, and the identity changed.

Nothing on the Mac side changes. The receiver binds the same way, the wire
protocol is unchanged, and pairing is still same-network only.

## The refresh, not built

The operator's words: "it's an empty shell for them to essentially carry with
them and run as their free, 24/7 always available pocket Grux". What ships
today is a pairing shell: it streams the Mac's microphone and speech and shows
a connection state. Away from the Mac's network it does nothing at all.

What "pocket Grux" would have to mean, smallest first:

1. **Say something and have it land.** A single field that queues text to the
   Mac and shows the reply when the Mac is reachable again. No model on the
   phone, no server: a queue with a timestamp. This alone turns the shell into
   something worth carrying, and it is the only item here that needs no new
   infrastructure.
2. **The day, read-only.** Today's card (next thing, mail that needs a reply,
   what Grux did) pushed from the Mac on connect and cached. Again no server:
   the phone shows the last thing the Mac told it, with the time it was told.
3. **Away from the network.** The honest options are a relay the operator runs
   or a Cloudflare tunnel with a fixed host. Both are a real decision about
   exposure: the pairing secret stops being a same-network secret. The tunnel
   half of this repo was deliberately ripped out in P-R-7, and putting it back
   is a security decision, not a feature.
4. **Voice on the phone itself.** Whisper on-device is feasible and is the
   point at which "24/7 pocket Grux" stops depending on the Mac being awake.
   It is also the largest piece by far and needs its own plan.

Ordering is deliberate: 1 and 2 are days and cost nothing to run; 3 is a
decision before it is a build; 4 is a project.

## What the rename does NOT do

It does not make the phone useful away from the Mac, and it does not touch the
pairing protocol. Anyone reading this file because the phone stopped working
should start at "This is a re-pair".
