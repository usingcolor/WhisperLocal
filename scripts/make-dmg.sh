#!/usr/bin/env bash
# Build an Apple Silicon Release app and pack it into a drag-to-Applications DMG.
# Public downloads should be built from the oss / public tree (generic defaults, no team ID).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: DMG builds are Apple Silicon only (FluidAudio uses Float16)." >&2
  exit 1
fi

codesign_identity="${CODESIGN_IDENTITY:--}"
notarize="${NOTARIZE:-0}"
signed_release=0
if [[ "$codesign_identity" != "-" ]]; then
  signed_release=1
fi

if [[ "$notarize" == "1" ]]; then
  if [[ "$signed_release" != "1" ]]; then
    echo "error: NOTARIZE=1 requires a Developer ID CODESIGN_IDENTITY." >&2
    exit 1
  fi
  for name in NOTARYTOOL_KEY_PATH NOTARYTOOL_KEY_ID NOTARYTOOL_ISSUER_ID APPLE_TEAM_ID; do
    if [[ -z "${!name:-}" ]]; then
      echo "error: NOTARIZE=1 requires $name." >&2
      exit 1
    fi
  done
  if [[ ! -f "$NOTARYTOOL_KEY_PATH" ]]; then
    echo "error: NOTARYTOOL_KEY_PATH does not exist: $NOTARYTOOL_KEY_PATH" >&2
    exit 1
  fi
elif [[ "$notarize" != "0" ]]; then
  echo "error: NOTARIZE must be 0 or 1." >&2
  exit 1
fi

codesign_keychain_args=()
if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
  codesign_keychain_args=(--keychain "$CODESIGN_KEYCHAIN")
fi

version="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("project.yml").read_text()
match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', text)
print(match.group(1) if match else "0.1.0")
PY
)"

if grep -q "DEVELOPMENT_TEAM" project.yml; then
  echo "note: this tree has an Apple team ID. Public DMGs should come from oss." >&2
fi

echo "==> Generating Xcode project"
xcodegen generate

derived="${root}/build/DerivedData"
if [[ "$signed_release" == "1" ]]; then
  echo "==> Building WhisperLocal ${version} (Release, arm64, Developer ID)"
  hardened_runtime=YES
else
  echo "==> Building WhisperLocal ${version} (Release, arm64, ad-hoc signed)"
  hardened_runtime=NO
fi
xcodebuild \
  -scheme WhisperLocal \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME="$hardened_runtime" \
  build

app="${derived}/Build/Products/Release/WhisperLocal.app"
if [[ ! -d "$app" ]]; then
  echo "error: expected app at $app" >&2
  exit 1
fi

id="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [[ "$id" != "com.usingcolor.WhisperLocal" ]]; then
  echo "error: DMG build must be the public bundle, got '$id'" >&2
  exit 1
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/whisperlocal-dmg.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
payload="${stage}/payload"
mkdir -p "$payload"

if [[ "$signed_release" == "1" ]]; then
  echo "==> Developer ID codesign (hardened runtime and secure timestamp)"
  codesign --force --deep \
    --options runtime \
    --timestamp \
    --sign "$codesign_identity" \
    "${codesign_keychain_args[@]}" \
    --entitlements WhisperLocal/App/WhisperLocal.entitlements \
    "$app"
else
  echo "==> Ad-hoc codesign"
  codesign --force --deep --sign - \
    --entitlements WhisperLocal/App/WhisperLocal.entitlements \
    "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

if [[ "$signed_release" == "1" ]]; then
  signature_info="$(codesign --display --verbose=4 "$app" 2>&1)"
  printf '%s\n' "$signature_info"
  if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_info"; then
    echo "error: app is not signed by a Developer ID Application certificate." >&2
    exit 1
  fi
  if [[ -n "${APPLE_TEAM_ID:-}" ]] &&
     ! grep -q "^TeamIdentifier=${APPLE_TEAM_ID}$" <<<"$signature_info"; then
    echo "error: signed app TeamIdentifier does not match APPLE_TEAM_ID." >&2
    exit 1
  fi
fi

notarize_and_wait() {
  local submission="$1"
  local label="$2"
  local result="${stage}/${label}-notary-result.json"

  echo "==> Submitting $label to Apple notarization"
  xcrun notarytool submit "$submission" \
    --key "$NOTARYTOOL_KEY_PATH" \
    --key-id "$NOTARYTOOL_KEY_ID" \
    --issuer "$NOTARYTOOL_ISSUER_ID" \
    --wait \
    --output-format json | tee "$result"
  python3 - "$result" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get("status") != "Accepted":
    raise SystemExit(
        f"error: Apple notarization status was {result.get('status', 'unknown')!r}, not 'Accepted'."
    )
PY
}

if [[ "$notarize" == "1" ]]; then
  app_archive="${stage}/WhisperLocal.zip"
  echo "==> Archiving app for notarization"
  ditto -c -k --keepParent "$app" "$app_archive"
  notarize_and_wait "$app_archive" app
  echo "==> Stapling notarization ticket to app"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi

ditto "$app" "${payload}/WhisperLocal.app"
ln -s /Applications "${payload}/Applications"

dist="${root}/dist"
mkdir -p "$dist"
dmg="${dist}/WhisperLocal-${version}-arm64.dmg"
rm -f "$dmg"

echo "==> Creating $dmg"
hdiutil create \
  -volname "WhisperLocal" \
  -srcfolder "$payload" \
  -ov \
  -format UDZO \
  "$dmg"

if [[ "$signed_release" == "1" ]]; then
  echo "==> Signing DMG"
  codesign --force \
    --timestamp \
    --sign "$codesign_identity" \
    "${codesign_keychain_args[@]}" \
    "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi

if [[ "$notarize" == "1" ]]; then
  notarize_and_wait "$dmg" dmg
  echo "==> Stapling notarization ticket to DMG"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi

echo "==> Done: $dmg"
ls -lh "$dmg"
