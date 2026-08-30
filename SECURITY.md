# Security policy

Grux reads the window you are looking at, opens terminal sessions, and follows
links on your behalf. That is the product, and it is also the threat model: a
bug here does not corrupt a document, it leaks a secret or reaches somewhere it
was never supposed to reach. So reports are wanted, and there is a private
channel for them.

## Reporting a vulnerability

**Do not open a public issue for a bypass.** Use either channel below. The second
one always works.

1. **GitHub private vulnerability reporting** on this repository, under
   **Security**, then **Report a vulnerability**.
2. **Email `security@gruxai.com`** with `Grux security` in the subject.

Include the input that triggers it and what you expected instead. A failing test
case is the fastest possible path to a fix, and it is the difference between a
report that gets fixed this week and one that gets argued about.

## What to expect

| Stage | Timing |
|---|---|
| Acknowledgement that a human read it | Within 3 days |
| Assessment, for anything reproducible | Within 14 days |
| Fix and release | Depends on severity, stated in the assessment |

You get credit in the release notes unless you would rather not be named. Say so
in the report and you will not be.

**There is no bounty.** This is a solo project and pretending otherwise would
waste your time. The policy is here because the class of bug matters, not
because there is money behind it.

## Scope

**In scope**, and these are the reports worth your effort:

- A secret that survives `SecretRedactor.redact` and reaches a log, a prompt, a
  model provider, or the screen.
- A URL that `URLGuard.evaluate` allows and that reaches a private address,
  cloud metadata, or loopback.
- Any path where a command runs that the user did not approve, or where an undo
  does not actually undo.
- Credential handling: keys read from somewhere they should not be, written
  somewhere they should not be, or sent to a provider the user did not choose.
- Anything that makes the app act on content it merely READ. Text on your screen
  and text on a fetched page are data, never instructions.

**Already documented as known limits.** These are real, they are pinned by tests,
and a report that restates one is not a finding:

- `URLGuard` does not follow redirects and does not resolve DNS.
- `SecretRedactor` is a matcher, not a parser, and four specific defects are
  already pinned by tests in the suite.

See the pinned issues on
[grux-guardrails](https://github.com/dotcomjack/grux-guardrails/issues) for the
current list before you write anything up.

**Out of scope:**

- Anything requiring an attacker who already has your unlocked Mac and your
  login. Local physical access ends the conversation.
- Findings from an automated scanner with no reproduction attached.
- The model saying something wrong. That is a quality bug, and it belongs in a
  normal public issue.
- Vulnerabilities in a dependency that upstream already has an advisory for,
  unless Grux uses it in a way that makes it materially worse.

## Supported versions

The latest release on `main` is the supported one. This project ships often
enough that backporting to an older tag is not a promise worth making, so it is
not made here.

## Where the security work actually lives

The guards are a separate MIT library,
[grux-guardrails](https://github.com/dotcomjack/grux-guardrails), so they can be
audited, tested, and reused without pulling in the app. If you are looking for
the code behind `SecretRedactor` or `URLGuard`, that is the repository to read.