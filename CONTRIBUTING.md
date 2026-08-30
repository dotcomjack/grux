# Contributing to Grux

Pull requests are welcome. This document is short on purpose, but the rules below
are enforced by tests rather than by review, so reading it first will save you a
round trip.

## Getting set up

```sh
git clone https://github.com/dotcomjack/grux.git
cd grux/Grux-Mac
swift build
swift test
```

You need macOS 14 or later and the Swift 5.9 toolchain. `./build.sh` produces and
installs the actual app; see the README for signing.

**`swift build` does not compile the test target.** A green build tells you
nothing about the suite. Run `swift test` and read the `Executed N tests` line. No
such line means zero tests ran, which is a failure, not a pass.

## The four rules that are enforced mechanically

These fail CI, so it is cheaper to know them now.

### 1. The setup contract is frozen

`Grux-Mac/docs/` holds a contract describing every credential, permission,
endpoint and setup step the app can require, and `scripts/check-contract.py`
fails if any of it changes meaning.

This exists because onboarding used to promise things that were not true. It
asked for five credentials nothing ever read, and told users a feature was ready
when it was not. The contract makes a false promise a build failure.

To change what a feature requires, add a dated amendment to the change record
rather than editing an existing entry. `CR-29`, `CR-30` and `CR-31` are the
precedent to copy. An amendment needs to say what changed, and why the old entry
was wrong.

```sh
python3 Grux-Mac/scripts/check-contract.py
```

### 2. No em dashes or en dashes, anywhere

Not in copy, not in comments, not in commit messages. Use a comma, a period, a
colon, parentheses or a pipe. An ASCII hyphen is fine and is not what this
catches.

The guard scans by literal character across everything that ships. It exists
because the Mac sources were clean by habit while the iOS app carried thirty,
including two inside permission dialogs that users read before granting camera
and local network access.

### 3. No personal identity in shipping strings

No real names, home addresses, account identifiers, team identifiers or builder
paths. The scan covers the whole shipping tree, not a hand picked subset, and the
release extractor scans its own output again afterwards.

### 4. Every guard must be able to fail

If you add a check, add a test that plants the thing it detects and asserts it is
caught. This is not ceremony. A width assertion in this repo once passed against
an empty label, because empty text keeps its padding, so the guard was green and
blind at the same time. Expect your first assertion to be vacuous and go looking
for it.

The same applies to a guard with two directions. `PhoneDeclarationsMatchBehaviourTests`
does not assert that location keys are absent; it asserts the manifest agrees with
the code, in whichever direction the code goes, so wiring the feature up fixes the
test instead of deleting it.

## Working on the app

**Run the whole suite, not a filter.** The suite is full of deliberate tripwires
on exact counts and sets: the number of labs features, the number of registry
rows, the set of capabilities with an alternate source. When one fires, it is
asking you to write down a decision, not to update a number until it goes quiet.

**Do not edit Swift structure with regular expressions.** Use the compiler.

**Never end a change with the app unbuilt.** If you touched app code, build it.

## Pull requests

- One concern per pull request.
- Say what you verified and how. An exit code, a status code, a path or a quoted
  line of output beats "tested locally".
- If your change makes a guard fail, explain why the guard was wrong. Do not widen
  it to green.
- New dependencies need a reason. The tree currently has exactly one direct
  dependency and keeping that number small is deliberate.

Commit messages follow Conventional Commits (`feat(scope):`, `fix(scope):`,
`test(scope):`, `docs(scope):`). Check `git log` for the local flavour.

## Reporting bugs

Open an issue with your macOS version, whether you built from source or ran a
release, and what you expected. If it involves a permission or a credential, say
which one, and never paste the credential itself.

For anything exploitable, use [private reporting](.github/SECURITY.md) instead of
a public issue.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
