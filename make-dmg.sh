#!/bin/bash
# Builds the app and packs it into dist/TrackLivery-<version>.dmg,
# ready to send to anyone (or yourself on another Mac).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUILD_NUMBER=$(cat BUILD_NUMBER)
APP_NAME="TrackLivery"
DMG="dist/TrackLivery-${VERSION}-build${BUILD_NUMBER}.dmg"

./build.sh

# Checks before anything is packed or sent to Apple. Any failure stops the release.
# (Added 1 Nov 2026: build 104 passed every other step yet never opened, and a copy
# that cannot open cannot update itself.)
CHECKS=$(mktemp -d)
SRC=(); for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SRC+=("$f"); done
swiftc -swift-version 5 -F Frameworks -framework Sparkle \
  -Xlinker -rpath -Xlinker "$PWD/Frameworks" -o "$CHECKS/safety" Tests/SafetyChecks.swift "${SRC[@]}"
"$CHECKS/safety"

# The built app must open and show its window within 8 seconds, with no exception logged.
# The folder watcher and update checks are switched off for this run only.
"build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" -watchEnabled NO -SUEnableAutomaticChecks NO \
  > "$CHECKS/launch.log" 2>&1 &
PID=$!
sleep 8
WINDOW=$(swift -e "import CoreGraphics
let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let mine = l.filter { (\$0[kCGWindowOwnerPID as String] as? Int) == $PID && (\$0[kCGWindowLayer as String] as? Int) == 0 }
print(mine.contains { ((\$0[kCGWindowBounds as String] as? [String: Any])?[\"Width\"] as? Double ?? 0) > 200 } ? \"yes\" : \"no\")")
ALIVE=no; kill -0 "$PID" 2>/dev/null && ALIVE=yes
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
if [ "$ALIVE" != yes ] || [ "$WINDOW" != yes ] || grep -qE "Exception|FAULT" "$CHECKS/launch.log"; then
  echo "LAUNCH CHECK FAILED: running=$ALIVE window=$WINDOW"; tail -20 "$CHECKS/launch.log"; exit 1
fi
echo "LAUNCH CHECK PASSED"
rm -rf "$CHECKS"

rm -rf dist
mkdir -p dist

# Lay out the installer window with dmgbuild (pip install dmgbuild). It writes the
# layout and background itself, so it works without Finder automation.
DMGBUILD="${DMGBUILD:-$(command -v dmgbuild || echo "$HOME/Developer/.cache/dmgbuild-venv/bin/dmgbuild")}"
[ -x "$DMGBUILD" ] || { echo "dmgbuild not found: pip install dmgbuild, or set DMGBUILD"; exit 1; }
"$DMGBUILD" -s dmg-settings.py -D app="build/${APP_NAME}.app" "Track Livery" "$DMG"

# Sign the disk image, then (when a notarisation profile is set) send it to Apple's
# malware check and staple the approval to it, so it opens without a warning offline.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alexis Armstrong (ZS7MZV3753)}"
if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign -f -s "$SIGN_IDENTITY" --timestamp "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
  else
    echo "note: not notarised (set NOTARY_PROFILE to the name of a notarytool keychain profile)"
  fi
fi

echo "Created $DMG"
