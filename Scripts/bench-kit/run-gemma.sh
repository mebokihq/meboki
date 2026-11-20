#!/bin/bash
# Meboki bench kit: the same cases through Gemma on this Mac, for a fair speed comparison with Apple's model.
# usage: ./run-gemma.sh [path/to/Meboki.app] [model.gguf ...]
#   Meboki.app default /Applications/Meboki.app (its bundled llama-server is used).
#   Models default: Gemma 4 E2B and E4B from ~/Library/Application Support/Meboki/Models (whichever are there).
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT"
if [ -z "${MEBOKI_CAFFEINATED:-}" ]; then
  MEBOKI_CAFFEINATED=1 exec /usr/bin/caffeinate -ims /bin/bash "$KIT/$(basename "$0")" "$@"
fi

APP="${1:-/Applications/Meboki.app}"
[ $# -gt 0 ] && shift
SERVER="$APP/Contents/MacOS/llama-server"
RUN="$KIT/meboki-eval-run"
OUT="$KIT/results"
mkdir -p "$OUT"
LOG="$OUT/run-gemma.log"
: > "$LOG"

if [ ! -x "$SERVER" ]; then
  echo "No llama-server in $APP. Give the path to Meboki.app:  ./run-gemma.sh /path/to/Meboki.app"
  exit 1
fi

MODELS=()
if [ $# -gt 0 ]; then
  MODELS=("$@")
else
  DIR="$HOME/Library/Application Support/Meboki/Models"
  for f in "$DIR/gemma-4-E2B-it-Q4_0.gguf" "$DIR/gemma-4-E4B-it-Q4_0.gguf"; do
    [ -f "$f" ] && MODELS+=("$f")
  done
fi
if [ ${#MODELS[@]} -eq 0 ]; then
  echo "No Gemma model found in ~/Library/Application Support/Meboki/Models."
  echo "Download Gemma 4 E2B or E4B in Meboki › Settings › Models, or pass a .gguf path after the app path."
  exit 1
fi

PID=""
stop_server() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  fi
  PID=""
}
trap stop_server EXIT INT TERM

free_port() {
  local p
  while :; do
    p=$((18000 + RANDOM % 1000))
    /usr/bin/nc -z 127.0.0.1 "$p" 2>/dev/null || { echo "$p"; return; }
  done
}

echo "Meboki bench: Gemma via llama-server"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(sysctl -n machdep.cpu.brand_string) · $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
"$RUN" --probe > "$OUT/machine.json" 2>/dev/null

for MODEL in "${MODELS[@]}"; do
  base="$(basename "$MODEL" .gguf)"
  case "$base" in
    gemma-4-E2B*) label="gemma-4-e2b-q4_0" ;;
    gemma-4-E4B*) label="gemma-4-e4b-q4_0" ;;
    *) label="$(echo "$base" | tr 'A-Z' 'a-z')" ;;
  esac
  PORT="$(free_port)"
  URL="http://127.0.0.1:$PORT"
  echo
  echo "== $label (port $PORT)"
  # The app's server arguments (ServerManager): 4 slots sharing one 8192-token KV pool.
  "$SERVER" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -c 8192 -np 4 --kv-unified --jinja --no-webui -ngl 999 \
    >> "$LOG" 2>&1 &
  PID=$!
  started=$(date +%s)
  ready=""
  for _ in $(seq 1 240); do
    if /usr/bin/curl -s -m 2 "$URL/health" 2>/dev/null | grep -q ok; then ready=1; break; fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.5
  done
  if [ -z "$ready" ]; then
    echo "   llama-server didn't start (details in results/run-gemma.log)"
    stop_server
    continue
  fi
  echo "   loaded in $(( $(date +%s) - started )) s"
  n=0
  for spec in "quality-us|--cases cases.jsonl --prompt us" \
              "quality-uk|--cases cases.jsonl --prompt uk" \
              "stream-us|--cases cases.jsonl --prompt us --stream" \
              "lanes2-us|--cases cases.jsonl --prompt us --lanes 2" \
              "lanes4-us|--cases cases.jsonl --prompt us --lanes 4" \
              "page-l1|--cases page.jsonl --prompt us" \
              "page-l2|--cases page.jsonl --prompt us --lanes 2" \
              "page-l4|--cases page.jsonl --prompt us --lanes 4"; do
    n=$((n + 1))
    name="${spec%%|*}"
    rest="${spec#*|}"
    echo "   [$n/8] $name"
    # shellcheck disable=SC2086
    "$RUN" --server "$URL" --label "$label" --out "$OUT/${label}__$name.jsonl" $rest 2> >(tee -a "$LOG" >&2) \
      || echo "   step failed (details in results/run-gemma.log)"
  done
  stop_server
done

ZIP="$KIT/meboki-bench-results.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$OUT" "$ZIP"
echo
echo "Done. Send back this one file:"
echo "  $ZIP"
