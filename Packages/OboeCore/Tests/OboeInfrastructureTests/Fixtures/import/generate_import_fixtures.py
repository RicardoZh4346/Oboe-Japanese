#!/usr/bin/env python3
"""Deterministic fixture generator for the v0.7.0 S16 delimited-text parser.

Writes the small committed fixtures into this directory (default) and can emit
the non-committed 100k-row stress file to a caller-specified path:

    python3 generate_import_fixtures.py                 # write small fixtures here
    python3 generate_import_fixtures.py --out DIR       # write small fixtures to DIR
    python3 generate_import_fixtures.py --rows100k PATH # write 100k-row CSV to PATH

Seeded output is byte-for-byte reproducible.
"""

import argparse
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))


def write(path: str, data: bytes) -> None:
    with open(path, "wb") as fh:
        fh.write(data)


def small_fixtures() -> dict[str, bytes]:
    # Quoted newline inside a field; CRLF record terminators; quoted \r\n inside a field.
    quoted_newline = (
        'a,b\n'
        '"line one\nline two",second\n'
        '"carriage\r\nreturn",x\r\n'
        'last,row\n'
    ).encode("utf-8")

    # "" escape sequences inside quoted fields, quote at field start/end.
    escaped_quotes = (
        '"say ""hi""",plain\n'
        '"""leading and trailing""",2\n'
        '"a""b""c",3\n'
    ).encode("utf-8")

    # UTF-8 BOM prefix.
    bom_utf8 = b"\xef\xbb\xbf" + "head,tail\n値,1\n".encode("utf-8")

    # UTF-16LE with BOM.
    utf16le = "詞,読み,意味\n本,ほん,book\n".encode("utf-16-le")
    utf16le = b"\xff\xfe" + utf16le

    # TSV with quoted tab inside a field.
    tsv_basic = "a\tb\tc\n1\t\"x\ty\"\t3\nlast\trow\there\n".encode("utf-8")

    # Rows ending in delimiters -> trailing empty fields kept; blank line -> [""].
    trailing_empty = (
        "a,b,\n"
        "only,\n"
        ",\n"
        "x,y,z\n"
    ).encode("utf-8")

    # Final record without trailing newline.
    no_final_newline = "a,b\nc,d".encode("utf-8")

    # Multi-byte content incl. 4-byte emoji: chunk-boundary stress splits inside it.
    multibyte_split = (
        "field,value\n"
        "emoji,😀🎉日本語\n"
        "combining,é\n"  # e + combining acute — grapheme split-stress too
        "done,👍🏽\n"
    ).encode("utf-8")

    # Unclosed quote: error must carry logicalRow=2 and the record's line range.
    bad_unclosed = "ok,fine\n\"never closed,still open\n".encode("utf-8")

    return {
        "quoted-newline.csv": quoted_newline,
        "escaped-quotes.csv": escaped_quotes,
        "bom-utf8.csv": bom_utf8,
        "utf16le.csv": utf16le,
        "tsv-basic.tsv": tsv_basic,
        "trailing-empty-fields.csv": trailing_empty,
        "no-final-newline.csv": no_final_newline,
        "multibyte-split.csv": multibyte_split,
        "bad-unclosed-quote.csv": bad_unclosed,
    }


def write_rows100k(path: str) -> None:
    """Emit a deterministic 100_000-row CSV (NOT committed to the repo)."""
    rng = random.Random(0x0B0E)
    words = ["単語", "言葉", "会話", "読書", "旅行", "勉強", "音楽", "料理"]
    with open(path, "w", encoding="utf-8", newline="") as fh:
        for i in range(100_000):
            w = rng.choice(words)
            fh.write(f'{w}{i},よみ{i},"意味 {i}, with comma",tag{i}\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=HERE, help="directory for small fixtures")
    parser.add_argument("--rows100k", metavar="PATH", help="write 100k-row CSV to PATH")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    for name, data in small_fixtures().items():
        write(os.path.join(args.out, name), data)
    if args.rows100k:
        write_rows100k(args.rows100k)


if __name__ == "__main__":
    main()
