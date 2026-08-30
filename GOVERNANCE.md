# Governance

Grux is maintained by one person. This document says so plainly, describes how
decisions actually get made, and states what happens if that person stops. A
governance document that describes a committee which does not exist is worse
than none, because it is the first thing that turns out to be false.

## Who decides

**Maintainer: DotcomJack ([@dotcomjack](https://github.com/dotcomjack)).** Sole
maintainer, final say on scope, design, and what ships.

There is no committee, no voting, and no BDFL succession plan pretending to be
one. If that is a problem for your use case, the license is MIT and forking is a
legitimate answer rather than a hostile one.

## How a change lands

1. Open an issue first for anything larger than a bug fix. A pull request that
   redesigns something without a prior conversation is the most likely kind to
   be declined, and that is a waste of your afternoon rather than a judgement of
   your code.
2. Pull requests go against `main`.
3. **CI has to be green, and the rules it enforces are in
   [CONTRIBUTING.md](CONTRIBUTING.md).** They are enforced by tests rather than
   by review on purpose, so the feedback is fast and it is not a matter of
   opinion.
4. The maintainer reviews and merges. Response time is best effort. This is not
   anyone's day job.

Security reports do not follow this path. They go to the private channel in
[SECURITY.md](SECURITY.md).

## What gets accepted

- **Bug fixes with a test.** Nearly always, and quickly.
- **Documentation that corrects something false.** Always.
- **A new feature.** Discuss it first. The app has a deliberately opinionated
  scope and the answer is sometimes no, which is easier to hear before you have
  written it than after.
- **A dependency.** Rarely, and it needs an argument. Every dependency in an app
  that reads your screen is a supply-chain question, not a convenience question.

## Becoming a maintainer

There is no formal ladder because there has been no need for one. A contributor
with a track record of merged changes who wants commit access should ask, in an
issue. It will be a judgement call, made in the open, and the answer and its
reasoning will be written in that issue rather than decided privately.

## If the maintainer stops

This is the honest bus factor answer, and it is the reason this section exists.

- The code is **MIT licensed**, permanently. Nothing can be clawed back.
- Every release is tagged and its assets stay on GitHub.
- If this repository is unmaintained for **six months** with no release and no
  substantive issue response, treat it as dormant and fork it. You do not need
  permission, and no notice will be given, because a maintainer who has gone
  quiet is by definition not around to give one.
- The security channels in [SECURITY.md](SECURITY.md) are the last thing to be
  abandoned. If a report there goes unacknowledged past the stated window, that
  is the strongest signal that the project is dormant.

## Releases

Releases are cut from `main` and tagged. `CHANGELOG.md` is the record of what
changed. There is no fixed cadence: a release happens when something is worth
shipping.