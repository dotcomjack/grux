# Reporting a security issue

**Do not open a public issue for anything exploitable.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/dotcomjack/grux/security/advisories/new),
or by email to **jack@dotcomjack.com**.

Please include what you did, what happened, and what you expected. A proof of
concept helps enormously. Never include a real credential in a report; the
Keychain service name and the last four characters are enough to identify one.

You should get a first reply within a few days. This is a solo project, so please
be patient rather than assuming silence means the report was ignored.

## Scope

Grux is a local application with no hosted backend, so most of the interesting
surface is on the user's own machine. Reports that are particularly welcome:

- A path from model output to a filesystem read or write that escapes the
  allowlist and denylist in `FilesystemTool`
- A prompt injection that reaches a real action without passing through the
  approval gate
- A way to exfiltrate a Keychain credential, or to get one written to disk
- A way to defeat the secret redaction applied before content is sent to a model
- A command that reaches the shell despite the denylist

Out of scope: anything that requires physical access to an unlocked Mac, anything
that requires the user to install a modified build, and anything that depends on
the operating system already being compromised. These are documented as
non-defences in [the full threat model](../Grux-Mac/SECURITY.md), section 8.

## The full threat model

[`Grux-Mac/SECURITY.md`](../Grux-Mac/SECURITY.md) is the canonical document. It
covers the architecture, the layered controls with file and line anchors, the
allowlist and denylist, rate limits, the audit log format, key rotation, and an
explicit section on what Grux does **not** protect you from. Read section 8 before
reporting, in case what you found is already documented as a known limit.
