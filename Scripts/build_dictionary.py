#!/usr/bin/env python3
"""Build Oboe's distributable, read-only Japanese dictionary database.

Offline pipeline: pinned JMdict_e XML + pinned Tomoshi open-data SQLite in,
deterministic japanese-dictionary.sqlite + NOTICE + QA report out. No network
access; every input is verified against Scripts/dictionary_sources_v1.json
(byte size + SHA-256) before it is read.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
SOURCE_MANIFEST_VERSION = 1
BUILD_VERSION = "build_dictionary/1.0"
NORMALIZER_VERSION = "oboe-search-normalizer/1"
FINGERPRINT_ALGORITHM = "jmdict-sense-fingerprint/1"
APPLICATION_ID = 0x4F424449  # "OBDI"
REQUIRED_SOURCE_IDS = {"jmdict_e", "tomoshi"}
REQUIRED_SOURCE_FILES = {
    "jmdict_e": {"JMdict_e"},
    "tomoshi": {"tomoshi-dict-open.db"},
}
# Table allowlist inside the Tomoshi overlay (decisions.md §2.7). Everything
# else in that database is never read, let alone shipped.
TOMOSHI_ALLOWED_TABLES = {"zh_defs", "table_licenses", "meta"}
TOMOSHI_OVERLAY_LOCALE = "zh-CN"
TOMOSHI_REQUIRED_LICENSE = "CC-BY-SA-4.0"
ZH_LANGUAGE_TAG = "zho"
MAX_ELEMENT_TEXT = 1_000_000
QA_SAMPLE_LIMIT = 50

# Locked JMdict DTD entity map (name -> expansion), captured from the pinned
# snapshot's internal subset. The DTD gate only accepts internal general
# entity declarations whose (name, value) pair appears here; anything else —
# external entities, parameter entities, unparsed entities, unknown names,
# rewritten values — fails the build before parsing starts.
JMDICT_ENTITIES = {
    "Buddh": "Buddhism", "Christn": "Christianity", "MA": "martial arts",
    "Shinto": "Shinto",
    "X": "rude or X-rated term (not displayed in educational software)",
    "abbr": "abbreviation",
    "adj-f": "noun or verb acting prenominally",
    "adj-i": "adjective (keiyoushi)",
    "adj-ix": "adjective (keiyoushi) - yoi/ii class",
    "adj-kari": "'kari' adjective (archaic)",
    "adj-ku": "'ku' adjective (archaic)",
    "adj-na": "adjectival nouns or quasi-adjectives (keiyodoshi)",
    "adj-nari": "archaic/formal form of na-adjective",
    "adj-no": "nouns which may take the genitive case particle 'no'",
    "adj-pn": "pre-noun adjectival (rentaishi)",
    "adj-shiku": "'shiku' adjective (archaic)",
    "adj-t": "'taru' adjective",
    "adv": "adverb (fukushi)",
    "adv-to": "adverb taking the 'to' particle",
    "agric": "agriculture", "anat": "anatomy", "arch": "archaic",
    "archeol": "archeology", "archit": "architecture",
    "art": "art, aesthetics", "astron": "astronomy",
    "ateji": "ateji (phonetic) reading", "audvid": "audiovisual",
    "aux": "auxiliary", "aux-adj": "auxiliary adjective",
    "aux-v": "auxiliary verb", "aviat": "aviation", "baseb": "baseball",
    "biochem": "biochemistry", "biol": "biology", "bot": "botany",
    "boxing": "boxing", "bra": "Brazilian", "bus": "business",
    "cards": "card games", "char": "character", "chem": "chemistry",
    "chmyth": "Chinese mythology", "chn": "children's language",
    "civeng": "civil engineering", "cloth": "clothing", "col": "colloquial",
    "comp": "computing", "company": "company name", "conj": "conjunction",
    "cop": "copula", "creat": "creature", "cryst": "crystallography",
    "ctr": "counter", "dated": "dated term", "dei": "deity",
    "dent": "dentistry", "derog": "derogatory", "doc": "document",
    "ecol": "ecology", "econ": "economics",
    "elec": "electricity, elec. eng.", "electr": "electronics",
    "embryo": "embryology", "engr": "engineering", "ent": "entomology",
    "euph": "euphemistic", "ev": "event",
    "exp": "expressions (phrases, clauses, etc.)", "fam": "familiar language",
    "fem": "female term or language", "fict": "fiction",
    "figskt": "figure skating", "film": "film", "finc": "finance",
    "fish": "fishing", "food": "food, cooking",
    "form": "formal or literary term",
    "gardn": "gardening, horticulture", "genet": "genetics",
    "geogr": "geography", "geol": "geology", "geom": "geometry",
    "gikun": "gikun (meaning as reading) or jukujikun (special kanji reading)",
    "given": "given name or forename, gender not specified", "go": "go (game)",
    "golf": "golf", "gramm": "grammar", "grmyth": "Greek mythology",
    "group": "group", "hanaf": "hanafuda", "hist": "historical term",
    "hob": "Hokkaido-ben", "hon": "honorific or respectful (sonkeigo) language",
    "horse": "horse racing", "hum": "humble (kenjougo) language",
    "iK": "word containing irregular kanji usage",
    "id": "idiomatic expression",
    "ik": "word containing irregular kana usage",
    "int": "interjection (kandoushi)", "internet": "Internet",
    "io": "irregular okurigana usage", "joc": "jocular, humorous term",
    "jpmyth": "Japanese mythology", "kabuki": "kabuki", "ksb": "Kansai-ben",
    "ktb": "Kantou-ben", "kyb": "Kyoto-ben", "kyu": "Kyuushuu-ben",
    "law": "law", "leg": "legend", "ling": "linguistics", "logic": "logic",
    "m-sl": "manga slang", "mahj": "mahjong", "male": "male term or language",
    "manga": "manga", "math": "mathematics", "mech": "mechanical engineering",
    "med": "medicine", "met": "meteorology", "mil": "military",
    "min": "mineralogy", "mining": "mining", "motor": "motorsport",
    "music": "music", "myth": "mythology",
    "n": "noun (common) (futsuumeishi)",
    "n-adv": "adverbial noun (fukushitekimeishi)", "n-pr": "proper noun",
    "n-pref": "noun, used as a prefix", "n-suf": "noun, used as a suffix",
    "n-t": "noun (temporal) (jisoumeishi)", "nab": "Nagano-ben",
    "net-sl": "Internet slang", "noh": "noh", "num": "numeric",
    "oK": "word containing out-dated kanji or kanji usage", "obj": "object",
    "obs": "obsolete term", "ok": "out-dated or obsolete kana usage",
    "on-mim": "onomatopoeic or mimetic word",
    "organization": "organization name", "ornith": "ornithology",
    "osb": "Osaka-ben", "oth": "other", "paleo": "paleontology",
    "pathol": "pathology", "person": "full name of a particular person",
    "pharm": "pharmacology", "phil": "philosophy", "photo": "photography",
    "physics": "physics", "physiol": "physiology", "place": "place name",
    "pn": "pronoun", "poet": "poetical term",
    "pol": "polite (teineigo) language", "politics": "politics",
    "pref": "prefix", "print": "printing", "product": "product name",
    "proverb": "proverb", "prowres": "professional wrestling",
    "prt": "particle", "psy": "psychiatry", "psyanal": "psychoanalysis",
    "psych": "psychology", "quote": "quotation",
    "rK": "rarely used kanji form", "rail": "railway", "rare": "rare term",
    "relig": "religion", "rk": "rarely used kana form",
    "rkb": "Ryuukyuu-ben", "rommyth": "Roman mythology",
    "sK": "search-only kanji form", "sens": "sensitive", "serv": "service",
    "ship": "ship name", "shogi": "shogi", "sk": "search-only kana form",
    "ski": "skiing", "sl": "slang", "sports": "sports", "stat": "statistics",
    "station": "railway station", "stockm": "stock market", "suf": "suffix",
    "sumo": "sumo", "surg": "surgery", "surname": "family or surname",
    "telec": "telecommunications", "thb": "Touhoku-ben",
    "tradem": "trademark", "tsb": "Tosa-ben", "tsug": "Tsugaru-ben",
    "tv": "television", "uk": "word usually written using kana alone",
    "unc": "unclassified", "unclass": "unclassified name",
    "v-unspec": "verb unspecified", "v1": "Ichidan verb",
    "v1-s": "Ichidan verb - kureru special class",
    "v2a-s": "Nidan verb with 'u' ending (archaic)",
    "v2b-k": "Nidan verb (upper class) with 'bu' ending (archaic)",
    "v2b-s": "Nidan verb (lower class) with 'bu' ending (archaic)",
    "v2d-k": "Nidan verb (upper class) with 'dzu' ending (archaic)",
    "v2d-s": "Nidan verb (lower class) with 'dzu' ending (archaic)",
    "v2g-k": "Nidan verb (upper class) with 'gu' ending (archaic)",
    "v2g-s": "Nidan verb (lower class) with 'gu' ending (archaic)",
    "v2h-k": "Nidan verb (upper class) with 'hu/fu' ending (archaic)",
    "v2h-s": "Nidan verb (lower class) with 'hu/fu' ending (archaic)",
    "v2k-k": "Nidan verb (upper class) with 'ku' ending (archaic)",
    "v2k-s": "Nidan verb (lower class) with 'ku' ending (archaic)",
    "v2m-k": "Nidan verb (upper class) with 'mu' ending (archaic)",
    "v2m-s": "Nidan verb (lower class) with 'mu' ending (archaic)",
    "v2n-s": "Nidan verb (lower class) with 'nu' ending (archaic)",
    "v2r-k": "Nidan verb (upper class) with 'ru' ending (archaic)",
    "v2r-s": "Nidan verb (lower class) with 'ru' ending (archaic)",
    "v2s-s": "Nidan verb (lower class) with 'su' ending (archaic)",
    "v2t-k": "Nidan verb (upper class) with 'tsu' ending (archaic)",
    "v2t-s": "Nidan verb (lower class) with 'tsu' ending (archaic)",
    "v2w-s": "Nidan verb (lower class) with 'u' ending and 'we' conjugation (archaic)",
    "v2y-k": "Nidan verb (upper class) with 'yu' ending (archaic)",
    "v2y-s": "Nidan verb (lower class) with 'yu' ending (archaic)",
    "v2z-s": "Nidan verb (lower class) with 'zu' ending (archaic)",
    "v4b": "Yodan verb with 'bu' ending (archaic)",
    "v4g": "Yodan verb with 'gu' ending (archaic)",
    "v4h": "Yodan verb with 'hu/fu' ending (archaic)",
    "v4k": "Yodan verb with 'ku' ending (archaic)",
    "v4m": "Yodan verb with 'mu' ending (archaic)",
    "v4n": "Yodan verb with 'nu' ending (archaic)",
    "v4r": "Yodan verb with 'ru' ending (archaic)",
    "v4s": "Yodan verb with 'su' ending (archaic)",
    "v4t": "Yodan verb with 'tsu' ending (archaic)",
    "v5aru": "Godan verb - -aru special class",
    "v5b": "Godan verb with 'bu' ending",
    "v5g": "Godan verb with 'gu' ending",
    "v5k": "Godan verb with 'ku' ending",
    "v5k-s": "Godan verb - Iku/Yuku special class",
    "v5m": "Godan verb with 'mu' ending",
    "v5n": "Godan verb with 'nu' ending",
    "v5r": "Godan verb with 'ru' ending",
    "v5r-i": "Godan verb with 'ru' ending (irregular verb)",
    "v5s": "Godan verb with 'su' ending",
    "v5t": "Godan verb with 'tsu' ending",
    "v5u": "Godan verb with 'u' ending",
    "v5u-s": "Godan verb with 'u' ending (special class)",
    "v5uru": "Godan verb - Uru old class verb (old form of Eru)",
    "vet": "veterinary terms", "vi": "intransitive verb", "vidg": "video games",
    "vk": "Kuru verb - special class", "vn": "irregular nu verb",
    "vr": "irregular ru verb, plain form ends with -ri",
    "vs": "noun or participle which takes the aux. verb suru",
    "vs-c": "su verb - precursor to the modern suru",
    "vs-i": "suru verb - included", "vs-s": "suru verb - special class",
    "vt": "transitive verb", "vulg": "vulgar expression or word",
    "vz": "Ichidan verb - zuru verb (alternative form of -jiru verbs)",
    "work": "work of art, literature, music, etc. name", "yoji": "yojijukugo",
    "zool": "zoology",
}
JMDICT_ENTITY_VALUES = {value: name for name, value in JMDICT_ENTITIES.items()}

# keb/reb priority markers -> derived common rank. nfXX codes are JMdict's own
# 500-word frequency bands, so they keep their band number; the four named
# channels fold into band 1 (first band) or 2 (second band). This is a
# relative commonness hint for sorting, never a corpus frequency claim.
PRIORITY_BAND1 = {"news1", "ichi1", "spec1", "gai1"}
PRIORITY_BAND2 = {"news2", "ichi2", "spec2", "gai2"}
PRIORITY_NF = re.compile(r"^nf([0-9]{2})$")

SENSE_TAG_CATEGORIES = (
    "field", "misc", "dialect", "xref", "ant", "s_inf", "lsource", "gloss_attr",
)
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
JMDICT_CREATED = re.compile(r"<!--\s*JMdict created:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\s*-->")


@dataclass
class Gloss:
    text: str
    language: str
    g_type: str | None
    g_gend: str | None


@dataclass
class Lsource:
    text: str
    language: str
    ls_type: str | None
    ls_wasei: str | None


@dataclass
class Sense:
    stagk: list[str] = field(default_factory=list)
    stagr: list[str] = field(default_factory=list)
    pos: list[str] = field(default_factory=list)
    xref: list[str] = field(default_factory=list)
    ant: list[str] = field(default_factory=list)
    fields: list[str] = field(default_factory=list)
    misc: list[str] = field(default_factory=list)
    s_inf: list[str] = field(default_factory=list)
    lsource: list[Lsource] = field(default_factory=list)
    dial: list[str] = field(default_factory=list)
    glosses: list[Gloss] = field(default_factory=list)
    examples: int = 0
    pos_inherited: bool = False


@dataclass
class KanjiElement:
    keb: str
    ke_inf: list[str]
    ke_pri: list[str]


@dataclass
class ReadingElement:
    reb: str
    no_kanji: bool
    re_restr: list[str]
    re_inf: list[str]
    re_pri: list[str]


@dataclass
class JmdictEntry:
    ent_seq: int
    forms: list[KanjiElement]
    readings: list[ReadingElement]
    senses: list[Sense]


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip()


def normalize_search(value: str) -> str:
    """App-consistent search normalization: NFKC + casefold + katakana -> hiragana."""
    normalized = unicodedata.normalize("NFKC", value).strip().casefold()
    return "".join(
        chr(ord(character) - 0x60)
        if "ァ" <= character <= "ヶ"
        else character
        for character in normalized
    )


def priority_rank(codes: Iterable[str]) -> int | None:
    best: int | None = None
    for code in codes:
        if code in PRIORITY_BAND1:
            score = 1
        elif code in PRIORITY_BAND2:
            score = 2
        else:
            match = PRIORITY_NF.fullmatch(code)
            if match is None:
                continue
            score = int(match.group(1))
        if best is None or score < best:
            best = score
    return best


def entity_code(expanded: str, anomalies: dict[str, int], context: str) -> str:
    """Map expat-expanded entity text back to the locked JMdict tag code."""
    name = JMDICT_ENTITY_VALUES.get(expanded)
    if name is not None:
        return name
    anomalies[context] = anomalies.get(context, 0) + 1
    return expanded


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
        raise ValueError(f"source manifestVersion must be {SOURCE_MANIFEST_VERSION}")
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
    date_pattern = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
    for source_id, source in sources.items():
        if not isinstance(source, dict):
            raise ValueError(f"source {source_id} metadata must be an object")
        for key in (
            "version", "license", "licenseURL", "attribution", "sourceURL",
            "retrievedAt", "modifications",
        ):
            if not isinstance(source.get(key), str) or not source[key].strip():
                raise ValueError(f"source {source_id} is missing {key} metadata")
        for url_key in ("sourceURL", "licenseURL"):
            if not source[url_key].startswith("https://"):
                raise ValueError(f"source {source_id} {url_key} must use HTTPS")
        if not date_pattern.fullmatch(source["retrievedAt"]):
            raise ValueError(f"source {source_id} retrievedAt must be YYYY-MM-DD")
        consumed = source.get("consumedTables")
        if not isinstance(consumed, list) or not all(
            isinstance(item, str) and item for item in consumed
        ):
            raise ValueError(f"source {source_id} consumedTables must be a list of table names")
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
                raise ValueError(f"source {source_id}/{file_id} downloadURL must use HTTPS")
    tomoshi_tables = set(sources["tomoshi"]["consumedTables"])
    if not tomoshi_tables.issubset(TOMOSHI_ALLOWED_TABLES):
        raise ValueError(
            f"tomoshi consumedTables exceed the allowlist: "
            f"{sorted(tomoshi_tables - TOMOSHI_ALLOWED_TABLES)}"
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
    reject_app_bundled_source(args.jmdict, "jmdict_e/JMdict_e")
    verify_source_file(args.jmdict, sources["jmdict_e"]["files"]["JMdict_e"], "jmdict_e/JMdict_e")
    reject_app_bundled_source(args.chinese_overlay, "tomoshi/tomoshi-dict-open.db")
    verify_source_file(
        args.chinese_overlay,
        sources["tomoshi"]["files"]["tomoshi-dict-open.db"],
        "tomoshi/tomoshi-dict-open.db",
    )


# --------------------------------------------------------------------------
# DTD gate
# --------------------------------------------------------------------------

def scan_dtd_subset(data: bytes) -> set[str]:
    """Verify the JMdict internal DTD subset against the locked entity map.

    Returns the declared entity names. Raises on anything outside the
    whitelist: external DOCTYPE identifiers, external/parameter/unparsed
    entities, unknown or rewritten entity declarations, conditional sections,
    or unknown markup declarations.
    """
    match = re.search(rb"<!DOCTYPE\s+([A-Za-z0-9_.:-]+)([^\[]*)\[", data)
    if match is None:
        raise ValueError("JMdict DTD internal subset was not found")
    root_name = match.group(1).decode("ascii", "replace")
    if root_name != "JMdict":
        raise ValueError(f"unexpected DOCTYPE root: {root_name}")
    header = match.group(2)
    if re.search(rb"SYSTEM|PUBLIC", header):
        raise ValueError("DOCTYPE must not reference an external subset")

    # Walk the internal subset declaration by declaration; stop at ']>'.
    subset_start = match.end()
    pos = subset_start
    declared_entities: set[str] = set()
    while True:
        # Skip whitespace and comments.
        ws = re.match(rb"\s+", data[pos:])
        if ws:
            pos += ws.end()
        if data.startswith(b"]>", pos):
            break
        if data.startswith(b"<!--", pos):
            end = data.find(b"-->", pos)
            if end < 0:
                raise ValueError("unterminated comment in DTD")
            pos = end + 3
            continue
        if data.startswith(b"<?", pos):
            end = data.find(b"?>", pos)
            if end < 0:
                raise ValueError("unterminated PI in DTD")
            pos = end + 2
            continue
        if not data.startswith(b"<!", pos):
            raise ValueError(f"unexpected content in DTD subset at byte {pos}")
        decl_end = data.find(b">", pos)
        if decl_end < 0:
            raise ValueError("unterminated declaration in DTD")
        decl = data[pos + 2 : decl_end].decode("utf-8", "replace")
        keyword = decl.split(None, 1)[0] if decl.split(None, 1) else ""
        if keyword == "ENTITY":
            declared_entities.add(parse_entity_decl(decl))
        elif keyword in ("ELEMENT", "ATTLIST", "NOTATION"):
            if re.search(r"SYSTEM|PUBLIC", decl):
                raise ValueError(f"external identifier in DTD {keyword} declaration")
        else:
            raise ValueError(f"forbidden DTD declaration: <{keyword or decl[:40]}>")
        pos = decl_end + 1
    return declared_entities


def jmdict_created_date(data: bytes) -> str:
    head = data[: 1024 * 1024].decode("utf-8", "replace")
    created = JMDICT_CREATED.search(head)
    if created is None:
        raise ValueError("JMdict snapshot comment (created date) was not found")
    return created.group(1)


def parse_entity_decl(decl: str) -> str:
    parts = decl.split(None, 1)
    body = parts[1].strip() if len(parts) > 1 else ""
    if body.startswith("%"):
        raise ValueError("parameter entities are not allowed in the JMdict DTD")
    match = re.fullmatch(r'([A-Za-z0-9_.:-]+)\s+(?:"([^"]*)"|\'([^\']*)\')\s*', body)
    if match is None:
        raise ValueError(f"unsupported entity declaration (external/unparsed?): <!ENTITY {body[:60]}>")
    name = match.group(1)
    value = match.group(2) if match.group(2) is not None else match.group(3)
    locked = JMDICT_ENTITIES.get(name)
    if locked is None:
        raise ValueError(f"entity '{name}' is not in the locked JMdict entity map")
    if locked != value:
        raise ValueError(
            f"entity '{name}' expansion was rewritten: {value!r} != locked {locked!r}"
        )
    return name


def check_element_text(element: ET.Element, context: str) -> str:
    text = "".join(element.itertext())
    if len(text) > MAX_ELEMENT_TEXT:
        raise ValueError(f"oversized element text at {context}")
    return text


def parse_entry(element: ET.Element, anomalies: dict[str, int]) -> JmdictEntry:
    ent_seq_el = element.find("ent_seq")
    if ent_seq_el is None or ent_seq_el.text is None:
        raise ValueError("entry is missing ent_seq")
    try:
        ent_seq = int(ent_seq_el.text.strip())
    except ValueError as error:
        raise ValueError(f"invalid ent_seq: {ent_seq_el.text!r}") from error
    context = f"entry {ent_seq}"

    forms: list[KanjiElement] = []
    for k_ele in element.findall("k_ele"):
        keb_el = k_ele.find("keb")
        if keb_el is None:
            raise ValueError(f"{context}: k_ele missing keb")
        keb = check_element_text(keb_el, context)
        ke_inf = [
            entity_code(check_element_text(inf, context), anomalies, "ke_inf")
            for inf in k_ele.findall("ke_inf")
        ]
        ke_pri = [check_element_text(pri, context) for pri in k_ele.findall("ke_pri")]
        forms.append(KanjiElement(keb=keb, ke_inf=ke_inf, ke_pri=ke_pri))

    readings: list[ReadingElement] = []
    for r_ele in element.findall("r_ele"):
        reb_el = r_ele.find("reb")
        if reb_el is None:
            raise ValueError(f"{context}: r_ele missing reb")
        reb = check_element_text(reb_el, context)
        re_inf = [
            entity_code(check_element_text(inf, context), anomalies, "re_inf")
            for inf in r_ele.findall("re_inf")
        ]
        if re_inf:
            anomalies["re_inf_elements"] = anomalies.get("re_inf_elements", 0) + len(re_inf)
        if r_ele.find("re_nokanji") is not None:
            anomalies["re_nokanji"] = anomalies.get("re_nokanji", 0) + 1
        readings.append(
            ReadingElement(
                reb=reb,
                no_kanji=r_ele.find("re_nokanji") is not None,
                re_restr=[check_element_text(r, context) for r in r_ele.findall("re_restr")],
                re_inf=re_inf,
                re_pri=[check_element_text(pri, context) for pri in r_ele.findall("re_pri")],
            )
        )
    if not readings:
        raise ValueError(f"{context}: entry has no r_ele")

    senses: list[Sense] = []
    for index, s_el in enumerate(element.findall("sense")):
        sense = Sense()
        sense.stagk = [check_element_text(t, context) for t in s_el.findall("stagk")]
        sense.stagr = [check_element_text(t, context) for t in s_el.findall("stagr")]
        sense.pos = [
            entity_code(check_element_text(p, context), anomalies, "pos")
            for p in s_el.findall("pos")
        ]
        sense.xref = [check_element_text(t, context) for t in s_el.findall("xref")]
        sense.ant = [check_element_text(t, context) for t in s_el.findall("ant")]
        sense.fields = [
            entity_code(check_element_text(t, context), anomalies, "field")
            for t in s_el.findall("field")
        ]
        sense.misc = [
            entity_code(check_element_text(t, context), anomalies, "misc")
            for t in s_el.findall("misc")
        ]
        sense.s_inf = [check_element_text(t, context) for t in s_el.findall("s_inf")]
        sense.dial = [
            entity_code(check_element_text(t, context), anomalies, "dial")
            for t in s_el.findall("dial")
        ]
        sense.lsource = [
            Lsource(
                text=check_element_text(t, context),
                language=t.attrib.get(XML_LANG, "eng"),
                ls_type=t.attrib.get("ls_type"),
                ls_wasei=t.attrib.get("ls_wasei"),
            )
            for t in s_el.findall("lsource")
        ]
        sense.glosses = [
            Gloss(
                text=check_element_text(g, context),
                language=g.attrib.get(XML_LANG, "eng"),
                g_type=g.attrib.get("g_type"),
                g_gend=g.attrib.get("g_gend"),
            )
            for g in s_el.findall("gloss")
        ]
        sense.examples = len(s_el.findall("example"))
        if sense.examples:
            anomalies["example_elements"] = anomalies.get("example_elements", 0) + sense.examples
        senses.append(sense)
    if not senses:
        raise ValueError(f"{context}: entry has no sense")

    # JMdict contract: a sense without <pos> inherits the previous sense's POS.
    for index, sense in enumerate(senses):
        if not sense.pos and index > 0:
            sense.pos = list(senses[index - 1].pos)
            sense.pos_inherited = True
            anomalies["pos_inherited"] = anomalies.get("pos_inherited", 0) + 1

    return JmdictEntry(ent_seq=ent_seq, forms=forms, readings=readings, senses=senses)


def parse_jmdict(path: Path) -> tuple[list[JmdictEntry], dict[str, Any]]:
    data = path.read_bytes()
    declared = scan_dtd_subset(data)
    created_date = jmdict_created_date(data)
    entries: list[JmdictEntry] = []
    anomalies: dict[str, int] = {}
    context = ET.iterparse(io.BytesIO(data), events=("end",))
    for _, element in context:
        if element.tag != "entry":
            continue
        entries.append(parse_entry(element, anomalies))
        element.clear()
    if not entries:
        raise ValueError("JMdict parse produced no entries")
    sequences = [entry.ent_seq for entry in entries]
    if len(set(sequences)) != len(sequences):
        raise ValueError("duplicate ent_seq values in JMdict input")
    entries.sort(key=lambda entry: entry.ent_seq)
    return entries, {
        "declaredEntities": len(declared),
        "jmdictCreated": created_date,
        "anomalies": anomalies,
    }


# --------------------------------------------------------------------------
# Chinese overlay
# --------------------------------------------------------------------------

def load_chinese_overlay(
    path: Path,
) -> tuple[dict[int, dict[str, Any]], list[str], dict[str, str], dict[str, str]]:
    """Read ONLY zh_defs (zh-CN), table_licenses and meta from Tomoshi.

    Returns (valid rows keyed by numeric entry_id, invalid entry_id strings,
    table licenses, meta). Rows whose entry_id is not numeric or whose data is
    not a JSON object are quarantined in the invalid list.
    """
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        missing = TOMOSHI_ALLOWED_TABLES - tables
        if missing:
            raise ValueError(f"tomoshi overlay is missing required tables: {sorted(missing)}")
        licenses = {
            row[0]: row[1]
            for row in connection.execute(
                "SELECT table_name, license FROM table_licenses"
            )
        }
        if licenses.get("zh_defs") != TOMOSHI_REQUIRED_LICENSE:
            raise ValueError(
                "tomoshi table_licenses must license zh_defs as "
                f"{TOMOSHI_REQUIRED_LICENSE}: {licenses.get('zh_defs')}"
            )
        meta = dict(connection.execute("SELECT key, value FROM meta"))
        for required_key in ("export_version", "exported_at"):
            if required_key not in meta:
                raise ValueError(f"tomoshi meta is missing {required_key}")
        rows: dict[int, dict[str, Any]] = {}
        invalid: list[str] = []
        for entry_id, locale, data in connection.execute(
            "SELECT entry_id, locale, data FROM zh_defs"
        ):
            if locale != TOMOSHI_OVERLAY_LOCALE:
                continue
            try:
                key = int(entry_id)
                payload = json.loads(data)
                if not isinstance(payload, dict):
                    raise ValueError("zh_defs data is not a JSON object")
            except (ValueError, TypeError):
                invalid.append(str(entry_id))
                continue
            rows[key] = payload
        return rows, sorted(invalid), licenses, meta
    finally:
        connection.close()


def sense_fingerprint(ent_seq: int, sense_order: int, sense: Sense) -> str:
    canonical = "\u001f".join(
        [
            "jmdict",
            str(ent_seq),
            str(sense_order),
            ";".join(sorted(set(sense.pos))),
            ";".join(normalize_text(g.text).casefold() for g in sense.glosses),
            ";".join(sorted(set(sense.stagk))),
            ";".join(sorted(set(sense.stagr))),
        ]
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# Schema + write
# --------------------------------------------------------------------------

def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA foreign_keys = ON;
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY NOT NULL,
            primary_form TEXT NOT NULL CHECK (length(primary_form) > 0),
            common_rank INTEGER CHECK (common_rank IS NULL OR common_rank > 0)
        );
        CREATE TABLE forms (
            id INTEGER PRIMARY KEY NOT NULL,
            entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            text TEXT NOT NULL CHECK (length(text) > 0),
            normalized_text TEXT NOT NULL,
            form_type TEXT NOT NULL DEFAULT 'standard',
            priority INTEGER
        );
        CREATE TABLE readings (
            id INTEGER PRIMARY KEY NOT NULL,
            entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            reading TEXT NOT NULL CHECK (length(reading) > 0),
            normalized_reading TEXT NOT NULL,
            no_kanji INTEGER NOT NULL DEFAULT 0 CHECK (no_kanji IN (0, 1))
        );
        CREATE TABLE reading_form_restrictions (
            reading_id INTEGER NOT NULL REFERENCES readings(id) ON DELETE CASCADE,
            form_id INTEGER NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
            PRIMARY KEY (reading_id, form_id)
        );
        CREATE TABLE senses (
            id INTEGER PRIMARY KEY NOT NULL,
            entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            sense_order INTEGER NOT NULL CHECK (sense_order >= 0),
            UNIQUE (entry_id, sense_order)
        );
        CREATE TABLE sense_form_restrictions (
            sense_id INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
            form_id INTEGER NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
            PRIMARY KEY (sense_id, form_id)
        );
        CREATE TABLE sense_reading_restrictions (
            sense_id INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
            reading_id INTEGER NOT NULL REFERENCES readings(id) ON DELETE CASCADE,
            PRIMARY KEY (sense_id, reading_id)
        );
        CREATE TABLE sense_pos (
            sense_id INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
            code TEXT NOT NULL CHECK (length(code) > 0),
            PRIMARY KEY (sense_id, code)
        );
        CREATE TABLE sense_tags (
            sense_id INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
            category TEXT NOT NULL CHECK (category IN
                ('field', 'misc', 'dialect', 'xref', 'ant', 's_inf', 'lsource', 'gloss_attr')),
            code TEXT NOT NULL CHECK (length(code) > 0),
            PRIMARY KEY (sense_id, category, code)
        );
        CREATE TABLE dictionary_sources (
            source_id TEXT PRIMARY KEY NOT NULL,
            source_name TEXT NOT NULL,
            source_version TEXT NOT NULL,
            source_url TEXT NOT NULL,
            license TEXT NOT NULL,
            license_url TEXT NOT NULL,
            retrieved_at TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            input_bytes INTEGER NOT NULL CHECK (input_bytes > 0),
            attribution TEXT NOT NULL,
            consumed_tables_json TEXT NOT NULL CHECK (json_valid(consumed_tables_json)),
            modifications TEXT NOT NULL
        );
        CREATE TABLE glosses (
            sense_id INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
            language TEXT NOT NULL CHECK (length(language) > 0),
            text TEXT NOT NULL CHECK (length(text) > 0),
            gloss_order INTEGER NOT NULL CHECK (gloss_order >= 0),
            source_id TEXT NOT NULL REFERENCES dictionary_sources(source_id),
            is_machine_generated INTEGER NOT NULL DEFAULT 0
                CHECK (is_machine_generated IN (0, 1)),
            source_fingerprint TEXT,
            UNIQUE (sense_id, gloss_order)
        );
        CREATE TABLE entry_gloss_overlays (
            entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            language TEXT NOT NULL CHECK (length(language) > 0),
            text TEXT NOT NULL CHECK (length(text) > 0),
            source_id TEXT NOT NULL REFERENCES dictionary_sources(source_id)
        );
        CREATE TABLE dictionary_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE INDEX idx_forms_normalized ON forms(normalized_text, entry_id);
        CREATE INDEX idx_forms_entry ON forms(entry_id, id);
        CREATE INDEX idx_readings_normalized ON readings(normalized_reading, entry_id);
        CREATE INDEX idx_readings_entry ON readings(entry_id, id);
        CREATE INDEX idx_sense_tags ON sense_tags(sense_id, category);
        CREATE INDEX idx_overlays_entry ON entry_gloss_overlays(entry_id, language);
        """
    )


