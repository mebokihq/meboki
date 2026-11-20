#!/usr/bin/env bash
# Builds the bench kit: a folder + zip that measures Apple's built-in model (and optionally Gemma) on a macOS 26
# Mac with no Xcode and no Python (eval/README.md "Apple Intelligence on another Mac").
#   build/meboki-bench-kit/       meboki-eval-run (release, signed), cases.jsonl, page.jsonl, run-apple.sh,
#                                 run-gemma.sh, README.txt
#   build/meboki-bench-kit.zip    the same, to AirDrop or copy over
# The runner is signed ad hoc unless MEBOKI_BENCH_IDENTITY names a codesigning identity (e.g. Developer ID).
# Nothing is uploaded. Score the returned results with: python3 eval/bench_remote.py <results dir>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/meboki-bench-kit"
ZIP="$ROOT/build/meboki-bench-kit.zip"

swift build -c release --product meboki-eval-run
BIN="$(swift build -c release --show-bin-path)/meboki-eval-run"

rm -rf "$OUT" "$ZIP"
mkdir -p "$OUT"
cp "$BIN" "$OUT/meboki-eval-run"
/usr/bin/python3 eval/export_cases.py "$OUT"
cp Scripts/bench-kit/run-apple.sh Scripts/bench-kit/run-gemma.sh Scripts/bench-kit/README.txt "$OUT/"
chmod +x "$OUT/meboki-eval-run" "$OUT/run-apple.sh" "$OUT/run-gemma.sh"

IDENTITY="${MEBOKI_BENCH_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --identifier com.meboki.eval-run "$OUT/meboki-eval-run"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier com.meboki.eval-run "$OUT/meboki-eval-run"
fi
codesign --verify --verbose=1 "$OUT/meboki-eval-run"

/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$OUT" "$ZIP"
echo "Bench kit: $ZIP"
