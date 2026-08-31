#!/usr/bin/env node
//
// The front door. `npx grux`.
//
// This package is a LAUNCHER, not a second command line. It owns exactly three
// jobs: find Grux.app, put `grux` on your PATH, and get out of the way. Every
// actual command is the Swift binary inside the app bundle, so there is one
// implementation of the grammar and no chance of the two drifting.
//
// The one shim flag is `--link-only`, and it is only recognised as the first
// argument. Everything else is passed through untouched, which is why
// `npx grux status --json` behaves exactly like `grux status --json`.

import { spawnSync } from 'node:child_process'
import { locate, appVersion, RELEASES } from '../lib/locate.js'
import { link, pathLineFor } from '../lib/link.js'
import { out, err, fill, rail, row, accent, dim } from '../lib/ui.js'

const DONE = 0
const FAILED = 1
const WAITING = 2

function bail(code, lines) {
  for (const l of lines) err(l)
  process.exit(code)
}

function notMac() {
  err(rail('LOOK'))
  err(row('needed', 'Grux runs on macOS', 'Grux is a native Mac app and its command line talks to that app over a local socket, so there is nothing here for this platform to run.'))
  err('')
  err(fill(`This machine reports ${process.platform}.`, 2))
  err('')
  process.exit(FAILED)
}

function notInstalled() {
  out(rail('LOOK'))
  out(row('needed', 'Grux.app is not on this Mac', 'The command line ships inside the app bundle. It is not a separate download, so there is nothing this launcher can usefully install on its own.'))
  out('')
  out(fill('Download it, drag it to Applications, then run this again:', 2))
  out('')
  out('    ' + accent(RELEASES))
  out('')
  out(dim(fill('Nothing was changed on this Mac.', 2)))
  out('')
  process.exit(WAITING)
}

function main() {
  if (process.platform !== 'darwin') notMac()

  const argv = process.argv.slice(2)
  const linkOnly = argv[0] === '--link-only'
  const passthrough = linkOnly ? argv.slice(1) : argv

  const found = locate()
  if (!found) notInstalled()

  // Linking is best effort and never fatal. A reader who cannot write to any
  // PATH directory can still run every command through `npx grux`, so a
  // failure here costs convenience and nothing else. Reporting it as a hard
  // error would be the launcher lying about how much it matters.
  let linked = null
  let linkError = null
  try {
    linked = link(found.bin)
  } catch (e) {
    linkError = e
  }

  const quiet = passthrough.length > 0 && !linkOnly

  if (!quiet) report(found, linked, linkError)

  if (linkOnly) process.exit(linked ? DONE : FAILED)

  // A terminal that cannot answer a question cannot be walked through setup,
  // so the non interactive path lands on `status`, which states where you are
  // and names the command that moves you. Same grammar, no hang.
  const isTTY = process.stdin.isTTY === true && process.stdout.isTTY === true
  const args = passthrough.length > 0
    ? passthrough
    : (isTTY ? ['setup'] : ['status', '--no-input'])

  const r = spawnSync(found.bin, args, { stdio: 'inherit' })
  if (r.error) {
    bail(FAILED, ['', fill(`Could not run ${found.bin}: ${r.error.message}`, 2), ''])
  }
  process.exit(r.status === null ? FAILED : r.status)
}

function report(found, linked, linkError) {
  out(rail('LOOK'))
  const v = appVersion(found.app)
  out(row('ready', `Grux.app${v ? '   ' + v : ''}`, found.app))

  if (linked && linked.status === 'already') {
    out(row('ready', 'grux is already on your PATH', linked.path))
  } else if (linked) {
    out(row('ready', linked.status === 'replaced' ? 'grux relinked' : 'grux is now on your PATH', linked.path))
  } else {
    out(row('optional', 'grux is not on your PATH', `Could not write a link: ${linkError && linkError.message}. Every command still works through "npx grux".`))
  }

  if (linked && linked.needsPathLine) {
    out('')
    out(fill(`${linked.dir} is not on your PATH. Add this to your shell profile to use "grux" directly:`, 2))
    out('')
    out('    ' + accent(pathLineFor(linked.dir)))
  }
  out('')
}

main()
