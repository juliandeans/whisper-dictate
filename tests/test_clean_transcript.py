import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import clean_transcript as ct  # noqa: E402

SCRIPT = str(Path(__file__).resolve().parent.parent / "lib" / "clean_transcript.py")


class CleanTests(unittest.TestCase):
    def test_normal_text_passes_through(self):
        code, result = ct.clean("This is a normal sentence.", prompt="")
        self.assertEqual(code, 0)
        self.assertEqual(result, "This is a normal sentence.")

    def test_shrinking_echo_collapses_to_first(self):
        text = "Was sind die besten Optionen? Die besten. Besten."
        code, result = ct.clean(text, prompt="")
        self.assertEqual(code, 0)
        self.assertEqual(result, "Was sind die besten Optionen?")

    def test_five_identical_sentences_collapse_to_one(self):
        text = " ".join(["This is the same sentence."] * 5)
        code, result = ct.clean(text, prompt="")
        self.assertEqual(code, 0)
        self.assertEqual(result, "This is the same sentence.")

    def test_two_identical_sentences_are_kept(self):
        text = "This is the same sentence. This is the same sentence."
        code, result = ct.clean(text, prompt="")
        self.assertEqual(code, 0)
        self.assertEqual(result, text)

    def test_vielen_dank_is_hallucination(self):
        code, result = ct.clean("Vielen Dank.", prompt="")
        self.assertEqual(code, 2)
        self.assertEqual(result, "")

    def test_thanks_for_watching_is_hallucination(self):
        code, result = ct.clean("Thanks for watching!", prompt="")
        self.assertEqual(code, 2)
        self.assertEqual(result, "")

    def test_prompt_fragment_of_three_or_more_words_is_dropped(self):
        prompt = "The script writes its log file every time it runs."
        code, result = ct.clean("The script writes its log", prompt=prompt)
        self.assertEqual(code, 2)
        self.assertEqual(result, "")

    def test_two_word_text_contained_in_prompt_is_kept(self):
        prompt = "The script writes its log file every time it runs."
        code, result = ct.clean("The script", prompt=prompt)
        self.assertEqual(code, 0)
        self.assertEqual(result, "The script")

    def test_invalid_json_via_main_exits_1(self):
        proc = subprocess.run(
            [sys.executable, SCRIPT, "some prompt"],
            input="not json",
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 1)

    def test_extra_phrase_from_file_is_hallucination(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False, encoding="utf-8"
        ) as f:
            f.write("# comment\nMusic playing.\n")
            path = f.name
        try:
            env = dict(os.environ)
            env["EXTRA_HALLUCINATIONS_FILE"] = path
            proc = subprocess.run(
                [sys.executable, SCRIPT, ""],
                input=json.dumps({"text": "Music playing."}),
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(proc.returncode, 2)
            self.assertEqual(proc.stdout, "")
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
