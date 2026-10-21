#!/bin/zsh
# Sign, notarize and staple Skillgarden.app for direct distribution (#212). See docs/release.md.
# Usage: scripts/release_app.sh [--dry-run]
# The script reads two values from the environment only, never from arguments or files in git:
#   SKILLGARDEN_SIGN_IDENTITY   the "Developer ID Application: …" certificate name in the Keychain
#   SKILLGARDEN_NOTARY_PROFILE  the notarytool Keychain profile (xcrun notarytool store-credentials)
# notarytool reads the Apple credentials from the Keychain profile. The script never prints a password or a token.
# --dry-run prints each command and runs nothing, so it needs no certificate and no profile.
# The result is build/release/Skillgarden-<version>.zip, which holds the stapled app.
set -euo pipefail
cd "$(dirname "$0")/.."

USAGE="usage: scripts/release_app.sh [--dry-run]"
DRY_RUN=0
case ${1-} in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) print -r -- "$USAGE"; exit 0 ;;
  *) print -r -- "$USAGE" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { print -r -- "$USAGE" >&2; exit 2 }

# A missing value stops the script before the build. The setup lines are the lines of "One-time setup" in docs/release.md.
typeset -A SETUP=(
  SKILLGARDEN_SIGN_IDENTITY 'export SKILLGARDEN_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"'
  SKILLGARDEN_NOTARY_PROFILE 'export SKILLGARDEN_NOTARY_PROFILE=skillgarden-notary'
)
MISSING=0
for name in SKILLGARDEN_SIGN_IDENTITY SKILLGARDEN_NOTARY_PROFILE; do
  if [[ -z ${(P)name-} ]]; then
    print -r -- "error: $name is not set. Set it (see docs/release.md, \"One-time setup\"):" >&2
    print -r -- "  ${SETUP[$name]}" >&2
    MISSING=1
  fi
done
(( MISSING == 0 )) || exit 2
IDENTITY=$SKILLGARDEN_SIGN_IDENTITY
PROFILE=$SKILLGARDEN_NOTARY_PROFILE
if (( ! DRY_RUN )) && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
  print -r -- "error: no valid signing identity \"$IDENTITY\" in the Keychain. See docs/release.md, \"Prerequisites\"." >&2
  exit 2
fi

APP=build/Skillgarden.app
OUT=build/release
UPLOAD=$OUT/Skillgarden-notarize.zip
MANIFEST=assets/llama.cpp/runtime.json
[[ -f $MANIFEST ]] || { print -r -- "error: $MANIFEST not found" >&2; exit 1 }

STEP=""
step() { STEP="[$1/6] $2"; print -r -- "$STEP" }
# Prints the command. Without --dry-run, runs it. If the command fails, its error stays on stderr and the script stops.
run() {
  print -r -- "+ ${(j: :)${(q-)@}}"
  (( DRY_RUN )) && return 0
  "$@" || { local code=$?; print -r -- "error: $STEP failed: $1 exited with status $code" >&2; exit 1 }
}

# Nested code, inner first: the llama.cpp libraries, llama-server, then the two helpers (#121, #123).
# The list comes from runtime.json, so a dry run needs no bundle. bundle_app.sh copies the same files.
NAMES=(${(f)"$(plutil -extract sha256 xml1 -o - "$MANIFEST" | awk -F'[<>]' '/<key>/ { print $3 }')"})
NESTED=()
for name in ${(M)NAMES:#*.dylib}; do NESTED+=("$APP/Contents/Helpers/llama/$name"); done
for name in ${NAMES:#(*.dylib|LICENSE*|NOTICE*)}; do NESTED+=("$APP/Contents/Helpers/llama/$name"); done
NESTED+=("$APP/Contents/Helpers/SkillgardenAIHost" "$APP/Contents/Helpers/skillgarden")
SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)

step 1 "Build release bundle"
run rm -rf "$OUT"
run ./scripts/build.sh app release
# The upstream hash check runs here: signing changes the binaries.
run zsh scripts/check_llama_runtime.sh "$APP"

step 2 "Sign nested code"
for file in $NESTED; do run $SIGN "$file"; done

step 3 "Sign app (hardened runtime)"
run $SIGN "$APP"

step 4 "Notarize"
run mkdir -p "$OUT"
run ditto -c -k --keepParent "$APP" "$UPLOAD"
SUBMIT=(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait --output-format plist)
print -r -- "+ ${(j: :)${(@q-)SUBMIT}}"
if (( ! DRY_RUN )); then
  RESULT=$("${SUBMIT[@]}") || true
  ID=$(print -r -- "$RESULT" | plutil -extract id raw -o - - 2>/dev/null) || ID=""
  STATUS=$(print -r -- "$RESULT" | plutil -extract status raw -o - - 2>/dev/null) || STATUS=""
  if [[ $STATUS != Accepted ]]; then
    MESSAGE=$(print -r -- "$RESULT" | plutil -extract message raw -o - - 2>/dev/null) || MESSAGE=""
    print -r -- "error: $STEP failed: status ${STATUS:-unknown}${MESSAGE:+ ($MESSAGE)}" >&2
    if [[ -n $ID ]]; then
      print -r -- "  submission id: $ID" >&2
      print -r -- "  Read the log: xcrun notarytool log $ID --keychain-profile ${(q-)PROFILE}" >&2
    fi
    exit 1
  fi
  print -r -- "Notarization accepted: submission id $ID"
fi
run rm -f "$UPLOAD"

step 5 "Staple"
run xcrun stapler staple "$APP"

step 6 "Verify"
run codesign --verify --deep --strict --verbose=2 "$APP"
run spctl -a -vv "$APP"
run xcrun stapler validate "$APP"
run zsh scripts/check_llama_runtime.sh --signed "$APP"

# The version of the bundle: CFBundleShortVersionString (#214), else the version of the bundled CLI.
VERSION="<version>"
if (( ! DRY_RUN )); then
  VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null) \
    || VERSION=$("$APP/Contents/Helpers/skillgarden" --version) \
    || { print -r -- "error: $STEP failed: no version in $APP" >&2; exit 1 }
  VERSION=${VERSION#skillgarden }
fi
ARTIFACT=$OUT/Skillgarden-$VERSION.zip
run ditto -c -k --keepParent "$APP" "$ARTIFACT"

if (( DRY_RUN )); then
  print -r -- "Dry run: no command ran."
  print -r -- "Artifact: $ARTIFACT"
  exit 0
fi
print -r -- "Artifact: $ARTIFACT"
print -r -- "SHA-256: $(shasum -a 256 < "$ARTIFACT" | awk '{ print $1 }')"
print -r -- "Version: $VERSION"
