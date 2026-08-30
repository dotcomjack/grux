# Prototypes

Interactive prototypes of flows that are not written yet. Open one in a browser. There is
no build step, no server and no dependency: every file here is a single self contained
HTML document that works from a double click.

```
cli-onboarding.html   grux setup, the 1.2 terminal onboarding flow
extract-registry.py   lifts the real capability data out of Sources/Grux into it
```

## Why these exist

A flow argued about in prose gets agreed to and then built wrong, because the disagreement
was never visible. A flow drawn as mockups gets agreed to and then built wrong for a
subtler reason: a mockup cannot be wrong. It has no arithmetic to check.

`cli-onboarding.html` has arithmetic, and the arithmetic is the product claim. The claim is
"a permission is only ever requested because a feature you picked needs it", and that is
either true of a given selection or it is not. So the prototype is driven by the app's own
`FeatureRegistry` and `SetupContract`, parsed out of the Swift by `extract-registry.py`,
and it ships a self test that asserts the claim rather than illustrating it.

## Run the checks

```sh
python3 prototypes/extract-registry.py           # re-embed after a Swift change
python3 prototypes/extract-registry.py --check   # exit 1 if the embedded data has drifted
```

### Measuring a branch before merging it

The prototype's numbers are the app's numbers, so a branch that edits `FeatureRegistry.swift`
moves them. `--src` and `--out` answer "by how much" without editing the committed file:

```sh
mkdir -p /tmp/w2 && git archive <ref> Grux-Mac/Sources/Grux | tar -x -C /tmp/w2
python3 prototypes/extract-registry.py --src /tmp/w2/Grux-Mac/Sources/Grux --check
python3 prototypes/extract-registry.py --src /tmp/w2/Grux-Mac/Sources/Grux \
        --out /tmp/w2/preview.html      # a second copy, side by side, both self testable
```

Measured 2026-08-28 against `audit/wave-2`, 32 commits ahead of `main`: same 43
capabilities, same 39 features, same 25/14 split, same permission order. **One row changed.**
`chat` gains an `anyOf` group, so it needs an Anthropic key OR a local model rather than
both, and `endpoint.ollama` moves out of `optional` into that group.

That one row is worth the whole exercise, because reading `requires` alone after the merge
would tell somebody they need two credentials to open Chat when they need one. Over-asking
is precisely what this flow exists to stop, so `derived()` models the groups and `selfTest`
asserts that nothing inside one is ever reported as individually required.

**The parser failure that got there first is the more useful lesson.** Its first version
required a row to end at `optionalSteps: [...])`, so every row carrying the new `anyOf`
argument silently failed to match and was dropped. The parse came back with 38 features and
reported that wave-2 had deleted Chat, which is the app's default landing tab. A parser that
drops what it does not understand returns a clean looking wrong answer, so the extractor now
counts `FeatureRow(id:` declarations independently and refuses to write a partial registry.

In the page's console:

```js
__grux.selfTest()        // 11 assertions over the flow and its arithmetic
__grux.state()           // where the flow is, and everything chosen so far
__grux.derived()         // blocking, degrading and never-asked, for the current selection
__grux.drive(['2','enter','enter'])   // walk it without touching the keyboard
```

`selfTest` restores whatever was on screen when it started, so it is safe to run mid demo.

## Every assertion is green, and one of them took a contract change

`every capability is claimed by a feature or a blueprint` was RED from the day it was
written. It is green as of 2026-08-28, and getting it there is the worked example of what
this harness is for.

It first reported TEN unclaimed ids. Eight of those were wrong: a blueprint declares
capabilities in its own right, so `pr-digest` needs a GitHub token and a repo list while
the generic `schedules` feature hosting it needs neither. Reading only `FeatureRegistry`
called eight live capabilities dead, which is a worse failure than missing two because it
is the kind of finding somebody acts on. The extractor now parses the
`## Capabilities required` table of every blueprint, and the assertion reports
`claimedOnlyByBlueprint` separately so the distinction stays visible rather than collapsing
into a pass.

The remaining two were real. `key.openai` and `key.openrouter` described a shape the code
does not have: `CustomEndpointStore` holds one key per user-added endpoint under its own
Keychain account, not two scalar slots on the app, and CR-31 had already removed both from
`chat`. CR-34 deleted them from contract section 1.1 on 2026-08-28. The contract now
carries 41 ids.

`scripts/check-contract.py` had reported clean throughout, and the reason is worth keeping.
It counts usage only from lines beginning with a pipe, so prose never counted. What kept
those two looking used was the section 7 RESOLUTION TABLE row that still read "Declared by
`chat` (optional)" after CR-31 had reversed exactly that. **A table documenting a
capability's history is indistinguishable from a table declaring it.** The orphan rule
itself works: planting `key.planted` into contract 1.1 produced
`[orphan-capability] key.planted is declared by zero features`. CR-34 works around it the
way the analytics deletion did, by naming a deleted id in prose rather than as an id.

## Rules for a new prototype here

1. **Real data or no data.** If a screen shows a count, a list or a consequence, it comes
   out of the source of truth through a script like `extract-registry.py`, with a `--check`
   mode. A prototype that quietly disagrees with the app teaches the wrong flow to everyone
   who reviews it.
2. **One input path.** The keyboard and the driver both go through the same `send()`. Two
   code paths means the scripted walk proves something no human will ever do.
3. **Assertions, not screenshots.** Ship a `selfTest()`. A screenshot proves a frame was
   drawn; it cannot prove the number in it was right.
4. **The six beats.** LOOK, CHOOSE, COST, GRANT, HAND OFF, PROVE, in that order, on the
   rail at the top. See `docs/cli-grammar.md`.
