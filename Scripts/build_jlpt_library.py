#!/usr/bin/env python3
"""Build Oboe's distributable, read-only JLPT vocabulary database."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


LEVELS = ("N5", "N4", "N3", "N2", "N1")
SCHEMA_VERSION = 2
SOURCE_MANIFEST_VERSION = 1
REQUIRED_SOURCE_IDS = {
    "openjlpt",
    "tomoshi",
    "unidic_cwj",
    "kanjium",
    "tatoeba",
}
REQUIRED_SOURCE_FILES = {
    "openjlpt": {f"{level.lower()}.json" for level in LEVELS},
    "tomoshi": {"tomoshi-dict-open.db"},
    "unidic_cwj": {"lex_3_1.csv"},
    "kanjium": {"accents.txt"},
    "tatoeba": {
        "jpn_sentences.tsv.bz2",
        "cmn_sentences.tsv.bz2",
        "jpn-cmn_links.tsv.bz2",
    },
}
PART_OF_SPEECH_WHITELIST = (
    "名词", "代词",
    "五段动词", "一段动词", "する动词", "くる动词",
    "他动词", "自动词",
    "い形容词", "な形容词",
    "副词", "助词", "助动词", "接续词", "感叹词",
    "量词", "接头词", "接尾词", "表达",
)
MISSING_CHINESE_DEFINITION = 1 << 0
AMBIGUOUS_TOMOSHI_MATCH = 1 << 1
READING_FROM_KANA_HEADWORD = 1 << 2
JLPT_LEVEL_CONFLICT = 1 << 3
EXPECTED_PITCH_COUNT = 8_132
EXPECTED_NULL_PITCH_COUNT = 202
EXPECTED_EXAMPLE_COUNT = 14_362
TRANSLATION_CONTROL_CHARACTERS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
TRANSLATION_CJK_CHARACTER = re.compile(r"[\u3400-\u9fff]")
TRANSLATION_TRAILING_ENGLISH_CLAUSE = re.compile(
    r"(?:[\s,，。.!?！？:：;；-]*)"
    r"[A-Za-z]+(?:['’][A-Za-z]+)?"
    r"(?:(?:\s+|,\s*)[A-Za-z]+(?:['’][A-Za-z]+)?){1,}[.!?]*\s*$"
)


@dataclass(frozen=True)
class SourceWord:
    level: str
    headword: str
    reading: str
    meanings_en: list[str]
    examples: list[dict[str, str]]
    sort_order: int
    flags: int


@dataclass(frozen=True)
class Match:
    entry_id: str
    meaning_zh: str | None
    part_of_speech: str | None
    frequency_rank: int | None
    tomoshi_level: str | None
    ambiguous: bool


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip()


def normalize_reading(value: str) -> str:
    normalized = normalize_text(value)
    return "".join(
        chr(ord(character) - 0x60)
        if "ァ" <= character <= "ヶ"
        else character
        for character in normalized
    )


def stable_vocab_id(level: str, headword: str, reading: str) -> str:
    digest = hashlib.sha256(f"{headword}\n{reading}".encode("utf-8")).hexdigest()
    return f"openjlpt:{level}:{digest}"


def stable_example_id(vocab_id: str, japanese: str, english: str, order: int) -> str:
    payload = f"{vocab_id}\n{order}\n{japanese}\n{english}".encode("utf-8")
    return f"example:{hashlib.sha256(payload).hexdigest()}"


def load_expected_counts(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if set(value["byLevel"]) != set(LEVELS):
        raise ValueError("expected counts must contain exactly N5 through N1")
    if sum(value["byLevel"].values()) != value["total"]:
        raise ValueError("expected counts total does not match per-level values")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_source_manifest(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"source manifest was not found: {path}")
    with path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("manifestVersion") != SOURCE_MANIFEST_VERSION:
        raise ValueError(
            f"source manifestVersion must be {SOURCE_MANIFEST_VERSION}"
        )
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"source schemaVersion must be {SCHEMA_VERSION}")
    if not normalize_text(manifest.get("datasetVersion", "")):
        raise ValueError("source manifest datasetVersion is missing")
    sources = manifest.get("sources")
    if not isinstance(sources, dict) or set(sources) != REQUIRED_SOURCE_IDS:
        actual = set(sources) if isinstance(sources, dict) else set()
        raise ValueError(
            "source manifest must contain exactly these sources: "
            f"{sorted(REQUIRED_SOURCE_IDS)}; missing={sorted(REQUIRED_SOURCE_IDS - actual)}, "
            f"unexpected={sorted(actual - REQUIRED_SOURCE_IDS)}"
        )
    sha_pattern = re.compile(r"^[0-9a-f]{64}$")
    for source_id, source in sources.items():
        if not isinstance(source, dict):
            raise ValueError(f"source {source_id} metadata must be an object")
        for key in ("version", "license", "attribution", "sourceURL"):
            if not isinstance(source.get(key), str) or not source[key].strip():
                raise ValueError(f"source {source_id} is missing {key} metadata")
        if not source["sourceURL"].startswith("https://"):
            raise ValueError(f"source {source_id} sourceURL must use HTTPS")
        files = source.get("files")
        if not isinstance(files, dict) or not files:
            raise ValueError(f"source {source_id} has no file metadata")
        if set(files) != REQUIRED_SOURCE_FILES[source_id]:
            raise ValueError(
                f"source {source_id} must contain exactly these files: "
                f"{sorted(REQUIRED_SOURCE_FILES[source_id])}"
            )
        for file_id, metadata in files.items():
            if not isinstance(metadata, dict):
                raise ValueError(f"source {source_id}/{file_id} metadata must be an object")
            if not sha_pattern.fullmatch(str(metadata.get("sha256", ""))):
                raise ValueError(f"source {source_id}/{file_id} has an invalid SHA-256")
            if not isinstance(metadata.get("bytes"), int) or metadata["bytes"] <= 0:
                raise ValueError(f"source {source_id}/{file_id} has an invalid byte size")
            download_url = metadata.get("downloadURL")
            if not isinstance(download_url, str) or not download_url.startswith("https://"):
                raise ValueError(
                    f"source {source_id}/{file_id} downloadURL must use HTTPS"
                )
    return manifest


def verify_source_file(path: Path, metadata: dict[str, Any], label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"required source file was not found: {label}: {path}")
    actual_size = path.stat().st_size
    if actual_size != metadata["bytes"]:
        raise ValueError(
            f"source size mismatch for {label}: {actual_size}, expected {metadata['bytes']}"
        )
    actual_hash = sha256_file(path)
    if actual_hash != metadata["sha256"]:
        raise ValueError(
            f"source SHA-256 mismatch for {label}: {actual_hash}, "
            f"expected {metadata['sha256']}"
        )


def reject_app_bundled_source(path: Path, label: str) -> None:
    app_root = Path(__file__).resolve().parents[1] / "OboeApp"
    try:
        path.resolve().relative_to(app_root)
    except ValueError:
        return
    raise ValueError(f"raw source {label} must not be stored inside OboeApp: {path}")


def verify_source_inputs(args: argparse.Namespace, manifest: dict[str, Any]) -> None:
    sources = manifest["sources"]
    vocab_directory = resolve_vocab_directory(args.openjlpt)
    for level in LEVELS:
        file_id = f"{level.lower()}.json"
        path = vocab_directory / file_id
        reject_app_bundled_source(path, f"openjlpt/{file_id}")
        verify_source_file(path, sources["openjlpt"]["files"][file_id], f"openjlpt/{file_id}")

    source_files = (
        ("tomoshi", "tomoshi-dict-open.db", args.tomoshi),
        ("unidic_cwj", "lex_3_1.csv", args.unidic_cwj),
        ("kanjium", "accents.txt", args.kanjium),
        ("tatoeba", "jpn_sentences.tsv.bz2", args.tatoeba_jpn),
        ("tatoeba", "cmn_sentences.tsv.bz2", args.tatoeba_cmn),
        ("tatoeba", "jpn-cmn_links.tsv.bz2", args.tatoeba_links),
    )
    for source_id, file_id, path in source_files:
        reject_app_bundled_source(path, f"{source_id}/{file_id}")
        verify_source_file(path, sources[source_id]["files"][file_id], f"{source_id}/{file_id}")


def resolve_vocab_directory(openjlpt: Path) -> Path:
    candidates = (
        openjlpt,
        openjlpt / "data" / "json" / "vocab",
        openjlpt / "json" / "vocab",
    )
    for candidate in candidates:
        if all((candidate / f"{level.lower()}.json").is_file() for level in LEVELS):
            return candidate
    raise FileNotFoundError("OpenJLPT vocab JSON directory was not found")


def is_kana_only(value: str) -> bool:
    meaningful = [
        character
        for character in value
        if not character.isspace() and character not in "/、()＝="
    ]
    return bool(meaningful) and all(
        "ぁ" <= character <= "ゖ"
        or "ァ" <= character <= "ヺ"
        or character in "ー・ヽヾゝゞ"
        for character in meaningful
    )


def reading_from_kana_headword(value: str) -> str:
    """Choose the first pronunciation from OpenJLPT's occasional variant labels."""
    candidate = re.split(r"[/、]|\s+\(", value, maxsplit=1)[0]
    return normalize_text(candidate)


