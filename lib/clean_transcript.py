#!/usr/bin/env python3
"""Clean a Whisper JSON transcription response.

Reads a Whisper `/v1/audio/transcriptions` JSON response on stdin, and the
initial_prompt that was sent as argv[1]. Prints the cleaned transcript text
to stdout.

Exit codes:
  0 - cleaned text printed to stdout
  1 - response was not readable JSON (or had no "text" field)
  2 - the whole result was a hallucination (silence) or an echo of the
      prompt, so there is no real transcript to use

Standard library only, Python 3.9 compatible (this is the version macOS
ships as /usr/bin/python3).
"""

import json
import re
import sys
import unicodedata

# Phrases Whisper is known to invent on pure silence, instead of returning
# empty text. German ones come from a Whisper server tested against German
# audio; the English ones are the common equivalents reported for English
# audio (subtitle credits, "thank you for watching" outros, etc.).
BUILTIN_HALLUCINATIONS = (
    "Vielen Dank.",
    "Danke.",
    "Untertitel von Stephanie Geiges",
    "Untertitelung des ZDF, 2020",
    "Copyright WDR 2021",
    "Thank you.",
    "Thanks for watching!",
    "Thank you for watching.",
    "Subtitles by the Amara.org community",
)


def split_sentences(text):
    return [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()]


def norm(text):
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[^\w\s]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def words(text):
    return norm(text).split()


def is_echo(anchor_words, prev_len, cand_words):
    """Is `cand_words` a shrinking echo of the anchor sentence?

    On trailing silence, Whisper often tails off with a shrinking echo of
    the last real sentence: each repeat is one word shorter than the one
    before it, not word-for-word identical
    ("... the best options?" -> "... the best." -> "... best.").
    An exact-match comparison misses this entirely. A candidate counts as an
    echo when it has strictly fewer words than the previous sentence in the
    run, and almost all of its words come from the anchor sentence.
    """
    if not cand_words or not anchor_words or len(cand_words) >= prev_len:
        return False
    overlap = len(set(cand_words) & set(anchor_words))
    return overlap / len(cand_words) >= 0.7


def collapse_repeats(text):
    """Collapse runs of >=3 identical-or-echo sentences down to the first.

    Whisper can also get stuck in a loop and repeat the exact same sentence
    dozens of times verbatim. From three sentences in a row on - identical
    or a shrinking echo - only the first (most complete) one survives.
    """
    parts = split_sentences(text)
    out = []
    i = 0
    while i < len(parts):
        j = i
        anchor_words = words(parts[i])
        prev_len = len(anchor_words)
        while j + 1 < len(parts):
            cand_norm = norm(parts[j + 1])
            if cand_norm == norm(parts[i]):
                j += 1
                prev_len = len(cand_norm.split())
                continue
            cand_words = cand_norm.split()
            if is_echo(anchor_words, prev_len, cand_words):
                j += 1
                prev_len = len(cand_words)
                continue
            break
        run_len = j - i + 1
        out.extend(parts[i:i + 1] if run_len >= 3 else parts[i:j + 1])
        i = j + 1
    return " ".join(out)


def clean(text, prompt, extra_phrases=()):
    """Clean `text` given the `prompt` that was sent alongside it.

    Returns (code, result): code 0 with the cleaned text, or code 2 with an
    empty string when the result is nothing but a hallucination or an echo
    of the prompt.
    """
    result = collapse_repeats(text)

    hallucinations = set(norm(s) for s in BUILTIN_HALLUCINATIONS)
    hallucinations.update(norm(s) for s in extra_phrases if s.strip())

    result_norm = norm(result)
    prompt_norm = norm(prompt)

    if not result_norm or result_norm in hallucinations:
        return 2, ""

    # Substring, not equality: Whisper also echoes fragments of the prompt
    # sentence ("The script writes." out of a longer prompt sentence). From
    # three words on, so a genuinely short dictation like "The script."
    # is not discarded just because it happens to occur in the prompt.
    if len(result_norm.split()) >= 3 and result_norm in prompt_norm:
        return 2, ""

    return 0, result


def _load_extra_phrases(path):
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return []
    return [
        line.strip()
        for line in lines
        if line.strip() and not line.strip().startswith("#")
    ]


def main():
    import os

    prompt = sys.argv[1] if len(sys.argv) > 1 else ""

    try:
        data = json.load(sys.stdin)
        text = (data.get("text") or "").strip()
    except Exception:
        sys.exit(1)

    extra_phrases = _load_extra_phrases(os.environ.get("EXTRA_HALLUCINATIONS_FILE", ""))

    code, result = clean(text, prompt, extra_phrases)
    if code == 0:
        sys.stdout.write(result)
    sys.exit(code)


if __name__ == "__main__":
    main()
