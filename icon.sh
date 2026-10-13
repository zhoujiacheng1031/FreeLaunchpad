#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache build/AppIcon.iconset
xcrun swiftc -module-cache-path "$PWD/build/module-cache" DrawIcon.swift -o build/draw-icon
build/draw-icon "$PWD/build/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
