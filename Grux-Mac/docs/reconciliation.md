# Reconciliation

**Phase 2. The anti-drift mechanism.**

Two specifications were written in parallel against one contract. That is the fast way to
work and it is exactly how drift gets in: Track A adds a capability it needs, Track B reads
a config key it assumed, and neither notices until someone tries to build both. This turns
that into a red build on the day it happens instead of a discovery six weeks later.

`scripts/check-contract.py` parses `docs/contract.md` as the single source of truth and
checks every specification against it. No third-party dependencies, so CI needs no install
step.

```
python3 scripts/check-contract.py              # check, exit 1 on any finding
python3 scripts/check-contract.py --self-test  # prove the checker still fails correctly
```

## The rules

| Rule | Fails when | Why it is worth a red build |
|---|---|---|
| `unknown-capability` | A spec references a capability id absent from the vocabulary | The vocabulary is closed. An id that only exists in prose is a feature that will render an error instead of a setup card, which is the exact thing the state machine forbids. |
| `unknown-config-key` | A spec reads a config key absent from the namespace | A key with no owner has no default, no type, and no secret flag. It will be read as nil forever and nobody will know. |
| `no-remediation` | A vocabulary entry has an empty remediation string | Remediation text is the entire user experience of `needs-setup`. A capability without one degrades to a blank card. |
| `remediation-too-long` | Remediation exceeds 140 characters | It has to fit in a setup card without truncation. |
| `orphan-capability` | A capability is declared by zero features | Dead vocabulary rots. Either something should require it, or it should not exist. **Warning, not an error, until `docs/feature-registry.md` exists.** See below. |
| `duplicate-owner` | One config key is owned by two domains | Two owners means two defaults and two writers. |
| `secret-with-value` | A secret-flagged key appears with a literal value | This is the one rule that is a security control rather than a hygiene check. See below. |
| `dash` | An em dash or en dash appears in any doc | House rule, mechanically checkable, and far cheaper to catch on commit than in review. |

## The one rule that is a security control

`secret-with-value` is different in kind from the others. Contract section 2.4 says secrets
live only in Keychain and are enforced in four places: declared in the descriptor, refused
on read, refused on write, and checked in CI. **This script is that fourth place.**

The other three enforcement points live in code that does not exist yet. Until it does,
this is the only one that runs. It fails if a secret-flagged key appears with a literal
value in a blueprint, a sample config, or a committed fixture. Naming the key is fine and
necessary. Showing it with a value is how a plaintext credential gets committed by someone
following an example.

## Responding to a finding

**`unknown-capability` or `unknown-config-key`.** Do not add the id to the spec that
references it, and do not quietly delete the reference. One of two things is true: the
contract is incomplete, in which case amend `contract.md` first and re-run, or the spec
invented something, in which case fix the spec. The contract changes deliberately, never as
a side effect of unblocking a build.

**`orphan-capability`.** Usually means a feature that should declare it has not been
written yet, which is expected mid-project and is why it is a warning for now rather than a
failure. If nothing will ever require it, remove it from the vocabulary. Do not leave it.

**`dash`.** Replace with a comma, a colon, or a full stop. Never with a hyphen pretending
to be a dash.

## Contract change requests

Both tracks may raise these instead of inventing. A spec may contain a section headed
`Contract change requests`, and **everything after that heading is exempt from the
capability and config key rules**, because the whole point of raising a request is to name
something that does not exist yet. Everything before it is binding.

That exemption is deliberate and narrow, and **it is scoped to the SECTION, not to the rest
of the file.** An exempt section ends at the next heading of the same level or shallower,
and binding text resumes there.

That scoping was a bug once and is worth recording. The first version split the document at
the first matching heading and treated everything after it as exempt, which was harmless
while such a heading was always the last section. It stopped being harmless the moment a
"Recommended contract deletions" subsection appeared 62% of the way through the feature
registry: that single heading silently disabled the vocabulary rules for the remaining 431
lines, roughly 37% of the document, including an entire later section of resolved requests.
A plant test in that region passed when it should have failed, which is how it was found.
The self-test now carries a case asserting that binding text resumes after an exempt
subsection.

## Why orphan detection is a warning for now

The orphan rule assumes something enumerates every feature. Nothing does yet: contract
section 6 deliberately defers the feature registry to implementation, because enumerating
150 rows in a specification guarantees they go stale against the code.

So right now "declared by zero features" cannot be distinguished from "declared by a
feature nobody has written a spec for". `endpoint.imap` is used by the mail feature, which
is real and is simply not a blueprint. Failing the build on that would produce a
permanently red CI that everyone learns to ignore, which is worse than not checking.

It is therefore reported as a warning and **arms itself automatically**: the moment
`docs/feature-registry.md` exists, the same finding becomes an error. No one has to
remember to turn it on.

## Expected state during construction

The checker reports honestly rather than flattering the project. With both tracks landed
it reports:

```
contract: 28 capabilities, 46 config keys
specs:    18 files
7 warnings (not failing)
clean, no drift
```

Seven warnings are the truthful state of a vocabulary whose remaining entries belong to
features nobody has specced yet, and zero errors is a real result: two authors wrote 18
files against this contract without seeing each other's work and neither invented a
capability, a config key, or a secret shown with a value.

That green is only worth something because the checker proves it can still fail. That is
what `--self-test` is for: a check that never fails is decoration, so it plants an unknown
capability, an unknown key, an em dash, an en dash and four change-request heading shapes,
and confirms it catches every one before anyone trusts a clean run.

## CI

```yaml
# .github/workflows/contract.yml
name: Contract
on:
  push:
    branches: [main]
  pull_request:

jobs:
  reconcile:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Prove the checker works
        run: python3 scripts/check-contract.py --self-test
      - name: Reconcile specs against the contract
        run: python3 scripts/check-contract.py
```

The self-test runs first and on its own step. If the checker has been broken, that fails
loudly rather than producing a green reconcile that means nothing.

## What this does not check

Named so nobody mistakes a green run for more than it is.

It does not verify that a capability is resolved correctly at runtime, that a remediation
string is accurate, that a blueprint's prompt actually works, or that a config key is read
by the code that claims to own it. It is a consistency check between documents, not a
correctness check of a system. Every one of those gaps needs a test in the implementation,
and none of them should be assumed covered because this is green.
