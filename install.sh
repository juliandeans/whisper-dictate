#!/bin/bash
# Build the recorder app bundle, set up the config directory, and
# optionally trigger the macOS microphone permission prompt.
#
# Usage: ./install.sh [--lang de|en] [--skip-permission]
#
# Safe to run more than once: rebuilds the app bundle every time, but never
# overwrites an existing config or prompt file.

set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

LANG_CHOICE="en"
SKIP_PERMISSION=0

while [ $# -gt 0 ]; do
  case "$1" in
    --lang)
      LANG_CHOICE="${2:-en}"
      shift 2
      ;;
    --skip-permission)
      SKIP_PERMISSION=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

echo "== whisper-dictate install =="

# --- platform checks --------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This tool only works on macOS." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

PYTHON3=""
for candidate in /usr/bin/python3 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON3="$candidate"
    break
  fi
done
if [ -z "$PYTHON3" ]; then
  echo "python3 not found (expected at least /usr/bin/python3, macOS ships this by default)." >&2
  exit 1
fi
echo "Using python3: $(command -v "$PYTHON3")"

# --- build the recorder app bundle -------------------------------------

BUILD_DIR="$REPO_DIR/build"
APP_DIR="$BUILD_DIR/WhisperDictateRecorder.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

echo "Building WhisperDictateRecorder.app..."
mkdir -p "$MACOS_DIR"

swiftc -O \
  "$REPO_DIR/recorder/VoiceRecorder.swift" \
  -o "$MACOS_DIR/VoiceRecorder" \
  -framework AVFoundation \
  -framework Foundation

cp "$REPO_DIR/recorder/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Ad-hoc signing the app bundle..."
codesign --force --sign - "$APP_DIR"

echo "Built: $APP_DIR"

# --- config directory ---------------------------------------------------

CONFIG_DIR="$HOME/.config/whisper-dictate"
mkdir -p "$CONFIG_DIR"

if [ -e "$CONFIG_DIR/config" ]; then
  echo "Config already exists, leaving it as is: $CONFIG_DIR/config"
else
  cp "$REPO_DIR/config.example" "$CONFIG_DIR/config"
  echo "Wrote default config: $CONFIG_DIR/config"
fi

case "$LANG_CHOICE" in
  de) PROMPT_SOURCE="$REPO_DIR/prompts/de.txt" ;;
  en) PROMPT_SOURCE="$REPO_DIR/prompts/en.txt" ;;
  *)
    echo "Unknown --lang '$LANG_CHOICE' (use 'en' or 'de')" >&2
    exit 1
    ;;
esac

if [ -e "$CONFIG_DIR/prompt.txt" ]; then
  echo "Prompt file already exists, leaving it as is: $CONFIG_DIR/prompt.txt"
else
  cp "$PROMPT_SOURCE" "$CONFIG_DIR/prompt.txt"
  echo "Wrote default prompt ($LANG_CHOICE): $CONFIG_DIR/prompt.txt"
fi

# --- microphone permission ----------------------------------------------

if [ "$SKIP_PERMISSION" = "1" ]; then
  echo "Skipping microphone permission trigger (--skip-permission)."
else
  echo "Triggering the microphone permission prompt..."
  TMP_DIR="$(mktemp -d -t whisper-dictate-permission)"
  TMP_WAV="$TMP_DIR/test.wav"
  TMP_LOG="$TMP_DIR/test.log"
  TMP_PID="$TMP_DIR/test.pid"

  /usr/bin/open -n "$APP_DIR" --args "$TMP_WAV" "$TMP_LOG" "$TMP_PID"

  tries=40
  while [ $tries -gt 0 ] && [ ! -f "$TMP_PID" ]; do
    tries=$((tries - 1))
    sleep 0.05
  done

  # On first run macOS shows the permission dialog now, and the recorder
  # blocks until the user answers it. Give them up to two minutes.
  echo "If macOS asks for microphone access, click Allow."
  tries=1200
  while [ $tries -gt 0 ]; do
    grep -q "recording started" "$TMP_LOG" 2>/dev/null && break
    grep -q "ERROR" "$TMP_LOG" 2>/dev/null && break
    tries=$((tries - 1))
    sleep 0.1
  done

  # Record a short sample so we can check that real audio arrives.
  sleep 2

  if [ -f "$TMP_PID" ]; then
    kill -INT "$(cat "$TMP_PID")" 2>/dev/null || true
    tries=40
    while [ $tries -gt 0 ] && [ -f "$TMP_PID" ]; do
      tries=$((tries - 1))
      sleep 0.1
    done
  fi

  # A non-empty file proves nothing: without permission macOS delivers a
  # valid WAV full of digital silence (every sample exactly 0). Check the
  # loudest sample instead. Any real microphone picks up some room noise.
  PEAK=""
  if [ -s "$TMP_WAV" ]; then
    PEAK="$("$PYTHON3" -c '
import array, sys, wave
with wave.open(sys.argv[1]) as w:
    samples = array.array("h", w.readframes(w.getnframes()))
print(max((abs(s) for s in samples), default=0))
' "$TMP_WAV" 2>/dev/null || true)"
  fi

  if [ -n "$PEAK" ] && [ "$PEAK" -gt 0 ]; then
    echo "Microphone works: real audio arrived (peak level $PEAK)."
  else
    if [ "$PEAK" = "0" ]; then
      echo "The recording contains only digital silence. Usually this means"
      echo "macOS is blocking the microphone for WhisperDictateRecorder"
      echo "(or the input device is muted)."
    else
      echo "No audio was captured."
    fi
    echo "Check System Settings > Privacy & Security > Microphone and allow"
    echo "WhisperDictateRecorder. If it is not listed, run:"
    echo "  tccutil reset Microphone io.github.whisper-dictate.recorder"
    echo "and run ./install.sh again."
    if [ -s "$TMP_LOG" ]; then
      echo "Recorder log:"
      sed 's/^/  /' "$TMP_LOG"
    fi
  fi

  rm -rf "$TMP_DIR"
fi

# --- next steps -----------------------------------------------------------

cat <<EOF

== Install complete ==

Next steps:
  1. Start a Whisper server (see README.md for options), e.g.:
       mlx-openai-server launch --model-type whisper \\
         --model-path mlx-community/whisper-large-v3-turbo \\
         --host 127.0.0.1 --port 9090
  2. In Raycast: Extensions > Script Commands > Add Script Directory,
     and add: $REPO_DIR/raycast
     Then assign a hotkey to "Dictate" (e.g. Option+Space).
  3. Grant Raycast Accessibility permission (System Settings > Privacy &
     Security > Accessibility) so it can send the paste keystroke.
  4. Edit $CONFIG_DIR/config if your Whisper server needs different
     settings, and $CONFIG_DIR/prompt.txt for your own vocabulary.

If you use a different hotkey tool instead of Raycast, just run
$REPO_DIR/bin/dictate directly - it is the whole toggle.
EOF
