#!/bin/bash
# Shared logic for bin/dictate. Sourced, not executed directly.
#
# Public functions:
#   dictate_recording_active   -> 0 if a recording is currently running
#   dictate_start               -> starts the recording, caller should exit
#   dictate_transcribe          -> stops, transcribes, sets $TEXT and
#                                  $FOCUSED_APP; aborts (fail) on error

set -u

# Raycast v2 sets LC_ALL to an invalid macOS locale id (e.g.
# "en-US-u-ca-gregory-...-tz-xyz" instead of a real locale like
# "en_US.UTF-8"). pbcopy relies on this variable to encode the clipboard and
# produces mojibake for non-ASCII characters as a result. Override it
# unconditionally, regardless of what the caller sets.
export LC_ALL=en_US.UTF-8

# No hardcoded absolute tool paths: resolve everything through PATH, with
# common Homebrew locations added as a fallback so this also works when
# invoked from a minimal launchd/Raycast environment.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --- locate the repository -------------------------------------------------

# REPO is the directory containing bin/ and lib/, resolved from this file's
# real location (following symlinks, e.g. from raycast/dictate.sh).
_common_sh_source="${BASH_SOURCE[0]}"
while [ -L "$_common_sh_source" ]; do
  _common_sh_dir="$(cd -P "$(dirname "$_common_sh_source")" && pwd)"
  _common_sh_source="$(readlink "$_common_sh_source")"
  [[ "$_common_sh_source" != /* ]] && _common_sh_source="$_common_sh_dir/$_common_sh_source"
done
LIB_DIR="$(cd -P "$(dirname "$_common_sh_source")" && pwd)"
REPO="$(cd -P "$LIB_DIR/.." && pwd)"
unset _common_sh_source _common_sh_dir

# --- configuration -----------------------------------------------------

_load_config() {
  local config_file="${WHISPER_DICTATE_CONFIG:-$HOME/.config/whisper-dictate/config}"

  # Environment variables must win over the config file. Snapshot whichever
  # of these are already set in the environment, source the file (which
  # would otherwise overwrite them), then re-apply the snapshot.
  local keys=(WHISPER_URL WHISPER_MODEL WHISPER_API_KEY LANGUAGE PROMPT_FILE
    MIC MIC_INPUT_VOLUME EXTRA_HALLUCINATIONS_FILE PASTE)
  local key
  for key in "${keys[@]}"; do
    if [ -n "${!key+x}" ]; then
      eval "_env_override_$key=\${$key}"
    fi
  done

  if [ -r "$config_file" ]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  for key in "${keys[@]}"; do
    local override_var="_env_override_$key"
    if [ -n "${!override_var+x}" ]; then
      eval "$key=\${$override_var}"
    fi
    unset "$override_var" 2>/dev/null || true
  done
}

_load_config

WHISPER_URL="${WHISPER_URL:-http://127.0.0.1:9090/v1/audio/transcriptions}"
WHISPER_MODEL="${WHISPER_MODEL:-whisper-large-v3-turbo}"
WHISPER_API_KEY="${WHISPER_API_KEY:-}"
LANGUAGE="${LANGUAGE:-}"
PROMPT_FILE="${PROMPT_FILE:-$HOME/.config/whisper-dictate/prompt.txt}"
MIC="${MIC:-}"
MIC_INPUT_VOLUME="${MIC_INPUT_VOLUME:-}"
EXTRA_HALLUCINATIONS_FILE="${EXTRA_HALLUCINATIONS_FILE:-$HOME/.config/whisper-dictate/hallucinations.txt}"
PASTE="${PASTE:-1}"
export EXTRA_HALLUCINATIONS_FILE

DICTATE_TITLE="Dictate"

# --- state directory ---------------------------------------------------

STATE_DIR="${TMPDIR:-/tmp}/whisper-dictate"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

FLAGFILE="$STATE_DIR/recording"
PIDFILE="$STATE_DIR/recorder.pid"
APPFILE="$STATE_DIR/app"
WAVFILE="$STATE_DIR/recording.wav"
LOGFILE="$STATE_DIR/trace.log"
RECLOG="$STATE_DIR/recorder.log"
RESPONSEFILE="$STATE_DIR/last-response.json"

# The WAV from the recorder is 16 kHz, mono, 16-bit - exactly what Whisper
# expects. It is therefore sent unmodified (no ffmpeg preprocessing).
WAV_BYTES_PER_SEC=32000
MIN_WAV_BYTES=8000 # ~0.25s - anything shorter was an accidental trigger

log() { echo "$(date '+%H:%M:%S') $*" >>"$LOGFILE"; }

notify() { osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null; }

fail() {
  log "ERROR: $1"
  # A failed start must not leave its lock behind, or the next press would
  # be ignored as a "still starting" duplicate.
  [ "${DICTATE_OWNS_LOCK:-0}" = 1 ] && rm -rf "$FLAGFILE"
  notify "$DICTATE_TITLE" "$1"
  exit 1
}

# Load the initial_prompt from PROMPT_FILE. Comment lines (#) are stripped,
# the rest is joined into one paragraph. Without a file the prompt stays
# empty - Whisper still works, just with worse punctuation.
_load_prompt() {
  [ -r "$PROMPT_FILE" ] || {
    log "WARNING: no prompt file ($PROMPT_FILE) - transcription quality will suffer"
    return 0
  }
  grep -v '^[[:space:]]*#' "$PROMPT_FILE" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
}

WHISPER_PROMPT="$(_load_prompt)"

_find_recorder_app() {
  local candidate="${RECORDER_APP:-$REPO/build/WhisperDictateRecorder.app}"
  [ -e "$candidate" ] || return 1
  echo "$candidate"
}

# Waits until PID $1 is gone, at most $2 tenths of a second.
_wait_for_exit() {
  local pid="$1" tries="$2"
  while [ "$tries" -gt 0 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

dictate_recording_active() {
  [ -d "$FLAGFILE" ] || return 1
  # Clean up if the recorder process has died without the flag being removed.
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    # Between mkdir and the recorder writing its PID file there is a short
    # window without a PID. A second press in that window is a double
    # trigger, not an orphan: leave the lock alone.
    local age=$(( $(date +%s) - $(stat -f%m "$FLAGFILE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 10 ]; then
      log "Recording is still starting - ignoring duplicate call"
      exit 0
    fi
  fi
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    log "Orphaned lock (PID '$pid' not alive) - cleaning up"
    rm -rf "$FLAGFILE"
    rm -f "$PIDFILE" "$APPFILE"
    return 1
  fi
  return 0
}

dictate_start() {
  # Atomic lock against a hotkey firing twice: mkdir cannot succeed twice at
  # once. Without this, two near-simultaneous invocations would each start
  # their own recorder process; only the one whose PID ends up in $PIDFILE
  # last would ever be stopped, and the other would keep the microphone
  # open as a zombie.
  if ! mkdir "$FLAGFILE" 2>/dev/null; then
    log "Recording already active or starting concurrently - ignoring duplicate call"
    exit 0
  fi
  DICTATE_OWNS_LOCK=1

  log "-> START recording"

  FOCUSED_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
  log "Focused app: $FOCUSED_APP"
  echo "$FOCUSED_APP" >"$APPFILE"

  local app
  app=$(_find_recorder_app) ||
    fail "Recorder app not found - run ./install.sh"
  log "Recorder: $app"

  # The recorder only appends to its log. Start fresh so an old
  # "recording started" or ERROR line cannot fake or block this handshake.
  rm -f "$WAVFILE" "$PIDFILE" "$RECLOG"

  if [ -n "$MIC" ] && command -v SwitchAudioSource >/dev/null 2>&1; then
    local current
    current=$(SwitchAudioSource -c -t input 2>/dev/null)
    if [ "$current" != "$MIC" ]; then
      log "Input device '$current' -> '$MIC'"
      SwitchAudioSource -t input -s "$MIC" >/dev/null 2>&1 ||
        log "WARNING: could not select '$MIC'"
    fi
  fi

  if [ -n "$MIC_INPUT_VOLUME" ]; then
    log "Setting input volume to $MIC_INPUT_VOLUME"
    osascript -e "set volume input volume $MIC_INPUT_VOLUME" 2>/dev/null ||
      log "WARNING: could not set input volume"
  fi

  # `open -n` detaches the app from the calling script's process.
  /usr/bin/open -n "$app" --args "$WAVFILE" "$RECLOG" "$PIDFILE"

  # The recorder writes its PID file first, then logs "recording started".
  # Wait for both - the log line is the real readiness signal.
  local tries=60
  while [ $tries -gt 0 ] && [ ! -f "$PIDFILE" ]; do
    tries=$((tries - 1))
    sleep 0.05
  done
  [ -f "$PIDFILE" ] || {
    log "Recorder log: $(tail -5 "$RECLOG" 2>/dev/null)"
    fail "Recorder did not start (microphone busy?)"
  }

  local pid
  pid=$(cat "$PIDFILE")
  { [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null; } ||
    fail "Recorder PID '$pid' invalid"

  tries=60
  while [ $tries -gt 0 ]; do
    grep -q "recording started" "$RECLOG" 2>/dev/null && break
    grep -q "ERROR" "$RECLOG" 2>/dev/null && fail "Recorder reported an error - check $RECLOG"
    tries=$((tries - 1))
    sleep 0.05
  done
  [ $tries -gt 0 ] || fail "Recorder never became ready"

  DICTATE_OWNS_LOCK=0
  log "Recording started (PID $pid)"
  notify "$DICTATE_TITLE" "Recording..."
}

# Stops the recording and transcribes it. Sets $TEXT and $FOCUSED_APP.
dictate_transcribe() {
  log "-> STOP recording + transcribe"

  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  FOCUSED_APP=$(cat "$APPFILE" 2>/dev/null || true)
  rm -rf "$FLAGFILE"
  rm -f "$PIDFILE" "$APPFILE"

  # SIGINT so the recorder finishes the WAV file cleanly itself. A fast hard
  # kill would cut off the end of the sentence.
  if [ -n "$pid" ]; then
    log "Stopping recorder (PID $pid)"
    kill -INT "$pid" 2>/dev/null || true
    _wait_for_exit "$pid" 40 || {
      log "Recorder still alive after SIGINT - KILL"
      kill -9 "$pid" 2>/dev/null || true
      sleep 0.3
    }
  fi

  # Wait until the file size stops changing.
  local last=0 current=0 tries=20
  while [ $tries -gt 0 ]; do
    current=$(stat -f%z "$WAVFILE" 2>/dev/null || echo 0)
    [ "$current" -gt 0 ] && [ "$current" = "$last" ] && break
    last="$current"
    tries=$((tries - 1))
    sleep 0.1
  done

  log "Recording: ${current} bytes (~$((current / WAV_BYTES_PER_SEC))s)"
  [ "$current" -ge "$MIN_WAV_BYTES" ] || fail "Recording too short or empty"

  # Any HTTP answer counts as reachable - cloud endpoints may reject the
  # unauthenticated GET, but that still proves the server is up.
  local models_url="${WHISPER_URL%/audio/transcriptions}/models" http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$models_url" 2>/dev/null)
  { [ -n "$http_code" ] && [ "$http_code" != "000" ]; } ||
    fail "Whisper server not reachable ($WHISPER_URL)"

  log "Sending to Whisper (model=$WHISPER_MODEL, prompt=${#WHISPER_PROMPT} chars)"

  local -a curl_args=(
    -sS --max-time 120 -X POST
    -F "file=@$WAVFILE;type=audio/wav"
    -F "model=$WHISPER_MODEL"
    -F "temperature=0"
    -F "response_format=json"
    -F "prompt=$WHISPER_PROMPT"
  )
  [ -n "$LANGUAGE" ] && curl_args+=(-F "language=$LANGUAGE")
  [ -n "$WHISPER_API_KEY" ] && curl_args+=(-H "Authorization: Bearer $WHISPER_API_KEY")

  local response
  response=$(curl "${curl_args[@]}" "$WHISPER_URL" 2>>"$LOGFILE")

  printf '%s' "$response" >"$RESPONSEFILE"

  TEXT=$(printf '%s' "$response" | python3 "$LIB_DIR/clean_transcript.py" "$WHISPER_PROMPT")
  local rc=$?
  case $rc in
    0) ;;
    2) fail "Only silence detected" ;;
    *) fail "Response unreadable - check $RESPONSEFILE" ;;
  esac
  [ -n "$TEXT" ] || fail "No text recognized"

  log "Text: $TEXT"
}
