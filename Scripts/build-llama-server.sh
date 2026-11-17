#!/usr/bin/env bash
# Builds a static, Metal-enabled llama-server for Apple Silicon and copies it to Vendor/bin/.
# Usage: Scripts/build-llama-server.sh            (tag from LLAMA_TAG, default below)
set -euo pipefail

TAG="${LLAMA_TAG:-v1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.deps/llama.cpp-$TAG"
OUT="$ROOT/Vendor/bin"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi

cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF

cmake --build "$SRC/build" --config Release --target llama-server -j "$(sysctl -n hw.ncpu)"

mkdir -p "$OUT"
cp "$SRC/build/bin/llama-server" "$OUT/llama-server"
echo "$TAG" > "$OUT/llama-server.version"
echo "Built $OUT/llama-server ($TAG)"
# Must only link system libraries (no Homebrew paths), so the app runs on any Mac.
otool -L "$OUT/llama-server"
if otool -L "$OUT/llama-server" | grep -q "/opt/homebrew\|/usr/local"; then echo "ERROR: links non-system libraries"; exit 1; fi
