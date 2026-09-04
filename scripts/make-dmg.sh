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
notary_timeout="${NOTARY_TIMEOUT:-30m}"
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
echo "==> Building WhisperLocal ${version} (Release, arm64)"
if [[ "$signed_release" == "1" && -n "${CODESIGN_KEYCHAIN:-}" ]]; then
  security default-keychain -d user -s "$CODESIGN_KEYCHAIN"
fi
# Compile ad-hoc. Developer ID + timestamp on SPM objects (Cmlx especially)
# is what stretched an 11-minute compile past an hour. The .app is signed
# once after it exists.
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
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
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
  # Nested first, without app entitlements. Then the outer bundle with them.
  # --deep on the second pass would stamp microphone/network onto Swift dylibs
  # and Apple would reject notarization.
  echo "==> Developer ID codesign (hardened runtime and timestamp)"
  codesign --force --deep --options runtime --timestamp \
    --sign "$codesign_identity" \
    "${codesign_keychain_args[@]}" \
    "$app"
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

# Apple rejects notarization outright when the executable can be debugged.
# Xcode injects this for development-style signing; CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
# above prevents it and the entitlements re-sign strips it, so reaching here means
# one of those stopped working. Catch it now: the alternative is finding out from
# the notary service ten minutes later.
app_entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
if grep -q 'get-task-allow' <<<"$app_entitlements"; then
  echo "error: signed app still requests com.apple.security.get-task-allow." >&2
  echo "       Apple will reject notarization with status 'Invalid'." >&2
  echo "       Check CODE_SIGN_INJECT_BASE_ENTITLEMENTS and the entitlements re-sign." >&2
  exit 1
fi

# The mirror image: the re-sign must not drop what the app actually needs. Under the
# hardened runtime com.apple.security.device.audio-input gates the microphone even
# though this app is unsandboxed, so losing it signs, notarizes, and ships a build
# that never hears anything. Compare against the entitlements file rather than a
# hardcoded list, so a new entitlement is covered the day it is added.
printf '%s' "$app_entitlements" > "${stage}/signed-entitlements.plist"
python3 - WhisperLocal/App/WhisperLocal.entitlements "${stage}/signed-entitlements.plist" <<'PYENT'
import pathlib
import plistlib
import sys

declared = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
raw = pathlib.Path(sys.argv[2]).read_bytes().strip()
if not raw:
    raise SystemExit("error: the signed app carries no entitlements; the re-sign dropped them.")
try:
    actual = plistlib.loads(raw)
except Exception as error:
    raise SystemExit(f"error: could not parse entitlements from the signed app: {error}")

missing = sorted(k for k in declared if k not in actual)
changed = sorted(k for k in declared if k in actual and actual[k] != declared[k])
for key in missing:
    print(f"error: signed app is missing entitlement {key}", file=sys.stderr)
for key in changed:
    print(f"error: entitlement {key} is {actual[key]!r}, expected {declared[key]!r}", file=sys.stderr)
if missing or changed:
    raise SystemExit("error: signed entitlements do not match WhisperLocal.entitlements.")
PYENT

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

  echo "==> Submitting $label to Apple notarization (waiting up to ${notary_timeout})"
  # Do not let a non-zero exit kill the script here: on a timeout notarytool exits
  # non-zero, and `set -e` would skip the log fetch below — the one thing that
  # explains a failure. Capture the status and decide afterwards.
  local notary_status=0
  xcrun notarytool submit "$submission" \
    --key "$NOTARYTOOL_KEY_PATH" \
    --key-id "$NOTARYTOOL_KEY_ID" \
    --issuer "$NOTARYTOOL_ISSUER_ID" \
    --wait \
    --timeout "$notary_timeout" \
    --output-format json > "$result" || notary_status=$?
  cat "$result"

  if [[ ! -s "$result" ]] || ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$result" 2>/dev/null; then
    echo "error: notarytool returned no usable result for $label (exit ${notary_status})." >&2
    echo "       A timeout means Apple's notary service did not answer within ${notary_timeout};" >&2
    echo "       re-running the tag is usually enough. Anything else is a credential or network fault." >&2
    exit 1
  fi
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

# The app is not submitted on its own. Notarizing the DMG below covers the app
# inside it in a single round trip through Apple's queue, which is what we wait on.
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
