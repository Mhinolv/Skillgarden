#!/bin/zsh
# Check the llama.cpp runtime in an app bundle (default: build/Skillgarden.app). See docs/local-ai.md.
# Usage: scripts/check_llama_runtime.sh [<Skillgarden.app>]
# The checks use a PATH without Homebrew folders and no DYLD_* variables.
# Each check prints "PASS <check>" or "FAIL <check>: <detail>". A failure makes the exit status 1.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_INSERT_LIBRARIES

case ${1:-} in
  -h|--help) echo "usage: scripts/check_llama_runtime.sh [<Skillgarden.app>]"; exit 0 ;;
esac
APP=${1:-$(dirname "$0")/../build/Skillgarden.app}
APP=${APP%/}
LLAMA=$APP/Contents/Helpers/llama
MANIFEST=$LLAMA/runtime.json
LICENSES=$APP/Contents/Resources/Licenses/llama.cpp
FAILED=0

pass() { print -r -- "PASS $1" }
fail() { print -r -- "FAIL $1: $2"; FAILED=1 }

[[ -f $MANIFEST ]] || { print -r -- "error: no llama.cpp runtime at $LLAMA" >&2; exit 1 }
ARCH=$(plutil -extract architecture raw -o - "$MANIFEST" 2>/dev/null) || ARCH=""
TARGET=$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null) || TARGET=""
# Lines of "<file>\t<sha256>" from the sha256 dictionary of the manifest.
ENTRIES=$(plutil -extract sha256 xml1 -o - "$MANIFEST" 2>/dev/null | awk -F'[<>]' '/<key>/ { key = $3 } /<string>/ { print key "\t" $3 }')

# Every Mach-O file in the runtime folder.
BINARIES=()
for file in "$LLAMA"/*(N.); do
  [[ $(file -b "$file") == Mach-O* ]] && BINARIES+=("$file")
done

# 1. Every binary holds the manifest architecture (arm64).
detail=""
if [[ $ARCH != arm64 ]]; then
  detail="runtime.json architecture is \"$ARCH\", not \"arm64\""
elif [[ ! -f $LLAMA/llama-server ]]; then
  detail="llama-server not found"
else
  for file in $BINARIES; do
    archs=" $(lipo -archs "$file" 2>/dev/null) "
    [[ $archs == *" arm64 "* ]] || { detail="${file:t} has architectures:${archs% }"; break }
  done
fi
[[ -z $detail ]] && pass arm64 || fail arm64 "$detail"

# 2. No binary needs a newer macOS than the app (LSMinimumSystemVersion).
# Prints 1 when version $1 is newer than version $2.
newer() { awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, "."); for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) { print 1; exit } if (x[i] + 0 < y[i] + 0) exit } }' }
detail=""
if [[ -z $TARGET ]]; then
  detail="no LSMinimumSystemVersion in $APP/Contents/Info.plist"
else
  for file in $BINARIES; do
    # LC_BUILD_VERSION has "minos <v>". The older LC_VERSION_MIN_MACOSX has "version <v>".
    minos=$(otool -l "$file" | awk '/cmd LC_BUILD_VERSION/ { b = 1 } /cmd LC_VERSION_MIN_MACOSX/ { m = 1 } b && $1 == "minos" { print $2; exit } m && $1 == "version" { print $2; exit }')
    if [[ -z $minos ]]; then detail="${file:t} has no minimum macOS version"; break; fi
    if [[ -n $(newer "$minos" "$TARGET") ]]; then detail="${file:t} needs macOS $minos"; break; fi
  done
fi
[[ -z $detail ]] && pass "deployment target $TARGET" || fail "deployment target $TARGET" "$detail"

# 3. Every library resolves inside the runtime folder or the system, and llama-server starts.
detail=""
for file in $BINARIES; do
  for rpath in $(otool -l "$file" | awk '/cmd LC_RPATH/ { r = 1 } r && $1 == "path" { print $2; r = 0 }'); do
    case $rpath in
      @loader_path|@loader_path/|@executable_path|@executable_path/|/usr/lib/*|/System/Library/*) ;;
      *) detail="${file:t} has rpath $rpath"; break 2 ;;
    esac
  done
  # The first otool -L line names the file. A dylib also lists its own install name next.
  for lib in $(otool -L "$file" | awk 'NR > 1 { print $1 }'); do
    case $lib in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        [[ -f $LLAMA/${lib#*/} ]] || { detail="${file:t} needs $lib, not in Contents/Helpers/llama"; break 2 } ;;
      *) detail="${file:t} needs $lib outside the app"; break 2 ;;
    esac
  done
done
if [[ -z $detail && -x $LLAMA/llama-server ]]; then
  "$LLAMA/llama-server" --version >/dev/null 2>&1 || detail="llama-server --version failed"
fi
[[ -z $detail ]] && pass "library paths" || fail "library paths" "$detail"

# 4. The bundled files match runtime.json, and the license notice is present.
detail=""
if [[ -z $ENTRIES ]]; then
  detail="runtime.json has no sha256 entries"
else
  for line in ${(f)ENTRIES}; do
    name=${line%%$'\t'*}
    case $name in LICENSE*|NOTICE*) file=$LICENSES/$name ;; *) file=$LLAMA/$name ;; esac
    if [[ ! -f $file ]]; then detail="$name not found"; break; fi
    [[ $(shasum -a 256 < "$file") == ${line#*$'\t'}\ * ]] || { detail="$name does not match runtime.json"; break }
  done
  [[ -n $detail || -f $LICENSES/LICENSE ]] || detail="LICENSE not found in Contents/Resources/Licenses/llama.cpp"
fi
[[ -z $detail ]] && pass checksums || fail checksums "$detail"

exit $FAILED
