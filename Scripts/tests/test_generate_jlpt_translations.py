from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "generate_jlpt_translations.py"
SPEC = importlib.util.spec_from_file_location("generate_jlpt_translations", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
generate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generate
SPEC.loader.exec_module(generate)


class IdentityConverter:
    def convert(self, value: str) -> str:
        return value.replace("學", "学")


class TranslationGenerationTests(unittest.TestCase):
    def test_direct_translation_prefers_already_simplified_then_stable_id(self) -> None:
        selected = generate.choose_direct_translation(
            ["20", "10"],
            {"10": ["200"], "20": ["100", "300"]},
            {"100": "我去学校。", "200": "我去學校。", "300": "我要去学校。"},
            IdentityConverter(),
        )

        self.assertEqual(selected, ("20", "100", "我去学校。"))

    def test_translation_must_be_nonempty_bounded_chinese_text(self) -> None:
        generate.validate_translation("我没有去。", "example:ok")

        for value in ("", "school", "我\x00去"):
            with self.assertRaises(ValueError):
                generate.validate_translation(value, "example:bad")

    def test_batches_preserve_order_without_randomness(self) -> None:
        self.assertEqual(
            list(generate.batches(["a", "b", "c", "d", "e"], 2)),
            [["a", "b"], ["c", "d"], ["e"]],
        )

    def test_review_overrides_are_source_bound_and_hashed(self) -> None:
        payload = {
            "formatVersion": 1,
            "reviews": [
                {
                    "exampleID": "example:1",
                    "japanese": "五は八より少ない。",
                    "english": "Five is less than eight.",
                    "translationZh": "五小于八。",
                    "reason": "修正数字比较语义。",
                    "replacesSource": "opus_mt_en_zh",
                }
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "overrides.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

            reviews, digest = generate.load_review_overrides(path)

        self.assertEqual(reviews["example:1"]["translationZh"], "五小于八。")
        self.assertEqual(len(digest), 64)

    def test_model_sanitizer_removes_only_trailing_english_clause(self) -> None:
        self.assertEqual(
            generate.sanitize_model_translation("我能做到 I can do it."),
            "我能做到",
        )
        self.assertEqual(
            generate.sanitize_model_translation("A 大小与 B 相等。"),
            "A 大小与 B 相等。",
        )


if __name__ == "__main__":
    unittest.main()
