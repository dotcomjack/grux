# Grux 3.0 Phase F: the first thing a stranger sees

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grux opens as one centred question, "What do you want to do with Grux?", and the answer drives an onboarding that sets up what that person actually needs, with no permission prompt they did not ask for.

**Architecture:** `Sources/Grux/Onboarding/` already holds a tier wizard, a 39-row feature registry, a capability resolver and a setup-card system, all built and shipped. Phase F does not replace that machinery; it replaces the **entry** to it. One prompt, whose answer selects a feature set out of the registry that already knows what each feature needs. The tier wizard becomes the fallback for someone who would rather pick from a list, not the front door.

**Tech Stack:** Swift, SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md` section 9. Ledger: row P-F-1 and gate G-F.

## Global Constraints

- Build worktree, branch `main`. Test floor 2653, 0 failures.
- No em dashes and no en dashes. Dollar amounts as numerals with the symbol.
- **No permission is requested until the feature needing it is being set up, and the screen says what it is for first.** macOS TCC grants are keyed to the signing identity and a refused prompt is expensive to recover, so a prompt fired speculatively costs the person a trip to System Settings.
- Nothing ships off and undiscoverable: named at first run, a permanent Settings home, its off state explained. **First run is where the first of those three is satisfied**, so a feature missing from this flow fails the lock no matter how good its Settings page is.
- Design tokens unchanged.

## Depends on

- Phase C: the Developer and Labs doors exist and the rail is computed, so "I write code" has something to unlock.
- Phase E: Tuning exists to be named.
- The existing `FeatureRegistry` (39 rows), `CapabilityResolver` and `CapabilitySetupCard`. **Read them before writing anything.** They already answer what each feature needs and whether it is satisfied; re-deriving that in the onboarding flow is how two sources of truth appear.

---

## P-F-1: First run

### Task F1: One centred prompt

**Files:**
- Create: `Sources/Grux/Onboarding/FirstPromptView.swift`
- Modify: `Sources/Grux/LaunchRootView.swift` (the first-run gate already lives here)
- Test: `Tests/GruxTests/FirstPromptTests.swift`

A full-window, centred question, on the palette, with a text field and a microphone. Nothing else on the screen. No rail, no orb chrome, no tier grid.

- [ ] **Step 1: Write the failing test.** Assert the first-run screen presents exactly one question and no feature grid, driven by whatever model the view reads; if the view reads no model, create one first, because a screen whose content is inline cannot be tested.
- [ ] **Step 2 to 6** as the standard shape.
- [ ] Listening is **named on this first screen with its off state explained**, which is the section 9 requirement and a Definition of Done item. Reuse `ListeningSection.copy`, which already says what it takes and how to stop it. Do not write second copy for the same feature.

### Task F2: The answer selects a feature set

**Files:**
- Create: `Sources/Grux/Onboarding/IntentToFeatures.swift`
- Test: `Tests/GruxTests/IntentToFeaturesTests.swift`

**Interfaces:** `IntentToFeatures.select(answer:) async -> [String]`, returning feature ids from the registry.

This is a judgment over a free-text answer against 39 known capabilities, which is precisely a typed decision. **How it is asked depends on the backend call-shape decision**, so write the seam now and the call when that lands: the function takes a `DecisionEngine` and a threshold exactly as `ChatIntentClassifier.confirmPIMRoute` does.

- [ ] **The on-device path must produce a sensible set with no key**, because a stranger on a clean Mac has no key. Keyword overlap against the registry labels, plus a floor set (Chat, Mail, Calendar, Notes, Tasks) that everyone gets. Test the keyless path first and hardest: it is the one every new person hits.
- [ ] Test that no answer, however odd, selects zero features. An onboarding that concludes "nothing for you" is a bug.
- [ ] Test that "I write code" and its obvious variants unlock the Developer door, which is the section 3 requirement.

### Task F3: Setup, in an order with real logic

**Files:** `Sources/Grux/Onboarding/*`.

The decision record asks for the ordering and ADHD mode to have real logic rather than a fixed list. The rule:

1. Everything that needs nothing is already done; show it as done rather than asking.
2. Then what is needed by the most selected features, so one grant unlocks the most.
3. Then what is cheapest for the person (a toggle before a paste, a paste before an OAuth, an OAuth before a system permission).
4. Anything optional is offered once, at the end, as a list they can skip whole.

- [ ] Test the ordering as a pure function over a fixture selection. Red-prove by shuffling the rules and asserting the order changes.
- [ ] ADHD mode: one thing on screen at a time, no more than one decision per screen, and the count of what remains always visible. Test that no screen in the flow presents more than one decision when it is on.

### Task F4: Name the palette, the doors and Tuning

The command palette, the Developer door, the Labs door and Tuning are each named once during the flow. A test asserts all four appear in the flow's copy, because "named at first run" is the part of the discoverability lock that is easiest to let rot silently.

### Task F5: The flow is testable outside a first run

First run happens once per machine, which is why it has historically been hard to verify here. Add a reset path (a `~/.grux/fire-first-run-reset` trigger beside the others) so the flow can be walked repeatedly on a real install, and so the gate below can be run more than once.

---

## G-F: the phase gate

This gate is **a stranger run on a clean macOS VM**, not a test suite. It is the Definition of Done item that cannot be faked.

1. Clean VM, no keys, no grants, a person who has never seen Grux.
2. **At most 14 rail rows.** State the number counted from the screenshot, not from the model.
3. **No per-row BETA pill anywhere.**
4. **Listening named on the first screen with its off state explained.** Quote the copy.
5. **"Open my calendar" spoken with no wake word, acting in under 1 second.** State the measured time and the ledger row that recorded it. On device, with no key, this is the on-device provider answering, so this figure is the keyless one; record the Jev figure separately if a key is added.
6. No permission prompt appeared that the person did not ask for. List every prompt that did appear and what asked for it.
7. A journal of the run plus screenshots. The design says "screenshot plus journal, not a test", and that is because everything wrong with a first run is a thing a test cannot feel.

## Notes for whoever executes this

- The machinery already exists. If you are writing a capability resolver, stop: there is one, it is tested, and a second one is a bug.
- The keyless path is the default path. Build and test it first, then let a key make it better.
- Every prompt that fires without being asked for is a gate failure, not a rough edge.
