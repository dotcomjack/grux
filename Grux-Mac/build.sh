#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Grux build / sign pipeline
# Security stance:
#   • Not sandboxed, needs ScreenCaptureKit + AppleEvents + Mic.
#     Filesystem access from Claude is gated by Swift code in
#     FilesystemTool.swift (allowlist + denylist + rate limit
#     + audit log). See SECURITY.md.
#   • Hardened runtime ON (--options runtime).
#   • API keys live in macOS Keychain (service com.gruxai.grux),
#     never on disk.
#   • Audit log at ~/Library/Application Support/Grux/fs-audit.log.
# ============================================================

cd "$(dirname "$0")"

# Assemble the bundle in /tmp because iCloud Drive auto-injects
# com.apple.FinderInfo / fileprovider xattrs that block codesign.
STAGE="/tmp/grux-build"
APP="$STAGE/Grux.app"
BIN_NAME="Grux"

echo "[1/7] swift build (release)…"
# Drop resource bundles from the previous build FIRST. SwiftPM regenerates the
# ones the current dependency graph still needs and never deletes the ones it
# does not, so a bundle from a removed dependency survives forever and step 2
# copies every *.bundle it finds straight into the app.
#
# That is not cosmetic. PostHog was removed from Package.swift and
# Package.resolved, the binary links none of it, and PostHog_PostHog.bundle was
# STILL being shipped inside Grux.app months later, carrying a
# PrivacyInfo.xcprivacy that declares data collection by a dependency this app
# no longer has. For an app whose whole premise is that it phones nobody, a
# stale privacy manifest is a false declaration about exactly the thing users
# are being asked to trust.
if compgen -G ".build/release/*.bundle" > /dev/null; then
    rm -rf .build/release/*.bundle
    echo "   pruned stale resource bundles (SwiftPM rebuilds the live ones)"
fi
swift build -c release --arch arm64
# The CLI is a separate product, so the default build does not produce it.
swift build -c release --arch arm64 --product grux-cli

# Scrub any stale ./build/ bundle. A prior revision of this script wrote
# there; LaunchServices registers the unsigned copy under com.gruxai.grux and
# TCC ends up binding Microphone / SpeechRecognition grants to THAT cdhash.
# Every subsequent launch of the properly-signed /Applications/Grux.app then
# fails the csreq check and re-prompts. See audit 2026-04-24.
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [[ -d "./build" ]]; then
    if [[ -d "./build/Grux.app" ]]; then
        "$LSREG" -u "./build/Grux.app" 2>/dev/null || true
    fi
    rm -rf "./build"
    echo "   scrubbed stale ./build/ (would poison TCC with an unsigned cdhash grant)"
fi

echo "[2/7] Assembling .app bundle at ${APP}…"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"

# The CLI ships INSIDE the bundle, and it is called grux-cli in there for the same reason
# it is called that in .build.
#
# APFS is case-insensitive. Contents/MacOS/grux IS Contents/MacOS/Grux, so copying the CLI
# in under the name `grux` OVERWRITES THE APP BINARY. That is not a hypothetical: it
# happened on 2026-08-28, on the second attempt, after a comment in this very file claimed
# there was no ambiguity inside the bundle. The 57 MB app binary became a 1.7 MB CLI and
# nothing said so.
#
# What caught it was the leak gate's positive control, three steps later, reporting that it
# could no longer find the string "Ollama" in the bundle. A scan that cannot find something
# it knows is present is a scan of the wrong thing, and that is exactly what it had become.
# The gate is doing its job; the lesson is that a case-insensitive filesystem does not care
# which directory you are in.
#
# The command a person types is still `grux`, because the PATH entry is a symlink with that
# name pointing at this file. A symlink and its target may differ in case freely.
CLI_SRC=".build/release/grux-cli"
if [[ ! -f "$CLI_SRC" ]]; then
    echo "   FATAL: $CLI_SRC missing. The grux CLI did not build."
    exit 1
fi
cp "$CLI_SRC" "$APP/Contents/MacOS/grux-cli"
chmod +x "$APP/Contents/MacOS/grux-cli"
# Prove the app binary is still the app binary. The gate below would catch a clobber too,
# but it would say "Ollama is missing", and this says what actually happened.
APP_BIN_SIZE=$(wc -c < "$APP/Contents/MacOS/$BIN_NAME" | tr -d ' ')
CLI_SIZE=$(wc -c < "$APP/Contents/MacOS/grux-cli" | tr -d ' ')
if [[ "$APP_BIN_SIZE" -eq "$CLI_SIZE" ]]; then
    echo "   FATAL: $APP/Contents/MacOS/$BIN_NAME and grux-cli are the same file."
    echo "          A case-insensitive filesystem collapsed them. Do not name the CLI grux here."
    exit 1
fi
echo "   bundled the grux CLI ($CLI_SIZE bytes, app binary still $APP_BIN_SIZE)"

# Copy Info.plist
cp Info.plist "$APP/Contents/Info.plist"

# LICENCES SHIP WITH THE THING PEOPLE DOWNLOAD, not only with the repository.
#
# Grux is MIT, whose single obligation is that the notice travels with the
# software, and six of its eight dependencies are Apache 2.0, whose section 4(d)
# additionally requires reproducing any NOTICE file in redistributions.
# swift-crypto and swift-asn1 both ship one and both are redistributed inside
# this bundle as .bundle resources.
#
# Measured 2026-08-23, before this block existed: the app carried zero licence
# files while gruxai.com told visitors "the licence text is in the app bundle".
# The notices are GENERATED from Package.resolved, so a new dependency cannot
# quietly ship uncredited, and ThirdPartyNoticesTests fails when this file drifts.
echo "  bundling licences…"
python3 scripts/gen-third-party-notices.py >/dev/null || {
    echo "   FATAL: could not generate THIRD-PARTY-NOTICES.md"; exit 1;
}
cp ../LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp ../THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"

# Copy app icon (regenerate from tools/MakeIcon.swift if missing)
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "  AppIcon.icns missing, building from tools/MakeIcon.swift…"
    ./tools/build-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Copy Home tab hero assets (aurora backdrop + orb plate/cutout). HomeAssets
# loads these via Bundle.main from Contents/Resources/. Missing files are
# tolerated (the hero falls back to the brand gradient), so guard with || true.
cp Resources/Home/home-hero.jpg Resources/Home/home-orb-0.png Resources/Home/home-orb-cutout.png "$APP/Contents/Resources/" 2>/dev/null || true

# Copy any SwiftUI/SwiftPM generated bundles (SwiftUI previews, modular resources) if present
if compgen -G ".build/release/*.bundle" > /dev/null; then
    cp -R .build/release/*.bundle "$APP/Contents/Resources/" || true
fi

# Redact the builder's home directory out of the binary, BEFORE signing.
#
# SwiftPM generates a `resource_bundle_accessor.swift` per target with resources
# and hardcodes the ABSOLUTE build path as a fallback:
#
#   let buildPath = "/Users/<whoever-built-it>/.../swift-transformers_Hub.bundle"
#
# That string ships. Anyone who runs `strings` on the download reads the
# builder's username and their directory layout, which for an open source
# release is a gratuitous leak from a line that never executes: the bundle is
# copied into Contents/Resources, so `mainPath` always resolves first and the
# fallback is dead code.
#
# Overwritten in place with an equal-length placeholder so every offset in the
# Mach-O stays valid. Must run before codesign, or the signature is invalidated.
echo "[3/7] Redact builder paths from the binaries…"
# BOTH Mach-O binaries, not just the app.
#
# The CLI joined the bundle on 2026-08-28 and the redaction still named only the app, so
# grux-cli shipped 98 embedded copies of the builder's home directory. The leak gate caught
# it, which is what it is for, but the shape of the mistake is worth naming: a step that
# hardcodes ONE artifact silently stops covering the bundle the moment the bundle grows.
for TARGET in "$APP/Contents/MacOS/Grux" "$APP/Contents/MacOS/grux-cli"; do
python3 - "$TARGET" <<'REDACT'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = p.read_bytes()
# EVERY absolute home path, not just the ones under .build. The first version
# required `.build/` and left 518 source-file paths from debug info behind,
# and `strings` reported zero because those live in structured debug sections
# it does not surface. A raw byte scan is the only honest check here.
pat = re.compile(rb"/Users/[A-Za-z0-9._-]+(?:/[^\x00\n\"]{0,200})?")
hits = list(pat.finditer(data))
if not hits:
    print("   no builder paths embedded")
    raise SystemExit(0)
out = bytearray(data)
for m in hits:
    # Same byte length, so nothing downstream shifts. Points at a path that
    # cannot exist, which is the honest state: this fallback must never be used.
    filler = b"/nonexistent/redacted-build-path"
    span = m.end() - m.start()
    out[m.start():m.end()] = (filler * (span // len(filler) + 1))[:span]
p.write_bytes(bytes(out))
print(f"   redacted {len(hits)} embedded build path(s)")
REDACT
done

echo "[3b/7] Leak gate: scan the assembled bundle…"
# Source-level guards cannot see what ships. This one reads the artifact.
# Runs BEFORE codesign on purpose: signing embeds the signing identity into the
# signature blob, which is public in every signed Mac app and is a cryptographic
# requirement rather than a leak, so scanning first means no exemption is needed.
# Rationale, the banned list and `--self-test` all live in the script.
"$(dirname "$0")/tools/leak-gate.py" "$APP"

echo "[4/7] Codesign with stable identity (TCC grants persist across rebuilds)…"
# Stage is on local disk (not iCloud) so xattrs stay clean.
xattr -cr "$APP"
# TWO IDENTITIES, because a dev build and a distributable build have opposite
# requirements and one certificate cannot satisfy both.
#
# DEV (default): the pinned Apple Development cert. macOS keys every TCC grant to
# the signing identity, so holding this stable is what keeps microphone, screen
# recording and accessibility from re-prompting on every rebuild.
#
# RELEASE (GRUX_RELEASE=1): "Developer ID Application", which is the ONLY kind of
# certificate Apple will notarize. This is not a preference. Until 2026-08-17 the
# GRUX_NOTARIZE=1 path uploaded an Apple-Development-signed app to notarytool,
# which Apple rejects outright, so the release path could never have worked and
# nobody had run it. Measured on the dev build: `spctl -a` says "rejected" and
# `stapler validate` says no ticket, which is exactly what a stranger's Mac would
# conclude on download.
#
# A release build deliberately does NOT install to /Applications, because signing
# with a different identity revokes the dev install's TCC grants. It leaves a
# distributable artifact and stops.
if [[ "${GRUX_RELEASE:-0}" == "1" ]]; then
    SIGN_ID=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    if [[ -z "$SIGN_ID" ]]; then
        echo "   FATAL: GRUX_RELEASE=1 but no 'Developer ID Application' certificate is installed."
        echo "          Apple will not notarize anything signed with any other kind."
        exit 1
    fi
    echo "   release identity: $SIGN_ID"
else
    # Overridable, because this default is one specific machine's certificate and
    # nobody else has it. Without the override a contributor's build silently
    # fell through to the ad-hoc branch below and re-prompted for microphone,
    # screen recording and accessibility on every single rebuild, with nothing
    # anywhere telling them there was a way out. Their own identity hash comes
    # from `security find-identity -v -p codesigning`.
    SIGN_ID="${GRUX_SIGN_ID:-B60927A5F6DB390F63C3ED6402A110179B92A8D6}"
fi
# `--timestamp` (instead of =none) embeds an Apple secure timestamp so the
# signature, and therefore TCC grants bound to it, survive dev-cert
# rotation. It is also required for notarization. --deep is kept because SwiftPM
# generates non-bundle-format `.bundle` resource directories (e.g.
# swift-transformers_Hub.bundle) that codesign rejects when signed individually;
# --deep traverses and signs only the real code inside the app wrapper.
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" --entitlements Grux.entitlements --options runtime --timestamp "$APP"
else
    echo "  (stable identity missing, falling back to ad-hoc, permissions will re-prompt)"
    codesign --force --deep --sign - --entitlements Grux.entitlements --options runtime --timestamp=none "$APP"
fi

echo "[4/7] Verify signature + hardened runtime…"
codesign --verify --verbose=2 "$APP"
# Dump entitlements (mostly for audit log / human inspection). The app-sandbox
# key SHOULD be present and false, we intentionally run unsandboxed.
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" || true
HARDENED=$(codesign -d -v "$APP" 2>&1 | grep -o 'flags=0x[0-9a-f]* *(.*)' | head -1)
echo "   signed with flags: ${HARDENED:-unknown}"

echo "[5/7] Notarize (optional)…"
if [[ "${GRUX_NOTARIZE:-0}" == "1" ]]; then
    # Refuse rather than waste a round trip. Apple notarizes only Developer ID
    # signed code, so notarizing a dev-signed build is a guaranteed rejection,
    # and that is precisely what this path used to attempt.
    if [[ "${GRUX_RELEASE:-0}" != "1" ]]; then
        echo "   FATAL: GRUX_NOTARIZE=1 requires GRUX_RELEASE=1."
        echo "          Apple only notarizes Developer ID signed code. Without it this"
        echo "          uploads an Apple-Development-signed app and is rejected."
        exit 1
    fi
    # TWO WAYS TO AUTHENTICATE, and the API key is preferred.
    #
    # An app-specific password requires a human to sign in to appleid.apple.com,
    # pass 2FA and generate one by hand, which makes notarization a step nobody
    # can automate and a credential that sits in someone's clipboard. An App
    # Store Connect API key is a file, works unattended, and can be revoked
    # without touching the Apple ID itself.
    #
    # Nothing is hardcoded here: a key id and an issuer uuid identify a specific
    # developer account, and this script is published.
    if [[ -n "${ASC_KEY:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER:-}" ]]; then
        if [[ ! -f "$ASC_KEY" ]]; then
            echo "   FATAL: ASC_KEY is set but \$ASC_KEY does not exist."
            exit 1
        fi
        NOTARY_AUTH=(--key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER")
        echo "   auth: App Store Connect API key"
    elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
        echo "   auth: Apple ID and app-specific password"
    else
        echo "   FATAL: no notarization credentials."
        echo "          Preferred: ASC_KEY (path to a .p8), ASC_KEY_ID, ASC_ISSUER."
        echo "          Or:        APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID."
        exit 1
    fi

    echo "[notarize] uploading to Apple for notarization..."
    ZIP="$STAGE/Grux.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # The only check that speaks for a stranger's Mac. A stapled ticket that
    # Gatekeeper still rejects is not a shippable build.
    if spctl -a -vv -t exec "$APP" 2>&1 | grep -q "accepted"; then
        echo "   Gatekeeper: accepted"
    else
        echo "   FATAL: notarized and stapled, but Gatekeeper still rejects this build."
        spctl -a -vv -t exec "$APP" 2>&1 | head -3
        exit 1
    fi
elif [[ "${GRUX_RELEASE:-0}" == "1" ]]; then
    echo "   (release-signed but NOT notarized, a stranger's Mac will still refuse it;"
    echo "    set GRUX_NOTARIZE=1 with APPLE_ID / APPLE_APP_PASSWORD / APPLE_TEAM_ID)"
else
    echo "   (notarize skipped, needs GRUX_RELEASE=1 GRUX_NOTARIZE=1 plus Apple creds)"
fi

# A release build is a distributable artifact, not an install. Signing with the
# Developer ID identity revokes the dev install's TCC grants, so overwriting
# /Applications here would make every release build cost three permission
# re-grants for no reason. Leave the artifact and stop.
if [[ "${GRUX_RELEASE:-0}" == "1" ]]; then
    # DELIVERED TO ~/Downloads, NOT ~/Desktop, and that is the fix for a real
    # failure rather than a preference.
    #
    # This Mac syncs Desktop and Documents to iCloud. The fileprovider reapplies
    # com.apple.FinderInfo to anything landing there faster than the `xattr -cr`
    # below can clear it, so `codesign --verify --strict` failed on the delivered
    # copy every time while the /tmp stage was spotless. The whole release path
    # ran, notarized successfully, stapled successfully, and then exited FATAL on
    # the last line, which is the most expensive place to fail.
    #
    # ~/Downloads is not part of Desktop and Documents syncing. The zip that
    # actually ships is built from the STAGE either way.
    OUT="$HOME/Downloads/Grux-release.app"
    rm -rf "$OUT"
    ditto "$APP" "$OUT"

    # Strip xattrs AT THE DESTINATION, and verify the thing actually handed over.
    #
    # This script already stages in /tmp specifically because iCloud and Finder
    # inject com.apple.FinderInfo and fileprovider xattrs that codesign refuses
    # (see the comment at the top). It then delivered into ~/Desktop, which is
    # one of exactly those locations, and verified the STAGE instead. Measured on
    # the first real run of this path: stage 0 xattrs, delivered artifact 3,
    # including com.apple.FinderInfo, and `codesign --verify --strict` failed on
    # the artifact while passing on the stage.
    #
    # Plain `--verify` passes on both, which is why this hid: only --strict
    # rejects the detritus, and the notary service is strict. So the failure
    # would have surfaced for the first time during notarization, on a path that
    # had never successfully run, which is the worst possible place to discover
    # it.
    xattr -cr "$OUT"
    # The STAGE is the artifact of record: it is what the zip is cut from and
    # what Apple notarized. Verify it strictly and fail on it.
    if ! codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2; then
        echo "   FATAL: the STAGED artifact fails strict signature verification."
        exit 1
    fi
    # The delivered copy is a convenience. If the destination turns out to be
    # synced by something that reapplies xattrs, say so and carry on rather than
    # throwing away a successful notarization over a copy nobody ships.
    if ! codesign --verify --strict "$OUT" 2>/dev/null; then
        echo "   NOTE: $OUT picked up xattrs from its folder and fails --strict."
        echo "         The staged artifact and the zip are unaffected. Ship from:"
        echo "         $APP"
    fi

    # The zip that ships, cut AFTER stapling. The only zip this script used to
    # make was the pre-notarization upload, so the release artifact had to be
    # rebuilt by hand every time and could silently ship without a ticket.
    RELEASE_ZIP="$STAGE/Grux-release.zip"
    rm -f "$RELEASE_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_ZIP"
    echo "      shippable zip: $RELEASE_ZIP ($(wc -c < "$RELEASE_ZIP" | tr -d ' ') bytes, stapled)"

    echo "[6/7] Release artifact (NOT installed, dev install and its TCC grants untouched):"
    echo "      $OUT"
    codesign -dvv "$OUT" 2>&1 | grep -E "^Authority=Developer ID" | head -1 | sed 's/^/      /'
    xcrun stapler validate "$OUT" >/dev/null 2>&1 \
        && echo "      notarization ticket: stapled" \
        || echo "      notarization ticket: NONE, a stranger's Mac will refuse this"
    echo "[7/7] Done (release mode, nothing installed)."
    exit 0
fi

echo "[6/7] Install to /Applications…"
# Quit running instance before replacing the binary
if pgrep -x Grux > /dev/null; then
    osascript -e 'quit app "Grux"' 2>/dev/null || killall Grux 2>/dev/null || true
    sleep 0.6
fi
if [[ -d /Applications/Grux.app ]]; then
    rm -rf /Applications/Grux.app
fi
cp -R "$APP" /Applications/
# iCloud Drive / fileprovider can re-inject xattrs during the copy chain.
# Scrub once more in place so Gatekeeper and codesign remain happy.
xattr -cr /Applications/Grux.app

echo "[7/7] Opening…"
open /Applications/Grux.app

echo "✅ Done: /Applications/Grux.app"
echo "   audit log: ~/Library/Application Support/Grux/fs-audit.log"
