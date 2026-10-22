#!/bin/zsh
# Build SkillgardenApp and wrap it in build/Skillgarden.app so it launches as a normal Mac app.
# The skillgarden CLI goes in Contents/Helpers: Contents/MacOS/skillgarden would collide with
# Contents/MacOS/Skillgarden on a case-insensitive volume.
# The SkillgardenAIHost helper goes in Contents/Helpers. It runs llama-server and stops it when the app stops (#123).
# The pinned llama.cpp runtime (assets/llama.cpp/runtime.json) goes in Contents/Helpers/llama.
# The script copies it from SKILLGARDEN_LLAMA_DIR, or ~/.local/share/skillgarden/llama.cpp/<version>.
# It never downloads anything. See docs/local-ai.md.
# Contents/Resources/Licenses holds one folder of license notices for each component (#213).
# Usage: scripts/bundle_app.sh [debug|release]
#   The configuration (default: debug) applies to all three executables. Both write build/Skillgarden.app.
set -euo pipefail
cd "$(dirname "$0")/.."

USAGE="usage: scripts/bundle_app.sh [debug|release]"
case ${1-debug} in
  -h|--help) print -r -- "$USAGE"; exit 0 ;;
  debug|release) CONFIG=${1-debug} ;;
  *) print -r -- "$USAGE" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { print -r -- "$USAGE" >&2; exit 2 }

fail() { print -r -- "error: $1" >&2; exit 1 }

# Check the prepared runtime before the slow build.
MANIFEST=assets/llama.cpp/runtime.json
[[ -f $MANIFEST ]] || fail "$MANIFEST not found"
LLAMA_VERSION=$(plutil -extract version raw -o - "$MANIFEST") || fail "$MANIFEST has no version"
LLAMA_ARCH=$(plutil -extract architecture raw -o - "$MANIFEST") || fail "$MANIFEST has no architecture"
LLAMA_DIR=${SKILLGARDEN_LLAMA_DIR:-$HOME/.local/share/skillgarden/llama.cpp/$LLAMA_VERSION}
LLAMA_DIR=${LLAMA_DIR%/}
[[ -f $LLAMA_DIR/llama-server ]] || fail "llama.cpp runtime not found at $LLAMA_DIR. Prepare it first (see docs/local-ai.md)."
# Lines of "<file>\t<sha256>" from the sha256 dictionary of the manifest.
LLAMA_FILES=$(plutil -extract sha256 xml1 -o - "$MANIFEST" | awk -F'[<>]' '/<key>/ { key = $3 } /<string>/ { print key "\t" $3 }')
[[ -n $LLAMA_FILES ]] || fail "$MANIFEST has no sha256 entries"
for line in ${(f)LLAMA_FILES}; do
  file=${line%%$'\t'*}
  [[ -f $LLAMA_DIR/$file ]] || fail "$file: not found in $LLAMA_DIR"
  [[ $(shasum -a 256 < "$LLAMA_DIR/$file") == ${line#*$'\t'}\ * ]] || fail "$file: checksum does not match runtime.json"
done

# The notices of the components that the executables hold. A missing notice stops the script before the build.
# COMPONENTS keeps the order of the output.
typeset -A NOTICES=(Skillgarden LICENSE Yams Vendor/Yams/LICENSE libyaml Vendor/Yams/Sources/CYaml/LICENSE)
COMPONENTS=(Skillgarden Yams libyaml)
for notice in ${(v)NOTICES}; do
  [[ -f $notice ]] || fail "missing license notice: $notice"
done

# The release metadata for Info.plist comes from one source, the constants in Skillgarden.swift (#214).
# A missing value stops the script before the build.
RELEASE_SOURCE=Sources/SkillgardenCore/Skillgarden.swift
[[ -f $RELEASE_SOURCE ]] || fail "$RELEASE_SOURCE not found"
release_value() {
  local value
  value=$(sed -nE "s/^[[:space:]]*public static let $1 = $2\$/\\1/p" "$RELEASE_SOURCE" | head -n 1)
  [[ -n $value ]] || fail "Skillgarden.$1 not found in $RELEASE_SOURCE"
  print -r -- "$value"
}
VERSION=$(release_value version '"([0-9]+(\.[0-9]+)*)"')
BUILD_NUMBER=$(release_value buildNumber '([0-9]+)')
COPYRIGHT=$(release_value copyright '"([^"&<>]+)"')

PRODUCTS=(SkillgardenApp skillgarden SkillgardenAIHost)
for product in $PRODUCTS; do
  ./scripts/build.sh --configuration "$CONFIG" --product "$product"
done
# Copy only from the chosen configuration. A missing product stops the script: never fall back to the other one.
for product in $PRODUCTS; do
  [[ -f .build/$CONFIG/$product ]] || fail ".build/$CONFIG/$product not found"
done
APP=build/Skillgarden.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp ".build/$CONFIG/SkillgardenApp" "$APP/Contents/MacOS/Skillgarden"
cp ".build/$CONFIG/skillgarden" "$APP/Contents/Helpers/skillgarden"
cp ".build/$CONFIG/SkillgardenAIHost" "$APP/Contents/Helpers/SkillgardenAIHost"
cp assets/AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Skillgarden</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.skillgarden.app</string>
<key>CFBundleName</key><string>Skillgarden</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
<key>LSApplicationCategoryType</key><string>public.app-category.education</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

# llama-server and its libraries share one folder, so the release @loader_path rpath works unchanged.
# cp -L copies the file that a release symlink (libllama.0.dylib -> libllama.0.7.0.dylib) points to.
LLAMA=$APP/Contents/Helpers/llama
LICENSES=$APP/Contents/Resources/Licenses/llama.cpp
mkdir -p "$LLAMA" "$LICENSES"
for line in ${(f)LLAMA_FILES}; do
  file=${line%%$'\t'*}
  case $file in
    LICENSE*|NOTICE*) cp -L "$LLAMA_DIR/$file" "$LICENSES/$file" ;;
    *) cp -L "$LLAMA_DIR/$file" "$LLAMA/$file" ;;
  esac
done
cp "$MANIFEST" "$LLAMA/runtime.json"
echo "Bundled llama.cpp $LLAMA_VERSION ($LLAMA_ARCH) into $APP"
for component in $COMPONENTS; do
  mkdir -p "$APP/Contents/Resources/Licenses/$component"
  cp "${NOTICES[$component]}" "$APP/Contents/Resources/Licenses/$component/"
done
echo "Copied license notices: ${(j:, :)COMPONENTS}, llama.cpp"
echo "Bundled Skillgarden ($CONFIG) into $APP"
