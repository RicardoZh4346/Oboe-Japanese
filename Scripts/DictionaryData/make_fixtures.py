#!/usr/bin/env python3
"""Regenerate the committed dictionary fixtures.

Creates tomoshi_fixture.db (minimal zh_defs/table_licenses/meta overlay for
jmdict_fixture.xml) and rewrites dictionary_fixture_manifest.json with the
current fixture byte sizes and SHA-256 digests. Run after editing
jmdict_fixture.xml or the fixture row set below; commit all outputs.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE_XML = HERE / "jmdict_fixture.xml"
FIXTURE_DB = HERE / "tomoshi_fixture.db"
FIXTURE_MANIFEST = HERE / "dictionary_fixture_manifest.json"

# zh_defs rows: (entry_id, locale, data-json). 1001 = full coverage (3 senses);
# 1002 = full; 1003 = partial (key "9" is out of JMdict range); 9000 = entry
# missing from JMdict (quarantine); 8888 = zh-TW locale (never consumed).
ZH_ROWS = [
    (
        "1001",
        "zh-CN",
        {
            "senses": {
                "0": {
                    "glosses": [{"text": "吃"}, {"text": "进食"}],
                    "examples": {"0": "他吃了饭。"},
                },
                "1": {"glosses": [{"text": "吃饭"}]},
                "2": {"glosses": [{"text": "语法义"}]},
            }
        },
    ),
    ("1002", "zh-CN", {"senses": {"0": {"glosses": [{"text": "啊"}]}}}),
    (
        "1003",
        "zh-CN",
        {
            "senses": {
                "0": {"glosses": [{"text": "去"}]},
                "9": {"glosses": [{"text": "幻sense"}]},
            }
        },
    ),
    ("9000", "zh-CN", {"senses": {"0": {"glosses": [{"text": "不存在"}]}}}),
    ("8888", "zh-TW", {"senses": {"0": {"glosses": [{"text": "略"}]}}}),
]

LICENSES = [
    ("zh_defs", "CC-BY-SA-4.0", "lang_zh-CN.db", "JMdict-derived Chinese gloss translations © Y1Z"),
    ("entries", "CC-BY-SA-4.0", "dict.db", "JMdict, Electronic Dictionary Research and Development Group — https://www.edrdg.org/"),
    ("forms", "CC-BY-SA-4.0", "dict.db", "JMdict, Electronic Dictionary Research and Development Group — https://www.edrdg.org/"),
]

META = [
    ("export_version", "2"),
    ("exported_at", "2026-01-01T00:00:00+0900"),
    ("note", "Minimal fixture of the Tomoshi open-data layout for tests."),
]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_db() -> None:
    if FIXTURE_DB.exists():
        FIXTURE_DB.unlink()
    connection = sqlite3.connect(FIXTURE_DB)
    try:
        connection.executescript(
            """
            CREATE TABLE zh_defs (
                entry_id TEXT NOT NULL PRIMARY KEY,
                locale TEXT NOT NULL DEFAULT 'zh-CN',
                data TEXT
            );
            CREATE TABLE table_licenses (
                table_name TEXT PRIMARY KEY,
                license TEXT,
                source_db TEXT,
                attribution TEXT
            );
            CREATE TABLE meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE entries (
                id TEXT PRIMARY KEY,
                data TEXT
            );
            """
        )
        connection.executemany(
            "INSERT INTO zh_defs(entry_id, locale, data) VALUES (?, ?, ?)",
            [
                (entry_id, locale, json.dumps(payload, ensure_ascii=False, sort_keys=True))
                for entry_id, locale, payload in ZH_ROWS
            ],
        )
        connection.executemany(
            "INSERT INTO table_licenses(table_name, license, source_db, attribution)"
            " VALUES (?, ?, ?, ?)",
            LICENSES,
        )
        connection.executemany(
            "INSERT INTO meta(key, value) VALUES (?, ?)", META
        )
        connection.execute("INSERT INTO entries(id, data) VALUES ('decoy', 'not consumed')")
        connection.commit()
    finally:
        connection.close()


def make_manifest() -> None:
    manifest = {
        "manifestVersion": 1,
        "schemaVersion": 1,
        "datasetVersion": "2026.01.01-1",
        "sources": {
            "jmdict_e": {
                "version": "2026-01-01-daily",
                "license": "CC-BY-SA-4.0",
                "licenseURL": "https://creativecommons.org/licenses/by-sa/4.0/legalcode",
                "attribution": "JMdict Japanese-Multilingual Dictionary, Electronic Dictionary Research and Development Group (EDRDG)",
                "sourceURL": "https://www.edrdg.org/jmdict/j_jmdict.html",
                "retrievedAt": "2026-01-01",
                "consumedTables": ["entry"],
                "modifications": "Fixture manifest mirroring dictionary_sources_v1.json for tests.",
                "files": {
                    "JMdict_e": {
                        "bytes": FIXTURE_XML.stat().st_size,
                        "sha256": sha256_file(FIXTURE_XML),
                        "downloadURL": "https://example.invalid/fixtures/JMdict_e",
                    }
                },
            },
            "tomoshi": {
                "version": "v2026-01-01",
                "license": "CC-BY-SA-4.0",
                "licenseURL": "https://creativecommons.org/licenses/by-sa/4.0/legalcode",
                "attribution": "Tomoshi Dictionary Open Data fixture; only zh_defs (zh-CN) plus table_licenses/meta metadata are consumed",
                "sourceURL": "https://example.invalid/fixtures/tomoshi",
                "retrievedAt": "2026-01-01",
                "consumedTables": ["zh_defs", "table_licenses", "meta"],
                "modifications": "Fixture overlay manifest for tests.",
                "files": {
                    "tomoshi-dict-open.db": {
                        "bytes": FIXTURE_DB.stat().st_size,
                        "sha256": sha256_file(FIXTURE_DB),
                        "downloadURL": "https://example.invalid/fixtures/tomoshi-dict-open.db",
                    }
                },
            },
        },
    }
    FIXTURE_MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    make_db()
    make_manifest()
    print(f"wrote {FIXTURE_DB.name} ({FIXTURE_DB.stat().st_size} bytes)")
    print(f"wrote {FIXTURE_MANIFEST.name}")


if __name__ == "__main__":
    main()
