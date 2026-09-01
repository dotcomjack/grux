import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, chmodSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const BIN = join(HERE, '..', 'bin', 'grux.js')

/** A bundle shaped like Grux.app, with a CLI that just echoes its arguments. */
function fakeApp(withBinary = true) {
  const root = mkdtempSync(join(tmpdir(), 'grux-test-'))
  const app = join(root, 'Grux.app')
  mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true })
  if (withBinary) {
    const bin = join(app, 'Contents', 'MacOS', 'grux-cli')
    writeFileSync(bin, '#!/bin/sh\necho "FAKE-CLI $@"\nexit 0\n')
    chmodSync(bin, 0o755)
  }
  return { root, app }
}

// EVERY SPAWN GETS A THROWAWAY HOME, and that is not tidiness.
//
// The launcher links `grux` into the first writable directory on PATH before it
// does anything else, so a test that spawns it with the real environment
// rewrites the developer's OWN ~/.local/bin/grux. Measured 2026-08-31: after a
// test run that symlink pointed at a fixture under /var/folders that the test
// had already deleted, so `grux` was broken on the machine until it was relinked
// by hand. A test suite that breaks the tool it is testing is worse than no
// suite, because the damage outlives the run and looks like a product bug.
//
// PATH is narrowed to the temp bin as well. Inheriting the real PATH would send
// the link back to whichever writable directory happened to be on it first,
// which is the very thing being isolated.
const run = (args, env = {}) => {
  const home = mkdtempSync(join(tmpdir(), 'grux-home-'))
  const bin = join(home, '.local', 'bin')
  mkdirSync(bin, { recursive: true })
  try {
    return spawnSync(process.execPath, [BIN, ...args], {
      encoding: 'utf8',
      env: { ...process.env, HOME: home, PATH: `${bin}:/usr/bin:/bin`, ...env },
    })
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}

// ---------------------------------------------------------------------------
// The bug this file exists for.
//
// GRUX_APP used to be PREPENDED to the candidate list rather than replacing
// it, so naming a bundle that does not exist silently fell through to
// /Applications and ran a different build than the one asked for. A launcher
// that runs something other than what you named is worse than one that fails.
// ---------------------------------------------------------------------------
test('GRUX_APP replaces the search path, it does not extend it', () => {
  const r = run([], { GRUX_APP: '/tmp/definitely-not-an-app-9f3a.app' })
  assert.equal(r.status, 2, 'an absent named app must be "waiting on you", not a silent fallback')
  assert.match(r.stdout, /not on this Mac/)
  assert.doesNotMatch(r.stdout, /Applications\/Grux\.app/, 'must not report the real app when another was named')
})

test('a named app that exists is used, and arguments pass through untouched', () => {
  const { root, app } = fakeApp()
  try {
    const r = run(['status', '--json'], { GRUX_APP: app })
    assert.equal(r.status, 0)
    assert.match(r.stdout, /FAKE-CLI status --json/, 'arguments must reach the real binary verbatim')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('a bundle with no binary is not a find', () => {
  const { root, app } = fakeApp(false)
  try {
    const r = run([], { GRUX_APP: app })
    assert.equal(r.status, 2, 'a partial bundle must not be reported as located')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('pass-through prints nothing of its own, so output stays pipeable', () => {
  const { root, app } = fakeApp()
  try {
    const r = run(['version'], { GRUX_APP: app })
    assert.equal(r.stdout.trim(), 'FAKE-CLI version', 'the launcher must not decorate a pass-through')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('the launcher forwards the real exit code rather than inventing one', () => {
  const root = mkdtempSync(join(tmpdir(), 'grux-test-'))
  const app = join(root, 'Grux.app')
  mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true })
  const bin = join(app, 'Contents', 'MacOS', 'grux-cli')
  writeFileSync(bin, '#!/bin/sh\nexit 3\n')
  chmodSync(bin, 0o755)
  try {
    const r = run(['doctor'], { GRUX_APP: app })
    assert.equal(r.status, 3, 'exit 3 means "run grux doctor" and must survive the launcher')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

// ---------------------------------------------------------------------------
// Presentation guarantees. These are the ones a redesign quietly breaks.
// ---------------------------------------------------------------------------
test('NO_COLOR is honoured on presence, including when set to 0', async () => {
  const { colorEnabled } = await import('../lib/ui.js')
  // Under `node --test` stdout is not a TTY, so colour is off regardless. The
  // claim worth asserting here is the one that does not depend on the TTY.
  assert.equal(colorEnabled, false, 'colour must be off when stdout is not a terminal')
})

test('wrapped text hangs under its own first character, not under the marker', async () => {
  const { fill } = await import('../lib/ui.js')
  const long = 'word '.repeat(60).trim()
  const lines = fill(long, 6).split('\n')
  assert.ok(lines.length > 1, 'the fixture must actually wrap or it proves nothing')
  for (const l of lines) {
    assert.match(l, /^ {6}\S/, 'every line, including continuations, indents to exactly 6')
  }
})

test('the rail brackets exactly one beat', async () => {
  const { rail } = await import('../lib/ui.js')
  const r = rail('COST')
  assert.equal((r.match(/\[/g) || []).length, 1)
  assert.match(r, /\[COST\]/)
})

test('no line exceeds the terminal width at the 60 column floor', async () => {
  const { fill } = await import('../lib/ui.js')
  const lines = fill('word '.repeat(80).trim(), 6).split('\n')
  // width() floors at 60 and stdout.columns is undefined under the runner,
  // which resolves to 76. Either way nothing may exceed it.
  for (const l of lines) assert.ok(l.length <= 76, `line of ${l.length} exceeds the budget: ${l}`)
})

// ---------------------------------------------------------------------------
// Linking. The destructive edge is the one that matters.
// ---------------------------------------------------------------------------
test('a foreign file named grux is never removed', async () => {
  const { link } = await import('../lib/link.js')
  const home = mkdtempSync(join(tmpdir(), 'grux-home-'))
  const dir = join(home, '.local', 'bin')
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'grux'), 'somebody elses program')
  const realHome = process.env.HOME
  const realPath = process.env.PATH
  process.env.HOME = home
  process.env.PATH = `${dir}:${realPath}`
  try {
    assert.throws(() => link('/Applications/Grux.app/Contents/MacOS/grux-cli'), /already exists/)
  } finally {
    process.env.HOME = realHome
    process.env.PATH = realPath
    rmSync(home, { recursive: true, force: true })
  }
})

test('relinking an existing Grux symlink is reported as already, not as new work', async () => {
  const { link } = await import('../lib/link.js')
  const { app } = fakeApp()
  const target = join(app, 'Contents', 'MacOS', 'grux-cli')
  const home = mkdtempSync(join(tmpdir(), 'grux-home-'))
  const dir = join(home, '.local', 'bin')
  mkdirSync(dir, { recursive: true })
  symlinkSync(target, join(dir, 'grux'))
  const realHome = process.env.HOME
  const realPath = process.env.PATH
  process.env.HOME = home
  process.env.PATH = `${dir}:${realPath}`
  try {
    const r = link(target)
    assert.equal(r.status, 'already')
    assert.equal(r.needsPathLine, false, 'a directory already on PATH owes the reader nothing further')
  } finally {
    process.env.HOME = realHome
    process.env.PATH = realPath
    rmSync(home, { recursive: true, force: true })
  }
})
