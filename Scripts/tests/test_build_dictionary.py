from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "build_dictionary.py"
MANIFEST_PATH = Path(__file__).resolve().parents[1] / "dictionary_sources_v1.json"
DATA_DIR = Path(__file__).resolve().parents[1] / "DictionaryData"
FIXTURE_XML = DATA_DIR / "jmdict_fixture.xml"
FIXTURE_DB = DATA_DIR / "tomoshi_fixture.db"
FIXTURE_MANIFEST = DATA_DIR / "dictionary_fixture_manifest.json"
FIXTURE_QA = DATA_DIR / "dictionary_fixture_qa_cases.json"
SPEC = importlib.util.spec_from_file_location("build_dictionary", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
build_dictionary = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = build_dictionary
SPEC.loader.exec_module(build_dictionary)


def write_manifest(directory: Path, jmdict: Path, overlay: Path) -> Path:
    manifest = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    for source_id, file_id, path in (
        ("jmdict_e", "JMdict_e", jmdict),
        ("tomoshi", "tomoshi-dict-open.db", overlay),
    ):
        files = manifest["sources"][source_id]["files"][file_id]
        files["bytes"] = path.stat().st_size
        files["sha256"] = build_dictionary.sha256_file(path)
    path = directory / "manifest.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    return path


def run_build(
    directory: Path,
    jmdict: Path,
    overlay: Path,
    qa_cases: Path = FIXTURE_QA,
) -> tuple[dict, Path, Path, Path]:
    manifest = write_manifest(directory, jmdict, overlay)
    output = directory / "dict.sqlite"
    notice = directory / "NOTICE.txt"
    report = directory / "report.json"

    class Args:
        pass

    args = Args()
    args.source_manifest = manifest
    args.jmdict = jmdict
    args.chinese_overlay = overlay
    args.qa_cases = qa_cases
    args.generated_at = "2026-01-01T00:00:00Z"
    args.output = output
    args.notice = notice
    args.report = report
    args.validate_existing = False
    result = build_dictionary.build(args)
    return result, output, notice, report


class SourceManifestTests(unittest.TestCase):
    def test_committed_manifest_is_complete(self) -> None:
        manifest = build_dictionary.load_source_manifest(MANIFEST_PATH)
        self.assertEqual(manifest["manifestVersion"], 1)
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(set(manifest["sources"]), {"jmdict_e", "tomoshi"})
        self.assertEqual(
            manifest["sources"]["jmdict_e"]["files"]["JMdict_e"]["bytes"], 63130780
        )
        self.assertEqual(
            manifest["sources"]["tomoshi"]["files"]["tomoshi-dict-open.db"]["sha256"],
            "8b19c7d65a7d7d6df9afc58832b17b22fd349724e5d06d2acf3bb9a6c4b0ed9d",
        )

    def test_fixture_manifest_is_complete(self) -> None:
        manifest = build_dictionary.load_source_manifest(FIXTURE_MANIFEST)
        self.assertEqual(manifest["datasetVersion"], "2026.01.01-1")

    def test_missing_license_metadata_fails(self) -> None:
        manifest = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
        manifest["sources"]["tomoshi"]["license"] = ""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing license metadata"):
                build_dictionary.load_source_manifest(path)

    def test_tomoshi_consumed_tables_allowlist(self) -> None:
        manifest = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
        manifest["sources"]["tomoshi"]["consumedTables"].append("entries")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "allowlist"):
                build_dictionary.load_source_manifest(path)

    def test_sha_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.bin"
            path.write_bytes(b"locked input")
            metadata = {"bytes": path.stat().st_size, "sha256": "0" * 64}
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                build_dictionary.verify_source_file(path, metadata, "fixture")

    def test_missing_source_file_fails(self) -> None:
        metadata = {"bytes": 1, "sha256": "0" * 64}
        with self.assertRaisesRegex(FileNotFoundError, "required source file"):
            build_dictionary.verify_source_file(
                Path("/definitely/not/an/oboe/source"), metadata, "fixture"
            )

    def test_app_bundled_source_is_rejected(self) -> None:
        app_path = Path(__file__).resolve().parents[2] / "OboeApp" / "JMdict_e"
        with self.assertRaisesRegex(ValueError, "must not be stored inside OboeApp"):
            build_dictionary.reject_app_bundled_source(app_path, "fixture")


