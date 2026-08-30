#!/bin/zsh
# Fast tab sweep: switch a LIVE Grux OS to each tab and screenshot it.
#
#   Grux-Mac/tools/grux-sweep.sh <prefix> <tab>...
#   GRUX_SWEEP_OUT=/tmp/shots Grux-Mac/tools/grux-sweep.sh floor home chat mailbox
#
# Writes $GRUX_SWEEP_OUT/<prefix>-<tab>.png (default /tmp). Roughly 0.6s per tab.
# Requires Grux to already be running; it drives the live app through the
# ~/.grux/fire-open-tab trigger rather than relaunching per tab.
#
# WAITS ON THREE SIGNALS, and the third is why this is trustworthy:
#
#   1. The ack file. NOT SUFFICIENT ALONE: the app writes it when `requestedTab`
#      is set, which happens BEFORE SwiftUI repaints. Trusting the ack hands you
#      the previous tab's pixels.
#   2. A capture that decodes.
#   3. A frame that differs SUBSTANTIALLY from the PREVIOUS tab's frame. A plain
#      "did the bytes change" check is not enough: a live timestamp or a blinking
#      cursor changes the bytes while the OLD tab is still on screen, which
#      already produced a "jaxHQ" capture that was really Chat.
#
# The baseline capture before the loop exists because the FIRST tab otherwise
# has nothing to compare against, so it captures instantly and returns whatever
# was already on screen: the first "chat" capture in an early run was really
# Home.
#
# CALIBRATION, in changed PIXELS. This was a percentage twice, and it failed
# twice for the same underlying reason, so the unit itself was the bug.
#
# A percentage divides by the pane area, which makes it scale dependent: the
# same content change scores lower in a bigger window. Measured on one identical
# transition, Speakers to Contacts, an empty state against a 976-row list:
#
#     840pt floor    104,963 changed px    8%
#     2400pt wide    168,950 changed px    2%
#
# The wide switch changed MORE pixels and scored LOWER. A percentage threshold
# tuned at the floor (first 10, then 4) rejected it as "NEVER DIVERGED" at 2400.
# Tuning the percentage down a third time would only move the failure to the
# next window size.
#
# The count does not move with window size. Measured: a stale frame is EXACTLY 0
# (four live captures of one unchanged tab spanning 1.2s), and every real
# transition observed at either size is above 100,000. 20,000 sits an order of
# magnitude clear of both.
#
# The honest failure mode remains a false "NEVER DIVERGED", which is noisy but
# safe. If a tab ever renders a live counter its stale frames stop scoring 0;
# verify that tab by opening the PNG rather than by lowering this number.

set -u
HERE="${0:A:h}"
PREFIX="${1:?usage: grux-sweep.sh <prefix> <tab>...}"
shift
FIRSTTAB="${1:?usage: grux-sweep.sh <prefix> <tab>...}"
OUT="${GRUX_SWEEP_OUT:-/tmp}"
ACK="$HOME/.grux/open-tab-ack.txt"
FIRE="$HOME/.grux/fire-open-tab"
THRESH=20000   # changed PIXELS, not percent. A FLOOR only: the real bar is
               # measured per run from idle animation noise. See the calibration
               # note below.
FAILED=0

mkdir -p "$OUT"
[ -z "$(pgrep -x Grux)" ] && { echo "Grux is not running" >&2; exit 1; }

WINID=""; WINW=""; PREV=""

# Bootstrap onto a tab that is NOT the first one being swept, ALWAYS, for two
# reasons. Grux is a menu-bar app that can be running with no window at all, in
# which case there is nothing to resolve or capture. And even when a window is
# open, whatever tab it happens to be showing might be the first tab requested,
# which would make the baseline identical to the first capture and hang that tab
# on "NEVER DIVERGED".
# Deliberately NOT settings. This bootstrap runs on every sweep, and a sweep is
# often re-run several times in a row, so whatever tab is chosen here is the one
# the owner keeps catching their app sitting on. Settings is the worst possible
# choice for that: it is the screen that looks like something went wrong. Chat
# is the app's normal landing surface and reads as idle rather than stuck.
BOOT="chat"; [ "$FIRSTTAB" = "chat" ] && BOOT="home"

