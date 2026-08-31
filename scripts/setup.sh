#!/bin/bash
#
# setup.sh — everything Voz needs before it will build.
#
# Three things are missing from this repo on purpose, all of them too big for
# git: the Whisper speech model (~147 MB) and the two inference engines that
# Voz shells out to. This script fetches and builds all three.
#
# Run it once:   ./scripts/setup.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper.cpp}"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODEL="$ROOT/Voz/Models/ggml-base.bin"

command -v cmake >/dev/null || { echo "✗ cmake not found. Install it: brew install cmake"; exit 1; }
command -v git   >/dev/null || { echo "✗ git not found. Install Xcode command line tools."; exit 1; }

# ── 1. The speech model ───────────────────────────────────────────────────────
# Xcode treats this as a bundled resource, so the build FAILS without it.
if [ -f "$MODEL" ]; then
  echo "▸ 1/3  Speech model already present, skipping."
else
  echo "▸ 1/3  Downloading the Whisper base model (~147 MB)…"
  mkdir -p "$(dirname "$MODEL")"
  curl -L --fail --progress-bar \
    -o "$MODEL" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
fi

# ── 2. whisper.cpp — transcription ────────────────────────────────────────────
# Built in place rather than copied into the app. The binaries in a cmake build
# tree resolve their dylibs relative to that tree, so moving them elsewhere
# breaks them unless you rewrite the load paths. Voz auto-detects this location
# (see defaultBinaryCandidates in Settings.swift), so leaving them put is both
# simpler and more reliable.
if [ -x "$WHISPER_DIR/build/bin/whisper-cli" ]; then
  echo "▸ 2/3  whisper.cpp already built at $WHISPER_DIR, skipping."
else
  echo "▸ 2/3  Building whisper.cpp in $WHISPER_DIR…"
  [ -d "$WHISPER_DIR" ] || git clone --depth 1 https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
  cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$WHISPER_DIR/build" -j --config Release >/dev/null
fi

# ── 3. llama.cpp — the OPTIONAL summaries and speaker separation ──────────────
# Skip it with SKIP_LLAMA=1 if you only want dictation. Voz runs fine without
# it; the AI panel in Settings simply stays unavailable.
if [ "${SKIP_LLAMA:-0}" = "1" ]; then
  echo "▸ 3/3  SKIP_LLAMA=1, skipping llama.cpp. Dictation will work; AI features won't."
elif [ -x "$LLAMA_DIR/build/bin/llama-cli" ]; then
  echo "▸ 3/3  llama.cpp already built at $LLAMA_DIR, skipping."
else
  echo "▸ 3/3  Building llama.cpp in $LLAMA_DIR…"
  [ -d "$LLAMA_DIR" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON >/dev/null
  cmake --build "$LLAMA_DIR/build" -j --config Release >/dev/null
fi

cat <<DONE

✅ Ready. Now:

    open Voz.xcodeproj      then press ⌘R

On first launch macOS asks for Microphone, and for Accessibility so Voz can
type into other apps. Both are in System Settings ▸ Privacy & Security.

DONE
