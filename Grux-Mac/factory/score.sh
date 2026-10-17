#!/bin/bash
set -euo pipefail
marker="factory/wave1-marker.txt"
if [[ ! -f "$marker" ]]; then
  exit 1
fi
got=$(cat "$marker")
if [[ "$got" != "wave-1" ]]; then
  exit 1
fi
exit 0
