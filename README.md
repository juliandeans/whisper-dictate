# whisper-dictate

Push-to-talk dictation for macOS, backed by a local (or remote) Whisper
server.

Press a hotkey, speak, press it again. The recording is sent to an
OpenAI-compatible `/v1/audio/transcriptions` endpoint, the transcript is
cleaned of common Whisper hallucinations, and the result is pasted at the
cursor in whatever app was focused when you started recording.

```
hotkey press #1        speak            hotkey press #2
      |                                        |
      v                                        v
 start recording  ------------------->  stop, send WAV to Whisper,
 (recorder.app,                         clean transcript, paste at
  16kHz mono WAV)                       cursor in the focused app
```

This project does **not** install or manage a Whisper server - bring your
own. It only handles the recording, the toggle, the cleanup, and the
paste.

## Requirements

- macOS
- Xcode Command Line Tools (for `swiftc`, and the `python3` used to clean
  transcripts - standard library only, no packages) - `xcode-select --install`
- A Whisper server exposing an OpenAI-compatible
  `/v1/audio/transcriptions` endpoint (see below)
- [Raycast](https://raycast.com) (or any other hotkey/launcher tool that
  can run a shell command)
- Optional: [switchaudio-osx](https://github.com/deweller/switchaudio-osx)
  (`brew install switchaudio-osx`) if you want automatic input-device
  switching

## Install

```sh
git clone https://github.com/<your-user>/whisper-dictate.git
cd whisper-dictate
./install.sh          # or: ./install.sh --lang de
```

This builds `build/WhisperDictateRecorder.app`, ad-hoc signs it, creates
`~/.config/whisper-dictate/` with a default `config` and `prompt.txt` (only
if they don't already exist), and triggers the microphone permission
prompt once. Use `./install.sh --skip-permission` to only build and
configure.

## Start a Whisper server

Any OpenAI-compatible `/v1/audio/transcriptions` endpoint works. On Apple
Silicon, the recommended option is
[mlx-openai-server](https://github.com/cubist38/mlx-openai-server):

```sh
mlx-openai-server launch --model-type whisper \
  --model-path mlx-community/whisper-large-v3-turbo --port 9090
```

Alternatives:

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)'s built-in
  `whisper-server`, which also speaks the OpenAI API shape
- A cloud endpoint (e.g. OpenAI's own `/v1/audio/transcriptions`) - set
  `WHISPER_URL` and `WHISPER_API_KEY` accordingly

## Raycast setup

1. Raycast > Extensions > Script Commands > **Add Script Directory**, and
   point it at this repo's `raycast/` folder.
2. Find "Dictate" in Raycast and assign it a hotkey, e.g. `⌥Space`.
3. Grant Raycast **Accessibility** permission (System Settings > Privacy &
   Security > Accessibility) - it needs this to send the paste keystroke
   (`Cmd+V`) into the focused app.

## Other hotkey tools

`bin/dictate` is the entire toggle and takes no arguments. Bind any hotkey
tool (Hammerspoon, BetterTouchTool, Keyboard Maestro, a keyboard's own
macro layer, ...) to run it directly:

```sh
/path/to/whisper-dictate/bin/dictate
```

## Configuration

Config lives at `~/.config/whisper-dictate/config`, outside the repo, so a
`git pull` never touches your settings. It is a plain `KEY=value` shell
file (see `config.example` for the commented version); environment
variables of the same name override it.

| Key | Meaning |
|---|---|
| `WHISPER_URL` | Full URL of the `/v1/audio/transcriptions` endpoint |
| `WHISPER_MODEL` | Model name sent in the request |
| `WHISPER_API_KEY` | Optional bearer token, for cloud endpoints |
| `LANGUAGE` | Output language hint (e.g. `de`, `en`); empty = auto-detect |
| `PROMPT_FILE` | Path to the initial_prompt text file |
| `MIC` | Input device name to switch to (needs switchaudio-osx); empty = leave as is |
| `MIC_INPUT_VOLUME` | 0-100 input volume to set; empty = don't touch (system-wide, persistent!) |
| `EXTRA_HALLUCINATIONS_FILE` | Extra hallucination phrases, one per line |
| `PASTE` | `1` = paste at cursor, `0` = clipboard only |

Override `~/.config/whisper-dictate/config` itself with
`WHISPER_DICTATE_CONFIG=/some/other/path`.

## Writing a good prompt

`~/.config/whisper-dictate/prompt.txt` becomes Whisper's `initial_prompt`.
It is not an instruction to the model - it is faked "preceding transcript
text", and Whisper continues whatever style it sees there. Measured rules
(see `prompts/en.txt` / `prompts/de.txt` for the full explanation and an
example):

1. Write whole, correctly punctuated sentences - this is the actual reason
   the output gets punctuation and capitalization at all.
2. Use your domain's technical terms inside sentences, not as a bare word
   list - prose measurably beats a list.
3. Put the most important terms in the **last** sentence - the prompt sits
   directly before the audio, and the end has the strongest effect. Keep
   the whole thing short: Whisper only reads roughly the last 223 tokens.
4. No meta-instructions ("add punctuation") - such words tend to leak
   verbatim into the transcript.

## Why it works this way / lessons learned

- **The recorder must be a real app bundle**, not a bare CLI binary. macOS
  silently hands a CLI process silence instead of audio - no error, no
  permission dialog - unless the process belongs to an app bundle with
  `NSMicrophoneUsageDescription` in its `Info.plist`. The bundle is ad-hoc
  signed (`codesign --force --sign -`) so the signature covers the
  `Info.plist`. An ad-hoc signature changes with every rebuild, so macOS
  may ask for microphone access again after you re-run `./install.sh`.
- **Hallucinations and the echo filter.** On silence, Whisper doesn't
  return empty text - it invents plausible-sounding phrases (subtitle
  credits, "thank you for watching", or a fragment of the prompt itself).
  On silence right after speech, it often instead produces a *shrinking
  echo* of the last sentence, one word shorter each repeat, which an exact
  string comparison won't catch. `lib/clean_transcript.py` filters both: a
  fixed hallucination list plus a prompt-substring check, and a
  word-overlap heuristic for the shrinking echo, plus collapsing runs of
  3+ repeated/echoed sentences down to one.
- **No ffmpeg preprocessing.** Noise removal, denoising, and normalization
  filters were tested and measured **zero** benefit. They are deliberately
  not included - don't re-add them without measuring first.
- **16 kHz mono 16-bit is exactly what Whisper wants.** The recorder
  produces this format directly so the WAV is sent unmodified.
- **Microphone clipping.** Some built-in microphones clip audibly at the
  default macOS input volume of 100. Setting `MIC_INPUT_VOLUME=75` (or
  similar) fixes it, but note this is a **system-wide, persistent** macOS
  setting - it is off by default here for that reason.
- **`LC_ALL` and mojibake.** Some launchers (Raycast v2 included) set
  `LC_ALL` to an invalid macOS locale id. `pbcopy` relies on `LC_ALL` to
  encode the clipboard and produces mojibake for accented/non-ASCII
  characters if it's invalid. `lib/common.sh` overrides it unconditionally.
- **The double-trigger lock.** A hotkey firing twice in quick succession
  (bouncy key, double bind) would otherwise start two recorder processes;
  only one PID ever gets tracked, so the other becomes an orphan holding
  the microphone open. An atomic `mkdir` lock (mkdir can't succeed twice at
  once) prevents that.

## Troubleshooting

State and logs live in `$TMPDIR/whisper-dictate/` (`echo $TMPDIR` to find
it):

- `trace.log` - the toggle's own log (start/stop, Whisper call, errors)
- `recorder.log` - the recorder app's log
- `last-response.json` - the raw Whisper response from the last call

**Empty or silent recordings / no permission dialog ever appeared:**
reset the microphone permission and try again:

```sh
tccutil reset Microphone io.github.whisper-dictate.recorder
./install.sh
```

**Recorder app not found:** run `./install.sh` - `bin/dictate` looks for
`build/WhisperDictateRecorder.app` and fails with a clear message if it's
missing.

**Whisper server not reachable:** `lib/common.sh` checks the server's
`/v1/models` endpoint before sending audio, and fails fast with the URL it
tried if that check fails.

## License

MIT, see [LICENSE](LICENSE).
