from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "build_jlpt_library.py"
MANIFEST_PATH = Path(__file__).resolve().parents[1] / "jlpt_sources_v2.json"
MODEL_MANIFEST_PATH = (
    Path(__file__).resolve().parents[1] / "jlpt_translation_model_v1.json"
)
SPEC = importlib.util.spec_from_file_location("build_jlpt_library", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
build_jlpt_library = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = build_jlpt_library
SPEC.loader.exec_module(build_jlpt_library)


class SourceManifestTests(unittest.TestCase):
    def test_committed_manifest_is_complete(self) -> None:
        manifest = build_jlpt_library.load_source_manifest(MANIFEST_PATH)

        self.assertEqual(manifest["manifestVersion"], 1)
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(set(manifest["sources"]), build_jlpt_library.REQUIRED_SOURCE_IDS)

    def test_missing_license_metadata_fails_before_source_reads(self) -> None:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        manifest["sources"]["unidic_cwj"]["license"] = ""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "missing license metadata"):
                build_jlpt_library.load_source_manifest(path)

    def test_missing_source_file_fails(self) -> None:
        metadata = {"bytes": 1, "sha256": "0" * 64}

        with self.assertRaisesRegex(FileNotFoundError, "required source file"):
            build_jlpt_library.verify_source_file(
                Path("/definitely/not/an/oboe/source"), metadata, "fixture"
            )

    def test_hash_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.bin"
            path.write_bytes(b"locked input")
            metadata = {"bytes": path.stat().st_size, "sha256": "0" * 64}

            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                build_jlpt_library.verify_source_file(path, metadata, "fixture")

    def test_notice_generation_is_deterministic(self) -> None:
        manifest = build_jlpt_library.load_source_manifest(MANIFEST_PATH)
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.txt"
            second = Path(directory) / "second.txt"

            build_jlpt_library.write_notice(first, manifest)
            build_jlpt_library.write_notice(second, manifest)

            self.assertEqual(first.read_bytes(), second.read_bytes())


class SchemaV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        build_jlpt_library.create_schema(self.connection)

    def tearDown(self) -> None:
        self.connection.close()

    def test_schema_v2_columns_are_present(self) -> None:
        vocab_columns = {
            row["name"] for row in self.connection.execute("PRAGMA table_info(vocab)")
        }
        example_columns = {
            row["name"]
            for row in self.connection.execute("PRAGMA table_info(vocab_examples)")
        }

        self.assertTrue(
            {"pitch_accent", "pitch_source", "pitch_source_ref"}.issubset(
                vocab_columns
            )
        )
        self.assertTrue(
            {
                "translation_zh",
                "source_sentence_id",
                "translation_source",
                "translation_source_ref",
            }.issubset(example_columns)
        )

    def test_schema_v2_foreign_key_and_indexes_are_present(self) -> None:
        foreign_keys = self.connection.execute(
            "PRAGMA foreign_key_list(vocab_examples)"
        ).fetchall()
        self.assertTrue(
            any(
                row["table"] == "vocab"
                and row["from"] == "vocab_id"
                and row["to"] == "id"
                and row["on_delete"] == "CASCADE"
                for row in foreign_keys
            )
        )
        index_names = {
            row["name"]
            for table in ("vocab", "vocab_examples")
            for row in self.connection.execute(f"PRAGMA index_list({table})")
        }
        self.assertTrue(
            {
                "idx_vocab_pitch_source",
                "idx_vocab_examples_source_sentence",
                "idx_vocab_examples_translation_source",
            }.issubset(index_names)
        )

    def test_schema_v2_rejects_orphaned_provenance(self) -> None:
        with self.assertRaises(sqlite3.IntegrityError):
            self.connection.execute(
                """
                INSERT INTO vocab(
                    id, level, headword, reading, meaning_en_json,
                    pitch_source, normalized_headword, normalized_reading,
                    sort_order, data_flags
                ) VALUES ('id', 'N5', '語', 'ご', '[]', 'unidic', '語', 'ご', 0, 0)
                """
            )


class TranslationCoverageTests(unittest.TestCase):
    def coverage_lines(self, translation: str = "我去上学。") -> str:
        metadata = {
            "type": "meta",
            "formatVersion": 1,
            "exampleCount": 1,
            "modelRepository": "fixture/model",
            "modelRevision": "revision",
            "modelWeightsSHA256": "a" * 64,
        }
        record = {
            "type": "translation",
            "exampleID": "example:1",
            "level": "N5",
            "japanese": "学校へ行きます。",
            "english": "I go to school.",
            "translationZh": translation,
            "sourceSentenceID": "123",
            "translationSource": "opus_mt_en_zh",
            "translationSourceRef": "model:fixture",
            "status": "generated",
        }
        return "\n".join(
            json.dumps(value, ensure_ascii=False) for value in (metadata, record)
        ) + "\n"

    def test_valid_translation_coverage_loads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coverage.jsonl"
            path.write_text(self.coverage_lines(), encoding="utf-8")
            with mock.patch.object(build_jlpt_library, "EXPECTED_EXAMPLE_COUNT", 1):
                metadata, records = build_jlpt_library.load_translation_coverage(path)

        self.assertEqual(metadata["exampleCount"], 1)
        self.assertEqual(records["example:1"]["translationZh"], "我去上学。")

    def test_translation_without_cjk_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coverage.jsonl"
            path.write_text(self.coverage_lines("school"), encoding="utf-8")
            with mock.patch.object(build_jlpt_library, "EXPECTED_EXAMPLE_COUNT", 1):
                with self.assertRaisesRegex(ValueError, "line 2 is invalid"):
                    build_jlpt_library.load_translation_coverage(path)

    def test_translation_model_manifest_must_match_coverage(self) -> None:
        metadata = json.loads(MODEL_MANIFEST_PATH.read_text(encoding="utf-8"))
        model = metadata["model"]
        coverage = {
            "modelManifestSHA256": build_jlpt_library.sha256_file(
                MODEL_MANIFEST_PATH
            ),
            "modelRepository": model["repository"],
            "modelRevision": model["revision"],
            "modelWeightsSHA256": model["files"]["pytorch_model.bin"]["sha256"],
        }

        digest = build_jlpt_library.verify_translation_model_manifest(
            MODEL_MANIFEST_PATH, coverage
        )

        self.assertEqual(digest, coverage["modelManifestSHA256"])
        coverage["modelRevision"] = "different"
        with self.assertRaisesRegex(ValueError, "identity is inconsistent"):
            build_jlpt_library.verify_translation_model_manifest(
                MODEL_MANIFEST_PATH, coverage
            )


if __name__ == "__main__":
    unittest.main()
