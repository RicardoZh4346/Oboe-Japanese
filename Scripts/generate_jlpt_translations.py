#!/usr/bin/env python3
"""Generate deterministic Chinese coverage for Oboe's JLPT examples.

Direct Japanese-to-Mandarin Tatoeba links are preferred. Remaining examples
are translated from their existing English text with a pinned local OPUS-MT
model. This script never downloads files and never writes into the App bundle.
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import importlib.metadata
import json
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


FORMAT_VERSION = 1
CONTROL_CHARACTERS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
CJK_CHARACTER = re.compile(r"[\u3400-\u9fff]")
LATIN_WORD = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)?")
TRAILING_ENGLISH_CLAUSE = re.compile(
    r"(?:[\s,，。.!?！？:：;；-]*)"
    r"[A-Za-z]+(?:['’][A-Za-z]+)?"
    r"(?:(?:\s+|,\s*)[A-Za-z]+(?:['’][A-Za-z]+)?){1,}[.!?]*\s*$"
)


@dataclass(frozen=True)
class Example:
    id: str
    level: str
    japanese: str
    english: str


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(path: Path, metadata: dict[str, Any], label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"required {label} file was not found: {path}")
    if path.stat().st_size != metadata["bytes"]:
        raise ValueError(f"{label} byte size does not match the pinned manifest")
    if sha256_file(path) != metadata["sha256"]:
        raise ValueError(f"{label} SHA-256 does not match the pinned manifest")


def load_model_manifest(path: Path, model_directory: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("formatVersion") != FORMAT_VERSION:
        raise ValueError(f"translation model formatVersion must be {FORMAT_VERSION}")
    model = manifest.get("model", {})
    for key in ("repository", "revision", "license", "sourceURL", "targetToken"):
        if not isinstance(model.get(key), str) or not model[key].strip():
            raise ValueError(f"translation model metadata is missing {key}")
    files = model.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("translation model file manifest is empty")
    for name, metadata in files.items():
        verify_file(model_directory / name, metadata, f"translation model/{name}")
    return manifest


def load_examples(path: Path) -> list[Example]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return [
            Example(*row)
            for row in connection.execute(
                """
                SELECT e.id, v.level, e.japanese, e.english
                FROM vocab_examples AS e
                JOIN vocab AS v ON v.id = e.vocab_id
                ORDER BY e.id
                """
            )
        ]
    finally:
        connection.close()


def read_sentences(path: Path, expected_language: str) -> dict[str, str]:
    result: dict[str, str] = {}
    with bz2.open(path, "rt", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            parts = line.rstrip("\n").split("\t", 2)
            if len(parts) != 3 or parts[1] != expected_language:
                raise ValueError(f"invalid {expected_language} sentence at line {line_number}")
            sentence_id, _, text = parts
            text = normalize_text(text)
            if not sentence_id.isdigit() or not text:
                raise ValueError(f"invalid {expected_language} sentence at line {line_number}")
            result[sentence_id] = text
    return result


def read_links(path: Path) -> dict[str, list[str]]:
    result: dict[str, list[str]] = defaultdict(list)
    with bz2.open(path, "rt", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2 or not all(part.isdigit() for part in parts):
                raise ValueError(f"invalid Tatoeba link at line {line_number}")
            result[parts[0]].append(parts[1])
    for sentence_ids in result.values():
        sentence_ids.sort(key=int)
    return result


def choose_direct_translation(
    japanese_ids: list[str],
    links: dict[str, list[str]],
    chinese_sentences: dict[str, str],
    converter: Any,
) -> tuple[str, str, str] | None:
    candidates: list[tuple[int, int, int, str, str, str]] = []
    for japanese_id in japanese_ids:
        for chinese_id in links.get(japanese_id, []):
            raw = chinese_sentences.get(chinese_id)
            if raw is None:
                continue
            simplified = normalize_text(converter.convert(raw))
            already_simplified = 0 if simplified == raw else 1
            candidates.append(
                (
                    already_simplified,
                    int(chinese_id),
                    len(simplified),
                    japanese_id,
                    chinese_id,
                    simplified,
                )
            )
    if not candidates:
        return None
    _, _, _, japanese_id, chinese_id, simplified = min(candidates)
    return japanese_id, chinese_id, simplified


def batches(values: list[str], size: int) -> Iterable[list[str]]:
    for index in range(0, len(values), size):
        yield values[index : index + size]


def translate_english(
    texts: list[str],
    model_directory: Path,
    manifest: dict[str, Any],
    batch_size: int,
) -> dict[str, str]:
    try:
        import torch
        from opencc import OpenCC
        from transformers import MarianMTModel, MarianTokenizer
    except ImportError as error:
        raise RuntimeError(
            "translation generation requires torch, transformers, sentencepiece, and opencc"
        ) from error

    runtime = manifest["runtime"]
    actual_versions = {
        "torch": torch.__version__,
        "transformers": importlib.metadata.version("transformers"),
        "sentencepiece": importlib.metadata.version("sentencepiece"),
        "opencc-python-reimplemented": importlib.metadata.version(
            "opencc-python-reimplemented"
        ),
    }
    for name, expected in runtime.items():
        if name == "python":
            continue
        actual = actual_versions[name].split("+")[0]
        if actual != expected:
            raise ValueError(f"{name} version is {actual}, expected {expected}")

    generation = manifest["generation"]
    if generation.get("device") != "cpu" or generation.get("doSample") is not False:
        raise ValueError("only deterministic CPU generation is supported")
    torch.manual_seed(0)
    torch.use_deterministic_algorithms(True)
    tokenizer = MarianTokenizer.from_pretrained(model_directory, local_files_only=True)
    model = MarianMTModel.from_pretrained(model_directory, local_files_only=True)
    model.eval()
    converter = OpenCC(generation["openCCConfig"])
    target_token = manifest["model"]["targetToken"]
    result: dict[str, str] = {}
    with torch.inference_mode():
        for index, batch in enumerate(batches(texts, batch_size), start=1):
            inputs = tokenizer(
                [f"{target_token} {text}" for text in batch],
                return_tensors="pt",
                padding=True,
                truncation=True,
                max_length=generation["maxInputTokens"],
            )
            generated = model.generate(
                **inputs,
                do_sample=False,
                num_beams=generation["numBeams"],
                max_new_tokens=generation["maxNewTokens"],
            )
            outputs = tokenizer.batch_decode(generated, skip_special_tokens=True)
            for english, translation in zip(batch, outputs):
                result[english] = normalize_text(converter.convert(translation))
            print(
                f"translated {min(index * batch_size, len(texts))}/{len(texts)}",
                file=sys.stderr,
                flush=True,
            )
    return result


def validate_translation(value: str, example_id: str) -> None:
    if not value or len(value) > 500:
        raise ValueError(f"translation length is invalid for {example_id}")
    if CONTROL_CHARACTERS.search(value):
        raise ValueError(f"translation contains control characters for {example_id}")
    if not CJK_CHARACTER.search(value):
        raise ValueError(f"translation has no CJK character for {example_id}: {value}")


def sanitize_model_translation(value: str) -> str:
    """Remove a known Marian decoding artifact: a trailing English restatement."""
    normalized = normalize_text(value)
    if CJK_CHARACTER.search(normalized):
        without_english = TRAILING_ENGLISH_CLAUSE.sub("", normalized)
        if without_english != normalized:
            normalized = without_english.rstrip(" ,，。.!?！？:：;；-")
    return normalize_text(normalized)


def load_reusable_model_translations(
    path: Path | None,
    manifest: dict[str, Any],
) -> dict[str, str]:
    if path is None:
        return {}
    reusable: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        metadata = json.loads(next(handle))
        if (
            metadata.get("modelRevision") != manifest["model"]["revision"]
            or metadata.get("modelWeightsSHA256")
            != manifest["model"]["files"]["pytorch_model.bin"]["sha256"]
            or {
                key: value
                for key, value in metadata.get("generation", {}).items()
                if key != "stripTrailingEnglishClause"
            }
            != {
                key: value
                for key, value in manifest["generation"].items()
                if key != "stripTrailingEnglishClause"
            }
        ):
            raise ValueError("reusable coverage uses different model inputs")
        for line in handle:
            record = json.loads(line)
            if record.get("translationSource") == "opus_mt_en_zh":
                reusable[record["english"]] = record["translationZh"]
    return reusable


def load_review_overrides(path: Path) -> tuple[dict[str, dict[str, str]], str]:
    """Load human-reviewed corrections and bind them to their source sentences."""
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    if payload.get("formatVersion") != FORMAT_VERSION:
        raise ValueError(f"review override formatVersion must be {FORMAT_VERSION}")
    reviews = payload.get("reviews")
    if not isinstance(reviews, list):
        raise ValueError("review overrides must contain a reviews array")
    required_keys = {
        "exampleID", "japanese", "english", "translationZh", "reason",
        "replacesSource",
    }
    result: dict[str, dict[str, str]] = {}
    for index, review in enumerate(reviews):
        if not isinstance(review, dict) or set(review) != required_keys:
            raise ValueError(f"review override {index} has invalid keys")
        example_id = review["exampleID"]
        if not isinstance(example_id, str) or not example_id or example_id in result:
            raise ValueError(f"review override {index} has a duplicate or invalid exampleID")
        if review["replacesSource"] != "opus_mt_en_zh":
            raise ValueError(f"review override {example_id} must replace opus_mt_en_zh")
        if not normalize_text(review["reason"]):
            raise ValueError(f"review override {example_id} has no reason")
        validate_translation(normalize_text(review["translationZh"]), example_id)
        result[example_id] = review
    return result, sha256_file(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jlpt", type=Path, required=True)
    parser.add_argument("--tatoeba-jpn", type=Path, required=True)
    parser.add_argument("--tatoeba-cmn", type=Path, required=True)
    parser.add_argument("--tatoeba-links", type=Path, required=True)
    parser.add_argument("--tatoeba-eng", type=Path, required=True)
    parser.add_argument("--tatoeba-eng-cmn-links", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument(
        "--model-manifest",
        type=Path,
        default=Path(__file__).with_name("jlpt_translation_model_v1.json"),
    )
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--reuse-coverage", type=Path)
    parser.add_argument("--review-overrides", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.batch_size < 1 or args.batch_size > 128:
        parser.error("--batch-size must be between 1 and 128")

    try:
        from opencc import OpenCC
    except ImportError as error:
        raise RuntimeError("translation generation requires opencc") from error

    manifest = load_model_manifest(args.model_manifest, args.model)
    review_overrides, review_overrides_sha256 = load_review_overrides(
        args.review_overrides
    )
    supplemental = manifest["tatoebaSupplement"]["files"]
    verify_file(
        args.tatoeba_eng,
        supplemental["eng_sentences.tsv.bz2"],
        "Tatoeba English sentences",
    )
    verify_file(
        args.tatoeba_eng_cmn_links,
        supplemental["eng-cmn_links.tsv.bz2"],
        "Tatoeba English-Chinese links",
    )
    examples = load_examples(args.jlpt)
    japanese_sentences = read_sentences(args.tatoeba_jpn, "jpn")
    chinese_sentences = read_sentences(args.tatoeba_cmn, "cmn")
    links = read_links(args.tatoeba_links)
    english_sentences = read_sentences(args.tatoeba_eng, "eng")
    english_links = read_links(args.tatoeba_eng_cmn_links)
    japanese_ids_by_text: dict[str, list[str]] = defaultdict(list)
    for sentence_id, text in japanese_sentences.items():
        japanese_ids_by_text[text].append(sentence_id)
    for sentence_ids in japanese_ids_by_text.values():
        sentence_ids.sort(key=int)
    english_ids_by_text: dict[str, list[str]] = defaultdict(list)
    for sentence_id, text in english_sentences.items():
        english_ids_by_text[text].append(sentence_id)
    for sentence_ids in english_ids_by_text.values():
        sentence_ids.sort(key=int)

    converter = OpenCC(manifest["generation"]["openCCConfig"])
    direct: dict[str, tuple[str, str, str]] = {}
    english_pivot: dict[str, tuple[str, str, str]] = {}
    model_english: set[str] = set()
    generation_needed: set[str] = set()
    source_japanese_id: dict[str, str] = {}
    for example in examples:
        ids = japanese_ids_by_text.get(normalize_text(example.japanese), [])
        if not ids:
            raise ValueError(f"example does not match the pinned Japanese dump: {example.id}")
        source_japanese_id[example.id] = ids[0]
        selected = choose_direct_translation(ids, links, chinese_sentences, converter)
        if selected is not None:
            direct[example.id] = selected
        else:
            english_ids = english_ids_by_text.get(normalize_text(example.english), [])
            selected = choose_direct_translation(
                english_ids, english_links, chinese_sentences, converter
            )
            if selected is not None:
                english_pivot[example.id] = selected
            else:
                model_english.add(example.english)
                if example.id not in review_overrides:
                    generation_needed.add(example.english)

    unknown_review_ids = set(review_overrides) - {example.id for example in examples}
    if unknown_review_ids:
        raise ValueError(f"review overrides contain unknown IDs: {sorted(unknown_review_ids)}")
    reusable = load_reusable_model_translations(args.reuse_coverage, manifest)
    generated = {
        english: reusable[english]
        for english in sorted(generation_needed)
        if english in reusable
    }
    missing_generation = sorted(generation_needed - set(generated))
    generated.update(
        translate_english(missing_generation, args.model, manifest, args.batch_size)
    )
    model = manifest["model"]
    metadata = {
        "type": "meta",
        "formatVersion": FORMAT_VERSION,
        "generatedAt": args.generated_at,
        "exampleCount": len(examples),
        "directCount": len(direct),
        "englishPivotCount": len(english_pivot),
        "generatedCount": len(examples) - len(direct) - len(english_pivot),
        "reusedUniqueGeneratedCount": len(model_english) - len(missing_generation),
        "modelRepository": model["repository"],
        "modelRevision": model["revision"],
        "modelWeightsSHA256": model["files"]["pytorch_model.bin"]["sha256"],
        "modelManifestSHA256": sha256_file(args.model_manifest),
        "reviewOverrideCount": len(review_overrides),
        "reviewOverridesSHA256": review_overrides_sha256,
        "generation": manifest["generation"],
    }
    records: list[dict[str, Any]] = []
    source_counts: Counter[str] = Counter()
    for example in examples:
        review = review_overrides.get(example.id)
        if example.id in direct:
            japanese_id, chinese_id, translation = direct[example.id]
            source = "tatoeba_direct"
            source_ref = f"tatoeba:cmn:{chinese_id}"
            sentence_id = japanese_id
        elif example.id in english_pivot:
            english_id, chinese_id, translation = english_pivot[example.id]
            source = "tatoeba_english_pivot"
            source_ref = f"tatoeba:eng:{english_id}:cmn:{chinese_id}"
            sentence_id = source_japanese_id[example.id]
        else:
            translation = (
                ""
                if review is not None
                else sanitize_model_translation(generated[example.english])
            )
            source = "opus_mt_en_zh"
            source_ref = (
                f"huggingface:{model['repository']}@{model['revision']}:"
                + hashlib.sha256(example.english.encode("utf-8")).hexdigest()
            )
            sentence_id = source_japanese_id[example.id]
        if review is not None:
            if source != review["replacesSource"]:
                raise ValueError(
                    f"review override source changed for {example.id}: {source}"
                )
            if (
                review["japanese"] != example.japanese
                or review["english"] != example.english
            ):
                raise ValueError(f"review override source text changed for {example.id}")
            translation = normalize_text(review["translationZh"])
            source = "manual_review"
            source_ref = (
                f"oboe:translation-review:{review_overrides_sha256}:{example.id}"
            )
        validate_translation(translation, example.id)
        source_counts[source] += 1
        records.append(
            {
                "type": "translation",
                "exampleID": example.id,
                "level": example.level,
                "japanese": example.japanese,
                "english": example.english,
                "translationZh": translation,
                "sourceSentenceID": sentence_id,
                "translationSource": source,
                "translationSourceRef": source_ref,
                "status": (
                    "reviewed"
                    if source == "manual_review"
                    else "generated" if source == "opus_mt_en_zh" else "direct"
                ),
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(metadata, ensure_ascii=False, sort_keys=True) + "\n")
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    risky_patterns = re.compile(
        r"\b(not|never|no|without|before|after|more|less|first|last|\d+)\b",
        re.IGNORECASE,
    )
    risky = [record for record in records if risky_patterns.search(record["english"])]
    risky.sort(key=lambda record: hashlib.sha256(record["exampleID"].encode()).hexdigest())
    stratified_samples: dict[str, list[dict[str, Any]]] = {}
    for level in ("N5", "N4", "N3", "N2", "N1"):
        candidates = [record for record in records if record["level"] == level]
        candidates.sort(
            key=lambda record: hashlib.sha256(
                ("stratified:" + record["exampleID"]).encode()
            ).hexdigest()
        )
        stratified_samples[level] = candidates[:20]
    by_level = Counter(record["level"] for record in records)
    latin_token_candidates = []
    for record in records:
        tokens = LATIN_WORD.findall(record["translationZh"])
        if len(tokens) >= 2 or any(len(token) >= 8 for token in tokens):
            latin_token_candidates.append(record)
    report = {
        **metadata,
        "type": "qualityReport",
        "outputSHA256": sha256_file(args.output),
        "sourceCounts": dict(sorted(source_counts.items())),
        "byLevel": dict(sorted(by_level.items())),
        "uniqueJapanese": len({record["japanese"] for record in records}),
        "uniqueEnglishGenerated": len(model_english),
        "nonEmptyCoverage": sum(bool(record["translationZh"]) for record in records),
        "highRiskCount": len(risky),
        "highRiskSamples": risky[:100],
        "stratifiedSamples": stratified_samples,
        "latinTokenCandidateCount": len(latin_token_candidates),
        "latinTokenCandidates": latin_token_candidates,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