def load_openjlpt(openjlpt: Path, expected: dict[str, Any]) -> list[SourceWord]:
    directory = resolve_vocab_directory(openjlpt)
    result: list[SourceWord] = []
    seen_ids: set[str] = set()
    for level in LEVELS:
        path = directory / f"{level.lower()}.json"
        with path.open(encoding="utf-8") as handle:
            values = json.load(handle)
        if len(values) != expected["byLevel"][level]:
            raise ValueError(
                f"{level} count is {len(values)}, expected {expected['byLevel'][level]}"
            )
        for index, raw in enumerate(values):
            headword = normalize_text(raw.get("word", ""))
            if not headword:
                raise ValueError(f"{level}[{index}] has an empty word")
            raw_reading = normalize_text(raw.get("reading", ""))
            flags = 0
            if not raw_reading:
                if not is_kana_only(headword):
                    raise ValueError(f"{level}[{index}] has no reading: {headword}")
                raw_reading = reading_from_kana_headword(headword)
                flags |= READING_FROM_KANA_HEADWORD
            reading = normalize_reading(raw_reading)
            meanings = raw.get("meanings")
            if not isinstance(meanings, list) or not all(
                isinstance(item, str) and normalize_text(item) for item in meanings
            ):
                raise ValueError(f"{level}[{index}] has invalid meanings: {headword}")
            raw_examples = raw.get("examples", [])
            if not isinstance(raw_examples, list):
                raise ValueError(f"{level}[{index}] has invalid examples: {headword}")
            examples: list[dict[str, str]] = []
            for example_index, example in enumerate(raw_examples):
                if not isinstance(example, dict):
                    raise ValueError(f"{level}[{index}] example {example_index} is invalid")
                japanese = normalize_text(example.get("ja", ""))
                english = normalize_text(example.get("en", ""))
                if japanese:
                    examples.append({"ja": japanese, "en": english})
            vocab_id = stable_vocab_id(level, headword, reading)
            if vocab_id in seen_ids:
                raise ValueError(f"duplicate stable id for {level} {headword} {reading}")
            seen_ids.add(vocab_id)
            result.append(
                SourceWord(
                    level=level,
                    headword=headword,
                    reading=reading,
                    meanings_en=[normalize_text(item) for item in meanings],
                    examples=examples,
                    sort_order=index,
                    flags=flags,
                )
            )
    if len(result) != expected["total"]:
        raise ValueError(f"total count is {len(result)}, expected {expected['total']}")
    return result


