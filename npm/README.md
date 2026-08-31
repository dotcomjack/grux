# grux

The one command front door to [Grux OS](https://gruxai.com).

```sh
npx @dotcomjack/grux
```

That finds Grux.app on your Mac, puts `grux` on your PATH, and hands you to the
real command line. After the first run you can drop the `npx` and just type
`grux`.

## What this package is, and is not

It is a **launcher**, about 200 lines, with **no dependencies**.

Every actual command is the Swift binary that ships inside `Grux.app`, so there
is one implementation of the grammar and no chance of two front doors drifting
apart. This package never reimplements a command, never caches an answer, and
never talks to the network.

It does not download or install Grux. The command line lives inside the app
bundle rather than beside it, so there is no separate artifact to fetch. If the
app is not on your Mac, the launcher says so, prints the download link, and
changes nothing.

## Why the scoped name

npm refuses `grux` as a bare name. Its typosquatting filter rejects it as too
close to `grunt`, `grpc`, `flux`, `rax`, `rx` and `urix`, and the scoped name is
npm's own suggested remedy. The command it installs is still plain `grux`, so
after the first run you type three letters either way.

## Usage

```sh
npx @dotcomjack/grux                 # link, then run setup (or status when not a terminal)
npx @dotcomjack/grux status          # anything else is passed straight through
npx @dotcomjack/grux status --json   # including flags, verbatim
npx @dotcomjack/grux --link-only     # just put grux on the PATH, run nothing
```

`--link-only` is the single flag this launcher consumes, and only as the first
argument. Everything else reaches the Swift CLI untouched.

## Exit codes

The same four the Swift CLI uses, forwarded rather than reinvented.

| Code | Meaning |
|---|---|
| 0 | Done. |
| 1 | Failed. |
| 2 | Waiting on you, on this Mac. Nothing any flag can do. |
| 3 | Run `grux doctor`. |

`npx @dotcomjack/grux` on a Mac with no Grux.app exits **2**, because installing it is
something only you can do.

## Where the link goes

The first directory that is both writable by you and already on your `PATH`,
preferring `~/.local/bin`, then `/opt/homebrew/bin`, then `/usr/local/bin`.

It never uses `sudo`. An installer that asks for your password to place a
symlink has taught you that Grux asks for passwords, and that habit costs more
than the convenience is worth.

If a file named `grux` is already there and it is not one of ours, the launcher
refuses and tells you. It will not remove somebody else's program.

## Environment

| Variable | Effect |
|---|---|
| `GRUX_APP` | Use this bundle and no other. A miss is a miss, with no fallback. |
| `NO_COLOR` | Honoured on presence, so `NO_COLOR=0` still means no colour. |

## Requirements

macOS 14 or later, and [Grux.app](https://github.com/dotcomjack/grux/releases/latest).
Node 18 or later, which `npx` already implies.

## License

MIT.
