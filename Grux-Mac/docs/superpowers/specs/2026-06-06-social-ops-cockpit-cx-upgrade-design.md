# Social Ops Cockpit, CX upgrade design

Status: APPROVED 2026-06-06 (the owner: "build all of it"). Builds on the shipped cockpit.

## Goal

Make the cockpit safe and pleasant to operate: two-tap confirmed actions, real
feedback, and the context to act, on both the Mac Empire grid and the GruxPhone
Ops tab. Improve CX for a low-mobility operator (misfire-proof, legible, fast).

## Scope (all approved)

### 1. Two-tap arm-in-place (core)
Every state-changing action is two taps with changed text, identical on Mac + phone.
- Tap 1 arms the same button: label swaps, button recolors amber, ~4s auto-disarm.
- Tap 2 within the window executes. Arming a different action, or the timer
  expiring, disarms back to the resting label.
- Text map (resting -> armed):
  - Mute -> "Tap again to mute"; Unmute -> "Tap again to unmute"
  - Re-auth -> "Confirm re-auth"; Retry -> "Confirm retry"; Approve -> "Confirm approve"
- Only ONE action is armed at a time per cell.

### 2. In-flight + result feedback
- On tap 2: button shows "working..." and is disabled; the cell shows a subtle busy state.
- On completion: a brief inline toast/line reports the outcome
  ("muted", "retry sent", "re-auth: 2FA needed", "command failed: ...").
- Mechanism: reuse the existing-but-unused `socialOpsAck(brand, platform, status,
  message, ts)` envelope. After `executePhoneAction` runs the Mini command, the
  Mac sends a `socialOpsAck` with the result; the phone shows the toast. On the
  Mac surface the toast is local (no wire needed).

### 3. Tap-for-detail
- Tapping a cell opens a detail view (sheet on phone, inline expander on Mac):
  brand, platform, status, full reason (lastError), lastPostResult, reachTrend,
  "checked <relative>", and the contextual actions for that cell.
- The grid pill itself no longer needs to expand a raw action row inline; actions
  live in the detail view (cleaner grid). The Mac may keep an inline expander.

### 4. Freshness + Sweep now
- Per-cell "checked Xm ago" derived from lastChecked.
- Header: counts of green / amber / red (and muted) plus the snapshot freshness.
- "Sweep now" button: triggers a live re-check on demand.
  - Mac: calls `SocialOpsService.triggerSweep()` (POST /api/social-ops/sweep).
  - Phone: routes phone -> Mac -> Mini as a NEW `sweep` value on the existing
    `socialOpsAction` envelope (brand/platform may be empty); `executePhoneAction`
    maps action=="sweep" to `triggerSweep()` then re-pushes the grid. No new
    envelope type.

### 5. Haptics + polish
- Phone haptics: light impact on arm, success notification on confirm-complete,
  error notification on failure. (UIImpactFeedbackGenerator / UINotificationFeedbackGenerator.)
- Tight house styling, a small status legend (green=healthy, amber=degraded,
  red=down, grey=muted). No em/en dashes anywhere.

### 6. Audit additions
- Contextual actions: show only what applies to the cell state.
  - logged out / session invalid -> Re-auth (+ Mute)
  - 2FA challenge -> Re-auth (+ Mute)
  - last post failed -> Retry (+ Mute)
  - pending approval gate -> Approve (+ Mute)
  - muted -> Unmute
  - healthy -> Mute only (and a disabled "all good")
- Persistent last-action result on the cell: store the most recent action outcome
  per cell (in the store / view model) and render it small under the pill
  ("muted 1m ago", "re-auth: 2FA needed") so it survives the transient toast.
- Comfortable tap targets: bigger hit areas than the current pills (min ~40pt
  height on phone) since two-tap-arm prevents misfires; still house-lean.
- "Needs session" CTA: for red login-frontier cells (lastError contains "login
  wall" / "logged out"), a one-line hint "needs a logged-in session" in the
  detail view, pointing at the session-import path rather than just a red pill.

## Files

- `Sources/Grux/SocialOps/SocialOpsModels.swift` (+ iOS copy): add `case sweep`
  to `SocialOpAction`. Keep the two copies byte-identical.
- `Sources/Grux/SocialOps/SocialOpsSection.swift` (Mac): arm-in-place state,
  in-flight, detail expander, freshness, counts, Sweep now, contextual actions,
  last-action result, legend.
- `Sources/Grux/SocialOps/SocialOpsStore.swift` (Mac): track per-cell last-action
  result; expose a `sweep()` passthrough; record command outcomes.
- `Sources/Grux/SocialOps/SocialOpsCoordinator.swift` (Mac): `executePhoneAction`
  handles action=="sweep" (triggerSweep) and sends a `socialOpsAck` with the
  result after any phone action.
- `Sources/Grux/iPhone/PhoneReceiverService.swift` (Mac): `notifySocialOpsAck(...)`.
- `GruxPhone/GruxPhone/SocialOpsCockpitView.swift`: arm-in-place, in-flight,
  detail sheet, freshness, counts, Sweep now, haptics, contextual actions,
  last-action result, legend.
- `GruxPhone/GruxPhone/ChatStore.swift`: ingest `socialOpsAck` -> publish a
  transient toast + persist per-cell last-action result.
- `GruxPhone/GruxPhone/PhoneChatEnvelope.swift`: no new case (socialOpsAck and
  socialOpsAction already exist); only the shared `SocialOpAction.sweep` value
  is added via the models copy.

## Testing / verification

- Mac `swift build` clean; iOS `xcodebuild` BUILD SUCCEEDED.
- Two-tap: a single tap never executes; second tap does; auto-disarm after 4s;
  arming a second action disarms the first.
- Sweep now from the phone triggers a Mini sweep and the grid refreshes.
- Ack toast shows the real outcome (mute on a live cell; re-auth showing the 2FA
  wall).
- Install to device, verify on-device with the live grid.

## Out of scope

- The headless-login-to-green frontier (separate session-import work).
- Any Mini service behavior change beyond what already exists (sweep endpoint,
  record fields, command executor are reused as-is).
