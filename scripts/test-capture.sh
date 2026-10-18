#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build --product LedgerCheck
binary_directory="$(swift build --show-bin-path)"
app_sources=()
for source_file in "$project_root"/Sources/PromiseLedger/*.swift; do
  if [[ "${source_file##*/}" != "PromiseLedgerApp.swift" ]]; then
    app_sources+=("$source_file")
  fi
done
swiftc -parse-as-library \
  -I "$binary_directory/Modules" -I "$project_root/Sources/CSQLite" \
  "${app_sources[@]}" \
  "$project_root/Tests/LedgerAppTests/"*.swift \
  "$binary_directory/LedgerCore.build/"*.swift.o \
  "$binary_directory/LedgerMac.build/"*.swift.o \
  -o "$binary_directory/LedgerAppTests"
"$binary_directory/LedgerAppTests" "$@"