def english_tokens(value: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", normalize_text(value).casefold()))


def sense_similarity(source_meanings: list[str], glosses: Iterable[str]) -> float:
    source_strings = [normalize_text(item).casefold() for item in source_meanings]
    gloss_strings = [normalize_text(item).casefold() for item in glosses]
    if any(source == gloss for source in source_strings for gloss in gloss_strings):
        return 1.0
    best = 0.0
    for source in source_strings:
        source_tokens = english_tokens(source)
        for gloss in gloss_strings:
            if source in gloss or gloss in source:
                best = max(best, 0.85)
                continue
            gloss_tokens = english_tokens(gloss)
            union = source_tokens | gloss_tokens
            if union:
                best = max(best, len(source_tokens & gloss_tokens) / len(union))
    return best


def candidate_readings(entry: dict[str, Any]) -> set[str]:
    return {
        normalize_reading(item.get("text", ""))
        for item in entry.get("kana", [])
        if normalize_text(item.get("text", ""))
    }


def candidate_headwords(entry: dict[str, Any]) -> set[str]:
    return {
        normalize_text(item.get("text", ""))
        for group in (entry.get("kanji", []), entry.get("kana", []))
        for item in group
        if normalize_text(item.get("text", ""))
    }


def english_senses(entry: dict[str, Any]) -> list[list[str]]:
    return [
        [
            gloss.get("text", "")
            for gloss in sense.get("glosses", [])
            if gloss.get("lang") == "eng" and normalize_text(gloss.get("text", ""))
        ]
        for sense in entry.get("senses", [])
    ]


def choose_sense_indices(entry: dict[str, Any], source_meanings: list[str]) -> list[int]:
    scores = [sense_similarity(source_meanings, glosses) for glosses in english_senses(entry)]
    strong = [index for index, score in enumerate(scores) if score >= 0.70]
    if strong:
        return strong[:3]
    if scores and max(scores) >= 0.25:
        return [max(range(len(scores)), key=lambda index: scores[index])]
    return [0] if scores else []


def chinese_glosses(
    entry: dict[str, Any],
    zh_definition: dict[str, Any] | None,
    indices: list[int],
) -> list[str]:
    result: list[str] = []
    zh_senses = (zh_definition or {}).get("senses", {})
    entry_senses = entry.get("senses", [])
    for index in indices:
        zh_sense = zh_senses.get(str(index), {})
        candidates = [item.get("text", "") for item in zh_sense.get("glosses", [])]
        if not candidates and index < len(entry_senses):
            candidates = [
                item.get("text", "")
                for item in entry_senses[index].get("glosses", [])
                if item.get("lang") == "zho"
            ]
        for value in candidates:
            value = normalize_text(value)
            if value and value not in result:
                result.append(value)
    return result[:8]


POS_TRANSLATIONS = (
    ("Ichidan verb", "一段动词"),
    ("Godan verb", "五段动词"),
    ("suru verb", "する动词"),
    ("kuru verb", "くる动词"),
    ("transitive verb", "他动词"),
    ("intransitive verb", "自动词"),
    ("noun", "名词"),
    ("adverb", "副词"),
    ("adjective (keiyoushi)", "い形容词"),
    ("adjectival nouns or quasi-adjectives", "な形容词"),
    ("pronoun", "代词"),
    ("conjunction", "接续词"),
    ("interjection", "感叹词"),
    ("particle", "助词"),
    ("auxiliary", "助动词"),
    ("counter", "量词"),
    ("prefix", "接头词"),
    ("suffix", "接尾词"),
    ("expression", "表达"),
)


def localized_part_of_speech(entry: dict[str, Any], indices: list[int]) -> str | None:
    values: list[str] = []
    senses = entry.get("senses", [])
    for index in indices:
        if index >= len(senses):
            continue
        for raw in senses[index].get("pos", []):
            translated = next(
                (localized for marker, localized in POS_TRANSLATIONS if marker in raw),
                None,
            )
            if translated and translated not in values:
                values.append(translated)
    return " / ".join(values[:3]) or None


def validate_part_of_speech(value: str | None, context: str) -> None:
    if value is None:
        return
    components = [component.strip() for component in value.split("/")]
    unknown = [
        component
        for component in components
        if not component or component not in PART_OF_SPEECH_WHITELIST
    ]
    if unknown:
        raise ValueError(
            f"{context} contains unsupported part_of_speech components: {unknown}"
        )


def candidate_score(
    source: SourceWord,
    entry: dict[str, Any],
    form_is_common: bool,
    entry_is_common: bool,
    tomoshi_level: str | None,
    rank: int | None,
) -> float:
    score = 100.0 if source.reading in candidate_readings(entry) else 0.0
    if source.headword in candidate_headwords(entry):
        score += 20.0
    score += max(
        (sense_similarity(source.meanings_en, glosses) for glosses in english_senses(entry)),
        default=0.0,
    ) * 30.0
    score += 6.0 if form_is_common else 0.0
    score += 4.0 if entry_is_common else 0.0
    score += 5.0 if tomoshi_level == source.level else 0.0
    if rank is not None:
        score += max(0.0, 3.0 - min(rank, 30_000) / 10_000)
    return score


def match_tomoshi(connection: sqlite3.Connection, source: SourceWord) -> Match | None:
    rows = connection.execute(
        """
        SELECT f.entry_id, MAX(f.is_common) AS form_is_common,
               e.is_common AS entry_is_common, e.data AS entry_data,
               z.data AS zh_data, j.level AS tomoshi_level, r.rank
        FROM forms AS f
        JOIN entries AS e ON e.id = f.entry_id
        LEFT JOIN zh_defs AS z ON z.entry_id = e.id AND z.locale = 'zh-CN'
        LEFT JOIN vocab_jlpt AS j ON j.entry_id = e.id
        LEFT JOIN freq_rank AS r ON r.entry_id = e.id
        WHERE f.text = ?
        GROUP BY f.entry_id
        ORDER BY f.entry_id
        """,
        (source.headword,),
    ).fetchall()
    candidates: list[tuple[float, sqlite3.Row, dict[str, Any]]] = []
    for row in rows:
        entry = json.loads(row["entry_data"])
        if source.reading not in candidate_readings(entry):
            continue
        score = candidate_score(
            source,
            entry,
            bool(row["form_is_common"]),
            bool(row["entry_is_common"]),
            row["tomoshi_level"],
            row["rank"],
        )
        candidates.append((score, row, entry))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (-item[0], item[1]["entry_id"]))
    ambiguous = len(candidates) > 1 and candidates[0][0] - candidates[1][0] < 5.0
    if ambiguous:
        return Match(
            entry_id=candidates[0][1]["entry_id"],
            meaning_zh=None,
            part_of_speech=None,
            frequency_rank=candidates[0][1]["rank"],
            tomoshi_level=candidates[0][1]["tomoshi_level"],
            ambiguous=True,
        )
    _, row, entry = candidates[0]
    indices = choose_sense_indices(entry, source.meanings_en)
    zh_definition = json.loads(row["zh_data"]) if row["zh_data"] else None
    glosses = chinese_glosses(entry, zh_definition, indices)
    return Match(
        entry_id=row["entry_id"],
        meaning_zh="；".join(glosses) or None,
        part_of_speech=localized_part_of_speech(entry, indices),
        frequency_rank=row["rank"],
        tomoshi_level=row["tomoshi_level"],
        ambiguous=False,
    )


def ensure_tomoshi_schema(connection: sqlite3.Connection) -> dict[str, str]:
    required = {"entries", "forms", "zh_defs", "vocab_jlpt", "freq_rank", "meta", "table_licenses"}
    tables = {
        row[0]
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    missing = required - tables
    if missing:
        raise ValueError(f"Tomoshi database is missing tables: {sorted(missing)}")
    licenses = dict(
        connection.execute(
            "SELECT table_name, license FROM table_licenses WHERE table_name IN "
            "('entries','forms','zh_defs','vocab_jlpt','freq_rank')"
        )
    )
    if set(licenses) != {"entries", "forms", "zh_defs", "vocab_jlpt", "freq_rank"}:
        raise ValueError("Tomoshi database is missing target table license records")
    if any(value != "CC-BY-SA-4.0" for value in licenses.values()):
        raise ValueError(f"unexpected Tomoshi table licenses: {licenses}")
    return licenses


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA foreign_keys = ON;
        CREATE TABLE library_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE vocab (
            id TEXT PRIMARY KEY NOT NULL,
            level TEXT NOT NULL CHECK (level IN ('N1','N2','N3','N4','N5')),
            headword TEXT NOT NULL CHECK (length(trim(headword)) > 0),
            reading TEXT NOT NULL CHECK (length(trim(reading)) > 0),
            meaning_zh TEXT,
            meaning_en_json TEXT NOT NULL CHECK (json_valid(meaning_en_json)),
            part_of_speech TEXT,
            pitch_accent INTEGER CHECK (pitch_accent IS NULL OR pitch_accent >= 0),
            pitch_source TEXT CHECK (
                pitch_source IS NULL OR length(trim(pitch_source)) > 0
            ),
            pitch_source_ref TEXT CHECK (
                pitch_source_ref IS NULL OR length(trim(pitch_source_ref)) > 0
            ),
            frequency_rank INTEGER,
            openjlpt_source_id TEXT,
            tomoshi_entry_id TEXT,
            normalized_headword TEXT NOT NULL,
            normalized_reading TEXT NOT NULL,
            normalized_meaning_zh TEXT,
            sort_order INTEGER NOT NULL,
            data_flags INTEGER NOT NULL DEFAULT 0,
            CHECK (
                (pitch_accent IS NULL AND pitch_source IS NULL AND pitch_source_ref IS NULL)
                OR (pitch_accent IS NOT NULL AND pitch_source IS NOT NULL)
            )
        );
        CREATE TABLE vocab_examples (
            id TEXT PRIMARY KEY NOT NULL,
            vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
            japanese TEXT NOT NULL CHECK (length(trim(japanese)) > 0),
            english TEXT,
            translation_zh TEXT CHECK (
                translation_zh IS NULL OR length(trim(translation_zh)) > 0
            ),
            source_sentence_id TEXT CHECK (
                source_sentence_id IS NULL OR length(trim(source_sentence_id)) > 0
            ),
            translation_source TEXT CHECK (
                translation_source IS NULL OR length(trim(translation_source)) > 0
            ),
            translation_source_ref TEXT CHECK (
                translation_source_ref IS NULL OR length(trim(translation_source_ref)) > 0
            ),
            sort_order INTEGER NOT NULL DEFAULT 0,
            CHECK (
                (translation_zh IS NULL AND translation_source IS NULL
                    AND translation_source_ref IS NULL)
                OR (translation_zh IS NOT NULL AND translation_source IS NOT NULL)
            )
        );
        CREATE INDEX idx_vocab_level ON vocab(level);
        CREATE INDEX idx_vocab_level_order ON vocab(level, sort_order, id);
        CREATE INDEX idx_vocab_headword ON vocab(normalized_headword);
        CREATE INDEX idx_vocab_reading ON vocab(normalized_reading);
        CREATE INDEX idx_vocab_meaning_zh ON vocab(normalized_meaning_zh);
        CREATE INDEX idx_vocab_frequency ON vocab(level, frequency_rank);
        CREATE INDEX idx_vocab_pitch_source ON vocab(pitch_source, pitch_accent);
        CREATE INDEX idx_vocab_examples_vocab ON vocab_examples(vocab_id, sort_order);
        CREATE INDEX idx_vocab_examples_source_sentence
            ON vocab_examples(source_sentence_id);
        CREATE INDEX idx_vocab_examples_translation_source
            ON vocab_examples(translation_source);
        """
    )


def write_notice(
    path: Path,
    manifest: dict[str, Any],
    translation_metadata: dict[str, Any] | None = None,
) -> None:
    sources = manifest["sources"]
    translation_notice = ""
    if translation_metadata is not None:
        translation_notice = f"""
- OPUS-MT `{translation_metadata['modelRepository']}` revision `{translation_metadata['modelRevision']}`：对固定 Tatoeba 快照中没有可用中文直连的既有英文例句做构建期离线简体中文翻译，Apache 2.0。模型权重不进入 App bundle；经人工复核的修订以原句和文件哈希绑定。
"""
    content = f"""# Oboe 内置 JLPT 词汇数据来源与许可

数据集版本：{manifest['datasetVersion']}
SQLite schema：v{manifest['schemaVersion']}
OpenJLPT revision：`{sources['openjlpt']['version']}`
Tomoshi Open Data：`{sources['tomoshi']['version']}`
UniDic CWJ：`{sources['unidic_cwj']['version']}`
kanjium revision：`{sources['kanjium']['version']}`
Tatoeba snapshot：`{sources['tatoeba']['version']}`

本 SQLite 是 Oboe 为离线浏览与导入而制作的衍生数据集，按 **CC BY-SA 4.0** 提供。Oboe 应用代码的 MIT 许可不覆盖该数据集。

## 来源与署名

- OpenJLPT（evanclan/OpenJLPT）：JLPT N5–N1 社区等级、日文词形、假名、英文释义和 Tatoeba 日英例句，CC BY-SA 4.0。
- Jonathan Waller's JLPT Resources（tanos.co.uk）：社区 JLPT 等级来源，CC BY。
- JMdict / EDICT，Electronic Dictionary Research and Development Group（EDRDG）：词形、读音、英文释义和词性，CC BY-SA 4.0。
- Tomoshi Dictionary Open Data（Y1Z）：JMdict 衍生的简体中文释义与频率层，CC BY-SA 4.0。名称与 logo 不包含在许可中，本项目与 Tomoshi 不存在背书关系。
- UniDic CWJ 3.1.0（国立国語研究所）：现代书面语词典的发音形与音调型；本数据构建选择 New BSD 许可。
- kanjium（mifunetoshiro/kanjium，音调数据署名 Uros O.）：UniDic 未命中项的音调兜底，CC BY-SA 4.0。
- Tatoeba：日文、中文句子与 translation links，CC BY 2.0 FR。
{translation_notice}

## Oboe 的修改

Oboe 筛选 OpenJLPT vocabulary 数据；以 NFKC 和平假名规则规范化搜索字段；上游 reading 为空时，从 headword 变体标注中取第一个读音；按词形与读音匹配 Tomoshi/JMdict entry；合并可唯一确定的简体中文释义、词性与频率；保留英文 meanings 数组；转换为只读 SQLite schema，并生成稳定 sourceRef。schema v2 还会从固定版本 UniDic、kanjium 和 Tatoeba 输入生成带来源的音调与中文例句翻译；无法确定的音调保持 NULL，不用 AI 猜测。

构建脚本不联网，只接受命令行明确传入的本地文件，并在读取前按 `Scripts/jlpt_sources_v2.json` 校验字节数和 SHA-256。UniDic、Tomoshi 与 Tatoeba 原始大文件不进入 App bundle。

JLPT 官方目前不发布固定词汇清单；所有 N1～N5 标记均为社区整理的非官方分类，仅供学习参考。

许可证与原始 NOTICE：

- https://github.com/evanclan/OpenJLPT
- https://github.com/tomoshi-app/tomoshi-dict-data
- https://clrd.ninjal.ac.jp/unidic/en/
- https://github.com/mifunetoshiro/kanjium
- https://tatoeba.org/eng/downloads
- https://huggingface.co/Helsinki-NLP/opus-mt-en-zh
- https://creativecommons.org/licenses/by-sa/4.0/legalcode
- https://creativecommons.org/licenses/by/2.0/fr/
- https://www.edrdg.org/edrdg/licence.html
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def validate_database(
    path: Path,
    expected: dict[str, Any],
    notice: Path,
    required_schema_version: int | None = None,
) -> dict[str, Any]:
    if not notice.is_file() or notice.stat().st_size == 0:
        raise ValueError("NOTICE was not generated")
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        quick_check = connection.execute("PRAGMA quick_check").fetchone()[0]
        if quick_check != "ok":
            raise ValueError(f"SQLite quick_check failed: {quick_check}")
        foreign_keys = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_keys:
            raise ValueError(f"SQLite foreign key check failed: {foreign_keys[:3]}")
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        required_tables = {"library_meta", "vocab", "vocab_examples"}
        if not required_tables.issubset(tables):
            raise ValueError(f"library tables are incomplete: {required_tables - tables}")
        meta = dict(connection.execute("SELECT key, value FROM library_meta"))
        required_meta = {
            "schema_version", "dataset_version", "generated_at", "openjlpt_revision",
            "tomoshi_version", "license", "word_count_total", "word_count_n5",
            "word_count_n4", "word_count_n3", "word_count_n2", "word_count_n1",
        }
        if not required_meta.issubset(meta):
            raise ValueError(f"library metadata is incomplete: {required_meta - set(meta)}")
        try:
            schema_version = int(meta["schema_version"])
        except ValueError as error:
            raise ValueError("library schema_version is not an integer") from error
        if schema_version not in (1, SCHEMA_VERSION):
            raise ValueError(f"unsupported library schema version: {schema_version}")
        if required_schema_version is not None and schema_version != required_schema_version:
            raise ValueError(
                f"library schema is v{schema_version}, expected v{required_schema_version}"
            )

        vocab_columns = {
            row["name"] for row in connection.execute("PRAGMA table_info(vocab)")
        }
        example_columns = {
            row["name"] for row in connection.execute("PRAGMA table_info(vocab_examples)")
        }
        v1_vocab_columns = {
            "id", "level", "headword", "reading", "meaning_zh", "meaning_en_json",
            "part_of_speech", "frequency_rank", "openjlpt_source_id", "tomoshi_entry_id",
            "normalized_headword", "normalized_reading", "normalized_meaning_zh",
            "sort_order", "data_flags",
        }
        v1_example_columns = {"id", "vocab_id", "japanese", "english", "sort_order"}
        v2_vocab_columns = v1_vocab_columns | {
            "pitch_accent", "pitch_source", "pitch_source_ref",
        }
        v2_example_columns = v1_example_columns | {
            "translation_zh", "source_sentence_id", "translation_source",
            "translation_source_ref",
        }
        expected_vocab_columns = (
            v2_vocab_columns if schema_version == SCHEMA_VERSION else v1_vocab_columns
        )
        expected_example_columns = (
            v2_example_columns if schema_version == SCHEMA_VERSION else v1_example_columns
        )
        if vocab_columns != expected_vocab_columns:
            raise ValueError(
                f"vocab schema v{schema_version} columns are invalid: {sorted(vocab_columns)}"
            )
        if example_columns != expected_example_columns:
            raise ValueError(
                "vocab_examples schema "
                f"v{schema_version} columns are invalid: {sorted(example_columns)}"
            )

        by_level = {
            level: connection.execute(
                "SELECT COUNT(*) FROM vocab WHERE level = ?", (level,)
            ).fetchone()[0]
            for level in LEVELS
        }
        total = connection.execute("SELECT COUNT(*) FROM vocab").fetchone()[0]
        unique_ids = connection.execute("SELECT COUNT(DISTINCT id) FROM vocab").fetchone()[0]
        invalid_required = connection.execute(
            "SELECT COUNT(*) FROM vocab WHERE trim(headword) = '' OR trim(reading) = ''"
        ).fetchone()[0]
        if by_level != expected["byLevel"] or total != expected["total"]:
            raise ValueError(f"bundled counts do not match expected counts: {by_level}, {total}")
        if unique_ids != total or invalid_required:
            raise ValueError("bundled vocabulary IDs or required fields are invalid")
        for row in connection.execute(
            "SELECT id, part_of_speech FROM vocab WHERE part_of_speech IS NOT NULL"
        ):
            validate_part_of_speech(row["part_of_speech"], f"vocab {row['id']}")
        foreign_key_rows = connection.execute(
            "PRAGMA foreign_key_list(vocab_examples)"
        ).fetchall()
        if not any(
            row["table"] == "vocab"
            and row["from"] == "vocab_id"
            and row["to"] == "id"
            and row["on_delete"].upper() == "CASCADE"
            for row in foreign_key_rows
        ):
            raise ValueError("vocab_examples foreign key is missing or incomplete")
        index_names = {
            row["name"]
            for table in ("vocab", "vocab_examples")
            for row in connection.execute(f"PRAGMA index_list({table})")
        }
        required_indexes = {
            "idx_vocab_level", "idx_vocab_level_order", "idx_vocab_headword",
            "idx_vocab_reading", "idx_vocab_meaning_zh", "idx_vocab_frequency",
            "idx_vocab_examples_vocab",
        }
        if schema_version == SCHEMA_VERSION:
            required_indexes |= {
                "idx_vocab_pitch_source", "idx_vocab_examples_source_sentence",
                "idx_vocab_examples_translation_source",
            }
            required_meta |= {
                "source_manifest_version", "source_manifest_sha256",
                "tomoshi_sha256",
                "unidic_cwj_version", "unidic_cwj_sha256", "kanjium_revision",
                "kanjium_sha256", "tatoeba_snapshot", "tatoeba_jpn_sha256",
                "tatoeba_cmn_sha256", "tatoeba_links_sha256",
                "pitch_coverage_count", "pitch_null_count", "pitch_audit_sha256",
                "translation_coverage_count", "translation_coverage_sha256",
                "translation_model_repository", "translation_model_revision",
                "translation_model_weights_sha256",
                "translation_model_manifest_sha256",
            }
            missing_v2_meta = required_meta - set(meta)
            if missing_v2_meta:
                raise ValueError(f"schema v2 metadata is incomplete: {missing_v2_meta}")
            invalid_pitch = connection.execute(
                "SELECT COUNT(*) FROM vocab WHERE pitch_accent < 0 "
                "OR (pitch_accent IS NULL AND (pitch_source IS NOT NULL OR pitch_source_ref IS NOT NULL)) "
                "OR (pitch_accent IS NOT NULL AND pitch_source IS NULL)"
            ).fetchone()[0]
            invalid_translation = connection.execute(
                "SELECT COUNT(*) FROM vocab_examples WHERE "
                "(translation_zh IS NULL AND (translation_source IS NOT NULL "
                "OR translation_source_ref IS NOT NULL)) "
                "OR (translation_zh IS NOT NULL AND (translation_source IS NULL "
                "OR translation_source_ref IS NULL OR source_sentence_id IS NULL))"
            ).fetchone()[0]
            if invalid_pitch or invalid_translation:
                raise ValueError("schema v2 provenance fields are inconsistent")
            pitch_count = connection.execute(
                "SELECT COUNT(*) FROM vocab WHERE pitch_accent IS NOT NULL"
            ).fetchone()[0]
            null_pitch_count = total - pitch_count
            translation_count = connection.execute(
                "SELECT COUNT(*) FROM vocab_examples WHERE translation_zh IS NOT NULL"
            ).fetchone()[0]
            if (
                pitch_count != EXPECTED_PITCH_COUNT
                or null_pitch_count != EXPECTED_NULL_PITCH_COUNT
                or translation_count != EXPECTED_EXAMPLE_COUNT
            ):
                raise ValueError(
                    "schema v2 quality gate failed: "
                    f"pitch={pitch_count}, nullPitch={null_pitch_count}, "
                    f"translations={translation_count}"
                )
        if not required_indexes.issubset(index_names):
            raise ValueError(f"library indexes are incomplete: {required_indexes - index_names}")
        return {"total": total, "byLevel": by_level, "meta": meta}
    finally:
        connection.close()


def load_translation_coverage(
    path: Path,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    if not path.is_file():
        raise FileNotFoundError(f"translation coverage was not found: {path}")
    metadata: dict[str, Any] | None = None
    records: dict[str, dict[str, Any]] = {}
    required_keys = {
        "type", "exampleID", "level", "japanese", "english", "translationZh",
        "sourceSentenceID", "translationSource", "translationSourceRef", "status",
    }
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            value = json.loads(line)
            if line_number == 1:
                metadata = value
                if value.get("type") != "meta" or value.get("formatVersion") != 1:
                    raise ValueError("translation coverage metadata is invalid")
                continue
            if set(value) != required_keys or value.get("type") != "translation":
                raise ValueError(f"translation coverage line {line_number} has invalid keys")
            example_id = value["exampleID"]
            if not isinstance(example_id, str) or not example_id or example_id in records:
                raise ValueError(f"translation coverage line {line_number} has duplicate ID")
            translation = normalize_text(value["translationZh"])
            if (
                not translation
                or len(translation) > 500
                or TRANSLATION_CONTROL_CHARACTERS.search(translation)
                or not TRANSLATION_CJK_CHARACTER.search(translation)
            ):
                raise ValueError(f"translation coverage line {line_number} is invalid")
            if value["translationSource"] not in {
                "tatoeba_direct", "tatoeba_english_pivot", "opus_mt_en_zh",
                "manual_review",
            }:
                raise ValueError(f"translation coverage line {line_number} has unknown source")
            if (
                value["translationSource"] == "opus_mt_en_zh"
                and TRANSLATION_TRAILING_ENGLISH_CLAUSE.search(translation)
            ):
                raise ValueError(
                    f"translation coverage line {line_number} has trailing English output"
                )
            if not str(value["sourceSentenceID"]).isdigit():
                raise ValueError(f"translation coverage line {line_number} has invalid sentence ID")
            if not normalize_text(value["translationSourceRef"]):
                raise ValueError(f"translation coverage line {line_number} has no source ref")
            value["translationZh"] = translation
            records[example_id] = value
    if metadata is None or len(records) != EXPECTED_EXAMPLE_COUNT:
        raise ValueError(
            f"translation coverage has {len(records)} records, expected {EXPECTED_EXAMPLE_COUNT}"
        )
    if metadata.get("exampleCount") != EXPECTED_EXAMPLE_COUNT:
        raise ValueError("translation coverage metadata count is invalid")
    return metadata, records


def verify_translation_model_manifest(
    path: Path, coverage_metadata: dict[str, Any]
) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"translation model manifest was not found: {path}")
    digest = sha256_file(path)
    if coverage_metadata.get("modelManifestSHA256") != digest:
        raise ValueError("translation coverage does not match the model manifest")
    with path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    model = manifest.get("model", {})
    required = ("repository", "revision", "license", "sourceURL")
    if manifest.get("formatVersion") != 1 or any(
        not normalize_text(model.get(key, "")) for key in required
    ):
        raise ValueError("translation model manifest metadata is incomplete")
    weights = model.get("files", {}).get("pytorch_model.bin", {}).get("sha256")
    if (
        coverage_metadata.get("modelRepository") != model.get("repository")
        or coverage_metadata.get("modelRevision") != model.get("revision")
        or coverage_metadata.get("modelWeightsSHA256") != weights
    ):
        raise ValueError("translation coverage model identity is inconsistent")
    return digest


def apply_translation_coverage(
    connection: sqlite3.Connection,
    metadata: dict[str, Any],
    records: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    rows = connection.execute(
        "SELECT id, japanese, english FROM vocab_examples ORDER BY id"
    ).fetchall()
    if len(rows) != EXPECTED_EXAMPLE_COUNT or {row[0] for row in rows} != set(records):
        raise ValueError("translation coverage IDs do not exactly match generated examples")
    source_counts: Counter[str] = Counter()
    with connection:
        for example_id, japanese, english in rows:
            record = records[example_id]
            if record["japanese"] != japanese or record["english"] != english:
                raise ValueError(f"translation source text changed for {example_id}")
            connection.execute(
                """
                UPDATE vocab_examples
                SET translation_zh = ?, source_sentence_id = ?,
                    translation_source = ?, translation_source_ref = ?
                WHERE id = ?
                """,
                (
                    record["translationZh"],
                    record["sourceSentenceID"],
                    record["translationSource"],
                    record["translationSourceRef"],
                    example_id,
                ),
            )
            source_counts[record["translationSource"]] += 1
    translated = connection.execute(
        "SELECT COUNT(*) FROM vocab_examples WHERE translation_zh IS NOT NULL"
    ).fetchone()[0]
    if translated != EXPECTED_EXAMPLE_COUNT:
        raise ValueError(f"Chinese example coverage is {translated}/{EXPECTED_EXAMPLE_COUNT}")
    return {
        "coverage": translated,
        "sourceCounts": dict(sorted(source_counts.items())),
        "modelRepository": metadata["modelRepository"],
        "modelRevision": metadata["modelRevision"],
        "modelWeightsSHA256": metadata["modelWeightsSHA256"],
    }


def run_pitch_enrichment(
    connection: sqlite3.Connection,
    database_path: Path,
    args: argparse.Namespace,
    manifest: dict[str, Any],
) -> dict[str, Any]:
    args.quality_report_dir.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable,
        str(Path(__file__).with_name("audit_pitch_accent.py")),
        "--jlpt", str(database_path),
        "--unidic", f"cwj={args.unidic_cwj}",
        "--kanjium", str(args.kanjium),
        "--out", str(args.quality_report_dir),
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    audit_path = args.quality_report_dir / "audit-results.jsonl"
    results: dict[str, dict[str, Any]] = {}
    with audit_path.open(encoding="utf-8") as handle:
        for line in handle:
            value = json.loads(line)
            if value["id"] in results:
                raise ValueError(f"duplicate pitch audit ID: {value['id']}")
            results[value["id"]] = value
    vocab_ids = {row[0] for row in connection.execute("SELECT id FROM vocab")}
    if set(results) != vocab_ids:
        raise ValueError("pitch audit IDs do not exactly match generated vocabulary")

    sources = manifest["sources"]
    status_counts: Counter[str] = Counter()
    source_counts: Counter[str] = Counter()
    high_pitch_count = 0
    pitch_count = 0
    null_count = 0
    with connection:
        for vocab_id in sorted(results):
            result = results[vocab_id]
            status_counts[result["status"]] += 1
            pitch = result["primary"]
            if pitch is None:
                null_count += 1
                pitch_source = None
                pitch_source_ref = None
            else:
                if not isinstance(pitch, int) or pitch < 0 or pitch > result["mora"]:
                    raise ValueError(f"invalid pitch result for {vocab_id}: {pitch}")
                pitch_count += 1
                high_pitch_count += int(pitch >= 5)
                primary_source = result["primarySource"]
                if primary_source.startswith("cwj/"):
                    pitch_source = "unidic_cwj"
                    candidate = next(
                        (
                            item for item in result["candidates"]
                            if item.get("source") == "cwj"
                        ),
                        None,
                    )
                    if candidate is None:
                        raise ValueError(f"UniDic pitch has no source candidate: {vocab_id}")
                    pitch_source_ref = (
                        f"unidic-cwj:{sources['unidic_cwj']['version']}:"
                        f"lid:{candidate['lid']}:lemma:{candidate['lemmaId']}:"
                        f"via:{candidate['matchedVia']}"
                    )
                elif primary_source == "kanjium":
                    pitch_source = "kanjium"
                    note = next(
                        (item for item in result["notes"] if item.startswith("kanjium")),
                        None,
                    )
                    if note is None:
                        raise ValueError(f"kanjium pitch has no source note: {vocab_id}")
                    pitch_source_ref = (
                        f"kanjium:{sources['kanjium']['version']}:{note}"
                    )
                else:
                    raise ValueError(f"unknown pitch source for {vocab_id}: {primary_source}")
                source_counts[pitch_source] += 1
            connection.execute(
                """
                UPDATE vocab
                SET pitch_accent = ?, pitch_source = ?, pitch_source_ref = ?
                WHERE id = ?
                """,
                (pitch, pitch_source, pitch_source_ref, vocab_id),
            )
    if pitch_count != EXPECTED_PITCH_COUNT or null_count != EXPECTED_NULL_PITCH_COUNT:
        raise ValueError(
            f"pitch coverage is {pitch_count} values/{null_count} NULL, expected "
            f"{EXPECTED_PITCH_COUNT}/{EXPECTED_NULL_PITCH_COUNT}"
        )
    return {
        "coverage": pitch_count,
        "nullCount": null_count,
        "highPitchCount": high_pitch_count,
        "statusCounts": dict(sorted(status_counts.items())),
        "sourceCounts": dict(sorted(source_counts.items())),
        "auditSHA256": sha256_file(audit_path),
        "auditStdout": completed.stdout.strip().splitlines(),
    }


def build(args: argparse.Namespace) -> dict[str, Any]:
    expected = load_expected_counts(args.expected_counts)
    if args.validate_existing:
        return validate_database(args.output, expected, args.notice)

    manifest = load_source_manifest(args.source_manifest)
    verify_source_inputs(args, manifest)
    translation_metadata, translation_records = load_translation_coverage(
        args.translation_coverage
    )
    translation_model_manifest_sha256 = verify_translation_model_manifest(
        args.translation_model_manifest, translation_metadata
    )
    words = load_openjlpt(args.openjlpt, expected)
    tomoshi = sqlite3.connect(f"file:{args.tomoshi}?mode=ro", uri=True)
    tomoshi.row_factory = sqlite3.Row
    ensure_tomoshi_schema(tomoshi)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, staging_name = tempfile.mkstemp(
        prefix=f".{args.output.name}.", suffix=".building", dir=args.output.parent
    )
    os.close(descriptor)
    staging_path = Path(staging_name)
    staging_path.unlink()
    output = sqlite3.connect(staging_path)
    output.execute("PRAGMA journal_mode = DELETE")
    create_schema(output)

    report: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "datasetVersion": manifest["datasetVersion"],
        "sourceManifestSHA256": sha256_file(args.source_manifest),
        "openJLPTRevision": manifest["sources"]["openjlpt"]["version"],
        "tomoshiVersion": manifest["sources"]["tomoshi"]["version"],
        "total": len(words),
        "byLevel": {level: 0 for level in LEVELS},
        "chineseMatched": 0,
        "chineseMissing": 0,
        "ambiguousTomoshiMatches": 0,
        "jlptLevelConflicts": 0,
        "readingFilledFromKanaHeadword": 0,
        "exampleCount": 0,
        "exampleCoverage": 0.0,
        "pitch": {},
        "translations": {},
        "unresolvedSamples": [],
        "ambiguousSamples": [],
        "levelConflictSamples": [],
    }

    try:
        with output:
            for source in words:
                match = match_tomoshi(tomoshi, source)
                flags = source.flags
                tomoshi_entry_id: str | None = None
                meaning_zh: str | None = None
                part_of_speech: str | None = None
                frequency_rank: int | None = None
                if match is None:
                    flags |= MISSING_CHINESE_DEFINITION
                    if len(report["unresolvedSamples"]) < 50:
                        report["unresolvedSamples"].append(
                            {"level": source.level, "headword": source.headword, "reading": source.reading}
                        )
                elif match.ambiguous:
                    flags |= AMBIGUOUS_TOMOSHI_MATCH | MISSING_CHINESE_DEFINITION
                    tomoshi_entry_id = match.entry_id
                    frequency_rank = match.frequency_rank
                    report["ambiguousTomoshiMatches"] += 1
                    if len(report["ambiguousSamples"]) < 50:
                        report["ambiguousSamples"].append(
                            {"level": source.level, "headword": source.headword, "reading": source.reading}
                        )
                else:
                    tomoshi_entry_id = match.entry_id
                    meaning_zh = match.meaning_zh
                    part_of_speech = match.part_of_speech
                    validate_part_of_speech(
                        part_of_speech,
                        f"{source.level} {source.headword} ({source.reading})",
                    )
                    frequency_rank = match.frequency_rank
                    if not meaning_zh:
                        flags |= MISSING_CHINESE_DEFINITION
                    if match.tomoshi_level and match.tomoshi_level != source.level:
                        flags |= JLPT_LEVEL_CONFLICT
                        report["jlptLevelConflicts"] += 1
                        if len(report["levelConflictSamples"]) < 50:
                            report["levelConflictSamples"].append(
                                {
                                    "headword": source.headword,
                                    "reading": source.reading,
                                    "openJLPT": source.level,
                                    "tomoshi": match.tomoshi_level,
                                }
                            )
                if meaning_zh:
                    report["chineseMatched"] += 1
                else:
                    report["chineseMissing"] += 1
                if source.flags & READING_FROM_KANA_HEADWORD:
                    report["readingFilledFromKanaHeadword"] += 1
                report["byLevel"][source.level] += 1
                vocab_id = stable_vocab_id(source.level, source.headword, source.reading)
                output.execute(
                    """
                    INSERT INTO vocab(
                        id, level, headword, reading, meaning_zh, meaning_en_json,
                        part_of_speech, frequency_rank, openjlpt_source_id,
                        tomoshi_entry_id, normalized_headword, normalized_reading,
                        normalized_meaning_zh, sort_order, data_flags
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        vocab_id,
                        source.level,
                        source.headword,
                        source.reading,
                        meaning_zh,
                        json.dumps(source.meanings_en, ensure_ascii=False, separators=(",", ":")),
                        part_of_speech,
                        frequency_rank,
                        vocab_id,
                        tomoshi_entry_id,
                        normalize_text(source.headword).casefold(),
                        normalize_reading(source.reading).casefold(),
                        normalize_text(meaning_zh).casefold() if meaning_zh else None,
                        source.sort_order,
                        flags,
                    ),
                )
                for example_order, example in enumerate(source.examples[:3]):
                    output.execute(
                        """
                        INSERT INTO vocab_examples(id, vocab_id, japanese, english, sort_order)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (
                            stable_example_id(
                                vocab_id, example["ja"], example["en"], example_order
                            ),
                            vocab_id,
                            example["ja"],
                            example["en"] or None,
                            example_order,
                        ),
                    )
                    report["exampleCount"] += 1

            generated_at = args.generated_at
            sources = manifest["sources"]
            metadata = {
                "schema_version": str(SCHEMA_VERSION),
                "dataset_version": manifest["datasetVersion"],
                "generated_at": generated_at,
                "source_manifest_version": str(manifest["manifestVersion"]),
                "source_manifest_sha256": sha256_file(args.source_manifest),
                "openjlpt_revision": sources["openjlpt"]["version"],
                "tomoshi_version": sources["tomoshi"]["version"],
                "tomoshi_sha256": sources["tomoshi"]["files"]["tomoshi-dict-open.db"]["sha256"],
                "unidic_cwj_version": sources["unidic_cwj"]["version"],
                "unidic_cwj_sha256": sources["unidic_cwj"]["files"]["lex_3_1.csv"]["sha256"],
                "kanjium_revision": sources["kanjium"]["version"],
                "kanjium_sha256": sources["kanjium"]["files"]["accents.txt"]["sha256"],
                "tatoeba_snapshot": sources["tatoeba"]["version"],
                "tatoeba_jpn_sha256": sources["tatoeba"]["files"]["jpn_sentences.tsv.bz2"]["sha256"],
                "tatoeba_cmn_sha256": sources["tatoeba"]["files"]["cmn_sentences.tsv.bz2"]["sha256"],
                "tatoeba_links_sha256": sources["tatoeba"]["files"]["jpn-cmn_links.tsv.bz2"]["sha256"],
                "license": "CC BY-SA 4.0",
                "word_count_total": str(expected["total"]),
                **{
                    f"word_count_{level.lower()}": str(expected["byLevel"][level])
                    for level in LEVELS
                },
            }
            output.executemany(
                "INSERT INTO library_meta(key, value) VALUES (?, ?)", metadata.items()
            )

        report["pitch"] = run_pitch_enrichment(
            output, staging_path, args, manifest
        )
        report["translations"] = apply_translation_coverage(
            output, translation_metadata, translation_records
        )
        enrichment_metadata = {
            "pitch_coverage_count": str(report["pitch"]["coverage"]),
            "pitch_null_count": str(report["pitch"]["nullCount"]),
            "pitch_audit_sha256": report["pitch"]["auditSHA256"],
            "translation_coverage_count": str(report["translations"]["coverage"]),
            "translation_coverage_sha256": sha256_file(args.translation_coverage),
            "translation_model_repository": report["translations"]["modelRepository"],
            "translation_model_revision": report["translations"]["modelRevision"],
            "translation_model_weights_sha256": report["translations"]["modelWeightsSHA256"],
            "translation_model_manifest_sha256": translation_model_manifest_sha256,
        }
        with output:
            output.executemany(
                "INSERT INTO library_meta(key, value) VALUES (?, ?)",
                enrichment_metadata.items(),
            )
        report["exampleCoverage"] = round(
            output.execute(
                "SELECT COUNT(DISTINCT vocab_id) * 1.0 / (SELECT COUNT(*) FROM vocab) "
                "FROM vocab_examples"
            ).fetchone()[0],
            6,
        )
        output.execute("ANALYZE")
        output.commit()
        output.execute("VACUUM")
    finally:
        failed = sys.exc_info()[0] is not None
        output.close()
        tomoshi.close()
        if failed and staging_path.exists():
            staging_path.unlink()

    try:
        write_notice(args.notice, manifest, translation_metadata)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        validate_database(
            staging_path,
            expected,
            args.notice,
            required_schema_version=SCHEMA_VERSION,
        )
        os.replace(staging_path, args.output)
    except Exception:
        if staging_path.exists():
            staging_path.unlink()
        raise
    return report


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openjlpt", type=Path)
    parser.add_argument("--tomoshi", type=Path)
    parser.add_argument("--unidic-cwj", type=Path)
    parser.add_argument("--kanjium", type=Path)
    parser.add_argument("--tatoeba-jpn", type=Path)
    parser.add_argument("--tatoeba-cmn", type=Path)
    parser.add_argument("--tatoeba-links", type=Path)
    parser.add_argument("--translation-coverage", type=Path)
    parser.add_argument(
        "--translation-model-manifest",
        type=Path,
        default=Path(__file__).with_name("jlpt_translation_model_v1.json"),
    )
    parser.add_argument("--quality-report-dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--notice", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--expected-counts",
        type=Path,
        default=Path(__file__).with_name("jlpt_expected_counts.json"),
    )
    parser.add_argument(
        "--source-manifest",
        type=Path,
        default=Path(__file__).with_name("jlpt_sources_v2.json"),
    )
    parser.add_argument("--generated-at")
    parser.add_argument("--validate-existing", action="store_true")
    args = parser.parse_args(argv)
    if args.validate_existing:
        return args
    required_build_arguments = {
        "--openjlpt": args.openjlpt,
        "--tomoshi": args.tomoshi,
        "--unidic-cwj": args.unidic_cwj,
        "--kanjium": args.kanjium,
        "--tatoeba-jpn": args.tatoeba_jpn,
        "--tatoeba-cmn": args.tatoeba_cmn,
        "--tatoeba-links": args.tatoeba_links,
        "--translation-coverage": args.translation_coverage,
        "--translation-model-manifest": args.translation_model_manifest,
        "--quality-report-dir": args.quality_report_dir,
        "--report": args.report,
        "--generated-at": args.generated_at,
    }
    missing = [name for name, value in required_build_arguments.items() if value is None]
    if missing:
        parser.error(f"required when building: {', '.join(missing)}")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv or sys.argv[1:])
        result = build(args)
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except Exception as error:
        print(f"build_jlpt_library.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
