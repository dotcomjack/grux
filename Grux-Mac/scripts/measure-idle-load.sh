#!/usr/bin/env bash
# Idle load, measured the same way every time (Phase R acceptance criterion 7):
# wait until the app has 90 seconds of uptime, then take 12 CPU readings 5 seconds
# apart with `top`, which reports each interval on its own (ps %cpu is a decaying
# average and smears a fix into the reading before it). Prints each reading, the
# mean, and resident memory.
#
#   scripts/measure-idle-load.sh [label]
set -euo pipefail
label="${1:-idle}"
pid="$(pgrep -f 'Grux.app/Contents/MacOS/Grux$' | head -1 || true)"
[[ -n "$pid" ]] || { echo "Grux is not running" >&2; exit 1; }

uptime_s() {
  local e; e="$(ps -o etime= -p "$pid" | tr -d ' ')"
  local d=0 h=0 m=0 s=0
  if [[ "$e" == *-* ]]; then d="${e%%-*}"; e="${e#*-}"; fi
  IFS=: read -r a b c <<<"$e"
  if [[ -n "${c:-}" ]]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$s ))
}
while (( $(uptime_s) < 90 )); do sleep 5; done

# 13 frames: top's first frame has no interval behind it, so it is dropped.
readings="$(top -l 13 -s 5 -pid "$pid" -stats cpu 2>/dev/null \
  | awk '/^%CPU/{getline; print $1}' | tail -12)"
mem_mb="$(( $(ps -o rss= -p "$pid" | tr -d ' ') / 1024 ))"
mean="$(awk '{s+=$1; n++} END {printf "%.1f", s/n}' <<<"$readings")"
echo "label=$label pid=$pid samples=$(wc -l <<<"$readings" | tr -d ' ') mean_cpu=${mean}% rss=${mem_mb}MB"
echo "readings: $(tr '\n' ' ' <<<"$readings")"
