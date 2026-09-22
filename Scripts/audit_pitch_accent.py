#!/usr/bin/env python3
"""T01 audit: match Oboe's JLPT vocabulary against a pinned UniDic lex.csv.

Read-only against both inputs. Produces coverage / ambiguity / anomaly
reports under the output directory; nothing is written back into the app
bundle or the SQLite files.

Usage:
    python3 Scripts/audit_pitch_accent.py \
        --jlpt OboeApp/Resources/JLPT/jlpt-library.sqlite \
        --unidic /path/to/lex_3_1.csv \
        --out docs/v0.5/pitch-audit
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

# UniDic CWJ lex_3_1.csv column indices (0-based), verified against the
# 3.1.0 distribution: 33 columns per row.
COL_SURFACE = 0
COL_POS1 = 4
COL_POS2 = 5
COL_CTYPE = 8
COL_LEMMA = 11
COL_ORTHBASE = 14
COL_PRONBASE = 15
COL_GOSHU = 16
COL_ATYPE = 28
COL_ACONTYPE = 29
COL_AMODTYPE = 30
COL_LID = 31
COL_LEMMA_ID = 32

# 语种的候选优先级：和 > 漢 > 外 > 混 > 固 > 記号/不明。
GOSHU_PRIORITY = {"和": 0, "漢": 1, "外": 2, "混": 3, "固": 4, "記号": 5, "不明": 6}

# 白名单词性 → UniDic pos1/cType 过滤条件。
POS_NARROWING: dict[str, tuple[set[str], "re.Pattern | None"]] = {
    "名词": ({"名詞"}, None),
    "代词": ({"代名詞"}, None),
    "五段动词": ({"動詞"}, re.compile(r"^五段")),
    "一段动词": ({"動詞"}, re.compile(r"^[上下]一段")),
    "する动词": ({"動詞"}, re.compile(r"^サ行変格")),
    "くる动词": ({"動詞"}, re.compile(r"^カ行変格")),
    "他动词": ({"動詞"}, None),
    "自动词": ({"動詞"}, None),
    "い形容词": ({"形容詞"}, None),
    "な形容词": ({"形状詞"}, None),
    "副词": ({"副詞"}, None),
    "助词": ({"助詞"}, None),
    "助动词": ({"助動詞"}, None),
    "接续词": ({"接続詞"}, None),
    "感叹词": ({"感動詞"}, None),
    "量词": ({"名詞"}, None),  # pos2 助数詞仍属 名詞
    "接头词": ({"接頭辞"}, None),
    "接尾词": ({"接尾辞"}, None),
    "表达": (set(), None),  # 无对应类目，不参与收窄
}

SMALL_KANA = set("ぁぃぅぇぉゃゅょゎゕゖァィゥェォャュョヮヵヶ")
KANA_VOWEL = {}


def _build_vowel_table() -> dict[str, str]:
    table: dict[str, str] = {}
    groups = [
        "あかさたなはまやらわがざだばぱ",
        "いきしちにひみりぎじぢびぴ",
        "うくすつぬふむゆるぐずづぶぷゔ",
        "えけせてねへめれげぜでべぺ",
        "おこそとのほもよろをごぞどぼぽ",
    ]
    vowels = ["あ", "い", "う", "え", "お"]
    for group, vowel in zip(groups, vowels):
        for ch in group:
            table[ch] = vowel
    # 小假名的元音决定长音展开（ヒャー → ひゃあ）。
    for small, vowel in {
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お",
        "ゃ": "あ", "ゅ": "う", "ょ": "お", "ゎ": "あ", "ゕ": "あ", "ゖ": "え",
    }.items():
        table[small] = vowel
    # 片假名同样映射。
    for ch, vowel in list(table.items()):
        table[chr(ord(ch) + 0x60)] = vowel
    return table


KANA_VOWEL = _build_vowel_table()


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip()


def kata_to_hira(value: str) -> str:
    return "".join(
        chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in value
    )


def mora_count(reading: str) -> int:
    """Mirror of OboeDomain.JapaneseMoraCounter — keep in sync."""
    normalized = kata_to_hira(normalize_text(reading))
    count = 0
    for ch in normalized:
        if ch.isspace():
            continue
        if ch in SMALL_KANA and count > 0:
            continue
        count += 1
    return count


def pron_to_reading_kana(pron: str) -> str:
    """Single best-effort expansion of UniDic pronBase into kana spelling."""
    variants = pron_spellings(pron)
    return sorted(variants, key=len)[0] if variants else kata_to_hira(normalize_text(pron))


def pron_spellings(pron: str) -> set[str]:
    """All plausible kana spellings of a UniDic pronBase string.

    UniDic writes every long vowel as ー; orthographic readings spell it
    differently by etymology — お段→う (とうきょう) or お (おおきい),
    え段→い (えいご) or え (おねえさん), あ/う/い 段→同元音; 外来语词
    reading 也可能直接保留 ー (ぼーるぺん). Each ー expands independently,
    so the result is a small set (bounded at 64 variants).
    """
    base = kata_to_hira(normalize_text(pron)).replace("・", "").replace(" ", "")
    variants: list[str] = [""]
    for ch in base:
        if ch != "ー":
            variants = [v + ch for v in variants]
            continue
        expanded: list[str] = []
        for variant in variants:
            vowel = None
            for prev in reversed(variant):
                vowel = KANA_VOWEL.get(prev)
                if vowel is not None:
                    break
            options = ["ー"]
            if vowel == "お":
                options += ["う", "お"]
            elif vowel == "え":
                options += ["い", "え"]
            elif vowel is not None:
                options.append(vowel)
            expanded.extend(variant + opt for opt in options)
        variants = expanded[:64]
    return set(variants)


def headword_variants(headword: str) -> list[str]:
    """JLPT headwords may list alternates: いい/よい, より、ほう, 見る 観る."""
    parts = re.split(r"[/、\s　]+", headword)
    seen: list[str] = []
    for part in parts:
        variant = normalize_text(part)
        if variant and variant not in seen:
            seen.append(variant)
    return seen or [normalize_text(headword)]


def is_kana_only(value: str) -> bool:
    return bool(value) and all(
        not ("一" <= c <= "鿿") and not c.isascii() for c in value if not c.isspace()
    )


def reading_variants(reading: str, headword: str) -> list[tuple[str, str]]:
    """Return (normalizedReading, note) variants to try, in order.

    JLPT readings may list alternates (なん/なに, しち / なな, じゅう とお),
    suru-verb stems (reading さんぽする for headword 散歩 — UniDic indexes
    the noun, so the stem is tried as a fallback marked 'suru_stem'),
    parenthesised POS notes ((感), (終わり)) that are not readings at all,
    and a trailing は which UniDic pronBase writes as ワ (こんにちは).
    """
    variants: list[tuple[str, str]] = []
    for part in re.split(r"[/、\s　]+", reading):
        part = part.strip()
        if not part or re.search(r"[\[\]［］0-9０-９A-Za-zａ-ｚＡ-Ｚ]", part):
            continue
        candidates = [part]
        if re.search(r"[()（）]", part):
            # あたたか(い) → あたたかい / あたたか; pure notes like (感) → ""
            candidates = [
                re.sub(r"[()（）]", "", part),
                re.sub(r"\([^)]*\)|（[^）]*）", "", part),
            ]
        for cand in candidates:
            kana = normalize_reading_kana(normalize_text(cand))
            if (
                kana
                and re.search(r"[ぁ-んァ-ヶー]", kana)
                and all(v[0] != kana for v in variants)
            ):
                variants.append((kana, ""))
    if not variants:
        kana = kata_to_hira(normalize_text(headword))
        if is_kana_only(kana):
            variants = [(normalize_reading_kana(kana), "headword_reading")]
    if variants:
        first_kana = variants[0][0]
        if (
            first_kana.endswith("する")
            and len(first_kana) > 3
            and not normalize_text(headword).endswith("する")
        ):
            variants.append((first_kana[: -len("する")], "suru_stem"))
        for kana, note in list(variants):
            if kana.endswith("は"):
                variants.append((kana[:-1] + "わ", note or "final_ha_wa"))
    return variants


def normalize_reading_kana(hira: str) -> str:
    """Collapse orthographic づ/ぢ/を to modern pronunciation ず/じ/お,
    matching UniDic pronBase conventions (ツヅク is stored as ツズク)."""
    return (
        kata_to_hira(hira)
        .replace("づ", "ず")
        .replace("ぢ", "じ")
        .replace("を", "お")
    )


@dataclass
class UniDicCandidate:
    lemma_id: str
    lid: str
    pos1: str
    pos2: str
    ctype: str
    goshu: str
    orthbase: str
    pronbase: str
    pron_kana: str
    atype_raw: str
    matched_via: str  # surface | orthBase | lemma | orth | pronOnly
    source: str  # 例如 cwj / csj

    @property
    def atype_candidates(self) -> list[int]:
        if self.atype_raw in ("", "*"):
            return []
        result = []
        for part in self.atype_raw.split(","):
            part = part.strip()
            if part.isdigit():
                result.append(int(part))
        return result


@dataclass
class AuditResult:
    vocab_id: str
    level: str
    headword: str
    reading: str
    pos_raw: str
    status: str  # unique | multi_candidate | ambiguous | unmatched_reading | unmatched_headword | no_accent_field
    primary: int | None
    primary_source: str
    mora: int
    candidates: list[UniDicCandidate] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def vocab_pos_atoms(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [p.strip() for p in raw.split("/") if p.strip()]


def pos_filter(cands: list[UniDicCandidate], atoms: list[str]) -> list[UniDicCandidate]:
    wanted_pos1: set[str] = set()
    ctype_patterns: list[re.Pattern] = []
    for atom in atoms:
        spec = POS_NARROWING.get(atom)
        if not spec:
            continue
        pos1_set, pattern = spec
        wanted_pos1 |= pos1_set
        if pattern:
            ctype_patterns.append(pattern)
    if not wanted_pos1:
        return cands
    narrowed = [c for c in cands if c.pos1 in wanted_pos1]
    if ctype_patterns and narrowed:
        verb_like = [c for c in narrowed if c.pos1 == "動詞"]
        if verb_like and any(
            p.match(c.ctype or "") for c in verb_like for p in ctype_patterns
        ):
            narrowed = [
                c
                for c in narrowed
                if c.pos1 != "動詞" or any(p.match(c.ctype or "") for p in ctype_patterns)
            ]
    return narrowed or cands


def candidate_rank(c: UniDicCandidate) -> tuple:
    return (
        {"surface": 0, "orthBase": 1, "lemma": 2, "orth": 3, "pronOnly": 4}.get(
            c.matched_via, 5
        ),
        GOSHU_PRIORITY.get(c.goshu, 9),
        {"cwj": 0, "csj": 1}.get(c.source, 9),
        c.lid,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jlpt", type=Path, required=True)
    parser.add_argument(
        "--unidic",
        type=str,
        required=True,
        nargs="+",
        help="lex CSV paths, optionally tagged name=path (e.g. cwj=lex_3_1.csv)",
    )
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--kanjium",
        type=Path,
        default=None,
        help="kanjium accents.txt (word<TAB>reading<TAB>accents) used as a "
        "secondary source for entries UniDic structurally lacks",
    )
    args = parser.parse_args()

    if not args.jlpt.is_file():
        print(f"JLPT database not found: {args.jlpt}", file=sys.stderr)
        return 2
    unidic_sources: list[tuple[str, Path]] = []
    for spec in args.unidic:
        if "=" in spec:
            name, _, raw = spec.partition("=")
        else:
            name, raw = Path(spec).stem, spec
        path = Path(raw)
        if not path.is_file():
            print(f"UniDic lex CSV not found: {path}", file=sys.stderr)
            return 2
        unidic_sources.append((name, path))

    db = sqlite3.connect(f"file:{args.jlpt}?mode=ro", uri=True)
    vocab = db.execute(
        "SELECT id, level, headword, reading, part_of_speech FROM vocab"
    ).fetchall()
    db.close()

    headword_set: set[str] = set()
    headword_of_vocab: dict[str, list[str]] = {}
    readings: dict[str, str] = {}
    reading_variants_of: dict[str, list[tuple[str, str]]] = {}
    kana_headword_ids: set[str] = set()
    kana_readings: set[str] = set()
    for row in vocab:
        variants = headword_variants(row[2])
        headword_of_vocab[row[0]] = variants
        headword_set.update(variants)
        readings[row[0]] = kata_to_hira(normalize_text(row[3]))
        rvariants = reading_variants(row[3], row[2])
        reading_variants_of[row[0]] = rvariants
        if is_kana_only(row[2]):
            kana_headword_ids.add(row[0])
            kana_readings.update(v for v, _ in rvariants)

    # 只保留可能命中的 UniDic 行；每个来源单次扫过。
    candidates_by_head: dict[str, list[UniDicCandidate]] = defaultdict(list)
    # 假名头部词兜底：按发音集合索引，用于 reading+POS 匹配。
    pron_index: dict[str, list[UniDicCandidate]] = defaultdict(list)
    for source_name, unidic_path in unidic_sources:
        with unidic_path.open(encoding="utf-8", newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 33:
                    continue
                surface, lemma, orthbase, orth = (
                    normalize_text(row[COL_SURFACE]),
                    normalize_text(row[COL_LEMMA]),
                    normalize_text(row[COL_ORTHBASE]),
                    normalize_text(row[12]),
                )
                matched_via = None
                key = None
                for via, value in (
                    ("surface", surface),
                    ("orthBase", orthbase),
                    ("lemma", lemma),
                    ("orth", orth),
                ):
                    if value in headword_set:
                        matched_via, key = via, value
                        break
                spellings = pron_spellings(row[COL_PRONBASE])
                candidate = UniDicCandidate(
                    lemma_id=row[COL_LEMMA_ID],
                    lid=row[COL_LID],
                    pos1=row[COL_POS1],
                    pos2=row[COL_POS2],
                    ctype=row[COL_CTYPE],
                    goshu=row[COL_GOSHU],
                    orthbase=row[COL_ORTHBASE],
                    pronbase=row[COL_PRONBASE],
                    pron_kana=pron_to_reading_kana(row[COL_PRONBASE]),
                    atype_raw=row[COL_ATYPE],
                    matched_via=matched_via or "pronOnly",
                    source=source_name,
                )
                if matched_via is not None:
                    candidates_by_head[key].append(candidate)
                if spellings & kana_readings:
                    for spelling in spellings & kana_readings:
                        pron_index[spelling].append(candidate)

    # 预先计算每个 UniDic 候选的发音拼写集合（按 lemma/lid 缓存）。
    spelling_cache: dict[str, set[str]] = {}

    def spellings_of(c: UniDicCandidate) -> set[str]:
        key = c.pronbase
        cached = spelling_cache.get(key)
        if cached is None:
            cached = pron_spellings(c.pronbase)
            spelling_cache[key] = cached
        return cached

    results: list[AuditResult] = []
    for vocab_id, level, headword, reading, pos_raw in vocab:
        variants = headword_of_vocab[vocab_id]
        mora = mora_count(reading)
        atoms = vocab_pos_atoms(pos_raw)
        reading_kana = readings[vocab_id]

        rows: list[UniDicCandidate] = []
        for variant in variants:
            rows.extend(candidates_by_head.get(variant, []))
            # する動詞：UniDic 可能有独立的 サ行変格 词目（散歩する）。
            if readings[vocab_id].endswith("する"):
                rows.extend(candidates_by_head.get(variant + "する", []))
        if not rows and vocab_id in kana_headword_ids:
            rows = list(pron_index.get(reading_kana, []))
        result = AuditResult(
            vocab_id=vocab_id,
            level=level,
            headword=headword,
            reading=reading,
            pos_raw=pos_raw or "",
            status="",
            primary=None,
            primary_source="",
            mora=mora,
        )
        if not rows:
            result.status = "unmatched_headword"
            results.append(result)
            continue

        rvariants = reading_variants_of[vocab_id]
        if not rvariants:
            # reading 列整体不可解析（如 "(かーぺっと)"），以 UniDic 词目的
            # 发音形作为事实读音，按正常候选流程处理。
            rvariants = [("", "reading_unusable")]
            reading_matches = list(rows)
            matched_variant_notes = ["reading_unusable"]
        else:
            reading_matches = []
            matched_variant_notes = []
            for variant_kana, note in rvariants:
                hits = [c for c in rows if variant_kana in spellings_of(c)]
                if hits:
                    reading_matches = hits
                    if note:
                        matched_variant_notes.append(note)
                    if variant_kana != reading_kana:
                        matched_variant_notes.append(f"reading_variant:{variant_kana}")
                    break
        if not reading_matches:
            result.status = "unmatched_reading"
            result.candidates = sorted(rows, key=candidate_rank)[:8]
            result.notes.append(
                "headword matched but no pronunciation equals reading"
            )
            results.append(result)
            continue
        result.notes.extend(matched_variant_notes)

        narrowed = pos_filter(reading_matches, atoms)
        narrowed.sort(key=candidate_rank)

        # 按 (lemma_id, pron_kana) 聚合多候选。
        grouped: dict[tuple[str, str], list[int]] = defaultdict(list)
        representative: dict[tuple[str, str], UniDicCandidate] = {}
        for c in narrowed:
            key = (c.lemma_id, c.pron_kana)
            representative.setdefault(key, c)
            for value in c.atype_candidates:
                if value not in grouped[key]:
                    grouped[key].append(value)

        distinct_pitches = sorted({p for values in grouped.values() for p in values})
        has_accent = any(values for values in grouped.values())
        if not has_accent:
            result.status = "no_accent_field"
            result.candidates = narrowed[:8]
            results.append(result)
            continue

        first_key = next(iter(grouped))
        primary = grouped[first_key][0]
        result.primary = primary
        rep = representative[first_key]
        result.primary_source = f"{rep.source}/{rep.matched_via}"
        result.candidates = narrowed[:12]

        # mora 校验应针对实际匹配的读音（reading 列可能是注释文本）。
        matched_reading = representative[first_key].pron_kana
        effective_mora = mora_count(matched_reading)
        result.mora = effective_mora
        if primary > effective_mora:
            result.notes.append(
                f"pitch {primary} exceeds reading mora {effective_mora}"
            )
        if len(distinct_pitches) > 1:
            result.status = "multi_candidate"
            result.notes.append(
                "candidates: " + ",".join(str(p) for p in distinct_pitches)
            )
        elif len(grouped) > 1:
            # 同一发音多 lemma 但音调一致 —— 不算歧义，记录即可。
            result.status = "unique"
            result.notes.append("multiple lemmas agree on pitch")
        else:
            result.status = "unique"
        results.append(result)

    # 第二来源：kanjium accents.txt（NHK 系数据，CC BY-SA 4.0）。
    # UniDic 是短单位词典，结构性缺少复合词词目；kanjium 只用于补齐
    # UniDic 未命中的条目，不覆盖 UniDic 结果。
    if args.kanjium:
        kanjium_wr: dict[tuple[str, str], list[int]] = defaultdict(list)
        kanjium_r: dict[str, list[int]] = defaultdict(list)
        with args.kanjium.open(encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 3:
                    continue
                word = normalize_text(parts[0])
                kread = normalize_reading_kana(parts[1])
                accs = [int(a) for a in parts[2].split(",") if a.strip().isdigit()]
                for acc in accs:
                    if acc not in kanjium_wr[(word, kread)]:
                        kanjium_wr[(word, kread)].append(acc)
                    if acc not in kanjium_r[kread]:
                        kanjium_r[kread].append(acc)
        for result in results:
            if result.status not in (
                "unmatched_headword",
                "unmatched_reading",
                "no_accent_field",
            ):
                continue
            variants = headword_of_vocab[result.vocab_id]
            rvariants = reading_variants_of[result.vocab_id]
            accents: list[int] = []
            via = ""
            matched_rv = ""
            for v in variants:
                for rv, _ in rvariants:
                    for rw in (v, v + "する"):
                        found = kanjium_wr.get((rw, rv))
                        if found:
                            accents, via, matched_rv = found, f"kanjium:{rw}", rv
                            break
                    if accents:
                        break
                if accents:
                    break
            if not accents and result.vocab_id in kana_headword_ids:
                for rv, _ in rvariants:
                    found = kanjium_r.get(rv)
                    if found:
                        accents, via, matched_rv = found, f"kanjium-reading:{rv}", rv
                        break
            if not accents:
                continue
            result.notes.append(via)
            result.primary = accents[0]
            result.primary_source = "kanjium"
            if matched_rv:
                result.mora = mora_count(matched_rv)
            if len(accents) > 1:
                result.status = "multi_candidate"
                result.notes.append(
                    "candidates: " + ",".join(str(p) for p in sorted(accents))
                )
            else:
                result.status = "unique"
            if result.primary is not None and result.primary > result.mora:
                result.notes.append(
                    f"pitch {result.primary} exceeds reading mora {result.mora}"
                )

    args.out.mkdir(parents=True, exist_ok=True)
    write_reports(args.out, results)

    counts = Counter(r.status for r in results)
    total = len(results)
    pitch_values = sum(r.primary is not None for r in results)
    print(f"total={total}")
    for status, n in sorted(counts.items()):
        print(f"  {status}: {n}")
    print(f"pitch coverage: {pitch_values}/{total} = {pitch_values / total:.2%}")
    print(f"null pitch: {total - pitch_values}")
    return 0


def write_reports(out: Path, results: list[AuditResult]) -> None:
    def rows(statuses: set[str]) -> list[AuditResult]:
        return [r for r in results if r.status in statuses]

    with (out / "audit-results.jsonl").open("w", encoding="utf-8") as fh:
        for r in results:
            fh.write(
                json.dumps(
                    {
                        "id": r.vocab_id,
                        "level": r.level,
                        "headword": r.headword,
                        "reading": r.reading,
                        "pos": r.pos_raw,
                        "status": r.status,
                        "primary": r.primary,
                        "primarySource": r.primary_source,
                        "mora": r.mora,
                        "notes": r.notes,
                        "candidates": [
                            {
                                "lemmaId": c.lemma_id,
                                "lid": c.lid,
                                "pos1": c.pos1,
                                "pos2": c.pos2,
                                "cType": c.ctype,
                                "goshu": c.goshu,
                                "orthBase": c.orthbase,
                                "pronBase": c.pronbase,
                                "aType": c.atype_raw,
                                "matchedVia": c.matched_via,
                                "source": c.source,
                            }
                            for c in r.candidates
                        ],
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )

    with (out / "unmatched.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["id", "level", "headword", "reading", "pos", "status", "near_candidates"])
        for r in rows({"unmatched_headword", "unmatched_reading", "no_accent_field"}):
            near = "; ".join(
                f"{c.orthbase}/{c.pronbase}[{c.atype_raw}]({c.pos1},{c.goshu})"
                for c in r.candidates[:6]
            )
            writer.writerow(
                [r.vocab_id, r.level, r.headword, r.reading, r.pos_raw, r.status, near]
            )

    with (out / "multi-candidate.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["id", "level", "headword", "reading", "pos", "primary", "all_candidates"])
        for r in rows({"multi_candidate"}):
            writer.writerow(
                [
                    r.vocab_id,
                    r.level,
                    r.headword,
                    r.reading,
                    r.pos_raw,
                    r.primary,
                    "; ".join(
                        f"{c.lemma_id}:{c.atype_raw}({c.pos1}/{c.ctype},{c.goshu},{c.matched_via})"
                        for c in r.candidates
                    ),
                ]
            )

    with (out / "anomalies.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["id", "level", "headword", "reading", "mora", "primary", "note"])
        for r in results:
            if r.primary is not None and r.primary > r.mora:
                writer.writerow(
                    [r.vocab_id, r.level, r.headword, r.reading, r.mora, r.primary, "; ".join(r.notes)]
                )

    high_pitch = [r for r in results if r.primary is not None and r.primary >= 5]
    with (out / "pitch-five-plus.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["id", "level", "headword", "reading", "mora", "pitch"])
        for r in high_pitch:
            writer.writerow([r.vocab_id, r.level, r.headword, r.reading, r.mora, r.primary])

    summary = {
        "total": len(results),
        "pitchValueCount": sum(r.primary is not None for r in results),
        "nullPitchCount": sum(r.primary is None for r in results),
        "byStatus": dict(Counter(r.status for r in results)),
        "byPrimarySource": dict(
            sorted(
                Counter(
                    "kanjium" if r.primary_source == "kanjium" else "unidic_cwj"
                    for r in results
                    if r.primary is not None
                ).items()
            )
        ),
        "pitchDistribution": dict(
            sorted(
                Counter(r.primary for r in results if r.primary is not None).items()
            )
        ),
        "pitchExceedsMora": sum(
            1 for r in results if r.primary is not None and r.primary > r.mora
        ),
        "byLevel": {
            level: dict(Counter(r.status for r in results if r.level == level))
            for level in ("N5", "N4", "N3", "N2", "N1")
        },
    }
    (out / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    raise SystemExit(main())
