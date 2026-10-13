#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache dist
staging="$(mktemp -d /private/tmp/free-launchpad-build.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
app="$staging/FreeLaunchpad.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
architecture="${FREE_LAUNCHPAD_ARCH:-$(uname -m)}"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$PWD/build/module-cache" \
  -target "$architecture-apple-macosx13.0" Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
  -o "$app/Contents/MacOS/FreeLaunchpad"
cp -X Info.plist "$app/Contents/Info.plist"
if [ -f build/AppIcon.icns ]; then cp -X build/AppIcon.icns "$app/Contents/Resources/"; fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto --norsrc --noextattr "$app" dist/FreeLaunchpad.app
ditto -c -k --norsrc --noextattr --keepParent "$app" "dist/FreeLaunchpad-macOS-${architecture}.zip"
echo "Built: $PWD/dist/FreeLaunchpad.app"
