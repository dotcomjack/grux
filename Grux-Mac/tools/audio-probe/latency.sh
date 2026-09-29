#!/usr/bin/env bash
# Resolve this script's own directory so the probes can live anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/Library/Application Support/Grux/wake.log"
ts_ms() { python3 -c "
import sys,datetime
t=sys.argv[1]
h,m,s=t.split(':')
print(int((int(h)*3600+int(m)*60+float(s))*1000))" "$1"; }

trial() {
  local phrase="$1"
  local mark; mark=$(wc -l < "$LOG")
  say -r 175 "$phrase"                      # blocks until the last syllable
  local spoken_end; spoken_end=$(python3 -c "
import datetime;n=datetime.datetime.now();print(int((n.hour*3600+n.minute*60+n.second)*1000+n.microsecond/1000))")
  # wait up to 12s for a decision line
  local line=""
  for i in $(seq 1 120); do
    line=$(tail -n +$((mark+1)) "$LOG" | grep -E "always on\): [^ ]+ executed" | head -1)
    [ -n "$line" ] && break
    sleep 0.1
  done
  if [ -z "$line" ]; then
    printf '%-22s  %s\n' "$phrase" "NO EXECUTION in 12s"
    tail -n +$((mark+1)) "$LOG" | grep -E "ambient chunk:|always on\)" | head -2 | sed 's/^/                          /'
    return
  fi
  local t; t=$(echo "$line" | awk '{print $1}')
  local exec_ms; exec_ms=$(ts_ms "$t")
  local delta=$((exec_ms - spoken_end))
  local prov; prov=$(echo "$line" | grep -oE "(local|jev):" | tr -d ':')
  local dms; dms=$(echo "$line" | grep -oE "[0-9]+ms" | head -1)
  local cmd; cmd=$(echo "$line" | sed -E 's/.*always on\): ([^ ]+) executed.*/\1/')
  printf '%-22s  end-to-exec %5dms   decision %-7s via %-5s  -> %s\n' "$phrase" "$delta" "$dms" "$prov" "$cmd"
}

ORIG=$(osascript -e 'output volume of (get volume settings)')
osascript -e "set volume output volume 60" >/dev/null
echo "Measuring: last syllable spoken  ->  command executed"
echo
for p in "open calendar" "open notes" "open documents" "open contacts" "open tasks"; do
  trial "$p"
  sleep 3
done
osascript -e "set volume output volume $ORIG" >/dev/null
echo
echo "(volume restored to $ORIG)"
