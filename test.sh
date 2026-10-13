#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Sources/AppGroups.swift Sources/AppBatchRunner.swift Sources/DesktopWorkspace.swift Sources/Layout.swift Sources/Grid.swift Sources/PageNames.swift Sources/BatchPlacement.swift Sources/BatchGrouping.swift Sources/PageManagerState.swift Sources/Presentation.swift Sources/Wallpaper.swift Sources/AppModel.swift Tests/Regression.swift -o build/regression
build/regression
