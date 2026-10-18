#!/bin/sh
# Build build/Toothpeek.app (universal: Apple silicon + Intel).
#   ./bundle.sh            build only (what CI does)
#   ./bundle.sh install    build, then install in /Applications
# VERSION (default 0.0.0-dev) and BUILD_NUMBER (default 1) set the app version.
set -eu
cd "$(dirname "$0")"

version="${VERSION:-0.0.0-dev}"
build_number="${BUILD_NUMBER:-1}"

# Sign with the "Apple Development" certificate when there is one: a stable identity across rebuilds
# (ad-hoc changes on every build). CI has no certificate and signs ad hoc. Widget attempt notes: docs/widget.md.
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Toothpeek"

app=build/Toothpeek.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp icon/AppIcon.icns "$app/Contents/Resources/"  # regenerate: swift icon/make_icon.swift
cp -R Localization/*.lproj "$app/Contents/Resources/"
case "$version" in *-*) cp docs/images/simulated-camera.jpg "$app/Contents/Resources/" ;; esac # printer simulator, dev builds only
cp "$bin" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.loicbisiere.Toothpeek</string>
  <key>CFBundleName</key><string>Toothpeek</string>
  <key>CFBundleExecutable</key><string>Toothpeek</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Toothpeek connects to your 3D printer on the local network to show its camera.</string>
</dict>
</plist>
PLIST

codesign --force --sign "${identity:--}" "$app" # "-" = ad hoc when no certificate
echo "Built $app $version ($([ -n "$identity" ] && echo "signed: Apple Development" || echo "ad hoc"))"

if [ "${1:-}" = install ]; then
  rm -rf /Applications/Toothpeek.app
  cp -R "$app" /Applications/
  echo "Installed /Applications/Toothpeek.app"
fi
