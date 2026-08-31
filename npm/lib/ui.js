// Presentation only. No policy decisions live here.
//
// The rules this file exists to keep, all of them borrowed from the Swift CLI
// so the two front doors cannot drift apart:
//
//   Colour is never the only carrier. Every state has a glyph and a word
//   first, and the colour is decoration on top of something already legible.
//   That is what makes NO_COLOR and a pipe safe rather than lossy.
//
//   NO_COLOR is honoured on PRESENCE, not on value. `NO_COLOR=0` still means
//   no colour, because that is what the standard says and a reader who set it
//   to zero was not asking for colour back.

const ESC = '['

const isTTY = process.stdout.isTTY === true

// Presence, not truthiness. See above.
const noColor = Object.prototype.hasOwnProperty.call(process.env, 'NO_COLOR')

export const colorEnabled = isTTY && !noColor && process.env.TERM !== 'dumb'

const wrap = (code) => (s) => (colorEnabled ? `${ESC}${code}m${s}${ESC}0m` : s)

// One accent, and it means exactly one thing: "this is the thing to read".
export const accent = wrap('38;5;179')
export const dim = wrap('2')
export const bold = wrap('1')

// The glyph vocabulary is shared with the Swift CLI. Same word, same meaning,
// in the app, in the CLI and here.
export const GLYPH = {
  ready: '+',
  needed: '!',
  waiting: '~',
  optional: '-',
}

// A terminal narrower than 60 columns is a terminal we still owe a readable
// answer to, so 60 is the floor rather than the assumption.
export function width() {
  const c = process.stdout.columns
  if (!c || !Number.isFinite(c)) return 76
  return Math.max(60, Math.min(c, 88))
}

/**
 * Wrap `text` to the usable width, hanging continuation lines under the first
 * character of the text rather than under the marker that introduced it. A
 * wrapped bullet that lines up with the dash reads as a new item, which is a
 * bug that has been shipped on this project before.
 */
export function fill(text, indent = 2, hanging = indent) {
  const room = width() - indent
  const words = String(text).split(/\s+/).filter(Boolean)
  const lines = []
  let line = ''
  for (const w of words) {
    if (line === '') line = w
    else if (line.length + 1 + w.length <= room) line += ' ' + w
    else { lines.push(line); line = w }
  }
  if (line !== '') lines.push(line)
  return lines
    .map((l, i) => ' '.repeat(i === 0 ? indent : hanging) + l)
    .join('\n')
}

export const out = (s = '') => process.stdout.write(s + '\n')
export const err = (s = '') => process.stderr.write(s + '\n')

/** The six beat rail, with the current beat bracketed. Mirrors the Swift CLI. */
const BEATS = ['LOOK', 'CHOOSE', 'COST', 'GRANT', 'HAND OFF', 'PROVE']
export function rail(current) {
  const cells = BEATS.map((b) => (b === current ? `[${b}]` : ` ${b} `))
  const painted = colorEnabled
    ? cells.map((c, i) => (BEATS[i] === current ? accent(c) : dim(c)))
    : cells
  return '\n  ' + painted.join(' ') + '\n'
}

/** A row whose glyph describes the SUBJECT of the row, not how it got here. */
export function row(state, label, detail) {
  const g = Object.prototype.hasOwnProperty.call(GLYPH, state) ? GLYPH[state] : ' '
  const head = `  ${g} ${label}`
  return detail ? `${head}\n${fill(detail, 6)}` : head
}
