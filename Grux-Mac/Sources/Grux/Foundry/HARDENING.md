# Grux autonomous-engine hardening

Defense-in-depth against the 2026-06-16 incident: a swarm worker
(`claude --permission-mode bypassPermissions` subprocess) wrote feature files
directly into the LIVE Grux source tree, broke the build, and Foundry's
auto-relaunch crash-looped.

## The five rails (all fail-safe)

1. **Swarm worker confinement** (`SwarmWorker.swift`). Every worker is wrapped in
   `/usr/bin/sandbox-exec` with an allow-default SBPL profile that denies
   `file-write*` to the three LIVE Grux code trees, then carves the worker's own
   assigned root (`spec.cwd`) and the temp dir back in (SBPL is last-match-wins).
   Reads stay open; only writes to the protected trees are blocked. If
   `sandbox-exec` is missing the worker spawns unconfined with a logged warning.

2. **Foundry green-land gate** (`GruxUpdater.selfInstall` + `verifyBuildsGreen`,
   driven off-main by `FoundryEngine.install`). Before any archive, `.landed`
   transition, or detached install spawn, the worktree must build green
   (`swift build -c release`) right now. A red tree is refused and left
   untouched; nothing overwrites the live `/Applications` build.

3. **Crash-loop breaker** (`GruxUpdater.activate` + `tripAutoLandPause`). After
   `breakerCrashThreshold` consecutive crash-at-launch events inside the
   crash-loop window, the last-good build is restored AND a persisted
   `auto-land-paused.json` flag is set. The governor honors the flag
   (`FoundryGovernor.tick` / `triggerManual`) and `selfInstall` refuses while it
   is set. A kept build resets the consecutive-crash run. Clear with
   `GruxUpdater.shared.clearAutoLandPause()` (a Self-Upgrade tab control or CLI
   trigger should call this; until wired, delete
   `foundry/updater/auto-land-paused.json`).

4. **Live-tree tripwire** (`LiveTreeTripwire.swift`, booted from `GruxApp`).
   At launch and every 5 minutes, runs `git status --porcelain` over the live
   build worktree and DETECTS untracked files under `Sources/`: it logs an alert
   and posts a notification. It moves nothing and deletes nothing. This document
   and the file's own header both used to claim it MOVES strays, which the code
   has not done since auto-quarantining ate a file mid-commit; the suggested
   destination is `~/.grux/quarantine/` and moving there is a human's call.

   The worktree path is read from `~/.grux/live-worktree.txt` and has no
   default, so on any machine that has not opted in the subsystem is inert. It
   used to be hardcoded to one person's layout, which both shipped that layout
   inside a public binary and left every other machine sweeping a path that
   could never exist.

5. **In-app FS denylist** (`FilesystemTool.swift`). The live build worktree
   roots are in `denylistSubstrings`, so no in-app Claude tool can address them.

## Org-wide pre-push build-green gate (manual install per repo)

`tools/pre-push-build-green.sh` refuses a push if the project does not build.
Install it as a `pre-push` hook in each LIVE production tree:

```bash
cp tools/pre-push-build-green.sh <repo>/tools/pre-push-build-green.sh
chmod +x <repo>/tools/pre-push-build-green.sh
ln -sf ../../tools/pre-push-build-green.sh <repo>/.git/hooks/pre-push
```

Which repos should carry it is per install, so no list is compiled in here: this
file ships to everyone, and one person's repo layout is not documentation for
anybody else. The test is the same everywhere. Install it in every tree where a
push reaches real users, meaning the branch that deploys, and leave it off
scratch clones and forks where a red build costs nothing.

Bypass for an emergency push with `GRUX_SKIP_BUILD_GATE=1 git push` (sparingly).
