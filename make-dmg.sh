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