def write_entries(
    connection: sqlite3.Connection,
    entries: list[JmdictEntry],
    zh_rows: dict[int, dict[str, Any]],
    report: dict[str, Any],
) -> dict[str, int]:
    counts = {
        "forms": 0, "readings": 0, "senses": 0, "glosses": 0,
        "senseTags": 0, "restrictions": 0, "zhGlosses": 0,
        "zhExamplesDropped": 0, "overlays": 0,
    }
    form_id = 0
    reading_id = 0
    sense_id = 0
    zh = report["chineseOverlay"]

    pending: dict[str, list] = {
        "entries": [], "forms": [], "readings": [], "reading_form_restrictions": [],
        "senses": [], "sense_pos": [], "sense_tags": [],
        "sense_form_restrictions": [], "sense_reading_restrictions": [], "glosses": [],
    }
    insert_sql = {
        "entries": "INSERT INTO entries(id, primary_form, common_rank) VALUES (?, ?, ?)",
        "forms": "INSERT INTO forms(id, entry_id, text, normalized_text, form_type,"
                 " priority) VALUES (?, ?, ?, ?, ?, ?)",
        "readings": "INSERT INTO readings(id, entry_id, reading, normalized_reading,"
                    " no_kanji) VALUES (?, ?, ?, ?, ?)",
        "reading_form_restrictions": "INSERT INTO reading_form_restrictions"
                                     "(reading_id, form_id) VALUES (?, ?)",
        "senses": "INSERT INTO senses(id, entry_id, sense_order) VALUES (?, ?, ?)",
        "sense_pos": "INSERT INTO sense_pos(sense_id, code) VALUES (?, ?)",
        "sense_tags": "INSERT INTO sense_tags(sense_id, category, code) VALUES (?, ?, ?)",
        "sense_form_restrictions": "INSERT INTO sense_form_restrictions"
                                   "(sense_id, form_id) VALUES (?, ?)",
        "sense_reading_restrictions": "INSERT INTO sense_reading_restrictions"
                                      "(sense_id, reading_id) VALUES (?, ?)",
        "glosses": "INSERT INTO glosses(sense_id, language, text, gloss_order,"
                   " source_id, is_machine_generated, source_fingerprint)"
                   " VALUES (?, ?, ?, ?, ?, ?, ?)",
    }
    # Parent tables always flush before their children.
    flush_order = (
        "entries", "forms", "readings", "reading_form_restrictions", "senses",
        "sense_pos", "sense_tags", "sense_form_restrictions",
        "sense_reading_restrictions", "glosses",
    )

    def flush() -> None:
        for name in flush_order:
            if pending[name]:
                connection.executemany(insert_sql[name], pending[name])
                pending[name].clear()

    for entry in entries:
        keb_to_form: dict[str, int] = {}
        reb_to_reading: dict[str, int] = {}
        pri_codes: list[str] = []
        primary_form = entry.forms[0].keb if entry.forms else entry.readings[0].reb

        for k_ele in entry.forms:
            form_id += 1
            keb_to_form[k_ele.keb] = form_id
            pri_codes.extend(k_ele.ke_pri)
            form_type = "+".join(sorted(set(k_ele.ke_inf))) or "standard"
            pending["forms"].append(
                (
                    form_id, entry.ent_seq, k_ele.keb, normalize_search(k_ele.keb),
                    form_type, priority_rank(k_ele.ke_pri),
                )
            )
            counts["forms"] += 1
        for r_ele in entry.readings:
            reading_id += 1
            reb_to_reading[r_ele.reb] = reading_id
            pri_codes.extend(r_ele.re_pri)
            pending["readings"].append(
                (
                    reading_id, entry.ent_seq, r_ele.reb,
                    normalize_search(r_ele.reb), 1 if r_ele.no_kanji else 0,
                )
            )
            counts["readings"] += 1
            for restr in r_ele.re_restr:
                target = keb_to_form.get(restr)
                if target is None:
                    raise ValueError(
                        f"entry {entry.ent_seq}: re_restr {restr!r} does not match any keb"
                    )
                pending["reading_form_restrictions"].append((reading_id, target))
                counts["restrictions"] += 1

        pending["entries"].append(
            (entry.ent_seq, primary_form, priority_rank(pri_codes))
        )

        zh_data = zh_rows.get(entry.ent_seq)
        zh_senses: dict[str, Any] = {}
        zh_entry_state = "none"
        if zh_data is not None:
            if not isinstance(zh_data.get("senses"), dict):
                zh_entry_state = "invalid"
            else:
                zh_senses = zh_data["senses"]
                zh_entry_state = "pending"

        aligned_keys: set[int] = set()
        invalid_keys: list[str] = []
        if zh_entry_state == "pending":
            for raw_key, payload in zh_senses.items():
                try:
                    key = int(raw_key)
                except (TypeError, ValueError):
                    invalid_keys.append(str(raw_key))
                    continue
                if not isinstance(payload, dict):
                    invalid_keys.append(str(raw_key))
                    continue
                if 0 <= key < len(entry.senses):
                    aligned_keys.add(key)
                else:
                    invalid_keys.append(str(raw_key))
            zh_entry_state = "aligned" if aligned_keys else "mismatched"

        fingerprints: dict[int, str] = {}
        for order, sense in enumerate(entry.senses):
            sense_id += 1
            pending["senses"].append((sense_id, entry.ent_seq, order))
            counts["senses"] += 1
            fingerprints[order] = sense_fingerprint(entry.ent_seq, order, sense)
            for code in sorted(set(sense.pos)):
                pending["sense_pos"].append((sense_id, code))
            for stagk in sense.stagk:
                target = keb_to_form.get(stagk)
                if target is None:
                    raise ValueError(
                        f"entry {entry.ent_seq}: stagk {stagk!r} does not match any keb"
                    )
                pending["sense_form_restrictions"].append((sense_id, target))
                counts["restrictions"] += 1
            for stagr in sense.stagr:
                target = reb_to_reading.get(stagr)
                if target is None:
                    raise ValueError(
                        f"entry {entry.ent_seq}: stagr {stagr!r} does not match any reb"
                    )
                pending["sense_reading_restrictions"].append((sense_id, target))
                counts["restrictions"] += 1
            seen_tags: set[tuple[str, str]] = set()
            for category, values in (
                ("field", sense.fields), ("misc", sense.misc),
                ("dialect", sense.dial), ("xref", sense.xref),
                ("ant", sense.ant), ("s_inf", sense.s_inf),
            ):
                for value in values:
                    if (category, value) in seen_tags:
                        continue
                    seen_tags.add((category, value))
                    pending["sense_tags"].append((sense_id, category, value))
                    counts["senseTags"] += 1
            for lsource in sense.lsource:
                code = json.dumps(
                    {
                        "text": lsource.text, "lang": lsource.language,
                        "lsType": lsource.ls_type, "wasei": lsource.ls_wasei,
                    },
                    ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                )
                if ("lsource", code) in seen_tags:
                    continue
                seen_tags.add(("lsource", code))
                pending["sense_tags"].append((sense_id, "lsource", code))
                counts["senseTags"] += 1
            gloss_order = 0
            for gloss_index, gloss in enumerate(sense.glosses):
                pending["glosses"].append(
                    (
                        sense_id, gloss.language, gloss.text, gloss_order,
                        "jmdict_e", 0, None,
                    )
                )
                gloss_order += 1
                counts["glosses"] += 1
                if gloss.g_type or gloss.g_gend:
                    pending["sense_tags"].append(
                        (
                            sense_id,
                            "gloss_attr",
                            json.dumps(
                                {
                                    "order": gloss_index, "type": gloss.g_type,
                                    "gend": gloss.g_gend,
                                },
                                ensure_ascii=False, sort_keys=True,
                                separators=(",", ":"),
                            ),
                        )
                    )
                    counts["senseTags"] += 1
            if order in aligned_keys:
                payload = zh_senses[str(order)]
                glosses = payload.get("glosses", [])
                examples = payload.get("examples", {})
                counts["zhExamplesDropped"] += len(examples)
                wrote_zh = False
                if isinstance(glosses, list):
                    for item in glosses:
                        if not isinstance(item, dict):
                            continue
                        text = normalize_text(str(item.get("text", "")))
                        if not text:
                            continue
                        pending["glosses"].append(
                            (
                                sense_id, ZH_LANGUAGE_TAG, text, gloss_order,
                                "tomoshi", 1, fingerprints[order],
                            )
                        )
                        gloss_order += 1
                        counts["zhGlosses"] += 1
                        wrote_zh = True
                if not wrote_zh:
                    zh["sensesEmptyGloss"] += 1

        if zh_entry_state == "aligned":
            zh["sensesAligned"] += len(aligned_keys)
            zh["sensesOutOfRange"] += len(invalid_keys)
            if invalid_keys or len(aligned_keys) < len(entry.senses):
                zh["entriesPartial"] += 1
            else:
                zh["entriesFull"] += 1
            for key in invalid_keys:
                if len(zh["outOfRangeSamples"]) < QA_SAMPLE_LIMIT:
                    zh["outOfRangeSamples"].append({"entry": entry.ent_seq, "key": key})
        elif zh_entry_state == "mismatched":
            zh["entriesMismatched"] += 1
            zh["sensesOutOfRange"] += len(invalid_keys)
            for key in invalid_keys:
                if len(zh["outOfRangeSamples"]) < QA_SAMPLE_LIMIT:
                    zh["outOfRangeSamples"].append({"entry": entry.ent_seq, "key": key})
            if len(zh["mismatchedSamples"]) < QA_SAMPLE_LIMIT:
                zh["mismatchedSamples"].append(
                    {"entry": entry.ent_seq, "keys": sorted(invalid_keys)}
                )
        elif zh_entry_state == "invalid":
            zh["entriesInvalidStructure"] += 1
            if len(zh["invalidSamples"]) < QA_SAMPLE_LIMIT:
                zh["invalidSamples"].append({"entry": entry.ent_seq})

        if len(pending["entries"]) >= 8000:
            flush()
    flush()
    return counts


