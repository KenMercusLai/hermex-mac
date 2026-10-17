#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export TMPDIR="${HERMEX_SCRATCH:-$HOME/.hermes/cache/scratch}"
mkdir -p "$TMPDIR"
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
# The standalone CLT ships Swift Testing outside swiftc's default search path.
# Keep the build environment minimal: tool failures must not dump host secrets.
exec env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" \
  swift test --build-system native --disable-xctest \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
