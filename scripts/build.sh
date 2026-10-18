#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration" --product PromiseLedger
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
bundle="$project_root/dist/Promise Ledger.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_directory/PromiseLedger" "$bundle/Contents/MacOS/PromiseLedger"
cp "$project_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
swift "$project_root/scripts/MakeIcon.swift" "$project_root/.build/AppIcon.iconset"
iconutil -c icns "$project_root/.build/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier life.promiseledger.mac "$bundle"
printf 'Built: %s\n' "$bundle"
