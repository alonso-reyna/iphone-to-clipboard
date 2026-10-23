#!/bin/zsh
# Builds "iPhone Photo.app" (universal: Apple Silicon + Intel) into ./build.
#
#   ./build.sh            build and install into ~/Applications
#   ./build.sh --release  build and create build/iPhone-Photo.zip (no install)
set -e
cd "$(dirname "$0")"

VERSION="1.1"
APP="build/iPhone Photo.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" main.swift -o "build/iPhonePhoto-$arch"
done
lipo -create build/iPhonePhoto-arm64 build/iPhonePhoto-x86_64 -output "$APP/Contents/MacOS/iPhonePhoto"
rm build/iPhonePhoto-*

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>iPhone Photo</string>
  <key>CFBundleDisplayName</key><string>iPhone Photo</string>
  <key>CFBundleIdentifier</key><string>com.alonsoreyna.fotodeliphone</string>
  <key>CFBundleExecutable</key><string>iPhonePhoto</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

if [[ "$1" == "--release" ]]; then
  ditto -c -k --keepParent "$APP" build/iPhone-Photo.zip
  echo "Release zip: build/iPhone-Photo.zip"
else
  pkill -x iPhonePhoto 2>/dev/null || true
  rm -rf "$HOME/Applications/iPhone Photo.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed: ~/Applications/iPhone Photo.app"
fi
