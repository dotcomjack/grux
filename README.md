# Grux

A native macOS app that gives an AI agent your mail, your calendar, your meetings
and a shell it can undo. Your own API key, or a local model and no key at all.

[![CI](https://github.com/dotcomjack/grux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/dotcomjack/grux/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/dotcomjack/grux?label=download&color=7C5CFF)](https://github.com/dotcomjack/grux/releases/latest)
[![Licence](https://img.shields.io/badge/licence-MIT-7C5CFF)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20Apple%20silicon-lightgrey)](#requirements)

**The god agent for solopreneurs on Mac.**

Thirty nine features and one hundred sixteen tools in one native window.

Grux opens persistent terminal sessions in your project and can undo anything it
did, because every command is snapshotted into a shadow git repository first. It
runs swarms of agents in parallel. It scaffolds, builds and runs iOS apps in the
simulator. It drives your screen when clicking is faster than describing. It
captures meetings, tells the speakers apart on device, and files the transcript.
And it reads its own source, proposes its next version, builds it, verifies it,
and waits for you to approve the install.

The mail, calendar, contacts, notes, documents and meetings already on your Mac
are the easy part, and it does those too.

It talks to a model you pay for directly, or to a local model with no key at all.
There is no Grux account, no Grux server, and no subscription. Your key, your
machine, your data.

If it earns it, a star is the whole ask.

**Status: shipping, currently 1.2.1.** 39 features ship, and a command line drives all of them. 25 are core and 14 are
labelled BETA in the sidebar because they are real but rough. Nothing is hidden
behind a waitlist. See [Feature tiers](#feature-tiers) for exactly which is which.

![Local Models: hardware-aware model recommendations for this Mac, through Ollama](docs/screenshots/local-models.png)

Grux reads your hardware and tells you which local models actually fit it, so you
can run the whole thing without sending a token to anyone.

![Integrations: tokens stored in the macOS Keychain, talking to services directly from your Mac](docs/screenshots/integrations.png)

Credentials go to your Keychain and services are called directly from your
machine. There is no server in the middle because there is no server.

These are the real interface, not mockups. Two surfaces rather than a gallery,
because the rest of the app is full of the author's own mail and calendar and
those are not yours to look at.

---

## Install

**Download the notarized build.** This is the front door. It is signed with a
Developer ID, notarized by Apple and stapled, so it opens on a Mac that has never
seen it without a right click and without a trip through System Settings.

[**Download Grux 1.2.1 for Apple silicon**](https://github.com/dotcomjack/grux/releases/latest) (23 MB, macOS 14+)

Unzip it, drag `Grux.app` to Applications, open it. There is no installer and no
updater phoning home. To check what you got before you run it:

```sh
shasum -a 256 Grux-macOS-arm64.zip     # compare against the checksum in the release notes

spctl -a -vv /Applications/Grux.app
# Grux.app: accepted
# source=Notarized Developer ID
```

The checksum lives in the release notes rather than here, because it changes every
release and a copy in this file is a copy that goes stale.

**Or through Homebrew.**

```sh
brew install --cask dotcomjack/tap/grux
```

**Then wire up the command line**, if you want one. This finds the app you just
installed, puts `grux` on your PATH and runs setup. It installs nothing itself:

```sh
npx @dotcomjack/grux
```

Building from source is in [Building](#building) below, and it is the path to take
if you want to change something rather than run it.

## Table of contents

- [What it actually does](#what-it-actually-does)
- [The command line](#the-command-line)
- [What it costs](#what-it-costs)
- [Requirements](#requirements)
- [Building](#building)
- [First run](#first-run)
- [Permissions, and what each one buys](#permissions-and-what-each-one-buys)
- [Privacy posture](#privacy-posture)
- [Feature tiers](#feature-tiers)
- [The phone companion](#the-phone-companion)
- [Build on it](#build-on-it)
- [Repository layout](#repository-layout)
- [Tests](#tests)
- [Who made this](#who-made-this)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

---

---

## What it actually does

The short version: one window, a sidebar of surfaces, and an assistant that can
reach the things a Mac assistant should be able to reach.

- **Chat** with tool use, against Anthropic or a local model.
- **Local models** through Ollama, so you can run the whole thing without sending
  a token to anyone.
- **Mailbox, Calendar, Contacts, Notes, Documents** against your real accounts,
  not a hosted copy of them.
- **Meetings** that record both the microphone and system audio, transcribe on
  device with WhisperKit, and never upload the raw audio.
- **Projects, Task Stack, Schedules, Skills, Commands** for the work around the
  work.
- **Research** over the web, with a search key you supply.
- **A shell** that runs real commands behind a path allowlist, a command
  denylist, a rate limit, and an audit log.
- **Approvals**, which is where anything sensitive stops and waits for you.

Every one of those is a real surface in the app. None of them is a stub.

## The command line

Grux can be set up and driven entirely from the terminal, without opening a
window. Shipped in 1.2.0, and the reason is not that a terminal is faster.

It is that the coding agent already sitting in that terminal can do the work
with you: install Grux, wire it into the rest of your machine, and go on
extending it long after setup is done.

Start here. One command, nothing to install first:

```sh
npx @dotcomjack/grux
```

That finds Grux.app, puts `grux` on your PATH, and runs setup. After the first
run, drop the `npx`. The launcher is a dependency free shim that only locates
the binary and steps aside, so there is one implementation of everything below
and no second front door to drift. Details in [npm/README.md](npm/README.md).

The binary itself lives at `Grux.app/Contents/MacOS/grux-cli`, so you can link
it by hand instead if you prefer:

```sh
ln -s /Applications/Grux.app/Contents/MacOS/grux-cli ~/.local/bin/grux
```

```sh
grux setup                 # the whole first run, unattended
grux status --json         # what is configured, what is missing
grux doctor                # what is wrong, and what to do about it
grux why <feature>         # why a feature says it needs setup
```

- **Every command runs unattended.** A flag for every choice and JSON on every
  read, so nothing hangs waiting for a prompt an agent cannot see.
- **Every command can print itself as a prompt** instead of running, so you can
  hand the job to whichever coding agent you already use rather than translating
  it yourself.
- **An MCP bridge**, so an agent that speaks it can drive Grux through the same
  tools you do.
- **Reads answer with Grux closed.** They come from files on disk. Writes go over
  a Unix socket at `0600`, so Grux still opens no network port.

The full surface, every command and every exit code, is in
[Grux-Mac/docs/cli-grammar.md](Grux-Mac/docs/cli-grammar.md).

## What it costs

Nothing, to Grux. It is MIT licensed and there is no hosted component.

You pay your model provider directly, at their prices, on your own account. Grux
never proxies a request through anything we run, so there is no markup and no
middleman with a copy of your prompts.

If you run a local model through Ollama, it costs nothing at all.

## Requirements

- macOS 14 (Sonoma) or later, Apple silicon
- Xcode 16 or later (Swift 6.0+). `Package.swift` says `swift-tools-version:5.9`,
  but `swift-transformers` pulls `swift-jinja` 2.x, which is written against
  tools-version 6.0, so an older toolchain cannot resolve the dependency graph
- An Anthropic API key, or Ollama running locally

Dependencies are deliberately thin. The only direct one is
[WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device speech, which
pulls in Apple's own packages plus HuggingFace's `swift-transformers`. There is no
analytics SDK, no crash reporter, and no telemetry package in the tree. You can
check that yourself in `Grux-Mac/Package.resolved`.

## Building

```sh
git clone https://github.com/dotcomjack/grux.git
cd grux/Grux-Mac
./build.sh
```

That builds a release binary, assembles `Grux.app`, signs it, installs it to
`/Applications`, and opens it.

**On signing.** macOS keys every permission grant to the signing identity, so
`build.sh` pins one to stop the app re-prompting on every rebuild. If you do not
have that certificate, and you will not, it falls back to an ad hoc signature and
says so. The app runs fine; you will just re-grant permissions after a rebuild.
Set `GRUX_SIGN_ID` to your own identity hash to make grants stick:

```sh
security find-identity -v -p codesigning        # find yours
GRUX_SIGN_ID=<your-identity-hash> ./build.sh
```

**Distributable builds.** `GRUX_RELEASE=1 ./build.sh` signs with a
`Developer ID Application` certificate and writes the artifact to your Desktop
without installing it, because signing with a different identity would revoke the
dev install's permission grants.

Add `GRUX_NOTARIZE=1` to notarize and staple. Authentication is either an App
Store Connect API key, which is preferred because it works unattended:

```sh
GRUX_RELEASE=1 GRUX_NOTARIZE=1 \
  ASC_KEY=~/private_keys/AuthKey_XXXXXXXXXX.p8 \
  ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER=<issuer-uuid> ./build.sh
```

or an Apple ID with an app-specific password, via `APPLE_ID`,
`APPLE_APP_PASSWORD` and `APPLE_TEAM_ID`. Apple notarizes only Developer ID
signed code, so `GRUX_NOTARIZE=1` without `GRUX_RELEASE=1` is refused rather than
uploaded and rejected.

## First run

**The minimum useful setup is one key.** Chat needs an Anthropic API key and
nothing else. Paste it in Settings and the app is usable.

Everything beyond that is opt in, and the app tells you what is missing rather
than failing quietly. Each sidebar row carries a dot when a feature it depends on
is unconfigured, and the setup sheet names the specific credential, permission or
step that is absent. A feature you never open never asks you for anything.

If you would rather not send anything to a hosted model at all, install
[Ollama](https://ollama.com), pull a model, and Grux will use it. The Local Models
tab picks it up automatically.

Credentials go to the macOS Keychain under the service `com.gruxai.grux`. They are
never written to disk in plaintext and never leave the machine except to the
provider they belong to.

## Permissions, and what each one buys

Grux asks for a lot, because it does a lot. Every one of these is optional, every
one is requested only when you first use the feature that needs it, and refusing
one disables exactly that feature and nothing else.

Nine permissions, and only five are required by anything at all. The other four
are asked for by a feature that still works without them, just with less in it.

| Permission | Required by | What refusing costs you |
|---|---|---|
| Microphone | Meetings | Voice input in Chat and Reactor |
| System audio capture | Meetings | Nothing else. This is the other half of the call, not your mic |
| Screen Recording | Focus log, Terminal Focus | Screen context in Chat |
| Calendar | Calendar | The agenda on Home, calendar tools in Chat and Reactor |
| Contacts | Contacts | Contact lookup in Chat |
| Automation | Nothing | Commands, Terminal Focus, and app control from Chat |
| Accessibility | Nothing | Window and selection awareness in Chat, and detail in Focus log |
| Notifications | Nothing | Alerts from Schedules, Workflows and Focus log |
| Full Disk Access | Nothing | Jax Command, one BETA surface, and nothing else anywhere |

That table is not typed by hand. `PermissionTableTests` parses it out of this
file and asserts both columns against the same `FeatureRegistry` the app reads at
runtime: the middle column must name exactly the features that list the
permission as required, and the right column must name exactly the features that
list it as optional. Move one without the other and the suite goes red.

**Grux is not sandboxed.** ScreenCaptureKit, AppleEvents and cross app microphone
access are not available inside the App Sandbox, so the OS level path allowlist is
not available either. The filesystem boundary is therefore enforced in Swift, in
one file, and that file is the only path from the model to your disk. It carries a
read only root allowlist, a denylist covering `.ssh`, `.aws`, `.env`, the Keychain,
Mail, Messages and browser profiles, a size cap, a rate limit, a secret pattern
scan on everything it returns, and an audit log. That trade is written up in full
in [SECURITY.md](Grux-Mac/SECURITY.md), including the parts it does not defend
against.

## Privacy posture

- **No account.** There is nothing to sign up for.
- **No server.** There is no Grux backend. Nothing is proxied.
- **No telemetry.** No analytics SDK, no crash reporter, no usage beacon. Grep the
  tree.
- **Your keys stay in your Keychain**, and go only to the provider they belong to.
- **Meeting audio is transcribed on device.** The recording does not leave the
  machine.
- **Everything the model reads from disk is logged** to
  `~/Library/Application Support/Grux/fs-audit.log`, including the denials. You
  can read it at any time and it is plain text.

The one thing to be clear eyed about: when you use a hosted model, that provider
sees what you send it. Grux redacts secrets it recognises before anything goes
out, but a hosted model is a third party by definition. Run Ollama if that matters
to you.

## Feature tiers

**Core (25).** Home, Chat, Approvals, Cognition Map, Projects, Task Stack,
Mailbox, Calendar, Notes, Documents, Contacts, Schedules, Folders, Research,
Skills, Compare, Local Models, Design Studio, Meetings, Speakers, Commands, Focus
log, Integrations, Outbound Webhooks, Settings.

**Labs (14), badged BETA in the sidebar.** Reactor, Jax Command, Feature Review,
Agents, Compose and send, Media Studio, Social, Workflows, Terminal Focus,
Self-Upgrade, Jax HQ, Meta Ads, Domain monitor, Phone companion.

Labs does not mean broken. It means the surface is real and the edges are not
sanded. A test asserts that every labs feature is badged and that no core feature
is, so the label cannot quietly go stale.

## The phone companion

`GruxPhone/` is a small iOS app that pairs with the Mac over your local network
and acts as a remote microphone and control surface. The link is
Curve25519 key exchange, ChaCha20-Poly1305 encryption and HMAC authentication, and
traffic never leaves your LAN.

It is a labs feature and it is opt in. If you never pair a phone, the Mac never
opens a listening socket.

## Build on it

The reason this is MIT and not a download is that most of what is in here is
plumbing, and plumbing is the part nobody wants to write twice. If you are building a
Mac agent, the four modules below are usable without the app around them.

**The pieces.** `GruxShellCore` is a PTY, the safety gates and the snapshot store.
`GruxAgentCore` is orchestration. `GruxSetupCore` is the capability and permission
model. `GruxMCPCore` is the read only MCP server. None of the four imports AppKit or
SwiftUI, so they build and test without the UI stack, and all four are `.library`
products in `Grux-Mac/Package.swift`. You can depend on one without taking the other
three or the app.

**To add a tool**, which is the most common thing anyone will want. Tools are declared
in `ChatService.allTools()` in `Grux-Mac/Sources/Grux/ChatService.swift` and handled in
the `switch` further down the same file. Copy `add_task`: the declaration is at the top
of `allTools()` and its handler is the first `case`. Two edits, same file, and the
model can call it. `ToolCatalogueTests` pins the count at 116, so adding one turns the
suite red until you move the pin on purpose.

**To add a surface**, meaning a row in the sidebar with its own screen. Add a
`FeatureRow` to `FeatureRegistry.rows` in
`Grux-Mac/Sources/Grux/Onboarding/FeatureRegistry.swift`, naming what it `requires` and
what is merely `optional`. The dot on the sidebar row, the setup sheet, the permission
table in this README and the BETA badge are all read from that one entry, so getting
the row right is the whole job.

**What you must not break.** Four guards, and each one exists because the thing it
catches already happened here:

```sh
cd Grux-Mac
swift test                          # 2498 tests
python3 scripts/check-contract.py   # the setup contract is frozen
```

The setup contract will not let a capability change meaning without a dated amendment
in `Grux-Mac/docs/`. `PermissionTableTests` fails if the permission table above stops
matching the registry. `NoPersonalIdentityTests` fails on a personal name anywhere in
the shipping tree. The dash guard fails on an em dash or en dash, comments included.
Several of them plant the fault they detect and assert they catch it, because a guard
that cannot fail is not a guard.

**What is unfinished, and what I would take.** Honestly said, since this is the part
that matters if you are deciding whether to spend an evening here:

- **A second model backend.** Chat talks to Anthropic or to Ollama. The seam is real
  but it has only ever had two implementations, so it is shaped by both of them rather
  than by the general case. A third would tell you where it is wrong.
- **The MCP server is read only.** Writes go over a Unix socket instead. Making it a
  full bidirectional surface is a contained piece of work and it would let any agent
  drive the whole app.
- **The 14 BETA surfaces.** Every one of them is real and none of them is finished.
  Workflows and Agents are the two with the most left in them.
- **Nothing here runs on an Intel Mac.** One arm64 slice, and no reason beyond nobody
  having needed it.

If you build something on this, open an issue and tell me. I would rather know.

## Repository layout

```
Grux-Mac/            the macOS app (Swift package, builds Grux.app)
  Sources/Grux/      the app itself
  Sources/GruxShellCore/    PTY shell, safety gates, snapshot store, no UI
  Sources/GruxAgentCore/    agent orchestration, no UI
  Sources/GruxMCPServer/    read only MCP server for external agents
  Tests/GruxTests/   the suite
  docs/              the setup contract and its change record
  scripts/           the frozen-contract checker
  SECURITY.md        the threat model, in full
GruxPhone/           the iOS companion
```

`GruxShellCore` and `GruxAgentCore` are deliberately free of AppKit and SwiftUI, so
they can be used and tested without the UI stack.

## Tests

```sh
cd Grux-Mac
swift test
```

Be aware that `swift build` does **not** compile the test target, so a green build
is not a green suite. The suite includes guards that are unusual and worth knowing
about before you touch them:

- The **setup contract** is frozen. `scripts/check-contract.py` fails if a
  capability changes meaning without a dated amendment in `docs/`.
- The **identity scan** fails on a personal name, address or account identifier
  anywhere in the shipping tree.
- The **dash guard** fails on an em dash or en dash anywhere that ships, comments
  included.
- Several guards **test themselves**, by planting the thing they detect and
  asserting they catch it. A guard that cannot fail is not a guard.

## Who made this

I have been building and shipping my own products since 2015. Right now that is
about a dozen of them, run by one person, from Detroit.

That is the reason this exists. Running a dozen small products alone was never
bottlenecked on code. It was the hour a day spent moving between a mail client, a
calendar, a terminal and four chat tabs that could not see any of it. So I built the
assistant I actually wanted: one that reads the window I am already in, handles the
mail, and takes the meeting notes.

Eight of the thirty-nine surfaces in here are literally the tooling that runs my
businesses. They ship instead of getting deleted, because taking them out would
misrepresent what you are downloading.

It was a hobby project for six months. It is not a startup, there is no account, and
there is nothing to buy. I am open sourcing it because it got useful enough to be
worth somebody else's time, and because software that reads your screen and your mail
should be readable back.

Expect rough edges. Fourteen surfaces say BETA because they earned it. If something
breaks, open an issue and tell me what you were doing.

## Security

The threat model, the layered controls with file and line anchors, the denylist,
the audit log format, and an explicit section on what Grux does **not** defend
against are all in [SECURITY.md](Grux-Mac/SECURITY.md).

**The two controls most likely to hurt you live in their own package.** Keeping a
credential out of a prompt, and stopping the agent following a hostile link, are
[grux-guardrails](https://github.com/dotcomjack/grux-guardrails): 115 tests, zero
dependencies, MIT, usable without any of the rest of this.

The reason to point you at it is not the test count. It carries
[six published advisories](https://github.com/dotcomjack/grux-guardrails/security/advisories?state=published)
against its own earlier releases, two of them critical, because six of the first
nine tags failed to redact something. Those tags are still resolvable rather than
deleted, so anyone pinned to one gets told by Dependabot instead of finding out
some other way. A security library with a clean disclosure record after nine tags
is a library nobody has attacked yet.

To report a vulnerability, see [SECURITY](.github/SECURITY.md). Please do not open
a public issue for anything exploitable.

## Contributing

Yes, please. [CONTRIBUTING.md](CONTRIBUTING.md) covers the frozen contract, the
house rules that are enforced by tests, and what a good pull request looks like
here. It is short and it will save you a round trip.

## License

MIT. See [LICENSE](LICENSE).

### Standing on other people's work

Grux links the software below, and each of those licences asks to travel with
it. MIT is permissive about what you may do with the code and not about the
notice: retaining it is the whole of the obligation. Six of these are Apache
2.0, which asks for more, including reproducing any NOTICE file.

The full licence text of every one of them, and the NOTICE files where they
exist, are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which also ships
inside `Grux.app` so it reaches somebody who never opens this page. That file is
generated from `Grux-Mac/Package.resolved`, and a test fails if it drifts, so a
new dependency cannot ship uncredited.

| Package | Licence |
|---|---|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache 2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache 2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache 2.0 |
| [whisperkit](https://github.com/argmaxinc/WhisperKit) | MIT |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |

Thanks in particular to [WhisperKit](https://github.com/argmaxinc/WhisperKit),
which is why meeting transcription runs on the machine and the audio never
leaves it.