class DTDGateTests(unittest.TestCase):
    def fixture_with_dtd(self, replacement: str) -> bytes:
        data = FIXTURE_XML.read_bytes()
        needle = b"<!ENTITY gikun"
        pos = data.index(needle)
        return data[:pos] + replacement + data[pos:]

    def test_locked_entities_pass(self) -> None:
        declared = build_dictionary.scan_dtd_subset(FIXTURE_XML.read_bytes())
        self.assertTrue({"v1", "vt", "gikun"}.issubset(declared))

    def test_external_entity_declaration_fails(self) -> None:
        bad = self.fixture_with_dtd(
            b'<!ENTITY evil SYSTEM "file:///etc/passwd">\n<!ENTITY gikun'
        )
        with self.assertRaisesRegex(ValueError, "unsupported entity declaration"):
            build_dictionary.scan_dtd_subset(bad)

    def test_parameter_entity_declaration_fails(self) -> None:
        bad = self.fixture_with_dtd(b'<!ENTITY % pe "x">\n<!ENTITY gikun')
        with self.assertRaisesRegex(ValueError, "parameter entities are not allowed"):
            build_dictionary.scan_dtd_subset(bad)

    def test_unknown_entity_declaration_fails(self) -> None:
        bad = self.fixture_with_dtd(b'<!ENTITY brandnew "not locked">\n<!ENTITY gikun')
        with self.assertRaisesRegex(ValueError, "not in the locked JMdict entity map"):
            build_dictionary.scan_dtd_subset(bad)

    def test_rewritten_entity_value_fails(self) -> None:
        bad = self.fixture_with_dtd(b'<!ENTITY v1 "hijacked expansion">\n<!ENTITY gikun')
        with self.assertRaisesRegex(ValueError, "expansion was rewritten"):
            build_dictionary.scan_dtd_subset(bad)

    def test_entity_expansion_bomb_fails(self) -> None:
        bomb = (
            b'<!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">\n'
            b'<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">\n'
            b'<!ENTITY gikun'
        )
        with self.assertRaisesRegex(ValueError, "not in the locked JMdict entity map"):
            build_dictionary.scan_dtd_subset(self.fixture_with_dtd(bomb))

    def test_conditional_section_fails(self) -> None:
        bad = self.fixture_with_dtd(b'<![INCLUDE[ <!ENTITY x "y"> ]]>\n<!ENTITY gikun')
        with self.assertRaisesRegex(ValueError, "forbidden DTD declaration"):
            build_dictionary.scan_dtd_subset(bad)

    def test_external_doctype_subset_fails(self) -> None:
        data = FIXTURE_XML.read_bytes().replace(
            b"<!DOCTYPE JMdict [", b'<!DOCTYPE JMdict SYSTEM "http://evil/dtd"> [', 1
        )
        with self.assertRaisesRegex(ValueError, "external subset"):
            build_dictionary.scan_dtd_subset(data)

    def test_undefined_entity_in_content_fails_parse(self) -> None:
        data = FIXTURE_XML.read_bytes().replace(b"&v5k-s;", b"&notdeclared;")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.xml"
            path.write_bytes(data)
            with self.assertRaises(Exception):
                build_dictionary.parse_jmdict(path)