def insert_dictionary_sources(connection: sqlite3.Connection, manifest: dict[str, Any]) -> None:
    names = {"jmdict_e": "JMdict (EDRDG)", "tomoshi": "Tomoshi Dictionary Open Data"}
    file_labels = {"jmdict_e": "JMdict_e", "tomoshi": "tomoshi-dict-open.db"}
    rows = []
    for source_id in sorted(manifest["sources"]):
        source = manifest["sources"][source_id]
        file_meta = source["files"][file_labels[source_id]]
        rows.append(
            (
                source_id,
                names[source_id],
                source["version"],
                source["sourceURL"],
                source["license"],
                source["licenseURL"],
                source["retrievedAt"],
                file_meta["sha256"],
                file_meta["bytes"],
                source["attribution"],
                json.dumps(sorted(source["consumedTables"]), separators=(",", ":")),
                source["modifications"],
            )
        )
    connection.executemany(
        "INSERT INTO dictionary_sources(source_id, source_name, source_version, source_url,"
        " license, license_url, retrieved_at, sha256, input_bytes, attribution,"
        " consumed_tables_json, modifications) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        rows,
    )


def write_notice(
    path: Path,
    manifest: dict[str, Any],
    counts: dict[str, int],
    zh: dict[str, Any],
) -> None:
    sources = manifest["sources"]
    content = f"""# Oboe Japanese Dictionary — Data Sources & Licenses

Dataset version: {manifest['datasetVersion']}
SQLite schema: v{manifest['schemaVersion']}
JMdict snapshot: {sources['jmdict_e']['version']}
Tomoshi Open Data: {sources['tomoshi']['version']}
Entries: {counts['entries']} / Forms: {counts['forms']} / Readings: {counts['readings']} / Senses: {counts['senses']}
Chinese (zh-CN) glosses overlaid: {counts['zhGlosses']} on {zh['entriesAligned']} entries

This SQLite database is a derived dataset built for offline dictionary
lookup inside Oboe. The data layer is distributed under **CC BY-SA 4.0**;
Oboe's application code license does not cover this dataset.

## Sources & Attribution

- JMdict Japanese-Multilingual Dictionary, Electronic Dictionary Research
  and Development Group (EDRDG) — headwords, readings, senses, English
  glosses, part-of-speech and restriction data. CC BY-SA 4.0.
- Tomoshi Dictionary Open Data (Y1Z), release {sources['tomoshi']['version']} —
  zh-CN gloss overlay derived from JMdict (table `zh_defs` only), consumed
  under its per-table CC BY-SA 4.0 license. The zh-CN layer is
  **machine-assisted** (LLM-aided translation reviewed upstream) and is
  flagged `is_machine_generated=1` in the database; English JMdict glosses
  are always retained. The Tomoshi name/logo are not covered by the
  license; no endorsement by Tomoshi is implied.

## Modifications

{sources['jmdict_e']['modifications']}

{sources['tomoshi']['modifications']}

Entries whose Chinese overlay could not be aligned to this JMdict snapshot
({zh['entriesMismatched']} fully mismatched, {zh['entriesMissingFromJmdict']} missing from JMdict, {zh['entriesInvalidStructure'] + zh['entriesInvalidData']} invalid rows)
were quarantined: they ship English glosses only and are listed in the build
QA report.

## Update mechanism

EDRDG requires downstream users to keep their JMdict data reasonably
current. Oboe updates this dictionary at build time only: the pinned
snapshot above is re-verified by byte size and SHA-256 on every build, the
database is regenerated, and updates ship with Oboe releases. The app never
downloads dictionary data at runtime. JMdict/EDRDG updates are checked on a
monthly cadence and re-pinned in Scripts/dictionary_sources_v1.json.

## Licenses

- https://creativecommons.org/licenses/by-sa/4.0/legalcode
- https://www.edrdg.org/edrdg/licence.html
- https://github.com/tomoshi-app/tomoshi-dict-data
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


# --------------------------------------------------------------------------
# Validation / quality gate
# --------------------------------------------------------------------------

EXPECTED_TABLES = {
    "entries", "forms", "readings", "reading_form_restrictions", "senses",
    "sense_form_restrictions", "sense_reading_restrictions", "sense_pos",
    "sense_tags", "glosses", "entry_gloss_overlays", "dictionary_sources",
    "dictionary_metadata",
}
EXPECTED_COLUMNS = {
    "entries": {"id", "primary_form", "common_rank"},
    "forms": {"id", "entry_id", "text", "normalized_text", "form_type", "priority"},
    "readings": {"id", "entry_id", "reading", "normalized_reading", "no_kanji"},
    "reading_form_restrictions": {"reading_id", "form_id"},
    "senses": {"id", "entry_id", "sense_order"},
    "sense_form_restrictions": {"sense_id", "form_id"},
    "sense_reading_restrictions": {"sense_id", "reading_id"},
    "sense_pos": {"sense_id", "code"},
    "sense_tags": {"sense_id", "category", "code"},
    "glosses": {
        "sense_id", "language", "text", "gloss_order", "source_id",
        "is_machine_generated", "source_fingerprint",
    },
    "entry_gloss_overlays": {"entry_id", "language", "text", "source_id"},
    "dictionary_sources": {
        "source_id", "source_name", "source_version", "source_url", "license",
        "license_url", "retrieved_at", "sha256", "input_bytes", "attribution",
        "consumed_tables_json", "modifications",
    },
    "dictionary_metadata": {"key", "value"},
}
REQUIRED_INDEXES = {
    "idx_forms_normalized", "idx_readings_normalized",
    "idx_forms_entry", "idx_readings_entry",
}
REQUIRED_METADATA_KEYS = {
    "schema_version", "dataset_version", "dictionary_version", "built_at",
    "generated_at", "build_version", "normalizer", "fingerprint_algorithm",
    "jmdict_source_version", "jmdict_source_sha256", "jmdict_source_bytes",
    "chinese_layer_version", "chinese_layer_sha256", "chinese_layer_bytes",
    "license_revision", "entry_count", "form_count", "reading_count",
    "sense_count", "gloss_count", "zh_gloss_count", "zh_entries_aligned",
    "source_manifest_sha256",
}


def load_qa_cases(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    if not path.is_file():
        raise FileNotFoundError(f"dictionary QA cases file was not found: {path}")
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    cases = payload.get("cases", [])
    if not isinstance(cases, list):
        raise ValueError("dictionary QA cases file has no case list")
    return [case for case in cases if case.get("reviewStatus") == "approved"]


def run_golden_checks(
    connection: sqlite3.Connection, cases: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    failures = []
    for case in cases:
        entry_id = case.get("entryId")
        row = connection.execute(
            "SELECT id FROM entries WHERE id = ?", (entry_id,)
        ).fetchone()
        if row is None:
            failures.append({"entryId": entry_id, "reason": "entry missing"})
            continue
        headword = case.get("headword")
        if headword and not connection.execute(
            "SELECT 1 FROM forms WHERE entry_id = ? AND text = ? LIMIT 1",
            (entry_id, headword),
        ).fetchone():
            failures.append({"entryId": entry_id, "reason": f"form {headword} missing"})
        reading = case.get("reading")
        if reading and not connection.execute(
            "SELECT 1 FROM readings WHERE entry_id = ? AND reading = ? LIMIT 1",
            (entry_id, reading),
        ).fetchone():
            failures.append({"entryId": entry_id, "reason": f"reading {reading} missing"})
        for code in case.get("pos", []):
            if not connection.execute(
                "SELECT 1 FROM sense_pos sp JOIN senses s ON s.id = sp.sense_id"
                " WHERE s.entry_id = ? AND sp.code = ? LIMIT 1",
                (entry_id, code),
            ).fetchone():
                failures.append({"entryId": entry_id, "reason": f"pos {code} missing"})
        if not connection.execute(
            "SELECT 1 FROM glosses g JOIN senses s ON s.id = g.sense_id"
            " WHERE s.entry_id = ? LIMIT 1",
            (entry_id,),
        ).fetchone():
            failures.append({"entryId": entry_id, "reason": "no glosses"})
    return failures


def validate_database(
    path: Path,
    notice: Path,
    qa_cases: list[dict[str, Any]] | None = None,
    required_schema_version: int | None = None,
) -> dict[str, Any]:
    if not notice.is_file() or notice.stat().st_size == 0:
        raise ValueError("NOTICE was not generated")
    notice_text = notice.read_text(encoding="utf-8")
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
                " AND name NOT LIKE 'sqlite_%'"
            )
        }
        if tables != EXPECTED_TABLES:
            raise ValueError(
                f"dictionary tables mismatch: missing={sorted(EXPECTED_TABLES - tables)}, "
                f"unexpected={sorted(tables - EXPECTED_TABLES)}"
            )
        for table, expected in EXPECTED_COLUMNS.items():
            actual = {row["name"] for row in connection.execute(f"PRAGMA table_info({table})")}
            if actual != expected:
                raise ValueError(
                    f"table {table} columns mismatch: {sorted(actual ^ expected)}"
                )
        meta = dict(connection.execute("SELECT key, value FROM dictionary_metadata"))
        missing_meta = REQUIRED_METADATA_KEYS - set(meta)
        if missing_meta:
            raise ValueError(f"dictionary metadata is incomplete: {sorted(missing_meta)}")
        try:
            schema_version = int(meta["schema_version"])
        except ValueError as error:
            raise ValueError("dictionary schema_version is not an integer") from error
        if required_schema_version is not None and schema_version != required_schema_version:
            raise ValueError(
                f"dictionary schema is v{schema_version}, expected v{required_schema_version}"
            )
        # NOTICE must describe the same artifact set as the DB metadata.
        if f"Dataset version: {meta['dataset_version']}" not in notice_text:
            raise ValueError("NOTICE dataset version does not match dictionary metadata")
        if meta["jmdict_source_version"] not in notice_text:
            raise ValueError("NOTICE does not name the JMdict snapshot version")
        if "EDRDG" not in notice_text or "CC BY-SA 4.0" not in notice_text:
            raise ValueError("NOTICE is missing required attribution language")
        index_names = {
            row["name"]
            for table in EXPECTED_TABLES
            for row in connection.execute(f"PRAGMA index_list({table})")
        }
        if not REQUIRED_INDEXES.issubset(index_names):
            raise ValueError(
                f"dictionary indexes are incomplete: {sorted(REQUIRED_INDEXES - index_names)}"
            )
        counts = {
            name: connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
            for name in (
                "entries", "forms", "readings", "senses", "glosses", "sense_tags",
            )
        }
        if counts["entries"] == 0:
            raise ValueError("dictionary has no entries")
        if connection.execute(
            "SELECT COUNT(*) - COUNT(DISTINCT id) FROM entries"
        ).fetchone()[0]:
            raise ValueError("duplicate entry ids")
        # Restriction tables must only link objects inside the same entry.
        dangling_checks = (
            (
                "reading_form_restrictions",
                "SELECT COUNT(*) FROM reading_form_restrictions r"
                " JOIN readings rd ON rd.id = r.reading_id"
                " JOIN forms f ON f.id = r.form_id"
                " WHERE rd.entry_id != f.entry_id",
            ),
            (
                "sense_form_restrictions",
                "SELECT COUNT(*) FROM sense_form_restrictions r"
                " JOIN senses s ON s.id = r.sense_id"
                " JOIN forms f ON f.id = r.form_id"
                " WHERE s.entry_id != f.entry_id",
            ),
            (
                "sense_reading_restrictions",
                "SELECT COUNT(*) FROM sense_reading_restrictions r"
                " JOIN senses s ON s.id = r.sense_id"
                " JOIN readings rd ON rd.id = r.reading_id"
                " WHERE s.entry_id != rd.entry_id",
            ),
        )
        for name, query in dangling_checks:
            bad = connection.execute(query).fetchone()[0]
            if bad:
                raise ValueError(f"{name}: {bad} cross-entry dangling relations")
        gloss_issues = connection.execute(
            "SELECT COUNT(*) FROM glosses WHERE length(trim(text)) = 0"
            " OR (language = 'zho' AND (source_id != 'tomoshi' OR is_machine_generated != 1))"
            " OR (language != 'zho' AND source_id NOT IN (SELECT source_id FROM dictionary_sources))"
        ).fetchone()[0]
        if gloss_issues:
            raise ValueError(f"{gloss_issues} gloss provenance/content violations")
        stat_tables = {
            row[0] for row in connection.execute("SELECT tbl FROM sqlite_stat1")
        }
        if not {"forms", "readings"}.issubset(stat_tables):
            raise ValueError("ANALYZE statistics are missing")
        golden_failures = run_golden_checks(connection, qa_cases or [])
        if golden_failures:
            raise ValueError(f"golden query checks failed: {golden_failures[:5]}")
        return {"counts": counts, "meta": meta}
    finally:
        connection.close()


# --------------------------------------------------------------------------
# Build pipeline
# --------------------------------------------------------------------------

def build(args: argparse.Namespace) -> dict[str, Any]:
    qa_cases = load_qa_cases(args.qa_cases)
    if args.validate_existing:
        return validate_database(args.output, args.notice, qa_cases)

    manifest = load_source_manifest(args.source_manifest)
    verify_source_inputs(args, manifest)
    entries, parse_stats = parse_jmdict(args.jmdict)
    jmdict_created = parse_stats["jmdictCreated"]
    if not manifest["sources"]["jmdict_e"]["version"].startswith(jmdict_created):
        raise ValueError(
            f"jmdict_e version '{manifest['sources']['jmdict_e']['version']}' does not match"
            f" snapshot creation date {jmdict_created}"
        )
    zh_rows, zh_invalid_ids, zh_licenses, zh_meta = load_chinese_overlay(
        args.chinese_overlay
    )

    report: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "datasetVersion": manifest["datasetVersion"],
        "buildVersion": BUILD_VERSION,
        "normalizer": NORMALIZER_VERSION,
        "fingerprintAlgorithm": FINGERPRINT_ALGORITHM,
        "sourceManifestSHA256": sha256_file(args.source_manifest),
        "jmdict": {
            "version": manifest["sources"]["jmdict_e"]["version"],
            "snapshotCreated": jmdict_created,
            "sha256": manifest["sources"]["jmdict_e"]["files"]["JMdict_e"]["sha256"],
            "bytes": manifest["sources"]["jmdict_e"]["files"]["JMdict_e"]["bytes"],
            "file": args.jmdict.name,
            "declaredEntities": parse_stats["declaredEntities"],
            "anomalies": parse_stats["anomalies"],
        },
        "tomoshi": {
            "version": manifest["sources"]["tomoshi"]["version"],
            "sha256": manifest["sources"]["tomoshi"]["files"]["tomoshi-dict-open.db"]["sha256"],
            "bytes": manifest["sources"]["tomoshi"]["files"]["tomoshi-dict-open.db"]["bytes"],
            "file": args.chinese_overlay.name,
            "exportMeta": zh_meta,
            "zhDefsLicense": zh_licenses.get("zh_defs"),
            "zhRowsTotal": len(zh_rows),
        },
        "counts": {},
        "chineseOverlay": {
            "entriesFull": 0,
            "entriesPartial": 0,
            "entriesMismatched": 0,
            "entriesInvalidStructure": 0,
            "entriesInvalidData": 0,
            "entriesMissingFromJmdict": 0,
            "sensesAligned": 0,
            "sensesOutOfRange": 0,
            "sensesEmptyGloss": 0,
            "alignmentRate": 0.0,
            "zhRowsConsumed": 0,
            "outOfRangeSamples": [],
            "mismatchedSamples": [],
            "missingEntrySamples": [],
            "invalidSamples": [],
            "invalidDataSamples": [],
        },
        "goldenChecks": {"cases": len(qa_cases)},
        "unmappedInputs": {},
    }

    # zh rows whose entry_id never appears in JMdict: quarantine, ship nothing.
    entry_ids = {entry.ent_seq for entry in entries}
    zh = report["chineseOverlay"]
    for key in sorted(zh_rows):
        if key not in entry_ids:
            zh["entriesMissingFromJmdict"] += 1
            if len(zh["missingEntrySamples"]) < QA_SAMPLE_LIMIT:
                zh["missingEntrySamples"].append({"entry": key})
    zh["entriesInvalidData"] = len(zh_invalid_ids)
    for bad_id in zh_invalid_ids[:QA_SAMPLE_LIMIT]:
        zh["invalidDataSamples"].append({"entry": bad_id})

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

    try:
        insert_dictionary_sources(output, manifest)
        counts = write_entries(output, entries, zh_rows, report)
        counts["entries"] = len(entries)
        report["counts"] = counts
        zh["zhRowsConsumed"] = zh["entriesFull"] + zh["entriesPartial"]
        zh["entriesAligned"] = zh["zhRowsConsumed"]
        referenced = zh["sensesAligned"] + zh["sensesOutOfRange"]
        zh["alignmentRate"] = (
            round(zh["sensesAligned"] / referenced, 6) if referenced else 0.0
        )
        anomalies = parse_stats["anomalies"]
        report["unmappedInputs"] = {
            "reInfReadings": anomalies.get("re_inf_elements", 0),
            "jmdictExampleElements": anomalies.get("example_elements", 0),
            "zhExampleBlocks": counts["zhExamplesDropped"],
            "note": "dropped under frozen schema v1 (no target table); see delivery notes",
        }

        metadata = {
            "schema_version": str(SCHEMA_VERSION),
            "dataset_version": manifest["datasetVersion"],
            "dictionary_version": manifest["datasetVersion"],
            "built_at": args.generated_at,
            "generated_at": args.generated_at,
            "build_version": BUILD_VERSION,
            "normalizer": NORMALIZER_VERSION,
            "fingerprint_algorithm": FINGERPRINT_ALGORITHM,
            "source_manifest_version": str(manifest["manifestVersion"]),
            "source_manifest_sha256": sha256_file(args.source_manifest),
            "jmdict_source_version": manifest["sources"]["jmdict_e"]["version"],
            "jmdict_source_sha256": manifest["sources"]["jmdict_e"]["files"]["JMdict_e"]["sha256"],
            "jmdict_source_bytes": str(manifest["sources"]["jmdict_e"]["files"]["JMdict_e"]["bytes"]),
            "jmdict_snapshot_created": jmdict_created,
            "chinese_layer_version": manifest["sources"]["tomoshi"]["version"],
            "chinese_layer_sha256": manifest["sources"]["tomoshi"]["files"]["tomoshi-dict-open.db"]["sha256"],
            "chinese_layer_bytes": str(manifest["sources"]["tomoshi"]["files"]["tomoshi-dict-open.db"]["bytes"]),
            "license_revision": "CC-BY-SA-4.0/EDRDG+Tomoshi-zh_defs",
            "entry_count": str(counts["entries"]),
            "form_count": str(counts["forms"]),
            "reading_count": str(counts["readings"]),
            "sense_count": str(counts["senses"]),
            "gloss_count": str(counts["glosses"]),
            "zh_gloss_count": str(counts["zhGlosses"]),
            "zh_entries_aligned": str(zh["zhRowsConsumed"]),
            "zh_alignment_rate": f"{zh['alignmentRate']:.6f}",
        }
        output.executemany(
            "INSERT INTO dictionary_metadata(key, value) VALUES (?, ?)",
            sorted(metadata.items()),
        )
        output.execute("ANALYZE")
        output.commit()
        output.execute("VACUUM")
        output.execute(f"PRAGMA application_id = {APPLICATION_ID}")
        output.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        output.commit()
    finally:
        failed = sys.exc_info()[0] is not None
        output.close()
        if failed and staging_path.exists():
            staging_path.unlink()

    try:
        write_notice(args.notice, manifest, counts, report["chineseOverlay"])
        args.report.parent.mkdir(parents=True, exist_ok=True)
        report["goldenChecks"]["failures"] = []
        try:
            validate_database(
                staging_path,
                args.notice,
                qa_cases,
                required_schema_version=SCHEMA_VERSION,
            )
        except Exception as error:
            report["validationError"] = str(error)
            args.report.write_text(
                json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            raise
        os.replace(staging_path, args.output)
    except Exception:
        if staging_path.exists():
            staging_path.unlink()
        raise
    report["validation"] = {"tables": len(EXPECTED_TABLES), "goldenCases": len(qa_cases)}
    report["outputBytes"] = args.output.stat().st_size
    report["outputSHA256"] = sha256_file(args.output)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jmdict", type=Path)
    parser.add_argument("--chinese-overlay", type=Path)
    parser.add_argument(
        "--source-manifest",
        type=Path,
        default=Path(__file__).with_name("dictionary_sources_v1.json"),
    )
    parser.add_argument(
        "--qa-cases",
        type=Path,
        default=Path(__file__).parent / "DictionaryData" / "dictionary_qa_cases.json",
    )
    parser.add_argument("--generated-at")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--notice", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--validate-existing", action="store_true")
    args = parser.parse_args(argv)
    if args.validate_existing:
        return args
    required = {
        "--jmdict": args.jmdict,
        "--chinese-overlay": args.chinese_overlay,
        "--generated-at": args.generated_at,
        "--report": args.report,
    }
    missing = [name for name, value in required.items() if value is None]
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
        print(f"build_dictionary.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
