# Local decisions: retiring the Decisions key

> **STATUS: ACTIVE, NOT STARTED.** Post-3.0. Decision record:
> `questionnaires/_decisions/grux-local-decisions-laya.md`. Nothing here ships
> until the bar in Phase 3 is met on the fixtures in Phase 0.

**Goal:** Grux decides as well as it does today with no key, no account and no
network, so the Decisions key can be deleted from the product rather than
merely made optional.

**Why it is not done already:** measured 2026-09-22, Laya out of the box reads
10 of 20 room-talk lines as commands (Jev: 3) and has zero recall on the
first-run selector at the shipped threshold. It is 9x faster than Jev and free.
The gap is fine-tuning and packaging, not the idea.

## Phase 0: the bar, frozen first

The two fixtures already exist and both are cheap to run:

- `Tests/GruxTests/VoiceGateFixtureTests.swift`, 26 lines, the hot path. The
  property is absolute: **with nobody addressing it, Grux must not act.**
- `docs/superpowers/evidence/2026-09-22-laya/` holds the 36-utterance voice
  comparison and the 54-answer selector comparison, with Jev's numbers as the
  incumbent column.

**The bar, in one line: a candidate ships when it false-fires no more than Jev
(3 of 20) AND reaches Jev's selector recall at equal precision, held out.**
Add a third fixture before starting: 200 utterances, labelled, half room talk,
because 36 is enough to reject and not enough to accept.

**Calibration is part of the bar, not a detail.** Every gate in Grux is a
threshold. Jev's 0.8 to 1.0 bucket was 88% true on held-out rows; a candidate
whose confidence does not mean what it says cannot drive an execute bar, and
Laya's own library warns that some of its buckets are uncalibrated.

## Phase 1: the data rule, decided before any training

Grux's decision ledger is the obvious training set and it is the operator's
real speech. **Weights trained on it must never ship.** Two paths, and the
choice belongs to the operator:

1. **Synthetic and public only.** Generate states from the app's own gates and
   vocabulary, label with Jev (which already answers these well), hold out a
   human-checked set. Ships.
2. **A personal adapter.** Train on the machine, from that machine's ledger,
   never leaves it. Better for that person, ships nothing.

Path 1 is the product. Path 2 is a later refinement and should not block it.

## Phase 2: the runtime, which is the real engineering

Laya is a Python SDK: 922 MB of environment plus 2.33 GB of weights, with no
server mode. Grux is a signed Swift app. Three options, in the order they
should be tried:

1. **Convert to Core ML.** ModernBERT-large and mmBERT are ordinary encoders;
   quantised, one checkpoint is roughly 200 to 400 MB and runs on the Neural
   Engine with no Python at all. This is the only option that keeps Grux a
   single signed app, and it is the one to try first.
2. **A sidecar the person already runs**, the Ollama pattern: Grux points at a
   local endpoint and never spawns anything. Honest, no orphaned processes
   (`PhoneTunnelInertTests` exists because a spawned child leaked 30 times),
   but it asks a stranger to install Python.
3. **Spawn a bundled Python.** Rejected unless 1 and 2 both fail: it is the
   spawn-and-reap problem this repo deliberately removed once already.

There is a fourth path worth measuring before any of this: **the local LLM the
person already has.** Grux runs Ollama for chat, and a constrained-JSON call to
that model needs NO new dependency. Measured expectation is 1 to 3 seconds,
which is too slow for the voice gate and perfectly fine for the once-per-install
selector, so it may retire the key for the selector alone at almost no cost.

## Phase 3: the switch, one gate at a time

Never a flag day. In order, each with the fixtures re-run and the numbers
written down:

1. The first-run selector (once per install, slowest tolerance, biggest win for
   a keyless stranger).
2. The approval-risk and PIM gates (batched, not on the hot path).
3. The voice gate (hot path, and the one with the safety property).

The Decisions key stays offered until step 3 passes. When it does, it becomes
what the Anthropic key is today: a thing you may add, not a thing Grux needs.

## What must not happen

- No new AI vendor. Laya is Apache 2.0 and local; that is the whole point.
- No training on the operator's ledger in anything that ships.
- No "it feels better" merge. The bar is two fixtures and a calibration curve,
  and a candidate that cannot beat them is not ready, however fast it is.
