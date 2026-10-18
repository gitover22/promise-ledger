#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
"$project_root/scripts/build.sh"
open "$project_root/dist/Promise Ledger.app"
