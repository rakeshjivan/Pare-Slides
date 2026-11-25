#!/bin/bash
# Builds Pare Slides.app and copies it into /Applications.
# Run from Terminal:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Pare Slides.app"
EXE="PareSlides"
ARCH="$(uname -m)"
MIN="14.0"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. An installer window will open."
  xcode-select --install || true
  echo "When it finishes, run:  bash build.sh  again."
  exit 1
fi

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

FLAGS=(-O -parse-as-library -swift-version 5)
# The new speech engine (macOS 26+) lives in the Speech framework, linked weakly so older macOS still opens the app.
FLAGS+=(-Xlinker -weak_framework -Xlinker Speech)
if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "Building Pare Slides (Apple Silicon + Intel)…"
  for A in arm64 x86_64; do
    xcrun swiftc "${FLAGS[@]}" -target "${A}-apple-macos${MIN}" Sources/*.swift -o "build/$EXE-$A"
  done
  lipo -create "build/$EXE-arm64" "build/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
else
  echo "Building Pare Slides for ${ARCH}…"
  xcrun swiftc "${FLAGS[@]}" -target "${ARCH}-apple-macos${MIN}" Sources/*.swift -o "$APP/Contents/MacOS/$EXE"
fi

BUILD="${BUILD_NUMBER:-0}"

# App icon (Resources/AppIcon.png -> AppIcon.icns)
if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi


cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pare Slides</string>
  <key>CFBundleDisplayName</key><string>Pare Slides</string>
  <key>CFBundleIdentifier</key><string>au.jivan.pareslides</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.$BUILD</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Pare Slides listens to your recording on this Mac to work out when each slide should appear.</string>
</dict>
</plist>
PLIST
rm -rf build

# Signing: releases use the same certificate as Pare Guide when the repo has the signing secrets,
# so the speech recognition permission survives updates. Otherwise the app is signed ad hoc.
IDENTITY="${SIGN_IDENTITY:--}"
if ! codesign --force --deep -s "$IDENTITY" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"; then
  echo "Signing with '$IDENTITY' failed: signing ad hoc instead."
  codesign --force --deep -s - "$APP"
fi
codesign -dr - "$APP" 2>&1 | tail -1

# On GitHub's build machines, stop here (the workflow zips the app).
if [ -n "${CI:-}" ]; then echo "Built $APP"; exit 0; fi

if ditto "$APP" "/Applications/$APP" 2>/dev/null; then
  echo "Installed to /Applications/Pare Slides.app"
  open "/Applications/$APP"
else
  echo "Built $(pwd)/$APP (couldn't copy to /Applications — drag it there yourself)."
  open "$APP"
fi
