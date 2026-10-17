#!/bin/zsh
# Launch smoke check: does a built Grux.app open an audio device at launch?
#
#   Grux-Mac/tools/audio-probe/launch-audio-unit.sh /path/to/Grux.app [seconds]
#
# Launches the app, waits (15 s by default), quits it, and reads the app's OWN
# unified log by pid for CoreAudio building an AUHAL ("Selecting device N from
# constructor"). Exits 1 if it found one, 0 if not, 2 if it could not measure.
#
# Why: on a clean Mac, merely building an output AUHAL at launch made coreaudiod
# ask TCC for the microphone, so the mic prompt appeared before any Grux window
# (W4 build 10, 2026-10-13). The unit tests count engines built through
# AudioFactory; this catches the same class on the shipped binary, whatever
# built the unit. Proven both ways on a test Mac: build 10 printed one
# constructor line and exited 1, build 11 printed none and exited 0.
#
# Reads `log` by absolute path: zsh has a `log` builtin that shadows it, and
# through that builtin every count reads zero, which looks like a pass.
set -u
APP=${1:?usage: launch-audio-unit.sh /path/to/Grux.app [seconds]}
WAIT=${2:-15}
BIN="$APP/Contents/MacOS/Grux"
[[ -x $BIN ]] || { echo "LAUNCH-AUDIO: no executable at $BIN"; exit 2; }
pgrep -x Grux >/dev/null && { echo "LAUNCH-AUDIO: quit the running Grux first, so the pid read is this launch"; exit 2; }

start=$(date "+%Y-%m-%d %H:%M:%S")
open -g -j -n "$APP"
pid=""
for i in $(seq 1 40); do pid=$(pgrep -nf "$BIN" | head -1); [[ -n $pid ]] && break; sleep 0.25; done
[[ -n $pid ]] || { echo "LAUNCH-AUDIO: the app did not start"; exit 2; }
sleep $WAIT
osascript -e 'quit app id "com.gruxai.grux"' >/dev/null 2>&1
for i in $(seq 1 50); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
kill -0 $pid 2>/dev/null && kill $pid
sleep 2

lines=$(/usr/bin/log show --start "$start" --style compact \
  --predicate "processID == $pid AND subsystem == \"com.apple.coreaudio\"" 2>/dev/null)
all=$(/usr/bin/log show --start "$start" --style compact --predicate "processID == $pid" 2>/dev/null | grep -c "Grux\[$pid")
# A log that holds nothing for the pid cannot say "no audio unit": it measured nothing.
(( all > 0 )) || { echo "LAUNCH-AUDIO: no log lines for pid $pid, so nothing was measured"; exit 2; }
built=$(print -r -- "$lines" | grep -c "from constructor")
echo "LAUNCH-AUDIO: pid=$pid wait=${WAIT}s log_lines=$all auhal_constructor=$built"
if (( built > 0 )); then
  print -r -- "$lines" | grep "from constructor\|IsDeviceUsable" | cut -c1-200
  echo "LAUNCH-AUDIO: FAIL, an audio unit was built at launch"
  exit 1
fi
echo "LAUNCH-AUDIO: PASS"
