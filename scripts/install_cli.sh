#!/bin/sh
# Copy the skillgarden CLI from the app bundle, or build it from source, to a destination.
# Usage: scripts/install_cli.sh [--app <Skillgarden.app>] [<destination>]
#   No arguments: build the release CLI from source and copy it to ~/.local/bin/skillgarden.
#   <destination>: a folder (an existing folder, a path that ends in "/", or a new path whose
#     name does not start with "skillgarden") gets <destination>/skillgarden. Any other path is
#     the file path of the copy.
#   Without --app, the script looks for build/Skillgarden.app, then /Applications/Skillgarden.app.
#   If no app bundle holds Contents/Helpers/skillgarden, the script builds from source.
# Caches live under .build/ (the sandbox cannot write ~/.cache). SwiftPM's own sandbox is
# disabled because nested sandboxes are not permitted.
set -e

fail() { echo "error: $1" >&2; exit 1; }
usage() { echo "usage: scripts/install_cli.sh [--app <Skillgarden.app>] [<destination>]" >&2; exit 2; }
# Make a path absolute against the caller's folder (the script changes folder below).
absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    .) printf '%s\n' "$PWD" ;;
    ./*) printf '%s\n' "$PWD/${1#./}" ;;
    *) printf '%s\n' "$PWD/$1" ;;
  esac
}

APP=""
DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || usage; APP=$(absolute "$2"); shift 2 ;;
    --app=*) APP=$(absolute "${1#--app=}"); shift ;;
    -h|--help) echo "usage: scripts/install_cli.sh [--app <Skillgarden.app>] [<destination>]"; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage ;;
    *) [ -z "$DEST" ] || usage; DEST=$(absolute "$1"); shift ;;
  esac
done

cd "$(dirname "$0")/.."
REPO=$PWD

if [ -z "$DEST" ]; then
  DEFAULT_DEST=1
  DEST_FILE="$HOME/.local/bin/skillgarden"
else
  DEFAULT_DEST=""
  case "$DEST" in
    */) DEST_FILE="${DEST}skillgarden" ;;
    *) if [ -d "$DEST" ]; then DEST_FILE="$DEST/skillgarden"
       elif [ -e "$DEST" ]; then DEST_FILE="$DEST"
       else
         case "$(basename "$DEST")" in
           skillgarden*) DEST_FILE="$DEST" ;;
           *) DEST_FILE="$DEST/skillgarden" ;;
         esac
       fi ;;
  esac
fi

# Find the source binary. No arguments keeps the source build.
SOURCE=""
if [ -n "$APP" ]; then
  APP=${APP%/}
  [ -x "$APP/Contents/Helpers/skillgarden" ] || fail "no skillgarden binary at $APP/Contents/Helpers/skillgarden"
  SOURCE="$APP/Contents/Helpers/skillgarden"
elif [ -z "$DEFAULT_DEST" ]; then
  for CANDIDATE in "$REPO/build/Skillgarden.app" "/Applications/Skillgarden.app"; do
    if [ -x "$CANDIDATE/Contents/Helpers/skillgarden" ]; then
      APP=$CANDIDATE
      SOURCE="$CANDIDATE/Contents/Helpers/skillgarden"
      break
    fi
  done
fi

if [ -z "$SOURCE" ]; then
  export CLANG_MODULE_CACHE_PATH="$REPO/.build/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$REPO/.build/module-cache"
  FLAGS="--disable-sandbox --cache-path $REPO/.build/swiftpm-cache --config-path $REPO/.build/swiftpm-config --security-path $REPO/.build/swiftpm-security"
  swift build $FLAGS -c release --product skillgarden
  SOURCE="$(swift build $FLAGS -c release --show-bin-path)/skillgarden"
  ORIGIN="built from source"
else
  ORIGIN="from $APP"
fi

DEST_DIR=$(dirname "$DEST_FILE")
mkdir -p "$DEST_DIR" 2>/dev/null || fail "cannot create folder $DEST_DIR"
[ ! -d "$DEST_FILE" ] || fail "$DEST_FILE is a folder"
# Remove an earlier copy first, so that a read-only or running copy does not block the overwrite.
rm -f "$DEST_FILE" 2>/dev/null || fail "cannot replace $DEST_FILE"
cp "$SOURCE" "$DEST_FILE" 2>/dev/null || fail "cannot copy $SOURCE to $DEST_FILE"
VERSION=$("$DEST_FILE" --version 2>/dev/null) || fail "$DEST_FILE --version failed"
VERSION=${VERSION#skillgarden }
echo "Installed skillgarden $VERSION to $DEST_FILE ($ORIGIN)"

if [ -n "$DEFAULT_DEST" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "~/.local/bin is not on PATH. Add this line to ~/.zshrc:"
       echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
  esac
fi
