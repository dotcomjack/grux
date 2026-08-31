import { existsSync, realpathSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const BUNDLE_ID = 'com.gruxai.grux'
export const RELEASES = 'https://github.com/dotcomjack/grux/releases/latest'

// The binary lives inside the app bundle. It is not a separate download and
// there is deliberately no second copy of it anywhere, because two copies of a
// client that speaks a versioned socket protocol is how you get a mismatch
// that reports itself as a connection failure.
const REL_BIN = 'Contents/MacOS/grux-cli'

/**
 * Every place a Grux.app can honestly be, cheapest lookup first.
 * Spotlight is last because it is the only one that can be slow, and it is the
 * only one that can find an app the person put somewhere unusual.
 */
export function candidates() {
  // GRUX_APP is both a test seam and the honest answer for somebody who keeps
  // their applications somewhere we do not guess. It is checked first and it
  // is checked the same way as any other candidate: a bundle that does not
  // carry the binary is still not a find, even when it was named explicitly.
  const override = process.env.GRUX_APP
  if (override) return [override]
  return [
    '/Applications/Grux.app',
    join(homedir(), 'Applications', 'Grux.app'),
  ]
}

// When the caller names an app explicitly, a miss is a miss. Falling back to
// Spotlight there would quietly run a DIFFERENT build than the one asked for,
// which is the single worst outcome for a launcher whose whole job is to be
// unambiguous about which binary it started.
export const overridden = () => Boolean(process.env.GRUX_APP)

function viaSpotlight() {
  try {
    const stdout = execFileSync(
      'mdfind',
      [`kMDItemCFBundleIdentifier == '${BUNDLE_ID}'`],
      { encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'] },
    )
    return stdout.split('\n').map((s) => s.trim()).filter(Boolean)
  } catch {
    // Spotlight being off, indexing, or absent is not an error. It is one
    // lookup of several and the caller has other ways to answer.
    return []
  }
}

/**
 * @returns {{app: string, bin: string} | null} The first bundle that actually
 * carries an executable CLI, or null. A bundle without the binary is NOT a
 * find: it is a partial or an old build, and reporting it as located is how a
 * caller ends up exec'ing a path that is not there.
 */
export function locate() {
  const search = overridden() ? candidates() : [...candidates(), ...viaSpotlight()]
  for (const app of search) {
    const bin = join(app, REL_BIN)
    if (existsSync(bin)) {
      try {
        return { app: realpathSync(app), bin: realpathSync(bin) }
      } catch {
        return { app, bin }
      }
    }
  }
  return null
}

/** The app's marketing version, or null when it cannot be read. */
export function appVersion(app) {
  try {
    return execFileSync(
      '/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleShortVersionString', join(app, 'Contents/Info.plist')],
      { encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim() || null
  } catch {
    return null
  }
}
