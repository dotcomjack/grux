# Grux Social Ops Cockpit, design spec (internal-first)

Status: SPEC, not started. Paused on purpose. Sequenced AFTER the Tailscale mesh rebuild lands.
Created: 2026-06-05. Origin: questionnaire answers (grux-social-ops-architecture-questionnaire.html).

## Decision: build this INSIDE the Grux app, not as a Telegram bot

The owner flagged the pivot ("we might want to take this spec into the Grux app, keeps everything internal, ATTENTION TO THIS THOUGHT"). The recommendation is yes, go internal. Those same requirements rule Telegram out as the primary surface:

- "Everything must be dynamic, live and breathing, no stale data." A Telegram message is a static snapshot at send time. Staying live means re-sending images on a loop. A native GruxPhone panel over the wire redraws as state changes, genuinely live.
- "Buttons direct Grux to handle the instruction via Mini, true operator controls." That is the GruxPhone to Mac to Mini path already shipped for one-tap post approval. Reuse it natively.
- "Keeps everything internal." A credentials vault, account-down intel, and remote operator commands should not flow through a third-party bot token.

Telegram drops to an OPTIONAL dumb-fallback alert only, used if GruxPhone is ever off the mesh. Native push (APNs / local notifications, already wired) is the primary alert channel.

This is why sequencing AFTER the Tailscale mesh is correct: the mesh is what makes "live and breathing, no stale data" reliable (stable MagicDNS, no rotating tunnel, no re-pair). The cockpit depends on that link.

## Locked answers (from the owner)

- Surface: internal Grux app (Mac + GruxPhone), Telegram optional fallback only.
- Posting transport: browser automation, no official platform APIs (no approval flows).
- Priority platforms: Threads, Instagram, TikTok, LinkedIn (in roughly that order).
- Architecture for multi-brand without switching: UNDECIDED, needs research (see open questions). The owner was skeptical that one Chrome profile per brand is worth the noise.
- Health detection: periodic sweep PLUS instant on-failure. Down states to watch: logged out, session expired / needs re-auth, post failed, rate limited / throttled, 2FA or security challenge, shadowban or sudden reach drop, account not switchable, plus anything else sensible.
- Alerts: instant on down, once-daily health digest, weekly trend summary.
- Dashboard: live and dynamic, never static. Image view, tap-back operator buttons, and a deep link, all reflecting live state.
- Two-way control: full. Status, retry, re-auth, mute, approve, all from the phone, each routed Grux to Mini.
- Credentials: build a Grux-worldwide credentials vault, social account info is one branch. You provide the logins once, the Mini handles prompt re-sign-in when an account times out or is logged out.
- Sequencing: after the Tailscale mesh. Possibly pause entirely until then.

## Components

1. Grux Credentials Vault (foundation, worldwide)
   - A single secure store for all Grux ecosystem credentials, with social accounts as one branch (others: API keys, service logins, etc.).
   - Backed by the macOS Keychain on the Mini (and Mac), never plaintext on disk, never in markdown. Access scoped to Grux processes.
   - Mini-side auto-re-login: when the health monitor sees an account logged out or session expired, the Mini pulls the credential from the vault and drives the browser sign-in (including the 2FA step, method TBD per account), then resumes posting. You provide the login once.

2. Account Health Monitor (Mini-side)
   - Periodic sweep (interval TBD, see open questions) plus instant on-failure hooks from the posting path.
   - Per brand, per platform health record: logged-in, session-valid, last-post-result, rate-limit state, 2FA-challenge, switchable, reach-trend. Stored as live state, not snapshots.
   - Emits events on state change, which drive both alerts and the live cockpit.

3. Live Social Ops Cockpit (GruxPhone, native)
   - Real-time brand-by-platform status grid (green / amber / red), updating over the wire, no stale data.
   - Two-tap operator controls per cell: retry post, re-auth / re-login, mute, approve. Each tap routes phone to Mac to Mini and executes, then the grid reflects the new state live.
   - Mirror panel on the Mac Grux app (Empire Dashboard area).

4. Alerting
   - Primary: native push (APNs / local notification) on down events, instant.
   - Daily health digest and weekly trend summary as native cards.
   - Optional Telegram fallback for pure down-alerts only, used when the phone is off the mesh.

## Open research questions (the owner asked for more thought here)

- Multi-brand posting without the switching bottleneck. Options to research and benchmark:
  - Harden the single Chrome profile + in-app switching (verify-after-switch guard already exists, the wrong_account refusal). Serial, UI-fragile, lowest cost.
  - One Chrome profile per brand. No switching, parallel, but more RAM and each needs its own logged-in session. The owner worried this is "added noise," consistency unproven. Needs a real test on the Mini (RAM headroom, session stability).
  - Decide empirically: stand up 2 to 3 per-brand profiles, measure RAM and reliability vs the single-profile switch over a week.
- 2FA handling per account: SMS, authenticator app, or email, and how the Mini reads the code for auto-re-login (the existing pattern reads codes from the open mail tab via Chrome).
- Rate-limit and shadowban detection heuristics (reach-drop thresholds) without official APIs.

## Sequencing

1. Tailscale mesh rebuild (feat-tailscale-mesh in the expansion map) lands first. It is the reliable live link this cockpit needs.
2. Then: credentials vault, health monitor, live cockpit, two-way controls, in that order.

When you greenlight the build, fold this into the Grux expansion map as a proper sequenced task (candidate id suggestion: feat-social-ops-cockpit, category Empire, depends on feat-tailscale-mesh).
