#!/usr/bin/env python3
"""Validate release assets before they are published (S26 pipeline gate).

Performs three families of checks, each logged as ``[ok]``/``[FAIL]``:

* IPA — file exists and is non-empty, opens as a zip, every member passes
  its CRC (``ZipFile.testzip``), exactly one ``Payload/<App>.app`` bundle
  exists, its Info.plist parses and carries bundle ID / version / build
  strings, all expected ``PlugIns/*.appex`` extensions are present, and
  every ``--expect-*`` assertion matches. ``--tag vX.Y.Z`` asserts the
  plist version equals the tag's version.
* SHA256SUMS — ``shasum -a 256`` compatible ``<hex>  <name>`` lines; the
  IPA's basename must be listed with the digest actually computed for the
  file passed via ``--ipa``. Other listed files are re-hashed when they
  exist next to the sums file (missing ones are reported as notes: release
  assets legitimately live elsewhere, e.g. GitHub Releases vs Pages).
* Source JSON (optional) — full AltSource schema validation reusing the
  S25 generator's ``validate_source``, then consistency: the app entry for
  the IPA's bundle ID must contain a ``(version, buildVersion)`` entry
  whose ``sha256``/``size``/``downloadURL`` match the IPA. With
  ``--require-source-entry`` the entry must exist; without it an absent
  entry is fine *unless* a conflicting or newer build is already
  published (same buildVersion under a different version, or a newer
  buildVersion entirely — i.e. the pipeline run is stale and must not be
  allowed to degrade the published source).

Exit code: 0 when every check passes, 1 when any check fails, 2 for usage
errors. This is a pure gate — it uploads nothing and mutates nothing.

Typical usage (mirrors .github/workflows/release.yml):

    python3 Scripts/validate_release_assets.py \
        --ipa dist/Oboe-v0.7.0.ipa --tag v0.7.0 \
        --expect-build-version 60 --expect-bundle-id org.example.Oboe \
        --sums dist/SHA256SUMS \
        --source staging/source.json --require-source-entry \
        --expect-download-url https://github.com/RicardoZh4346/Oboe-Japanese/releases/download/v0.7.0/Oboe-v0.7.0.ipa
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import zipfile
from pathlib import Path
from typing import Any


# The schema rules live in the S25 generator; import it the same way the
# test-suite does so the validator can never drift from the generator.
_GENERATOR_PATH = Path(__file__).resolve().parent / "generate_sidestore_source.py"


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        "generate_sidestore_source", _GENERATOR_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load S25 generator: {_GENERATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


try:
    gss = _load_generator()
    _GENERATOR_ERROR: Exception | None = None
except Exception as error:  # pragma: no cover - defensive
    gss = None
    _GENERATOR_ERROR = error


TAG_RE = re.compile(r"^v(?P<version>[0-9]+\.[0-9]+\.[0-9]+)$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
# `shasum -a 256` emits "<hex>  <name>" (text mode) or "<hex> *<name>"
# (binary mode); the S25 generator writes the two-space text form.
SUMS_LINE_RE = re.compile(r"^(?P<digest>[0-9a-f]{64}) (?P<mode>[ *])(?P<name>.+)$")

# The share extension is required inside every Oboe IPA; pass
# --expect-appex to replace this default with an explicit set.
DEFAULT_EXPECTED_APPEX = ["OboeShareExtension.appex"]


class Report:
    """Collects check outcomes; every check logs exactly one line."""

    def __init__(self) -> None:
        self.checks = 0
        self.errors = 0

    def ok(self, message: str) -> None:
        self.checks += 1
        print(f"[ok] {message}")

    def fail(self, message: str) -> None:
        self.checks += 1
        self.errors += 1
        print(f"[FAIL] {message}")

    def note(self, message: str) -> None:
        print(f"[..] {message}")

    def compare(self, label: str, expected: Any, actual: Any) -> None:
        """Record a check only when an expectation was supplied."""
        if expected is None:
            return
        if expected == actual:
            self.ok(f"{label}: {actual}")
        else:
            self.fail(f"{label}: expected {expected!r}, actual {actual!r}")


def inspect_ipa(
    ipa_path: Path, expected_appex: list[str], report: Report
) -> dict[str, Any] | None:
    """Zip-integrity, single-app and appex checks; returns plist info."""
    if not ipa_path.is_file():
        report.fail(f"IPA file not found: {ipa_path}")
        return None
    size = ipa_path.stat().st_size
    if size <= 0:
        report.fail(f"IPA is empty (size 0): {ipa_path}")
        return None
    report.ok(f"IPA exists: {ipa_path} ({size} bytes)")

    try:
        archive = zipfile.ZipFile(ipa_path)
    except zipfile.BadZipFile as error:
        report.fail(f"IPA is not a readable zip archive: {error}")
        return None

    appex_plists: dict[str, dict[str, Any]] = {}
    with archive:
        try:
            bad_member = archive.testzip()
        except Exception as error:
            report.fail(f"IPA zip integrity check raised: {error}")
            return None
        if bad_member is not None:
            report.fail(f"IPA member fails CRC check: {bad_member}")
            return None
        report.ok("IPA zip integrity: all member CRCs verified")

        names = archive.namelist()
        main_members = sorted(
            n for n in names if gss.MAIN_INFO_PLIST_RE.match(n)
        )
        if not main_members:
            report.fail("IPA contains no Payload/<App>.app/Info.plist")
            return None
        if len(main_members) > 1:
            report.fail(
                f"IPA contains multiple top-level .app bundles: {main_members}"
            )
            return None
        plist_member = main_members[0]
        try:
            plist = gss.read_plist_member(archive, plist_member)
        except gss.SourceError as error:
            report.fail(str(error))
            return None
        app_dir = plist_member.split("/")[1]
        report.ok(f"main app bundle plist: {plist_member}")

        appex_re = re.compile(
            r"^Payload/"
            + re.escape(app_dir)
            + r"/PlugIns/(?P<appex>[^/]+\.appex)/Info\.plist$"
        )
        found_appex = sorted(
            match.group("appex")
            for match in (appex_re.match(n) for n in names)
            if match is not None
        )
        for appex in expected_appex:
            if appex in found_appex:
                report.ok(f"expected appex present: PlugIns/{appex}")
                member = f"Payload/{app_dir}/PlugIns/{appex}/Info.plist"
                try:
                    appex_plists[appex] = gss.read_plist_member(archive, member)
                except gss.SourceError as error:
                    report.fail(str(error))
            else:
                report.fail(
                    f"expected appex missing: PlugIns/{appex} "
                    f"(found: {found_appex or 'none'})"
                )

    info: dict[str, Any] = {
        "size": size,
        "sha256": gss.sha256_file(ipa_path),
        "plist": plist,
        "appex_plists": appex_plists,
        "bundle_id": plist.get("CFBundleIdentifier"),
        "version": plist.get("CFBundleShortVersionString"),
        "build_version": plist.get("CFBundleVersion"),
    }
    for label, key in (
        ("CFBundleIdentifier", "bundle_id"),
        ("CFBundleShortVersionString", "version"),
        ("CFBundleVersion", "build_version"),
    ):
        value = info[key]
        if isinstance(value, str) and value:
            report.ok(f"{label}: {value}")
        else:
            report.fail(f"Info.plist is missing string key {label}")
            info[key] = None
    if info["build_version"] is not None:
        try:
            gss.build_version_sort_key(info["build_version"])
        except gss.SourceError as error:
            report.fail(f"CFBundleVersion is not numeric: {error}")
    return info


def check_appex_bundle_ids(info: dict[str, Any], report: Report) -> None:
    """Every extension's bundle ID must nest under the app's bundle ID."""
    bundle_id = info.get("bundle_id")
    if not bundle_id:
        return
    for appex, plist in info["appex_plists"].items():
        appex_id = plist.get("CFBundleIdentifier")
        if isinstance(appex_id, str) and appex_id.startswith(bundle_id + "."):
            report.ok(f"{appex} bundle ID nested under app: {appex_id}")
        else:
            report.fail(
                f"{appex} CFBundleIdentifier {appex_id!r} is not nested "
                f"under {bundle_id}"
            )


def check_sums(
    sums_path: Path, ipa_path: Path, ipa_digest: str, report: Report
) -> None:
    if not sums_path.is_file():
        report.fail(f"SHA256SUMS file not found: {sums_path}")
        return
    entries: list[tuple[str, str]] = []
    for lineno, raw in enumerate(
        sums_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw.strip():
            continue
        match = SUMS_LINE_RE.match(raw)
        if match is None:
            report.fail(f"{sums_path.name}:{lineno}: malformed line: {raw!r}")
            continue
        entries.append((match.group("digest"), match.group("name").strip()))
    if not entries:
        report.fail(f"{sums_path.name}: no checksum entries")
        return

    ipa_entry: str | None = None
    for digest, name in entries:
        if name == ipa_path.name:
            ipa_entry = digest
        candidate = sums_path.parent / name
        if candidate.is_file():
            actual = gss.sha256_file(candidate)
            if actual == digest:
                report.ok(f"{name}: sha256 verified ({digest[:12]}…)")
            else:
                report.fail(
                    f"{name}: sha256 mismatch — sums lists {digest}, "
                    f"file hashes to {actual}"
                )
        elif name != ipa_path.name:
            report.note(
                f"{name}: listed in sums but not next to it; "
                "cannot re-hash (release asset not staged here)"
            )
        if name == ipa_path.name and not candidate.is_file():
            report.note(
                f"{name}: verified against the --ipa file rather than "
                "a colocated copy"
            )

    if ipa_entry is None:
        report.fail(
            f"{sums_path.name} does not list the IPA {ipa_path.name}"
        )
    elif ipa_entry != ipa_digest:
        report.fail(
            f"{sums_path.name} lists {ipa_path.name} as {ipa_entry} "
            f"but the IPA hashes to {ipa_digest}"
        )
    else:
        report.ok(f"{sums_path.name} entry matches IPA sha256")


def check_source(
    source_path: Path,
    info: dict[str, Any],
    require_entry: bool,
    expect_download_url: str | None,
    report: Report,
) -> None:
    if not source_path.is_file():
        report.fail(f"source JSON not found: {source_path}")
        return
    try:
        source = json.loads(source_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        report.fail(f"source JSON is not valid JSON: {error}")
        return
    try:
        gss.validate_source(source)
    except gss.SourceError as error:
        report.fail(f"source fails AltSource schema validation: {error}")
        return
    report.ok("source passes AltSource schema validation (S25 validate_source)")

    bundle_id = info["bundle_id"]
    version = info["version"]
    build_version = info["build_version"]
    if bundle_id is None or version is None or build_version is None:
        report.note(
            "IPA identity incomplete; skipping source entry checks"
        )
        return

    app = next(
        (
            entry
            for entry in source["apps"]
            if isinstance(entry, dict)
            and entry.get("bundleIdentifier") == bundle_id
        ),
        None,
    )
    if app is None:
        if require_entry:
            report.fail(f"source has no apps[] entry for {bundle_id}")
        else:
            report.note(f"source has no apps[] entry for {bundle_id} yet")
        return

    versions = app["versions"]
    entry = next(
        (
            item
            for item in versions
            if item.get("version") == version
            and item.get("buildVersion") == build_version
        ),
        None,
    )
    if entry is None:
        conflict = next(
            (
                item
                for item in versions
                if item.get("buildVersion") == build_version
            ),
            None,
        )
        if conflict is not None:
            report.fail(
                f"buildVersion {build_version} is already published as "
                f"version {conflict.get('version')!r} — same-tag/same-build "
                "content changed"
            )
            return
        newest = max(
            versions, key=lambda item: gss.build_version_sort_key(item["buildVersion"])
        )
        if gss.build_version_sort_key(
            build_version
        ) < gss.build_version_sort_key(newest["buildVersion"]):
            report.fail(
                f"source already publishes newer build "
                f"{newest['version']} (build {newest['buildVersion']}); "
                f"this IPA is {version} (build {build_version}) — "
                "stale run must not downgrade the source"
            )
            return
        if require_entry:
            report.fail(
                f"source is missing the entry for {version} "
                f"(build {build_version})"
            )
        else:
            report.note(
                f"source has no entry for {version} (build {build_version}) yet"
            )
        return

    report.ok(f"source contains entry for {version} (build {build_version})")
    report.compare("source entry sha256", info["sha256"], entry.get("sha256"))
    report.compare("source entry size", info["size"], entry.get("size"))
    download_url = entry.get("downloadURL")
    if expect_download_url is not None:
        report.compare("source entry downloadURL", expect_download_url, download_url)
    else:
        try:
            gss.validate_url(download_url, "versions[].downloadURL")
            report.ok(f"source entry downloadURL is a valid https URL")
        except gss.SourceError as error:
            report.fail(str(error))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, help="release .ipa to validate")
    parser.add_argument(
        "--tag",
        help="release tag like v0.7.0; asserts CFBundleShortVersionString",
    )
    parser.add_argument("--expect-version", help="expected CFBundleShortVersionString")
    parser.add_argument("--expect-build-version", help="expected CFBundleVersion")
    parser.add_argument("--expect-bundle-id", help="expected CFBundleIdentifier")
    parser.add_argument("--expect-sha256", help="expected IPA SHA-256 hex digest")
    parser.add_argument("--expect-size", type=int, help="expected IPA byte size")
    parser.add_argument(
        "--expect-appex",
        action="append",
        metavar="NAME.appex",
        help=(
            "appex that must exist under PlugIns/; repeatable. When omitted, "
            f"defaults to {DEFAULT_EXPECTED_APPEX}"
        ),
    )
    parser.add_argument(
        "--sums", help="SHA256SUMS file to verify against the IPA"
    )
    parser.add_argument(
        "--source", help="source.json to schema-check and compare with the IPA"
    )
    parser.add_argument(
        "--require-source-entry",
        action="store_true",
        help="fail unless the source already contains this version's entry",
    )
    parser.add_argument(
        "--expect-download-url",
        help="expected versions[].downloadURL for this release",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if gss is None:
        print(
            f"validate_release_assets.py: cannot load the S25 generator "
            f"{_GENERATOR_PATH}: {_GENERATOR_ERROR}",
            file=sys.stderr,
        )
        return 2

    report = Report()

    tag_version: str | None = None
    if args.tag is not None:
        match = TAG_RE.match(args.tag)
        if match is None:
            print(
                f"validate_release_assets.py: --tag must look like vX.Y.Z, "
                f"got {args.tag!r}",
                file=sys.stderr,
            )
            return 2
        tag_version = match.group("version")
        report.ok(f"tag {args.tag} expects version {tag_version}")
    if args.expect_sha256 is not None and not SHA256_RE.match(args.expect_sha256):
        print(
            f"validate_release_assets.py: --expect-sha256 must be 64 hex "
            f"chars, got {args.expect_sha256!r}",
            file=sys.stderr,
        )
        return 2
    if args.tag is not None and args.expect_version is not None:
        if args.expect_version != tag_version:
            report.fail(
                f"--expect-version {args.expect_version!r} disagrees with "
                f"--tag {args.tag!r} (version {tag_version})"
            )
        else:
            report.ok(f"--expect-version matches tag {args.tag}")
    if tag_version is None and args.expect_version is None:
        print(
            "validate_release_assets.py: either --tag or --expect-version "
            "is required (version must be pinned to the release)",
            file=sys.stderr,
        )
        return 2
    expect_version = args.expect_version or tag_version

    ipa_path = Path(args.ipa)
    info = inspect_ipa(
        ipa_path, args.expect_appex or DEFAULT_EXPECTED_APPEX, report
    )
    if info is None:
        print(
            f"validate_release_assets.py: {report.errors} error(s) in "
            f"{report.checks} checks"
        )
        return 1

    report.compare(
        "CFBundleIdentifier", args.expect_bundle_id, info["bundle_id"]
    )
    report.compare("CFBundleShortVersionString", expect_version, info["version"])
    report.compare(
        "CFBundleVersion", args.expect_build_version, info["build_version"]
    )
    report.compare(
        "IPA sha256",
        args.expect_sha256.lower() if args.expect_sha256 else None,
        info["sha256"],
    )
    report.compare("IPA size", args.expect_size, info["size"])
    check_appex_bundle_ids(info, report)

    if args.sums is not None:
        check_sums(Path(args.sums), ipa_path, info["sha256"], report)
    if args.source is not None:
        check_source(
            Path(args.source),
            info,
            args.require_source_entry,
            args.expect_download_url,
            report,
        )

    if report.errors:
        print(
            f"validate_release_assets.py: {report.errors} error(s) in "
            f"{report.checks} checks"
        )
        return 1
    print(f"validate_release_assets.py: all {report.checks} checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
