#!/bin/zsh
# Accept the release artifact: Skillgarden.app or the zip of scripts/release_app.sh (#221). See docs/release.md.
# Usage: scripts/check_release.sh [--allow-unsigned] [<Skillgarden.app> | <Skillgarden-<version>.zip>]
# The default artifact is build/Skillgarden.app.
# Each check prints one "PASS", "FAIL" or "SKIP" line. A FAIL line holds the tool error.
# The script runs every check, then prints the artifact SHA-256 and a result line. A failed check makes the exit status 1.
# --allow-unsigned marks the signature and notarization checks SKIP. Use it for local and CI runs, never for a release.
# "runtime deps" also runs scripts/check_llama_runtime.sh (with --signed when the signature is checked).
# The CLI checks use a temporary library folder, never ~/Library/Application Support/Skillgarden. The script deletes it at exit.
# The SHA-256 of a zip is the hash of the zip file, as release_app.sh prints it.
# The SHA-256 of an app folder is the hash of the sorted "<sha256>  <path>" lines of its files.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_INSERT_LIBRARIES

USAGE="usage: scripts/check_release.sh [--allow-unsigned] [<Skillgarden.app> | <Skillgarden-<version>.zip>]"
SCRIPTS=${0:A:h}
ALLOW_UNSIGNED=0
case ${1:-} in
  -h|--help) print -r -- "$USAGE"; exit 0 ;;
  --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
