#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Dictate
# @raycast.mode silent
# @raycast.packageName whisper-dictate
# @raycast.icon 🎤
#
# Raycast Script Command entry point. Resolves its own real location
# (following symlinks, since Raycast script directories are often symlinked
# in) and execs bin/dictate from there.

set -u

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_SOURCE" ]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"

exec "$REPO_DIR/bin/dictate"