class OverlayTests(unittest.TestCase):
    def make_overlay(self, directory: Path, rows: list, licenses: list | None = None) -> Path:
        db = directory / "overlay.db"
        connection = sqlite3.connect(db)
        connection.executescript(
            """
            CREATE TABLE zh_defs (entry_id TEXT PRIMARY KEY, locale TEXT, data TEXT);
            CREATE TABLE table_licenses (table_name TEXT PRIMARY KEY, license TEXT,
                source_db TEXT, attribution TEXT);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            """
        )
        connection.executemany(
            "INSERT INTO zh_defs(entry_id, locale, data) VALUES (?, ?, ?)", rows
        )
        for row in licenses or [
            ("zh_defs", "CC-BY-SA-4.0", "lang_zh-CN.db", "fixture"),
        ]:
            connection.execute(
                "INSERT INTO table_licenses(table_name, license, source_db, attribution)"
                " VALUES (?, ?, ?, ?)",
                row,
            )
        connection.executemany(
            "INSERT INTO meta(key, value) VALUES (?, ?)",
            [("export_version", "2"), ("exported_at", "2026-01-01")],
        )
        connection.commit()
        connection.close()
        return db

    def test_missing_zh_license_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            overlay = self.make_overlay(
                Path(directory),
                [],
                licenses=[("zh_defs", "CC0-1.0", "x.db", "fixture")],
            )
            with self.assertRaisesRegex(ValueError, "license zh_defs"):
                build_dictionary.load_chinese_overlay(overlay)

    def test_missing_meta_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "overlay.db"
            connection = sqlite3.connect(db)
            connection.executescript(
                """
                CREATE TABLE zh_defs (entry_id TEXT PRIMARY KEY, locale TEXT, data TEXT);
                CREATE TABLE table_licenses (table_name TEXT PRIMARY KEY, license TEXT,
                    source_db TEXT, attribution TEXT);
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
                """
            )
            connection.execute(
                "INSERT INTO table_licenses VALUES ('zh_defs','CC-BY-SA-4.0','x','y')"
            )
            connection.execute("INSERT INTO meta VALUES ('export_version','2')")
            connection.commit()
            connection.close()
            with self.assertRaisesRegex(ValueError, "meta is missing"):
                build_dictionary.load_chinese_overlay(db)

    def test_invalid_json_and_non_numeric_ids_quarantined(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            overlay = self.make_overlay(
                Path(directory),
                [
                    ("notanumber", "zh-CN", '{"senses":{}}'),
                    ("1001", "zh-CN", "this is not json"),
                    ("7777", "zh-TW", '{"senses":{}}'),
                ],
            )
            rows, invalid, licenses, meta = build_dictionary.load_chinese_overlay(overlay)
            self.assertEqual(rows, {})
            self.assertEqual(invalid, ["1001", "notanumber"])


class BuildTests(unittest.TestCase):
    def test_fixture_build_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result, output, notice, report = run_build(
                Path(directory), FIXTURE_XML, FIXTURE_DB
            )
            self.assertTrue(output.is_file() and output.stat().st_size > 0)
            self.assertTrue(notice.is_file() and notice.stat().st_size > 0)
            counts = result["counts"]
            self.assertEqual(counts["entries"], 4)
            self.assertEqual(counts["zhGlosses"], 6)
            zh = result["chineseOverlay"]
            self.assertEqual(zh["entriesFull"], 2)
            self.assertEqual(zh["entriesPartial"], 1)
            self.assertEqual(zh["entriesMissingFromJmdict"], 1)
            self.assertEqual(zh["sensesOutOfRange"], 1)

    def test_fixture_schema_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, output, _, _ = run_build(Path(directory), FIXTURE_XML, FIXTURE_DB)
            connection = sqlite3.connect(f"file:{output}?mode=ro", uri=True)
            # pos inheritance: sense 2 of entry 1001 inherits v1+vt from sense 1.
            inherited = connection.execute(
                "SELECT code FROM sense_pos sp JOIN senses s ON s.id = sp.sense_id"
                " WHERE s.entry_id = 1001 AND s.sense_order = 1 ORDER BY code"
            ).fetchall()
            self.assertEqual([row[0] for row in inherited], ["v1", "vt"])
            # ke_inf codes folded into form_type.
            form_type = connection.execute(
                "SELECT form_type FROM forms WHERE text = '喰べる'"
            ).fetchone()[0]
            self.assertEqual(form_type, "ateji+io")
            # katakana readings normalize to hiragana.
            normalized = connection.execute(
                "SELECT normalized_reading FROM readings WHERE reading = 'タベル'"
            ).fetchone()[0]
            self.assertEqual(normalized, "たべる")
            no_kanji = connection.execute(
                "SELECT no_kanji FROM readings WHERE reading = 'タベル'"
            ).fetchone()[0]
            self.assertEqual(no_kanji, 1)
            # zh overlay only on aligned senses; out-of-range sense 9 absent.
            zh = connection.execute(
                "SELECT COUNT(*) FROM glosses WHERE language = 'zho'"
            ).fetchone()[0]
            self.assertEqual(zh, 6)
            zh_1003 = connection.execute(
                "SELECT COUNT(*) FROM glosses g JOIN senses s ON s.id = g.sense_id"
                " WHERE s.entry_id = 1003 AND g.language = 'zho'"
            ).fetchone()[0]
            self.assertEqual(zh_1003, 1)
            connection.close()

    def test_dangling_restriction_fails_build(self) -> None:
        data = FIXTURE_XML.read_bytes().replace(
            "<stagk>食べる</stagk>".encode(), "<stagk>食べない</stagk>".encode(), 1
        )
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / "bad.xml"
            xml.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "stagk"):
                run_build(Path(directory), xml, FIXTURE_DB)

    def test_dangling_re_restr_fails_build(self) -> None:
        data = FIXTURE_XML.read_bytes().replace(
            "<re_restr>食べる</re_restr>".encode(), "<re_restr>無い形</re_restr>".encode(), 1
        )
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / "bad.xml"
            xml.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "re_restr"):
                run_build(Path(directory), xml, FIXTURE_DB)

    def test_double_build_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "a"
            second = Path(directory) / "b"
            first.mkdir()
            second.mkdir()
            _, out1, _, _ = run_build(first, FIXTURE_XML, FIXTURE_DB)
            _, out2, _, _ = run_build(second, FIXTURE_XML, FIXTURE_DB)
            self.assertEqual(
                build_dictionary.sha256_file(out1), build_dictionary.sha256_file(out2)
            )

    def test_validate_existing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, output, notice, _ = run_build(Path(directory), FIXTURE_XML, FIXTURE_DB)

            class Args:
                pass

            args = Args()
            args.output = output
            args.notice = notice
            args.qa_cases = FIXTURE_QA
            args.validate_existing = True
            result = build_dictionary.build(args)
            self.assertIn("counts", result)

    def test_validate_existing_detects_fk_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, output, notice, _ = run_build(Path(directory), FIXTURE_XML, FIXTURE_DB)
            tampered = Path(directory) / "tampered.sqlite"
            tampered.write_bytes(output.read_bytes())
            connection = sqlite3.connect(tampered)
            connection.execute("PRAGMA foreign_keys = OFF")
            connection.execute("DELETE FROM entries WHERE id = 1001")
            connection.commit()
            connection.close()

            class Args:
                pass

            args = Args()
            args.output = tampered
            args.notice = notice
            args.qa_cases = FIXTURE_QA
            args.validate_existing = True
            with self.assertRaisesRegex(ValueError, "foreign key"):
                build_dictionary.build(args)

    def test_validate_existing_detects_cross_entry_restrictions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, output, notice, _ = run_build(Path(directory), FIXTURE_XML, FIXTURE_DB)
            tampered = Path(directory) / "tampered.sqlite"
            tampered.write_bytes(output.read_bytes())
            connection = sqlite3.connect(tampered)
            # Point sense 5's (entry 1003) restriction at a form of entry 1001.
            connection.execute(
                "INSERT INTO sense_form_restrictions(sense_id, form_id) VALUES (5, 1)"
            )
            connection.commit()
            connection.close()

            class Args:
                pass

            args = Args()
            args.output = tampered
            args.notice = notice
            args.qa_cases = FIXTURE_QA
            args.validate_existing = True
            with self.assertRaisesRegex(ValueError, "dangling"):
                build_dictionary.build(args)

    def test_validate_existing_detects_missing_zh_overlay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, output, notice, _ = run_build(Path(directory), FIXTURE_XML, FIXTURE_DB)
            tampered = Path(directory) / "tampered.sqlite"
            tampered.write_bytes(output.read_bytes())
            connection = sqlite3.connect(tampered)
            connection.execute("DELETE FROM glosses WHERE language = 'zho'")
            connection.commit()
            connection.close()

            class Args:
                pass

            args = Args()
            args.output = tampered
            args.notice = notice
            args.qa_cases = FIXTURE_QA
            args.validate_existing = True
            result = build_dictionary.build(args)
            self.assertEqual(result["counts"]["glosses"], 8)

    def test_failed_build_leaves_no_output(self) -> None:
        data = FIXTURE_XML.read_bytes().replace(
            "<stagr>たべる</stagr>".encode(), "<stagr>よめない</stagr>".encode(), 1
        )
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / "bad.xml"
            xml.write_bytes(data)
            with self.assertRaises(ValueError):
                run_build(Path(directory), xml, FIXTURE_DB)
            leftovers = [
                path for path in Path(directory).iterdir() if path.name != "manifest.json"
            ]
            self.assertEqual(leftovers, [xml])

    def test_notice_is_deterministic_and_discloses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, _, notice, _ = run_build(Path(directory), FIXTURE_XML, FIXTURE_DB)
            content = notice.read_text(encoding="utf-8")
            self.assertIn("CC BY-SA 4.0", content)
            self.assertIn("EDRDG", content)
            self.assertIn("machine-assisted", content)
            self.assertIn("build time only", content)


if __name__ == "__main__":
    unittest.main()
