#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
target="${1:-/Applications/BuhoLaunchpad.app}"
mkdir -p analysis
if [ -n "${REA_BIN:-}" ]; then
  rea_command=("$REA_BIN")
else
  rea_command=(npx --yes rea-agents@6.1.0)
fi
"${rea_command[@]}" providers --json > analysis/rea-providers.json
"${rea_command[@]}" inspect-artifact "$target" --json > analysis/rea-artifact.json
"${rea_command[@]}" inspect-plist "$target" --json > analysis/rea-plist.json
"${rea_command[@]}" trace-dylib-resolution "$target" --architecture arm64 --json > analysis/rea-dependencies.json
"${rea_command[@]}" inspect-plist "$target" --relative-path Contents/MacOS/BuhoLaunchpadServer.app/Contents/Resources/en.lproj/Localizable.strings --json > analysis/rea-localization.json
"${rea_command[@]}" decode-interface-builder "$target" --json > analysis/rea-interface.json
