#!/bin/bash
set -euo pipefail

# The intentionally invalid Swift 6 consumer must fail for actor isolation,
# rather than a missing toolchain, dependency, or unrelated compile error.
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${MGM_COMPILE_FAILURE_SCRATCH:-$ROOT/.build/swift6-compile-failure-$CONFIGURATION}"
LOG="$(mktemp "${TMPDIR:-/tmp}/mgm-flush-compile-failure.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

if swift build --package-path "$ROOT/Tests/Swift6CompileFailures" \
    --scratch-path "$SCRATCH" -c "$CONFIGURATION" --target CustomActorFlush >"$LOG" 2>&1; then
  cat "$LOG"
  echo "Custom-actor state mutation unexpectedly compiled ($CONFIGURATION)" >&2
  exit 1
fi
if ! grep -Eq "error: actor-isolated property 'completionCount' can ?not be mutated from the main actor" "$LOG"; then
  cat "$LOG"
  echo "Build failed without the expected MainActor isolation diagnostic ($CONFIGURATION)" >&2
  exit 1
fi
echo "Swift 6 custom-actor flush mutation correctly rejected ($CONFIGURATION)"
