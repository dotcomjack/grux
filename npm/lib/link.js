import { existsSync, lstatSync, mkdirSync, readlinkSync, symlinkSync, unlinkSync, accessSync, constants } from 'node:fs'
import { homedir } from 'node:os'
import { join, delimiter } from 'node:path'

/**
 * Directories we are willing to put the symlink in, best first.
 *
 * All three are conventional and none of them needs sudo when they are already
 * yours. We never write to a directory owned by root: an installer that asks
 * for a password to drop a symlink has taught the person that Grux asks for
 * passwords, and that is a habit worth more than the convenience.
 */
export function targets() {
  return [
    join(homedir(), '.local', 'bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ]
}

const pathDirs = () => (process.env.PATH || '').split(delimiter).filter(Boolean)

export const onPath = (dir) => pathDirs().includes(dir)

function writable(dir) {
  try {
    accessSync(dir, constants.W_OK)
    return true
  } catch {
    return false
  }
}

/**
 * Choose where the link goes.
 *
 * Preference order is deliberate: a directory that is BOTH already on PATH and
 * writable wins, because linking there is complete on its own and needs no
 * follow up from the reader. Only when nothing qualifies do we fall back to
 * creating ~/.local/bin, which then owes the reader a PATH line.
 */
export function chooseTarget() {
  const t = targets()
  for (const dir of t) if (existsSync(dir) && writable(dir) && onPath(dir)) return { dir, needsPathLine: false }
  for (const dir of t) if (existsSync(dir) && writable(dir)) return { dir, needsPathLine: true }
  return { dir: t[0], needsPathLine: !onPath(t[0]), mustCreate: true }
}

/**
 * @returns {{status: 'linked'|'already'|'replaced', path: string, needsPathLine: boolean, dir: string}}
 * @throws {Error} when the directory cannot be created or the link cannot be written.
 */
export function link(binPath) {
  const { dir, needsPathLine, mustCreate } = chooseTarget()
  if (mustCreate || !existsSync(dir)) mkdirSync(dir, { recursive: true })

  const dest = join(dir, 'grux')
  let status = 'linked'

  if (existsSync(dest) || isBrokenLink(dest)) {
    // An existing `grux` that already points where we want is a no-op, and
    // saying "linked" about it would be a small lie in the one place a reader
    // is deciding whether anything happened.
    if (isSymlinkTo(dest, binPath)) return { status: 'already', path: dest, needsPathLine, dir }

    // Anything else at that name is replaced ONLY when it is a symlink we
    // recognise as ours. A real file called `grux` belongs to somebody else
    // and removing it is not ours to do.
    if (!isOurSymlink(dest)) {
      const e = new Error(`${dest} already exists and is not a Grux symlink`)
      e.code = 'EOCCUPIED'
      throw e
    }
    unlinkSync(dest)
    status = 'replaced'
  }

  symlinkSync(binPath, dest)
  return { status, path: dest, needsPathLine, dir }
}

function isBrokenLink(p) {
  try {
    return lstatSync(p).isSymbolicLink()
  } catch {
    return false
  }
}

function isSymlinkTo(p, target) {
  try {
    return lstatSync(p).isSymbolicLink() && readlinkSync(p) === target
  } catch {
    return false
  }
}

/** Ours means: a symlink pointing into a Grux.app bundle. */
function isOurSymlink(p) {
  try {
    if (!lstatSync(p).isSymbolicLink()) return false
    return readlinkSync(p).includes('Grux.app/Contents/MacOS/')
  } catch {
    return false
  }
}

export const pathLineFor = (dir) => `export PATH="${dir}:$PATH"`
