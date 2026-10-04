#!/usr/bin/env bash
# Build the polish benchmark tool, then run it with whatever arguments follow.
#
# CODESIGN_IDENTITY matters more than it looks: the tool reads the API keys
# WhisperLocal saved in the Keychain, and macOS ties that permission to the
# binary's signature. Signed ad hoc, every rebuild is a new app and asks again;
# signed with the same Developer ID, "Always Allow" is answered once.
#
#   CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/polish-bench.sh run --pilot --engines all --keychain
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

derived="${root}/build/DerivedDataBench"
log="${root}/build/polish-bench-build.log"

sign_args=()
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  sign_args=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY" PROVISIONING_PROFILE_SPECIFIER=)
fi

xcodegen generate >/dev/null
if ! xcodebuild \
  -scheme PolishBench \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  ${sign_args[@]+"${sign_args[@]}"} \
  build >"$log" 2>&1; then
  grep -E "error:" "$log" | head -20 >&2
  echo "build failed — full log at $log" >&2
  exit 1
fi

exec "${derived}/Build/Products/Release/polish-bench" "$@"
