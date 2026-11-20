#!/bin/bash
# Meboki bench kit: measures Apple's built-in model (Apple Intelligence) on this Mac. No arguments.
# Needs macOS 26 with Apple Intelligence on. Writes everything into results/ next to this script and zips it.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT"
# Keep the Mac awake for the whole run (display may sleep; the run doesn't).
if [ -z "${MEBOKI_CAFFEINATED:-}" ]; then
  MEBOKI_CAFFEINATED=1 exec /usr/bin/caffeinate -ims /bin/bash "$KIT/$(basename "$0")" "$@"
fi

RUN="$KIT/meboki-eval-run"
OUT="$KIT/results"
mkdir -p "$OUT"
LOG="$OUT/run-apple.log"
: > "$LOG"

if [ ! -x "$RUN" ]; then
  echo "meboki-eval-run is missing or not executable in $KIT." | tee -a "$LOG"
  exit 1
fi

echo "Meboki bench: Apple Intelligence"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(sysctl -n machdep.cpu.brand_string) · $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"

# Availability (also saves this Mac's facts).
"$RUN" --probe > "$OUT/machine.json" 2> "$OUT/probe.err"
code=$?
if [ $code -ne 0 ]; then
  if [ $code -eq 3 ]; then
    echo
    echo "Apple's model can't run here: $(cat "$OUT/probe.err")"
    case "$(sed -n 's/.*"apple_model":"\([^"]*\)".*/\1/p' "$OUT/machine.json")" in
      notEnabled|modelNotReady)
        echo "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, wait until it says it's"
        echo "ready (the model downloads in the background), then run this again." ;;
      osTooOld) echo "This Mac runs macOS $(sw_vers -productVersion); the kit needs macOS 26 or later." ;;
    esac
  else
    echo
    echo "meboki-eval-run didn't start (exit $code). If macOS blocked it, run:  xattr -dr com.apple.quarantine \"$KIT\""
    cat "$OUT/probe.err"
  fi
  exit 1
fi
echo "Apple Intelligence is available. About 20–40 minutes; keep this window open."
echo

STEPS=9
n=0
step() {  # step "title" output-name runner-args...
  n=$((n + 1))
  local title="$1" name="$2"
  shift 2
  echo "[$n/$STEPS] $title"
  echo "== $title: $*" >> "$LOG"
  if ! "$RUN" --apple --label apple --out "$OUT/apple__$name.jsonl" "$@" 2> >(tee -a "$LOG" >&2); then
    echo "   step failed (details in results/run-apple.log); going on with the next one"
  fi
}

step "Quality, US prompt (122 cases + paragraph), first call cold" quality-us --cases cases.jsonl --prompt us
step "Quality, UK prompt" quality-uk --cases cases.jsonl --prompt uk
step "Time to first token (streamed)" stream-us --cases cases.jsonl --prompt us --stream
step "Apple's default guardrails (refusal comparison)" quality-us-defguard --cases cases.jsonl --prompt us --default-guardrails --label apple-defguard
step "2 requests at a time" lanes2-us --cases cases.jsonl --prompt us --lanes 2
step "4 requests at a time" lanes4-us --cases cases.jsonl --prompt us --lanes 4
step "Long-field page, 1 at a time" page-l1 --cases page.jsonl --prompt us
step "Long-field page, 2 at a time" page-l2 --cases page.jsonl --prompt us --lanes 2
step "Long-field page, 4 at a time" page-l4 --cases page.jsonl --prompt us --lanes 4

ZIP="$KIT/meboki-bench-results.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$OUT" "$ZIP"
echo
echo "Done. Send back this one file:"
echo "  $ZIP"
echo "(Optional: ./run-gemma.sh first to add the Gemma comparison; it updates the same zip.)"
