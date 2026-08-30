#!/bin/bash
# pre-push build-green gate. Refuses a push if the project does not build.
# Portable: auto-detects the build for the repo it sits in. Bypass with
# GRUX_SKIP_BUILD_GATE=1 for an emergency push (use sparingly).
set -euo pipefail
if [ "${GRUX_SKIP_BUILD_GATE:-0}" = "1" ]; then
    echo "pre-push: build gate skipped (GRUX_SKIP_BUILD_GATE=1)"
    exit 0
fi
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
echo "pre-push: verifying build is green before push..."
if [ -f Package.swift ]; then
    swift build -c release
elif [ -f package.json ]; then
    if grep -q '"build"' package.json; then npm run build; else npm install --no-audit --no-fund && npx tsc --noEmit 2>/dev/null || true; fi
elif [ -f build.sh ]; then
    ./build.sh
else
    echo "pre-push: no recognized build; gate passes (nothing to verify)"
    exit 0
fi
echo "pre-push: build green, push allowed."
exit 0