# Resolve the window. winid.swift prints: <id>\t<W>x<H>\t<owner>\t<title>
#
# It only ever sees ON-SCREEN windows (CGWindowListCopyWindowInfo with
# .optionOnScreenOnly), so a Grux that is hidden with Cmd+H, minimised to the
# Dock, or running as a menu-bar app with its window closed resolves to nothing.
resolve_window() {
  local tries="$1" i line
  for i in $(seq 1 "$tries"); do
    line=$(xcrun swift "$HERE/winid.swift" Grux 2>/dev/null | head -1)
    if [ -n "$line" ]; then
      WINID=$(print -r -- "$line" | cut -f1)
      WINW=$(print -r -- "$line" | cut -f2 | cut -dx -f1)
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# The next three steps look fussy and the ORDER is load-bearing in both
# directions, which is why this is not a single resolve-then-fire.
#
# Firing must come BEFORE the hard failure, because the fire-open-tab trigger is
# what makes openLaunchWindow unhide, deminiaturise, or recreate the window. An
# earlier version resolved first and exited "no Grux window found" before ever
# writing $FIRE, so on a hidden or minimised Grux the sweep aborted instead of
# waking it, and the restore path it depends on was unreachable.
#
# Capturing PRE must come BEFORE firing, because the baseline is only trustworthy
# if we can prove the bootstrap actually repainted; that check needs a snapshot of
# what was on screen first. It also needs a window to exist to capture at all.
#
# So: look without aborting, snapshot only if there IS something to snapshot,
# fire, then resolve for real.
resolve_window 6

PRE=""
if [ -n "$WINID" ]; then
  PRE="$OUT/${PREFIX}-_pre.png"
  screencapture -o -x -l"$WINID" "$PRE" 2>/dev/null
  [ -f "$PRE" ] || PRE=""
fi

rm -f "$ACK"; print -n "$BOOT" > "$FIRE"
for i in $(seq 1 40); do
  [ -f "$ACK" ] && [ "$(cat "$ACK" 2>/dev/null)" = "$BOOT" ] && break
  sleep 0.1
done

[ -z "$WINID" ] && resolve_window 20

# Still nothing, so ACTIVATE the app from outside and look again.
#
# This step is not belt-and-braces, it is the one that actually works, and the
# reason is worth writing down because the obvious fix was wrong. When Grux is
# running with no window, the trigger DOES reach openLaunchWindow and a window
# IS created: CGWindowListCopyWindowInfo with .optionAll lists it at 1040x732,
# titled "Grux OS". It simply never becomes ON-SCREEN, so winid.swift, which
# asks for .optionOnScreenOnly, cannot see it.
#
# The cause is macOS activation policy, not window state. A background app
# cannot pull itself to the front any more: NSApp.activate(ignoringOtherApps:)
# does not grant that, so makeKeyAndOrderFront leaves the window created but
# never surfaced. An earlier attempt to fix this in openLaunchWindow with
# NSApp.unhide and win.deminiaturize could not have worked, because the window
# was neither hidden nor minimized. Measured: `open -b com.gruxai.grux` brought the
# SAME window id on screen immediately.
#
# So the driver activates the app, which is something an external tool is
# allowed to do and the app is not.
if [ -z "$WINID" ]; then
  open -b com.gruxai.grux 2>/dev/null
  resolve_window 20
fi
[ -z "$WINID" ] && { echo "no Grux window found (Grux is running, the trigger fired and the app was activated, but no window ever came on screen)" >&2; exit 1; }

# Where the detail pane starts, as a fraction of width. The nav rail is a fixed
# 240pt (GruxLayout.navRail) at every window size, so this fraction MUST be
# derived rather than hardcoded: the 0.32 that is right at the 840pt floor
# throws away a third of the detail pane at 2400pt and makes real switches look
# like small ones.
RAILFRAC=$(python3 -c "print(min(0.6,(240+8)/max(1.0,float($WINW))))")
echo "window $WINID, ${WINW}pt wide, comparing from ${RAILFRAC} of width"

# Baseline BEFORE the first switch. Without it the first tab has nothing to
# compare against, so it short-circuits and returns whatever was already on
# screen. Do not remove this: dropping it is silent, and the run still prints a
# confident line for a tab it never actually opened.
#
# The baseline itself has to be VERIFIED, which is the subtler trap and it cost a
# wrong screenshot. Capturing right after the bootstrap ack is not enough: the
# ack fires when requestedTab is set, so the previous tab is still painted. A run
# that began on Home, bootstrapped to Chat, and then asked for featureReview
# captured Home as its baseline, and the first Chat frame differed from it by 6.8
# million pixels, so a Chat screenshot was confidently certified as
# featureReview. The tab had never switched at all.
#
# So the bootstrap is treated exactly like a real tab capture: snapshot what is
# on screen FIRST (done above, before the fire), then wait for the frame to
# actually differ from that snapshot. If it never differs, the app was already
# sitting on the bootstrap tab, and the current frame is the right baseline
# anyway.
#
# When PRE is empty there was no window to snapshot, so the window we are now
# looking at was just created or unhidden by the bootstrap and is already showing
# BOOT. There is nothing to diff against and nothing to prove: the first settled
# capture IS the bootstrap tab.
PREV="$OUT/${PREFIX}-_baseline.png"
BOOTOK=""
for i in $(seq 1 20); do
  sleep 0.2
  screencapture -o -x -l"$WINID" "$PREV" 2>/dev/null
  if [ -z "$PRE" ]; then BOOTOK=1; break; fi
  BD=$(python3 "$HERE/framediff.py" "$PRE" "$PREV" "$RAILFRAC" 2>/dev/null || echo 0)
  if [ "${BD:-0}" -ge "$THRESH" ]; then BOOTOK=1; break; fi
done
[ -n "$PRE" ] && rm -f "$PRE"
[ -f "$PREV" ] || PREV=""
[ -n "$BOOTOK" ] && echo "baseline on $BOOT (switched)" || echo "baseline on $BOOT (already there)"

# Measure how much the screen changes when NOTHING changes, and raise the bar
# above it.
#
# THRESH was a hand-picked 20000, chosen when a stale frame was believed to
# measure exactly 0. That is only true of a STATIC tab. Home animates: the orb
# glows and the starfield drifts. At the 1040pt default that motion stayed under
# the constant and nobody noticed. At 2400pt the same motion changed 21,145
# pixels all by itself, cleared the 20000 bar on the first try, and the sweep
# wrote a file called `ready2400-chat.png` containing the Home tab, with a
# confident "chat (21145 px)" on stdout. The tab had never switched.
#
# A constant cannot know how animated a given tab is at a given window size, so
# it is measured instead: two captures of the SAME tab, back to back, is the
# noise floor. A real switch has to clear it by a wide margin. Observed
# separation is enormous (noise in the tens of thousands, real switches in the
# millions), so the multiplier is not a close call.
# WAIT FOR THE BASELINE TO STOP MOVING, then measure what is left.
#
# The 21,145px false pass was not perpetual animation, which was the first
# guess and is worth recording as wrong. It was TRANSIENT LOAD. That sweep ran
# eight seconds after launch, while Home was still filling in its briefing and
# its agenda, so the baseline was captured mid-populate and every later frame of
# the SAME tab differed from it. Re-running minutes later measures 0.
#
# That distinction matters, because a one-shot noise sample cannot see it: taken
# early it reads high, taken late it reads 0, and neither tells you which you
# got. Settling does not have that problem. Capture until two consecutive frames
# of the baseline tab agree, and the baseline is then a frame the app has
# actually finished drawing. A stale frame afterwards scores near 0 against it
# and cannot clear the bar.
#
# The residual is still measured and still raises the threshold, for the case
# this does not cover: a tab with a genuinely permanent animation, which never
# settles and would otherwise spin here until the loop gives up.
SETTLEIMG="$OUT/${PREFIX}-_settle.png"
NOISE=0
SETTLED=""
if [ -n "$PREV" ]; then
  for i in $(seq 1 25); do
    sleep 0.2
    screencapture -o -x -l"$WINID" "$SETTLEIMG" 2>/dev/null
    NOISE=$(python3 "$HERE/framediff.py" "$PREV" "$SETTLEIMG" "$RAILFRAC" 2>/dev/null || echo 0)
    # Always keep the NEWER frame as the baseline. It is the same tab and closer
    # in time to the switch that follows.
    mv -f "$SETTLEIMG" "$PREV" 2>/dev/null
    if [ "${NOISE:-0}" -eq 0 ]; then SETTLED=1; break; fi
  done
  rm -f "$SETTLEIMG"
fi
FLOOR=$(( NOISE * 8 ))
[ "$FLOOR" -gt "$THRESH" ] && THRESH="$FLOOR"
if [ -n "$SETTLED" ]; then
  echo "baseline settled, residual ${NOISE} px, switch threshold ${THRESH} px"
else
  echo "baseline NEVER SETTLED, residual ${NOISE} px, switch threshold raised to ${THRESH} px"
fi

for TAB in "$@"; do
  rm -f "$ACK"; print -n "$TAB" > "$FIRE"
  for i in $(seq 1 30); do
    [ -f "$ACK" ] && [ "$(cat "$ACK" 2>/dev/null)" = "$TAB" ] && break
    sleep 0.1
  done

  # A tab key may carry a pane after a colon ("settings:models"). Colons are
  # legal in a POSIX filename but Finder renders them as slashes, so the file
  # name uses a dash while the TRIGGER still gets the real key.
  SAFE="${TAB//:/-}"
  DEST="$OUT/${PREFIX}-${SAFE}.png"; OK=""; D=0
  for i in $(seq 1 14); do
    sleep 0.15
    screencapture -o -x -l"$WINID" "$DEST" 2>/dev/null
    if [ -z "$PREV" ]; then OK=1; break; fi
    D=$(python3 "$HERE/framediff.py" "$PREV" "$DEST" "$RAILFRAC" 2>/dev/null || echo 0)
    if [ "${D:-0}" -ge "$THRESH" ]; then
      # DIFFERENT is not the same as ARRIVED. A big diff can come from an
      # intermediate frame: a scroll-to-anchor completing, a list populating, a
      # pane sliding. Accepting the first frame that clears the bar captured the
      # Settings capabilities pane, scrolled 30px, and filed it as the Models
      # pane on a 229,449px "switch".
      #
      # So the frame must also SETTLE: capture again and require the two to
      # agree before believing the destination has been reached. Same reasoning
      # as the baseline settle above, applied to the thing being certified.
      SETTLE="$OUT/${PREFIX}-_s.png"
      for j in $(seq 1 12); do
        sleep 0.15
        screencapture -o -x -l"$WINID" "$SETTLE" 2>/dev/null
        M=$(python3 "$HERE/framediff.py" "$DEST" "$SETTLE" "$RAILFRAC" 2>/dev/null || echo 0)
        mv -f "$SETTLE" "$DEST" 2>/dev/null
        [ "${M:-0}" -eq 0 ] && break
      done
      rm -f "$SETTLE"
      # Re-measure against the previous tab AFTER settling, because the settled
      # frame may be a different one from the frame that first cleared the bar.
      D=$(python3 "$HERE/framediff.py" "$PREV" "$DEST" "$RAILFRAC" 2>/dev/null || echo 0)
      if [ "${D:-0}" -ge "$THRESH" ]; then OK=1; break; fi
    fi
  done

  if [ -n "$OK" ]; then
    PREV="$DEST"; echo "  ${TAB} (${D} px)"
  else
    # Rename rather than leave it. The old version printed a warning and left a
    # file named `<prefix>-<tab>.png` sitting on disk holding the WRONG tab, so
    # anything that globbed the output directory afterwards picked up a
    # confidently mislabelled screenshot and the warning was long gone from
    # stdout. A file that says it is Chat must be Chat.
    mv -f "$DEST" "$OUT/${PREFIX}-${SAFE}.UNVERIFIED.png" 2>/dev/null
    echo "  ${TAB}: NEVER DIVERGED (best ${D} px, needed ${THRESH}), kept as ${PREFIX}-${SAFE}.UNVERIFIED.png"
    FAILED=$((FAILED + 1))
  fi
done

# Drop the baseline so a glob over the output directory cannot mistake it for a
# tab capture.
rm -f "$OUT/${PREFIX}-_baseline.png"

# Put the app back somewhere sane. A verification sweep drives the OWNER'S live
# app, so leaving it parked on whatever tab happened to be last in the argument
# list is not a neutral act: it looks exactly like the app froze there. Ending
# on Home is the difference between "the sweep finished" and "my app is stuck".
RESTORE="${GRUX_SWEEP_RESTORE:-home}"
rm -f "$ACK"; print -n "$RESTORE" > "$FIRE"
for i in $(seq 1 30); do
  [ -f "$ACK" ] && [ "$(cat "$ACK" 2>/dev/null)" = "$RESTORE" ] && break
  sleep 0.1
done
echo "restored to $RESTORE"

# Exit non-zero when any tab failed to verify. Without this a caller that checks
# the exit code, which is the normal thing to do, reads a run that mislabelled
# every tab as a clean success.
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED tab(s) UNVERIFIED"
  exit 1
fi
