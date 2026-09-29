# Grux 3.0 Phase E: Tuning, and Labs rethought

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One surface where a person tunes everything Grux does for them, organised by what Grux does rather than by subsystem, and a Labs door that reads as one considered cluster rather than seven loose experiments.

**Architecture:** Tuning is a new surface (`Sources/Grux/Tuning/`) that owns the execute threshold and every user-tunable behaviour. It does not own the switches: a switch that turns a feature on or off stays in Settings, because Settings is the permanent home the never-ship-it-hidden lock requires. Tuning owns the dials, Settings owns the doors, and the difference is that a dial has no off position.

**Tech Stack:** Swift, SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md` section 8 and the Labs row of the section 3 table. Ledger: rows P-E-1 to P-E-3 and gate G-E.

---

## THIS PHASE IS GATED ON A HUMAN, AND THAT IS THE POINT

**P-E-1 is "visuals FIRST, accepted before any code."** The decision record says the shape of Tuning is decided from visuals rather than argued from a spec, and the phase gate says visuals accepted before code. So the order here is not negotiable and no lane may claim P-E-2 until P-E-1 is marked DONE with the accepted visual's path in its Evidence cell.

**What an agent can do without the human:** produce the visuals. That is Task E1, and it is real work, not a checklist item handed over.

**What only the operator's principal can do:** accept one. Batch that ask: present all Tuning options and all Labs options in a single pass, say up front how many decisions are coming, and do not trickle them out one at a time.

---

## P-E-1: The Tuning visuals

### Task E1: Produce three 1:1 visuals of Tuning

**Files:**
- Create: `docs/superpowers/visuals/tuning-a.png`, `tuning-b.png`, `tuning-c.png` and `docs/superpowers/visuals/README.md`

**1:1 means 1:1.** Rendered at the real window size the app runs at, in the real palette, with the real type stack and the real content. Not a wireframe, not a sketch at an arbitrary canvas size. A visual accepted at the wrong scale is a decision made about a thing that does not exist; the sweep harness already proved in this repo that a capture is not self describing.

**What must be on every one of the three:**

| Dial | Today's home | Range |
|---|---|---|
| Execute threshold | `config.listeningThreshold`, default 0.70 | How sure Grux has to be before it acts instead of asking |
| Follow-up window | `VoiceCommandRouter.followUpWindow`, 45s | How long after Grux speaks your next sentence is assumed to be a reply |
| Daily decision budget | packet P-A10-3 | What Grux is allowed to spend before falling back to on device |
| Interruption appetite | `AmbientCoach` | How willing Grux is to speak up while you are working |
| Approval appetite | `HandsFreePolicy` | Which reversible things happen on the spot |
| Mail needs-you sensitivity | the needs-you score | How much reaches the count in the rail |
| Compaction aggressiveness | `CompactionPolicy` | How early a long thread gets summarised |

**Three genuinely different shapes, not three skins of one:**

- **A, the mixing desk.** Every dial visible at once, grouped by what Grux does. Everything in one glance, and it is dense.
- **B, one question at a time.** Each dial is a plain-language question with the current answer under it. Reads like a person talking, and it is taller.
- **C, the behaviour cards.** One card per thing Grux does ("Acts on what I say", "Interrupts me", "Spends money"), each opening to its dials. Best map to the "organised by what Grux does" requirement, and it hides detail one level down.

- [ ] **Step 1: Read `reference/design-tokens.md` and the running app.** Tokens are fixed for 3.0. A visual proposing a new token is proposing a change that is out of scope.
- [ ] **Step 2: Render all three at the real window size.**
- [ ] **Step 3: Put all three in one message with a one-line honest trade-off each.** No recommendation dressed as a description: say which one you would pick and why, in one sentence.
- [ ] **Step 4: Wait.** Do not write a line of `Tuning/` until one is accepted.
- [ ] **Step 5: Record the acceptance** in the ledger row with the accepted file's path.

### Task E2: Produce two visuals of the Labs door

Same rules. Labs holds eight surfaces (`reactor`, `jax.hq`, `jax.command`, `cognition.map`, `feature.review`, `self.upgrade`, `phone`, and the `roadmap` key). One badge at the door, never per row.

- **A, the shelf.** Eight cards with one line each on what it is for.
- **B, the changelog.** A list ordered by what changed most recently, so Labs reads as a place things arrive rather than a cupboard.

Batch these with Task E1's three, so it is one decision sitting rather than two.

---

## P-E-2: Build Tuning from the accepted visual

### Task E3 onward: one task per dial

**Files:** `Sources/Grux/Tuning/` (new), `Sources/Grux/SettingsView.swift` (the dials leave Settings), `Sources/Grux/Models.swift` (`GruxConfig` keys).

Every dial follows the same five beats and each is its own commit:

1. The config key exists with a `CodingKey`, an init default, and a `decodeIfPresent ?? default` so an existing install decodes cleanly. **This is not optional.** A new key without the decode fallback is a setting that silently resets for every person who already had Grux.
2. A test asserts the default and the decode fallback, exactly as `MicConsentTests.testBothListeningFeaturesShipOff` does for listening.
3. The dial renders from the accepted visual.
4. Changing it takes effect without a relaunch, or the surface says it takes effect on next launch. Never neither.
5. Its range is bounded so no value can make Grux unusable: a threshold of 0 acts on everything it hears, and a person must not be able to set that by dragging.

- [ ] A test asserts every dial's bounds and that the shipped default sits inside them.

### Task E-last: Tuning is discoverable

Named at first run (Phase F), a permanent home in the rail or behind Settings, and each dial explains what moving it costs. The three-part lock applies to Tuning itself, not only to the features it tunes.

---

## P-E-3: Labs rethought from its accepted visual

### Task E-labs: the door, the badge, and the eight surfaces

**Files:** `Sources/Grux/Labs/` (new or renamed), `DesignSystem/SidebarModel.swift`.

- One badge at the door. Phase B removed the per-row pills and Phase C built the door; this task is what goes behind it.
- Every one of the eight keeps its locked tab key working, same trap as the Phase C folds: `--open-tab=` falls back to `chat` silently on an unknown key.
- Labs says what Labs means, once, at the door. "Experimental" with no explanation is a pill, not an explanation.

---

## G-E: the phase gate

1. **The accepted visual's path is in the P-E-1 Evidence cell**, and the built surface matches it. This gate fails if code landed before acceptance, whatever the code looks like.
2. Every task checked, committed and pushed.
3. `swift build` exit 0. `swift test` exit 0, count at or above 2653, 0 failures.
4. Every new config key proven to decode from a config that predates it.
5. Every test introduced red-proven, planted failure named, restore proven byte-identical.
6. A sweep of Tuning and of the Labs door, running pid start equal to the installed binary mtime.

## Notes for whoever executes this

- Tuning owns dials, Settings owns doors. If you are about to put an on-off switch in Tuning, it belongs in Settings, and the reason is the discoverability lock rather than taste.
- Do not start E2 to save time while waiting for acceptance. The gate checks the order, and a surface built before its shape was chosen is the thing this phase exists to prevent.
- The visuals are work an agent can do. Producing them is not "handing over a checklist"; the checklist would be asking someone to imagine three layouts.
