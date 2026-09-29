# Grux 3.0 Phase G: ship it

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Version 3.0 everywhere it is written down, release notes that carry the measured before and after latency of every gate moved onto the engine, the open source guarantee passing, a notarized release build staged, and nothing published until the operator's principal says the word.

**Architecture:** No new code. This phase is version strings, generated documents, the existing guarantee scripts, and a build. The one piece of real work is the latency table, and it is real work because the "before" numbers have to come from somewhere honest.

**Tech Stack:** `scripts/oss-guarantee.sh`, `scripts/check-contract.py`, `scripts/extract-oss.py`, `build.sh`, `xcrun notarytool`.

**Spec:** roadmap Phase G row. Ledger: rows P-G-1, P-G-2 and gate G-G.

## Global Constraints

- Build worktree, branch `main`.
- Test floor 2653, 0 failures.
- No em dashes and no en dashes, including in the CHANGELOG. Dollar amounts as numerals with the symbol.
- **The MIT build carries no TypeSafe key.** It is a Definition of Done item and it is also the one mistake in this phase that cannot be taken back once a tag is public.
- **Both bundle identifiers unchanged**: `com.gruxai.grux` and `com.dcj.gruxphone`.
- Session ids stay off public surfaces. Older commits carry `Claude-Session:` trailers, so making anything public means stripping history first, and that is a separate decision that has not been made.
- **Publishing waits for one word.** Staging a release is free. Pushing a tag, cutting a GitHub release, and `npm publish` are not.

---

## P-G-1: Version 3.0 everywhere, and the release notes

### Task G1: Find every place the version is written

**Files:** `Info.plist:24` (currently `1.2.1`), `npm/package.json`, `README.md`, `CHANGELOG.md`, and anywhere else a grep finds it.

- [ ] **Step 1:** `grep -rn "1\.2\.1"` across the repo, excluding `.build`. **State the count found.**
- [ ] **Step 2:** Change them. **State the count changed, and reconcile the gap by name.** A version left behind in one file is how a build reports the wrong number to the person who installed it.
- [ ] **Step 3:** A test asserts `Info.plist`'s version and `npm/package.json`'s version are the same string. They are two files nobody diffs, and they drift.
- [ ] **Step 4:** Red-prove by changing one of them. Restore and `diff`.

### Task G2: The CHANGELOG, with the latency table

**Files:** `CHANGELOG.md`.

The table is a spec requirement and a Definition of Done item: **the measured before and after latency of every decision point moved onto the engine.**

| Gate | Before | After | Provider |
|---|---|---|---|
| Voice command versus chatter | | | |
| Chat intent | | | |
| Shell destructive | | | |
| Jax gate | | | |
| ... one row per gate that moved | | | |

**Where the numbers come from, honestly:**

- **After** is `DecisionLedger`, grouped by `surface`. That is what the surface strings are for and the ledger already records latency per row. Packet P-A9-7 owns producing this table.
- **Before** is the hard half. For a gate that was keyword matching, "before" is microseconds and the honest entry is that it was instant and wrong, not a number that implies it was doing the same job faster. **Say which gates got slower and by how much**, because several did, and a release note that only lists improvements is marketing rather than a changelog.
- Measured figures already in hand from 2026-09-20: voice on Jev at 383 ms, 420 ms, 469 ms and 598 ms across four live decisions; a six-question batched call at 400 ms against 780 ms for a single question.

- [ ] Every number in the table traceable to a ledger row or a quoted command output. No number appears that cannot be pointed at.

### Task G3: Site counts re-synced from the registry

The public site quotes feature counts. Phase C changed what is a row, what is a fold and what is ripped, so the counts moved. Re-sync them **from `FeatureRegistry`** rather than by hand, and have the sync script fail if it cannot read the registry rather than emitting a stale number.

---

## P-G-2: The guarantees, the build, the notarization

### Task G4: The open source guarantee

- [ ] `scripts/oss-guarantee.sh` PASS. Quote the output.
- [ ] `scripts/check-contract.py` clean. Quote the output.
- [ ] `scripts/extract-oss.py` produces the MIT tree, and **a grep of that tree for the TypeSafe key, the key's name, and the endpoint host returns nothing.** Prove the grep works first by planting a fake key in a scratch copy and watching it match. A check that returns nothing is broken until proven otherwise, and this is the highest-cost place in the repo for that rule to be ignored.
- [ ] `NoPersonalIdentityTests` and `NoTelemetryInSourcesTests` green. The first one has already caught a real leak in these very plan documents this month.

### Task G5: The release build

- [ ] `GRUX_RELEASE=1 GRUX_NOTARIZE=1 ./build.sh` with the Apple credentials.
- [ ] `spctl --assess` and `codesign --verify` both clean. Quote both.
- [ ] `ShippedBundleHygieneTests.testTheAuthorsNameAppearsNowhereWeControl` green. The one remaining occurrence is inside the Apple-issued certificate's `O=` field and is **not ours to remove**; the test knows that and asserts zero occurrences before the signature boundary. Do not attempt to "fix" the certificate.
- [ ] Install the built app and walk the Phase F stranger run once more on the notarized build, not on a debug build. A notarized binary is a different artifact and Gatekeeper treats it differently.

### Task G6: Stage, and stop

- [ ] Tag prepared locally, **not pushed**.
- [ ] Release notes written, **not published**.
- [ ] `npm` package built, **not published**.
- [ ] The ledger row says STAGED with the artifact paths.
- [ ] **Then stop and say so, in one message, with what is staged and what the word would release.**

---

## G-G: the phase gate

Every one of the nine Definition of Done items in `questionnaires/_decisions/grux-rethink-2026-09.md` has evidence in `2026-09-20-grux-3-0-evidence.md`:

1. Clean VM stranger run: at most 14 rows, no BETA pill, listening named with its off state, spoken "open my calendar" under 1 second. Screenshot plus journal.
2. Jargon test red-proven.
3. Every registry row has a recorded disposition and a reachable door.
4. Jev never acts alone on anything destructive: `rm -rf ~` at 0.99 still stops.
5. The wake-word downgrade works from the one Listening control, both ways, proven by `mic-status.json`.
6. The MIT build carries no TypeSafe key.
7. `swift build` exit 0, `swift test` exit 0 with the count printed and not below main, contract check clean, OSS guarantee PASS.
8. Chat matches the accepted finished face, captured with `tools/grux-sweep.sh`, running pid start equal to the installed binary mtime.
9. Release notes carry the measured before and after latency of every gate moved onto the engine.

**Publishing waits for one word.** The gate closing means the release is ready, not that it is out.

## Notes for whoever executes this

- The three sweep-shaped tasks here (version strings, site counts, the MIT grep) all need a stated count and a reconciled gap. "Updated the versions" with no number is how nine of twelve ship.
- The MIT key grep is the one check in this repo where a false negative is unrecoverable. Prove the grep matches a planted key before you trust it returning nothing.
- Nothing in this phase is urgent enough to skip a verification. The release has waited for six phases; it can wait for a grep.
