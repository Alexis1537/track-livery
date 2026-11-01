#!/bin/bash
# Builds the app and packs it into dist/TrackLivery-<version>.dmg,
# ready to send to anyone (or yourself on another Mac).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
APP_NAME="TrackLivery"
DMG="dist/TrackLivery-${VERSION}.dmg"

./build.sh

rm -rf dist
mkdir -p dist/stage
cp -R "build/${APP_NAME}.app" dist/stage/
ln -s /Applications dist/stage/Applications
cp Resources/AppIcon.icns dist/stage/.VolumeIcon.icns
python3 assets/dmg_background.py dist/stage/.background.png

# Create a read-write image, arrange the icons, then compress it read-only.
hdiutil create -volname "Track Livery" -srcfolder dist/stage -ov -format UDRW dist/tmp.dmg > /dev/null
# Attach without an explicit mount point: a custom --mountPoint under the repo
# is denied in some contexts, /Volumes always works.
DEVICE=$(timeout 60 hdiutil attach dist/tmp.dmg -nobrowse 2>/dev/null | grep '/Volumes/' | awk '{print $1}' | head -1)
[ -n "$DEVICE" ] || { echo "attach failed"; exit 1; }
echo "mounted $DEVICE"

# Arrange the icons and set the background. This needs Finder automation
# permission; if it is not granted yet, the DMG is still created (just with
# the default layout) - allow Terminal to control Finder once and rerun.
if timeout 25 osascript <<'EOF'
tell application "Finder"
  tell disk "Track Livery"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {72, 72, 712, 492}
    set background picture of container window to file ".background.png"
    set arrangement of container window to not arranged
    set icon size of container window to 96
    set position of item "TrackLivery.app" of container window to {150, 180}
    set position of item "Applications" of container window to {490, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "DMG layout customized"
else
  echo "note: Finder layout skipped (grant Terminal control of Finder once, then rerun for the custom background)"
fi

hdiutil detach "$DEVICE" > /dev/null 2>&1 || diskutil image detach "$DEVICE" > /dev/null 2>&1 || diskutil unmount "$DEVICE" > /dev/null 2>&1
sleep 1
hdiutil convert dist/tmp.dmg -format UDZO -o "$DMG" > /dev/null
rm -rf dist/stage dist/tmp.dmg

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
