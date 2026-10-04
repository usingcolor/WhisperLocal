#!/usr/bin/env bash
# Build and run the context benchmark. See Benchmarks/ContextBench/README.md.
#   scripts/context-bench.sh validate
#   scripts/context-bench.sh sessions --keychain
#   scripts/context-bench.sh real-log --keychain
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
derived="${root}/build/DerivedDataContextBench"
log="${root}/build/context-bench-build.log"
mkdir -p "${root}/build"

xcodegen generate >/dev/null
if ! xcodebuild \
  -scheme ContextBench \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build >"$log" 2>&1; then
  grep -E "error:" "$log" | head -20 >&2
  echo "build failed — full log at $log" >&2
  exit 1
fi
exec "${derived}/Build/Products/Release/context-bench" "$@"
