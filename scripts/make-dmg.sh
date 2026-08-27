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
echo "==> Building WhisperLocal ${version} (Release, arm64, ad-hoc signed)"
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
  build

app="${derived}/Build/Products/Release/WhisperLocal.app"
if [[ ! -d "$app" ]]; then
  echo "error: expected app at $app" >&2
  exit 1
fi

echo "==> Ad-hoc codesign"
codesign --force --deep --sign - \
  --entitlements WhisperLocal/App/WhisperLocal.entitlements \
  "$app"
codesign --verify --verbose=2 "$app"

stage="$(mktemp -d "${TMPDIR:-/tmp}/whisperlocal-dmg.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

ditto "$app" "${stage}/WhisperLocal.app"
ln -s /Applications "${stage}/Applications"

dist="${root}/dist"
mkdir -p "$dist"
dmg="${dist}/WhisperLocal-${version}-arm64.dmg"
rm -f "$dmg"

echo "==> Creating $dmg"
hdiutil create \
  -volname "WhisperLocal" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$dmg"

echo "==> Done: $dmg"
ls -lh "$dmg"
