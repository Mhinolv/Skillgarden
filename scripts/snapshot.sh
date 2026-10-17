#!/bin/zsh
# Offscreen UI snapshots for QA. Usage: scripts/snapshot.sh <out-dir>
# Builds SkillgardenApp, then writes <out-dir>/<screen>-<light|dark>.png for each screen.
# The store is seeded in a temporary directory from Tests/Fixtures/sample-course (never the real data).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
  echo "usage: scripts/snapshot.sh <out-dir>" >&2
  exit 2
fi
log=$(mktemp -t skillgarden-snapshot-build)
trap 'rm -f "$log"' EXIT
if ! ./scripts/build.sh --product SkillgardenApp >"$log" 2>&1; then
  cat "$log" >&2
  echo "snapshot: the app build failed" >&2
  exit 1
fi
exec .build/debug/SkillgardenApp --snapshot "$1" --fixture Tests/Fixtures/sample-course
