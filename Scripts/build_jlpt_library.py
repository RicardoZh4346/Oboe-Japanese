#!/usr/bin/env python3
"""Build Oboe's distributable, read-only JLPT vocabulary database."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sqlite3
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


LEVELS = ("N5", "N4", "N3", "N2", "N1")
MISSING_CHINESE_DEFINITION = 1 << 0
AMBIGUOUS_TOMOSHI_MATCH = 1 << 1
READING_FROM_KANA_HEADWORD = 1 << 2
JLPT_LEVEL_CONFLICT = 1 << 3


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
            frequency_rank INTEGER,
            openjlpt_source_id TEXT,
            tomoshi_entry_id TEXT,
            normalized_headword TEXT NOT NULL,
            normalized_reading TEXT NOT NULL,
            normalized_meaning_zh TEXT,
            sort_order INTEGER NOT NULL,
            data_flags INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE vocab_examples (
            id TEXT PRIMARY KEY NOT NULL,
            vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
            japanese TEXT NOT NULL CHECK (length(trim(japanese)) > 0),
            english TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_vocab_level ON vocab(level);
        CREATE INDEX idx_vocab_level_order ON vocab(level, sort_order, id);
        CREATE INDEX idx_vocab_headword ON vocab(normalized_headword);
        CREATE INDEX idx_vocab_reading ON vocab(normalized_reading);
        CREATE INDEX idx_vocab_meaning_zh ON vocab(normalized_meaning_zh);
        CREATE INDEX idx_vocab_frequency ON vocab(level, frequency_rank);
        CREATE INDEX idx_vocab_examples_vocab ON vocab_examples(vocab_id, sort_order);
        """
    )


def write_notice(path: Path, expected: dict[str, Any]) -> None:
    content = f"""# Oboe 内置 JLPT 词汇数据来源与许可

数据集版本：{expected['datasetVersion']}  
OpenJLPT revision：`{expected['openJLPTRevision']}`  
Tomoshi Open Data：`{expected['tomoshiVersion']}`

本 SQLite 是 Oboe 为离线浏览与导入而制作的衍生数据集，按 **CC BY-SA 4.0** 提供。Oboe 应用代码的 MIT 许可不覆盖该数据集。

## 来源与署名

- OpenJLPT（evanclan/OpenJLPT）：JLPT N5–N1 社区等级、日文词形、假名、英文释义和 Tatoeba 日英例句，CC BY-SA 4.0。
- Jonathan Waller's JLPT Resources（tanos.co.uk）：社区 JLPT 等级来源，CC BY。
- JMdict / EDICT，Electronic Dictionary Research and Development Group（EDRDG）：词形、读音、英文释义和词性，CC BY-SA 4.0。
- Tomoshi Dictionary Open Data（Y1Z）：JMdict 衍生的简体中文释义与频率层，CC BY-SA 4.0。名称与 logo 不包含在许可中，本项目与 Tomoshi 不存在背书关系。
- Tatoeba：日文例句及英文翻译，CC BY 2.0 FR。

## Oboe 的修改

Oboe 筛选 OpenJLPT vocabulary 数据；以 NFKC 和平假名规则规范化搜索字段；上游 reading 为空时，从 headword 变体标注中取第一个读音；按词形与读音匹配 Tomoshi/JMdict entry；合并可唯一确定的简体中文释义、词性与频率；保留英文 meanings 数组；转换为只读 SQLite schema，并生成稳定 sourceRef。歧义或缺失匹配不会由 AI 自动补全。

JLPT 官方目前不发布固定词汇清单；所有 N1～N5 标记均为社区整理的非官方分类，仅供学习参考。

许可证与原始 NOTICE：

- https://github.com/evanclan/OpenJLPT
- https://github.com/tomoshi-app/tomoshi-dict-data
- https://creativecommons.org/licenses/by-sa/4.0/legalcode
- https://creativecommons.org/licenses/by/2.0/fr/
- https://www.edrdg.org/edrdg/licence.html
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def validate_database(path: Path, expected: dict[str, Any], notice: Path) -> dict[str, Any]:
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
        meta = dict(connection.execute("SELECT key, value FROM library_meta"))
        required_meta = {
            "schema_version", "dataset_version", "generated_at", "openjlpt_revision",
            "tomoshi_version", "license", "word_count_total", "word_count_n5",
            "word_count_n4", "word_count_n3", "word_count_n2", "word_count_n1",
        }
        if not required_meta.issubset(meta):
            raise ValueError(f"library metadata is incomplete: {required_meta - set(meta)}")
        return {"total": total, "byLevel": by_level, "meta": meta}
    finally:
        connection.close()


def build(args: argparse.Namespace) -> dict[str, Any]:
    expected = load_expected_counts(args.expected_counts)
    if args.validate_existing:
        return validate_database(args.output, expected, args.notice)

    words = load_openjlpt(args.openjlpt, expected)
    tomoshi = sqlite3.connect(f"file:{args.tomoshi}?mode=ro", uri=True)
    tomoshi.row_factory = sqlite3.Row
    ensure_tomoshi_schema(tomoshi)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        args.output.unlink()
    output = sqlite3.connect(args.output)
    output.execute("PRAGMA journal_mode = DELETE")
    create_schema(output)

    report: dict[str, Any] = {
        "datasetVersion": expected["datasetVersion"],
        "openJLPTRevision": expected["openJLPTRevision"],
        "tomoshiVersion": expected["tomoshiVersion"],
        "total": len(words),
        "byLevel": {level: 0 for level in LEVELS},
        "chineseMatched": 0,
        "chineseMissing": 0,
        "ambiguousTomoshiMatches": 0,
        "jlptLevelConflicts": 0,
        "readingFilledFromKanaHeadword": 0,
        "exampleCount": 0,
        "exampleCoverage": 0.0,
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

            generated_at = args.generated_at or dt.datetime.now(dt.timezone.utc).isoformat()
            metadata = {
                "schema_version": "1",
                "dataset_version": expected["datasetVersion"],
                "generated_at": generated_at,
                "openjlpt_revision": expected["openJLPTRevision"],
                "tomoshi_version": expected["tomoshiVersion"],
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
        output.close()
        tomoshi.close()

    write_notice(args.notice, expected)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    validate_database(args.output, expected, args.notice)
    return report


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openjlpt", type=Path)
    parser.add_argument("--tomoshi", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--notice", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--expected-counts",
        type=Path,
        default=Path(__file__).with_name("jlpt_expected_counts.json"),
    )
    parser.add_argument("--generated-at")
    parser.add_argument("--validate-existing", action="store_true")
    args = parser.parse_args(argv)
    if args.validate_existing:
        return args
    if args.openjlpt is None or args.tomoshi is None or args.report is None:
        parser.error("--openjlpt, --tomoshi, and --report are required when building")
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
