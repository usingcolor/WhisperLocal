#!/usr/bin/env bash
# Install a Dev-channel app next to the public copy.
# Writes /Applications/WhisperLocal Dev.app — never /Applications/WhisperLocal.app.
#
# CODESIGN_IDENTITY signs the build with that identity instead of the project's
# automatic signing, which needs a "Mac Development" certificate this machine
# does not have. It matters beyond getting a build out: macOS keys Accessibility,
# Input Monitoring, and Microphone to the signature, so installing over the Dev
# app with a different one silently revokes all three. Pass the same identity the
# installed copy already carries:
#
#   codesign -dv "/Applications/WhisperLocal Dev.app"   # read Authority=
#   CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/install-dev.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

dest="/Applications/WhisperLocal Dev.app"
public="/Applications/WhisperLocal.app"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: Dev installs are Apple Silicon only." >&2
  exit 1
fi

echo "==> Generating Xcode project"
xcodegen generate

sign_args=()
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  if ! security find-identity -v -p codesigning | grep -qF "$CODESIGN_IDENTITY"; then
    echo "error: no codesigning identity matching '$CODESIGN_IDENTITY' in the keychain" >&2
    exit 1
  fi
  echo "==> Signing as $CODESIGN_IDENTITY"
  sign_args=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY"
    PROVISIONING_PROFILE_SPECIFIER=
  )
fi

derived="${root}/build/DerivedDataDev"
echo "==> Building WhisperLocal Dev (optimized, bundle com.usingcolor.WhisperLocal.dev)"
xcodebuild \
  -scheme WhisperLocalDev \
  -configuration Dev \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} \
  ${sign_args[@]+"${sign_args[@]}"} \
  build

app="${derived}/Build/Products/Dev/WhisperLocal Dev.app"
if [[ ! -d "$app" ]]; then
  echo "error: expected app at $app" >&2
  exit 1
fi

id="$(defaults read "$app/Contents/Info" CFBundleIdentifier)"
if [[ "$id" != "com.usingcolor.WhisperLocal.dev" ]]; then
  echo "error: Dev build has bundle id '$id' (refusing to install)" >&2
  exit 1
fi

if [[ "$dest" == "$public" ]]; then
  echo "error: refusing to overwrite the public app" >&2
  exit 1
fi

echo "==> Installing $dest (public app left alone)"
osascript -e 'quit app "WhisperLocal Dev"' >/dev/null 2>&1 || true
sleep 0.4
# Replace rather than merge so stale icons/resources do not linger.
rm -rf "$dest"
ditto "$app" "$dest"
open "$dest"
echo "==> Done: $dest"
defaults read "$dest/Contents/Info" CFBundleShortVersionString
defaults read "$dest/Contents/Info" CFBundleIdentifier
codesign -dv "$dest" 2>&1 | grep -E "^Authority=|^TeamIdentifier=" | head -2 || true
