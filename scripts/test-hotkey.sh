#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build --product LedgerCheck
binary_directory="$(swift build --show-bin-path)"
swiftc -parse-as-library \
  -I "$binary_directory/Modules" -I "$project_root/Sources/CSQLite" \
  "$project_root/Tests/LedgerHotKeyTests/main.swift" \
  "$binary_directory/LedgerCore.build/"*.swift.o \
  "$binary_directory/LedgerMac.build/"*.swift.o \
  -o "$binary_directory/LedgerHotKeyTests"
"$binary_directory/LedgerHotKeyTests"