esac
(( $# <= 1 )) && [[ ${1:-} != -* ]] || { print -r -- "$USAGE" >&2; exit 2 }
ARTIFACT=${1:-${SCRIPTS:h}/build/Skillgarden.app}
ARTIFACT=${ARTIFACT%/}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check_release.XXXXXX") || { print -r -- "error: cannot make a temporary folder" >&2; exit 1 }
trap 'rm -rf "$WORK"' EXIT

if [[ $ARTIFACT == *.zip ]]; then
  [[ -f $ARTIFACT ]] || { print -r -- "error: $ARTIFACT not found" >&2; exit 1 }
  ditto -x -k "$ARTIFACT" "$WORK/unzip" 2>/dev/null || { print -r -- "error: cannot unzip $ARTIFACT" >&2; exit 1 }
  APP=$WORK/unzip/Skillgarden.app
  [[ -d $APP ]] || { print -r -- "error: $ARTIFACT holds no Skillgarden.app" >&2; exit 1 }
  HASH=$(shasum -a 256 < "$ARTIFACT" | awk '{ print $1 }')
else
  APP=$ARTIFACT
  [[ -d $APP/Contents ]] || { print -r -- "error: no app bundle at $APP" >&2; exit 1 }
  HASH=$(cd "$APP" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done | shasum -a 256 | awk '{ print $1 }')
fi
PLIST=$APP/Contents/Info.plist
CLI=$APP/Contents/Helpers/skillgarden
LICENSES=$APP/Contents/Resources/Licenses
# The notices that scripts/bundle_app.sh copies (#213), in its output order.
COMPONENTS=(Skillgarden Yams libyaml llama.cpp)
TOTAL=0
FAILED=0

# One line for each check: the status, the label and the detail.
report() { (( TOTAL++ )); [[ $1 == FAIL ]] && (( FAILED++ )); printf '%-5s %-16s %s\n' "$1" "$2" "$3" }
# The first line of the tool output, or the fallback text.
first_line() { local line=${${1##[[:space:]]#}%%$'\n'*}; print -r -- "${line:-$2}" }
# plutil writes its error to stdout, so a missing key prints nothing and returns 1.
plist_value() { local value; value=$(plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null) && print -r -- "$value" }

# Every Mach-O file in Contents/MacOS and Contents/Helpers.
BINARIES=()
for file in "$APP"/Contents/{MacOS,Helpers}/**/*(N.); do
  [[ $(file -b "$file") == Mach-O* ]] && BINARIES+=("$file")
done

# 1. architecture: every binary holds arm64.
detail=""
EXECUTABLE=$(plist_value CFBundleExecutable) || EXECUTABLE=""
if [[ -z $EXECUTABLE || ! -f $APP/Contents/MacOS/$EXECUTABLE ]]; then
  detail="main executable Contents/MacOS/${EXECUTABLE:-<CFBundleExecutable>} not found"
elif [[ ! -f $CLI ]]; then
  detail="Contents/Helpers/skillgarden not found"
else
  for file in $BINARIES; do
    archs=" $(lipo -archs "$file" 2>&1) "
    [[ $archs == *" arm64 "* ]] || { detail="${file#$APP/} has architectures:${archs% }"; break }
  done
fi
[[ -z $detail ]] && report PASS architecture "arm64 (${#BINARIES} binaries)" || report FAIL architecture "$detail"

# 2. plist: the file is valid, holds the release keys (#214) and has the version of the bundled CLI.
detail=""
VERSION="" BUILD="" CATEGORY=""
if ! lint=$(plutil -lint "$PLIST" 2>&1); then
  detail=$(first_line "$lint" "plutil -lint failed")
else
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion NSHumanReadableCopyright \
             LSApplicationCategoryType LSMinimumSystemVersion; do
    [[ -n $(plist_value $key) ]] || { detail="Info.plist has no $key"; break }
  done
  VERSION=$(plist_value CFBundleShortVersionString) BUILD=$(plist_value CFBundleVersion) CATEGORY=$(plist_value LSApplicationCategoryType)
  if [[ -z $detail && -x $CLI ]]; then
    cli_version=$("$CLI" --version 2>&1) || cli_version=""
    [[ ${cli_version#skillgarden } == $VERSION ]] || detail="CFBundleShortVersionString $VERSION, but skillgarden --version is \"$cli_version\""
  fi
fi
[[ -z $detail ]] && report PASS plist "$VERSION ($BUILD), $CATEGORY" || report FAIL plist "$detail"

# 3. notices: each component has a license notice folder with a file that is not empty.
detail=""
for component in $COMPONENTS; do
  files=("$LICENSES/$component"/*(N.L+0))
  (( ${#files} )) || { detail="no license notice in Contents/Resources/Licenses/$component"; break }
done
[[ -n $detail || -s $LICENSES/llama.cpp/LICENSE ]] || detail="LICENSE not found in Contents/Resources/Licenses/llama.cpp"
[[ -z $detail ]] && report PASS notices "${(j:, :)COMPONENTS}" || report FAIL notices "$detail"

# 4. signature: a valid Developer ID signature with the hardened runtime and a secure timestamp.
if (( ALLOW_UNSIGNED )); then
  report SKIP signature --allow-unsigned
else
  detail=""
  if ! out=$(codesign --verify --deep --strict "$APP" 2>&1); then
    detail="codesign: $(first_line "${out#$APP: }" "verify failed")"
  else
    info=$(codesign -d --verbose=4 "$APP" 2>&1)
    directory=${${info#*$'\n'CodeDirectory }%%$'\n'*}
    if [[ $info != *$'\n'"Authority=Developer ID Application: "* ]]; then detail="the app is not signed with a Developer ID"
    elif [[ $directory != *flags=*[\(,]runtime[\),]* ]]; then detail="the app has no hardened runtime"
    elif [[ $info != *$'\n'Timestamp=* ]]; then detail="the app has no secure timestamp"
    fi
  fi
  [[ -z $detail ]] && report PASS signature "Developer ID, hardened runtime, timestamp" || report FAIL signature "$detail"
fi

# 5. notarization: the ticket is stapled and Gatekeeper accepts the app as notarized.
if (( ALLOW_UNSIGNED )); then
  report SKIP notarization --allow-unsigned
else
  detail=""
  if ! out=$(xcrun stapler validate "$APP" 2>&1); then
    detail="stapler: $(first_line "${${(f)out}[-1]}" "validate failed")"
  elif ! out=$(spctl -a -vv "$APP" 2>&1) || [[ $out != *"source=Notarized Developer ID"* ]]; then
    detail="spctl: $(first_line "${${out#$APP: }//$'\n'/, }" "assessment failed")"
  fi
  [[ -z $detail ]] && report PASS notarization "stapled, Notarized Developer ID" || report FAIL notarization "$detail"
fi

# 6. runtime deps: each library resolves in the bundle or the system, and check_llama_runtime.sh passes.
detail=""
for file in $BINARIES; do
  [[ $file == $APP/Contents/Helpers/llama/* ]] && continue
  # An @rpath library must resolve through an rpath in the bundle. SwiftPM also adds an absolute toolchain rpath.
  # The dynamic loader tries it only for an @rpath library, so an rpath alone is not a failure.
  folders=()
  for rpath in $(otool -l "$file" | awk '/cmd LC_RPATH/ { r = 1 } r && $1 == "path" { print $2; r = 0 }'); do
    case $rpath in @loader_path*|@executable_path*) folders+=("${file:h}${rpath#@*_path}") ;; esac
  done
  # The first otool -L line names the file.
  for lib in $(otool -L "$file" | awk 'NR > 1 { print $1 }'); do
    case $lib in
      /usr/lib/*|/System/Library/*) ;;
      @loader_path/*|@executable_path/*) [[ -f ${file:h}/${lib#*/} ]] || { detail="${file#$APP/} needs $lib, not in the bundle"; break 2 } ;;
      @rpath/*)
        found=0
        for folder in $folders; do [[ -f $folder/${lib#*/} ]] && { found=1; break }; done
        (( found )) || { detail="${file#$APP/} needs $lib, not in the bundle"; break 2 } ;;
      *) detail="${file#$APP/} needs $lib outside the bundle"; break 2 ;;
    esac
  done
done
if [[ -z $detail ]]; then
  signed=(); (( ALLOW_UNSIGNED )) || signed=(--signed)
  if ! out=$(zsh "$SCRIPTS/check_llama_runtime.sh" $signed "$APP" 2>&1); then
    lines=(${(f)out})
    problems=(${(M)lines:#(FAIL|error)*})
    detail="check_llama_runtime.sh: ${problems[1]:-$(first_line "$out" "failed")}"
  fi
fi
[[ -z $detail ]] && report PASS "runtime deps" "no paths outside the bundle" || report FAIL "runtime deps" "$detail"

# 7-9. cli publish, republish and inspect: the bundled CLI in a temporary library.
export SKILLGARDEN_DATA_DIR=$WORK/library
COURSE=$WORK/course
COURSE_ID=release-check
# Runs the CLI with --json. $REPLY holds the JSON output. If the run fails, $detail holds its error.
cli() {
  REPLY=$("$CLI" "$@" --json 2>"$WORK/stderr")
  local code=$?
  (( code == 0 )) && return 0
  local message=$(print -r -- "$REPLY" | plutil -extract diagnostics.0.message raw -o - - 2>/dev/null)
  detail="skillgarden $1 exited with status $code: ${message:-$(first_line "$(<"$WORK/stderr")" "no output")}"
  return 1
}
result() { print -r -- "$REPLY" | plutil -extract "result.$1" raw -o - - 2>/dev/null }

detail=""
if [[ ! -x $CLI ]]; then
  detail="Contents/Helpers/skillgarden not found"
elif cli init "$COURSE" --id $COURSE_ID --title "Release check" && cli publish "$COURSE"; then
  (( $(result created) > 0 )) || detail="publish created nothing"
fi
[[ -z $detail ]] && report PASS "cli publish" "temporary library" || report FAIL "cli publish" "$detail"

detail=""
if [[ ! -x $CLI ]]; then
  detail="Contents/Helpers/skillgarden not found"
elif cli publish "$COURSE"; then
  changes="created $(result created), updated $(result updated), removed $(result removed)"
  [[ $changes == "created 0, updated 0, removed 0" ]] || detail="republish changed the course: $changes"
fi
[[ -z $detail ]] && report PASS "cli republish" "temporary library" || report FAIL "cli republish" "$detail"

detail=""
if [[ ! -x $CLI ]]; then
  detail="Contents/Helpers/skillgarden not found"
elif cli inspect $COURSE_ID; then
  if [[ $(result id) != $COURSE_ID ]]; then detail="inspect did not show $COURSE_ID"
  elif (( $(result lectures) == 0 )); then detail="inspect shows no lectures"
  fi
fi
[[ -z $detail ]] && report PASS "cli inspect" "temporary library" || report FAIL "cli inspect" "$detail"

printf '%-9s %s\n' artifact "sha256 $HASH  $ARTIFACT"
if (( FAILED )); then
  printf '%-9s %s\n' result "FAIL ($FAILED of $TOTAL checks failed)"
  exit 1
fi
printf '%-9s %s\n' result "PASS ($TOTAL checks)"
