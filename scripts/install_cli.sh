#!/bin/sh
# Build the release skillgarden CLI and copy it to ~/.local/bin/skillgarden.
# Caches live under .build/ (the sandbox cannot write ~/.cache). SwiftPM's own sandbox is
# disabled because nested sandboxes are not permitted.
# Usage: scripts/install_cli.sh
set -e
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
FLAGS="--disable-sandbox --cache-path $PWD/.build/swiftpm-cache --config-path $PWD/.build/swiftpm-config --security-path $PWD/.build/swiftpm-security"
swift build $FLAGS -c release --product skillgarden
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cp "$(swift build $FLAGS -c release --show-bin-path)/skillgarden" "$BIN_DIR/skillgarden"
VERSION=$("$BIN_DIR/skillgarden" --version | sed 's/^skillgarden //')
echo "Installed skillgarden $VERSION to ~/.local/bin/skillgarden"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "~/.local/bin is not on PATH. Add this line to ~/.zshrc:"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac
