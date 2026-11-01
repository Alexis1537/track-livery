#!/bin/bash
# Builds build/TrackLivery.app from Sources/ + Resources/ + Frameworks/Sparkle.framework.
# Run at low priority if other builds are going: nice -n 10 ./build.sh
#
# Signing: by default the app is signed with the Developer ID certificate, with the
# hardened runtime and a secure timestamp, as Apple's notarisation requires.
# SIGN_IDENTITY=- ./build.sh makes a local, ad-hoc signed test copy instead (no network). It has
# its own identity (com.alexisarmstrong.tracklivery.test), so its settings are separate from
# the installed app's and it can run beside it. Start it with the folder watcher off:
#   build/TrackLivery.app/Contents/MacOS/TrackLivery -watchEnabled NO
# Any signing failure stops the build.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUILD_NUMBER=$(cat BUILD_NUMBER)
APP="build/TrackLivery.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alexis Armstrong (ZS7MZV3753)}"
ENTITLEMENTS="Resources/TrackLivery.entitlements"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

swiftc -swift-version 5 -O \
  -framework AppKit -framework Foundation -framework AudioToolbox -framework AVFoundation \
  -F Frameworks -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/TrackLivery" \
  Sources/*.swift

BUNDLE_ID=com.alexisarmstrong.tracklivery
[ "$SIGN_IDENTITY" = "-" ] && BUNDLE_ID=com.alexisarmstrong.tracklivery.test
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/>com\.alexisarmstrong\.tracklivery</>$BUNDLE_ID</" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
ditto Frameworks/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"

# Sign from the inside out (Sparkle's own instructions for apps built outside Xcode).
if [ "$SIGN_IDENTITY" = "-" ]; then
  TS=(); RT=()
else
  TS=(--timestamp); RT=(--options runtime)
fi
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -s "$SIGN_IDENTITY" ${TS[@]+"${TS[@]}"} ${RT[@]+"${RT[@]}"} "$S/XPCServices/Installer.xpc"
codesign -f -s "$SIGN_IDENTITY" ${TS[@]+"${TS[@]}"} ${RT[@]+"${RT[@]}"} --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
codesign -f -s "$SIGN_IDENTITY" ${TS[@]+"${TS[@]}"} ${RT[@]+"${RT[@]}"} "$S/Autoupdate"
codesign -f -s "$SIGN_IDENTITY" ${TS[@]+"${TS[@]}"} ${RT[@]+"${RT[@]}"} "$S/Updater.app"
codesign -f -s "$SIGN_IDENTITY" ${TS[@]+"${TS[@]}"} ${RT[@]+"${RT[@]}"} "$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$SIGN_IDENTITY" ${TS[@]+"${TS[@]}"} ${RT[@]+"${RT[@]}"} --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP (version $VERSION, build $BUILD_NUMBER, signed: $SIGN_IDENTITY)"
