# Update check: scope for 3.2 onward

Status: scoped 2026-10-17 on the owner's instruction ("auto update should be scoped for
versions moving forward"). Not built. Target: the next feature release.

## The problem, measured

- Grux has no way to learn that a newer release exists. A search of `Grux-Mac/Sources`
  for a release feed, an appcast, Sparkle or a GitHub releases call found none
  (2026-10-17). `GruxUpdater` (Foundry) rebuilds the app from local source and never
  looks at a release.
- So shipping 3.1.0 reached the site, GitHub, Homebrew and npm, and none of the copies
  already installed. A 3.0 user hears about 3.1 only by running `brew upgrade --cask grux`
  or by visiting gruxai.com again. 3.0 had 58 downloads by 2026-10-13 (gruxai.com facts).
- The README promises "no updater phoning home". Any design here must keep that promise
  in letter and spirit, or change the README in the same release and say so plainly.

## What to build (the smallest version that solves it)

**Notify, never auto-install.** Grux tells you a newer release exists and hands you the
download. It never downloads, replaces or relaunches itself.

1. **One request, no identity.** An unauthenticated `GET` of
   `https://api.github.com/repos/dotcomjack/grux/releases/latest`, the same public page
   anyone can open. It sends no install id, no version header beyond the standard user
   agent, no cookie, no key. Nothing is sent to a Grux server, because there is none.
2. **When.** At most once per 24 hours, after launch, in the background. Never on a
   metered or offline network path, and never during first run.
3. **What you see.** If `tag_name` is newer than `CFBundleShortVersionString` (semver
   compare, ignoring drafts and prereleases): one row in the panel's Now list, "Grux AI
   3.2 is available", with two actions: Download (opens the stable
   `releases/latest/download/Grux.dmg` URL in the browser) and Not now (hides that
   version). Homebrew installs (the app path is inside a Caskroom, or the app was
   symlinked by brew) show `brew upgrade --cask grux` instead of Download.
4. **Off is real, and findable.** Per the house rule that nothing ships off and
   undiscoverable, all three are required:
   - named at first run, on the existing privacy step, in one line;
   - a permanent toggle in Settings, General ("Check for new versions"), plus a "Check
     now" button that works even when the toggle is off;
   - its off state explained: what is requested, from where, how often, and that
     nothing about you is sent.
   Default: ON, because the request carries nothing about the user. If the owner rules
   it should default OFF, the first-run line becomes the switch.
5. **README.** "No updater phoning home" becomes an exact description: "Grux checks
   GitHub's public release page once a day to tell you about new versions. It sends
   nothing about you, never installs anything by itself, and you can turn it off."

## Out of scope

- Self-replacing the app bundle, Sparkle, delta updates, or a Grux update server.
- Auto-updating Homebrew installs (brew owns that).
- Any analytics on who updated.

## Tests (each red first)

- Version compare: 3.1.0 vs 3.2.0, 3.10.0 vs 3.9.0, and equal versions. Drafts and
  prereleases are ignored.
- The request carries no identifying header or query, asserted on the built `URLRequest`.
- The rate limit: a second check inside 24 hours makes no request.
- Off means off: with the toggle off, the scheduled check makes no request, and "Check
  now" still does.
- Discoverability: the toggle's Settings writer exists and first run names it, through
  the existing discoverability sweep.
- Homebrew detection picks the brew instruction for a Caskroom path.

## Release gate

Add the surface to `release/surfaces.json` when it ships: `post` then checks that the
live `releases/latest` answer parses with the same code path the app uses. Once that is
in place, the release proves that installed copies will hear about it.

## Floor and plan

- Floor: one request and one Now row, about a day of work with tests.
- Plan: two days including the README, the first-run line, Settings and a walk on the
  clean VM. The only blocker is the default (ON or OFF), which is the owner's ruling.
