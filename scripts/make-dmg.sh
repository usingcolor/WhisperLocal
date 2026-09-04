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
  NOTARYTOOL_KEY_ID="$(tr -d '[:space:]' <<<"$NOTARYTOOL_KEY_ID")"
  NOTARYTOOL_ISSUER_ID="$(tr -d '[:space:]' <<<"$NOTARYTOOL_ISSUER_ID")"
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
  if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    security default-keychain -d user -s "$CODESIGN_KEYCHAIN"
  fi
  # Xcode matches Developer ID by type + team; the full common name is used
  # later when signing the DMG with codesign.
  build_signing_args=(
    "CODE_SIGN_IDENTITY=Developer ID Application"
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGNING_ALLOWED=YES"
    "DEVELOPMENT_TEAM=${APPLE_TEAM_ID:-}"
    "ENABLE_HARDENED_RUNTIME=$hardened_runtime"
  )
  if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    build_signing_args+=(
      "OTHER_CODE_SIGN_FLAGS=--keychain $CODESIGN_KEYCHAIN --timestamp"
    )
  else
    build_signing_args+=("OTHER_CODE_SIGN_FLAGS=--timestamp")
  fi
else
  echo "==> Building WhisperLocal ${version} (Release, arm64, ad-hoc signed)"
  hardened_runtime=NO
  build_signing_args=(
    "CODE_SIGN_IDENTITY=-"
    "CODE_SIGNING_ALLOWED=YES"
    "DEVELOPMENT_TEAM="
    "ENABLE_HARDENED_RUNTIME=$hardened_runtime"
  )
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
  "${build_signing_args[@]}" \
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
  # Xcode signs the app, but Swift stdlib dylibs and SPM resource bundles
  # can land without hardened runtime. Notarization rejects that.
  echo "==> Re-signing nested Mach-O with hardened runtime"
  python3 - "$app" "$codesign_identity" "${CODESIGN_KEYCHAIN:-}" <<'PY'
import os
import subprocess
import sys

app, identity, keychain = sys.argv[1], sys.argv[2], sys.argv[3]
magics = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}
main = os.path.join(app, "Contents", "MacOS", "WhisperLocal")
paths = []
for dirpath, _, filenames in os.walk(app):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if path == main:
            continue
        try:
            with open(path, "rb") as handle:
                magic = handle.read(4)
        except OSError:
            continue
        if magic in magics:
            paths.append(path)
paths.sort(key=lambda p: p.count(os.sep), reverse=True)
for path in paths:
    cmd = [
        "codesign",
        "--force",
        "--options",
        "runtime",
        "--timestamp",
        "--sign",
        identity,
    ]
    if keychain:
        cmd.extend(["--keychain", keychain])
    cmd.append(path)
    subprocess.check_call(cmd)
PY
  echo "==> Signing app bundle"
  codesign --force --options runtime --timestamp \
    --sign "$codesign_identity" \
    "${codesign_keychain_args[@]}" \
    --entitlements WhisperLocal/App/WhisperLocal.entitlements \
    "$app"
  echo "==> Verifying Developer ID codesign"
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
  if ! grep -Eq 'flags=0x[0-9a-fA-F]*\(runtime\)' <<<"$signature_info"; then
    echo "error: app signature does not enable the hardened runtime." >&2
    exit 1
  fi
  if ! grep -q '^Timestamp=' <<<"$signature_info"; then
    echo "error: app signature does not include a secure timestamp." >&2
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
  python3 - "$result" "$NOTARYTOOL_KEY_PATH" "$NOTARYTOOL_KEY_ID" "$NOTARYTOOL_ISSUER_ID" <<'PY'
import json
import pathlib
import subprocess
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
status = result.get("status", "unknown")
if status == "Accepted":
    raise SystemExit(0)
submission_id = result.get("id")
if submission_id:
    print(f"==> Fetching notarization log for {submission_id}", flush=True)
    subprocess.run(
        [
            "xcrun",
            "notarytool",
            "log",
            submission_id,
            "--key",
            sys.argv[2],
            "--key-id",
            sys.argv[3],
            "--issuer",
            sys.argv[4],
        ],
        check=False,
    )
raise SystemExit(
    f"error: Apple notarization status was {status!r}, not 'Accepted'."
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
