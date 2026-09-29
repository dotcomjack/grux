#!/usr/bin/env bash
# Resolve this script's own directory so the probes can live anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# One arm of the A/B. Records the microphone with ffmpeg (a real third-party
# consumer) for 24s while a tone plays, launches Grux at t=6s, and reports
# what the recorder captured plus which VPIO decision Grux actually made.
ARM="$1"
LOG="$HOME/Library/Application Support/Grux/wake.log"
OUT=""$DIR"/arm-$ARM.wav"

osascript -e 'tell application "Grux" to quit' >/dev/null 2>&1
for i in $(seq 1 24); do pgrep -x Grux >/dev/null || break; sleep 0.5; done
pgrep -x Grux >/dev/null && { kill -9 "$(pgrep -x Grux)"; sleep 2; }
MARK=$(wc -l < "$LOG")
sleep 2

echo "[$ARM] recording 24s from the real microphone with ffmpeg; Grux launches at t=6s"
afplay "$DIR"/tone30.wav >/dev/null 2>&1 &
APID=$!
ffmpeg -hide_banner -loglevel error -f avfoundation -i ":1" -t 24 -y "$OUT" >/dev/null 2>&1 &
FPID=$!
sleep 6
echo "[$ARM] t=6s launching Grux"
open -a /Applications/Grux.app
wait $FPID
kill $APID 2>/dev/null

echo "[$ARM] Grux's own decision this run:"
tail -n +$((MARK+1)) "$LOG" | grep -E "VPIO BYPASSED|VoiceProcessingIO ENABLED|engine up" | head -4 | sed 's/^/    /'
echo "[$ARM] what the recorder captured:"
python3 "$DIR"/wavstat.py "$OUT" | sed 's/^/    /'
