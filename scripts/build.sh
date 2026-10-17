#!/bin/sh
# Canonical build: works in a normal shell and inside the agents' workspace-write sandbox.
# Caches live under .build/ (the sandbox cannot write ~/.cache). SwiftPM's own sandbox is
# disabled because nested sandboxes are not permitted.
# Usage: scripts/build.sh [test [<swift test options>] | app]
#   app: build the learner app and wrap it as build/Skillgarden.app.
set -e
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
FLAGS="--disable-sandbox --cache-path $PWD/.build/swiftpm-cache --config-path $PWD/.build/swiftpm-config --security-path $PWD/.build/swiftpm-security"
case "$1" in
  test) shift; exec swift test $FLAGS "$@" ;;
  app) exec ./scripts/bundle_app.sh ;;
  *) exec swift build $FLAGS "$@" ;;
esac
