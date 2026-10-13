#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
architecture="${FREE_LAUNCHPAD_ARCH:-$(uname -m)}"
archive="dist/FreeLaunchpad-macOS-${architecture}.zip"
if [ ! -f "$archive" ]; then
  echo "Missing $archive; run bash icon.sh and bash build.sh first." >&2
  exit 1
fi
staging="$(mktemp -d /private/tmp/free-launchpad-dmg.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/image"
ditto -x -k "$archive" "$staging/image"
app="$staging/image/FreeLaunchpad.app"
codesign --verify --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
# Reuse the verified application; packaging must not change its signing identity.
ln -s /Applications "$staging/image/Applications"
cat > "$staging/image/安装说明.txt" <<'EOF'
将 FreeLaunchpad 拖到 Applications，然后从应用程序打开。
Control + Option + 空格：显示 / 隐藏启动台。
Command + G：桌面工作组。
桌面归入需要辅助功能权限，应用内提供系统设置入口。
此构建使用本地临时签名，未经 Apple Developer ID 签名或公证。
EOF
output="$PWD/dist/FreeLaunchpad-${version}-macOS-${architecture}.dmg"
hdiutil create -ov -format UDZO -volname FreeLaunchpad -srcfolder "$staging/image" "$output"
hdiutil verify "$output"
echo "Packaged: $output"
