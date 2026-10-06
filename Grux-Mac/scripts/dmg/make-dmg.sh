#!/bin/bash
# Wrap a notarized Grux.app in Grux.dmg: the one file every Download button points at.
#
#   ASC_KEY=/path/AuthKey.p8 ASC_KEY_ID=... ASC_ISSUER=... \
#     bash Grux-Mac/scripts/dmg/make-dmg.sh /path/to/notarized/Grux.app [out-dir]
#
# Why a DMG and a stable name. Until 3.0 the release shipped zips and the site linked the
# releases page, so a stranger had to pick the app out of release notes, two identical
# zips and a source archive. A disk image that opens on "Drag Grux into Applications" is
# what a Mac user expects, and gruxai.com links
#   https://github.com/dotcomjack/grux/releases/latest/download/Grux.dmg
# directly. That URL only works if EVERY release uploads an asset named exactly Grux.dmg,
# and the site's deploy refuses when it does not resolve.
#
# The app inside must already be notarized and stapled (build.sh with GRUX_RELEASE=1
# GRUX_NOTARIZE=1). This script signs the image itself with the same Developer ID,
# notarizes and staples it, and refuses to finish unless Gatekeeper accepts both.
# Credentials are the same three variables build.sh reads; nothing is hardcoded.
set -euo pipefail
APP=${1:?path to a notarized Grux.app}
OUT=${2:-$PWD}
HERE=$(cd "$(dirname "$0")" && pwd)
: "${ASC_KEY:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER:?}"

spctl -a -t exec "$APP" 2>/dev/null || { echo "FATAL: $APP is not accepted by Gatekeeper; notarize the app first"; exit 1; }
SIGN_ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
[[ -n "$SIGN_ID" ]] || { echo "FATAL: no Developer ID Application identity on this Mac"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q dmgbuild pillow
(cd "$WORK" && "$WORK/venv/bin/python" "$HERE/background.py")
DMG="$OUT/Grux.dmg"
"$WORK/venv/bin/dmgbuild" -s "$HERE/settings.py" -D app="$APP" -D background="$WORK/background.tiff" "Grux" "$DMG"

codesign --sign "$SIGN_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# The two checks that speak for a stranger's Mac: the image, and the app inside it.
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | grep -q accepted \
  || { echo "FATAL: Gatekeeper rejects $DMG"; exit 1; }
MNT=$(hdiutil attach -nobrowse -readonly "$DMG" | tail -1 | awk -F'\t' '{print $NF}')
spctl -a -t exec "$MNT/Grux.app" 2>/dev/null || { hdiutil detach -quiet "$MNT"; echo "FATAL: the app inside is rejected"; exit 1; }
hdiutil detach -quiet "$MNT"

shasum -a 256 "$DMG"
echo "Upload it under exactly this name: gh release upload <tag> \"$DMG\""
