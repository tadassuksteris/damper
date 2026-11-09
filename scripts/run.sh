#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
"$project_root/scripts/build.sh" "${1:-debug}"
if [[ -n "$(lsappinfo find bundleID=io.github.tadassuksteris.damper)" ]]; then
    echo "Damper is running the previous build; quit it and re-run." >&2
    exit 1
fi
open "$project_root/build/Damper.app"
