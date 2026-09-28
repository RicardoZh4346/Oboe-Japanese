from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "generate_sidestore_source.py"
SPEC = importlib.util.spec_from_file_location("generate_sidestore_source", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
gss = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gss
SPEC.loader.exec_module(gss)


BUNDLE_ID = "org.example.Oboe"
DOWNLOAD_URL = "https://github.com/RicardoZh4346/Oboe-Japanese/releases/download/v0.7.0/Oboe-v0.7.0.ipa"


def make_ipa(
    path: Path,
    *,
    bundle_id: str = BUNDLE_ID,
    version: str = "0.7.0",
    build: str = "60",
    min_os: str = "17.0",
    privacy: dict | None = None,
    appex: dict[str, dict] | None = None,
    extra_top_app: bool = False,
    payload: bytes = b"fake-oboe-binary",
) -> Path:
    plist = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": min_os,
        "CFBundleExecutable": "Oboe",
    }
    if privacy:
        plist.update(privacy)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/Oboe.app/Oboe", payload)
        archive.writestr("Payload/Oboe.app/Info.plist", plistlib.dumps(plist))
        for name, extra_plist in (appex or {}).items():
            archive.writestr(
                f"Payload/Oboe.app/PlugIns/{name}/Info.plist",
                plistlib.dumps(extra_plist),
            )
        if extra_top_app:
            archive.writestr(
                "Payload/Other.app/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "org.example.Other",
                        "CFBundleShortVersionString": "1.0",
                        "CFBundleVersion": "1",
                    }
                ),
            )
    return path


def metadata_dict(**app_overrides) -> dict:
    app = {
        "name": "Oboe",
        "bundleIdentifier": BUNDLE_ID,
        "developerName": "RicardoZh4346",
        "localizedDescription": "iOS 日语学习应用",
        "iconURL": "https://example.com/assets/AppIcon.png",
        "tintColor": "#2563EB",
        "category": "other",
        "screenshots": [
            "https://example.com/assets/shot1.png",
            {"imageURL": "https://example.com/assets/shot2.png", "alt": "Reader"},
        ],
    }
    app.update(app_overrides)
    return {
        "source": {
            "name": "Oboe Sideloading Source",
            "identifier": "org.example.Oboe.sidestore-source",
            "subtitle": "test source",
            "iconURL": "https://example.com/assets/AppIcon.png",
            "website": "https://example.com/",
            "tintColor": "#2563EB",
        },
        "app": app,
    }


def write_metadata(directory: Path, **app_overrides) -> Path:
    path = directory / "metadata.json"
    path.write_text(
        json.dumps(metadata_dict(**app_overrides), ensure_ascii=False),
        encoding="utf-8",
    )
    return path


def base_argv(directory: Path, ipa: Path, metadata: Path) -> list[str]:
    return [
        "--ipa",
        str(ipa),
        "--download-url",
        DOWNLOAD_URL,
        "--metadata",
        str(metadata),
        "--date",
        "2026-09-27",
        "--dry-run",
    ]


def run_cli(argv: list[str]) -> tuple[int, str, str]:
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        code = gss.main(argv)
    return code, stdout.getvalue(), stderr.getvalue()


def run_generate(directory: Path, ipa: Path, extra_argv: list[str] | None = None,
                 metadata: Path | None = None) -> dict:
    metadata = metadata or write_metadata(directory)
    argv = base_argv(directory, ipa, metadata)
    argv.extend(extra_argv or [])
    return gss.generate(gss.parse_args(argv))


def version_entry(
    version: str = "0.6.0",
    build: str = "50",
    sha256: str = "a" * 64,
    size: int = 10_000_000,
) -> dict:
    return {
        "version": version,
        "buildVersion": build,
        "date": "2026-09-01",
        "downloadURL": f"https://example.com/Oboe-v{version}.ipa",
        "size": size,
        "sha256": sha256,
        "minOSVersion": "17.0",
    }


def existing_source(versions: list[dict]) -> dict:
    app = dict(metadata_dict()["app"])
    app["versions"] = versions
    app["appPermissions"] = {
        "entitlements": ["com.apple.security.application-groups"],
        "privacy": {},
    }
    return {
        "name": "Oboe Sideloading Source",
        "identifier": "org.example.Oboe.sidestore-source",
        "apps": [app],
        "news": [],
    }


def write_source(directory: Path, source: dict) -> Path:
    path = directory / "source.json"
    path.write_text(json.dumps(source, ensure_ascii=False), encoding="utf-8")
    return path


def write_entitlements(path: Path, keys: list[str]) -> Path:
    path.write_bytes(plistlib.dumps({key: True for key in keys}))
    return path


class SchemaGenerationTests(unittest.TestCase):
    def test_generated_source_matches_altsource_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(
                directory / "Oboe.ipa",
                privacy={"NSSpeechRecognitionUsageDescription": "朗读文本"},
                appex={
                    "OboeShareExtension.appex": {
                        "NSPhotoLibraryUsageDescription": "保存截图"
                    }
                },
            )
            entitlements = [
                write_entitlements(
                    directory / "Oboe.entitlements",
                    [
                        "application-identifier",
                        "com.apple.security.application-groups",
                        "keychain-access-groups",
                    ],
                ),
                write_entitlements(
                    directory / "Share.entitlements",
                    ["com.apple.security.application-groups"],
                ),
            ]
            result = run_generate(
                directory,
                ipa,
                ["--entitlements", *(str(path) for path in entitlements)],
            )
            source = result["source"]

            gss.validate_source(source)
            self.assertEqual(source["name"], "Oboe Sideloading Source")
            self.assertEqual(source["identifier"], "org.example.Oboe.sidestore-source")
            self.assertEqual(source["news"], [])
            self.assertFalse(source["nsfw"])

            (app,) = source["apps"]
            for key in (
                "name",
                "bundleIdentifier",
                "developerName",
                "localizedDescription",
                "iconURL",
                "versions",
                "appPermissions",
            ):
                self.assertIn(key, app)
            self.assertEqual(app["bundleIdentifier"], BUNDLE_ID)
            self.assertEqual(
                app["screenshots"],
                [
                    {"imageURL": "https://example.com/assets/shot1.png"},
                    {"imageURL": "https://example.com/assets/shot2.png", "alt": "Reader"},
                ],
            )
            self.assertEqual(
                app["appPermissions"]["entitlements"],
                ["com.apple.security.application-groups", "keychain-access-groups"],
            )
            self.assertEqual(
                app["appPermissions"]["privacy"],
                {
                    "NSSpeechRecognitionUsageDescription": "朗读文本",
                    "NSPhotoLibraryUsageDescription": "保存截图",
                },
            )

            (entry,) = app["versions"]
            self.assertEqual(entry["version"], "0.7.0")
            self.assertEqual(entry["buildVersion"], "60")
            self.assertEqual(entry["date"], "2026-09-27")
            self.assertEqual(entry["downloadURL"], DOWNLOAD_URL)
            self.assertEqual(entry["size"], ipa.stat().st_size)
            self.assertEqual(
                entry["sha256"],
                hashlib.sha256(ipa.read_bytes()).hexdigest(),
            )
            self.assertEqual(entry["minOSVersion"], "17.0")

            self.assertEqual(
                result["sha256sums"],
                f"{hashlib.sha256(ipa.read_bytes()).hexdigest()}  {ipa.name}\n",
            )
            self.assertEqual(result["status"], "added")

    def test_versions_are_sorted_by_build_version_descending(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source_path = write_source(
                directory,
                existing_source([version_entry("0.6.0", "50"), version_entry("0.5.0", "40")]),
            )
            ipa = make_ipa(directory / "Oboe.ipa")
            result = run_generate(
                directory, ipa, ["--existing-source", str(source_path)]
            )
            versions = result["source"]["apps"][0]["versions"]
            self.assertEqual(
                [(v["version"], v["buildVersion"]) for v in versions],
                [("0.7.0", "60"), ("0.6.0", "50"), ("0.5.0", "40")],
            )

    def test_schema_rejects_unsorted_or_incomplete_versions(self) -> None:
        source = existing_source(
            [version_entry("0.5.0", "40"), version_entry("0.6.0", "50")]
        )
        with self.assertRaises(gss.SourceError):
            gss.validate_source(source)

        incomplete = existing_source([version_entry()])
        del incomplete["apps"][0]["versions"][0]["size"]
        with self.assertRaises(gss.SourceError):
            gss.validate_source(incomplete)

        zero_size = existing_source([version_entry(size=0)])
        with self.assertRaises(gss.SourceError):
            gss.validate_source(zero_size)


class RejectionTests(unittest.TestCase):
    def test_wrong_expected_version_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, ["--expect-version", "9.9.9"])

    def test_bundle_identifier_mismatch_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            metadata = write_metadata(directory, bundleIdentifier="org.example.Other")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, metadata=metadata)
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, ["--expect-bundle-id", "org.example.Other"])

    def test_missing_ipa_and_missing_payload_plist_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            with self.assertRaises(FileNotFoundError):
                run_generate(directory, directory / "absent.ipa")

            empty_ipa = directory / "empty.ipa"
            with zipfile.ZipFile(empty_ipa, "w") as archive:
                archive.writestr("Payload/Oboe.app/Oboe", b"binary")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, empty_ipa)

            corrupt_plist = directory / "corrupt.ipa"
            with zipfile.ZipFile(corrupt_plist, "w") as archive:
                archive.writestr("Payload/Oboe.app/Info.plist", b"not a plist")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, corrupt_plist)

            multi_app = make_ipa(directory / "multi.ipa", extra_top_app=True)
            with self.assertRaises(gss.SourceError):
                run_generate(directory, multi_app)

    def test_size_and_sha256_mismatch_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, ["--expect-size", "1"])
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, ["--expect-sha256", "0" * 64])
            # Matching expectations pass.
            result = run_generate(
                directory,
                ipa,
                [
                    "--expect-size",
                    str(ipa.stat().st_size),
                    "--expect-sha256",
                    hashlib.sha256(ipa.read_bytes()).hexdigest(),
                ],
            )
            self.assertEqual(result["status"], "added")

    def test_version_rollback_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source_path = write_source(
                directory, existing_source([version_entry("0.7.0", "60")])
            )
            older = make_ipa(directory / "old.ipa", version="0.6.0", build="50")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, older, ["--existing-source", str(source_path)])

    def test_duplicate_version_with_different_hash_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source_path = write_source(
                directory, existing_source([version_entry("0.7.0", "60", sha256="b" * 64)])
            )
            ipa = make_ipa(directory / "Oboe.ipa")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, ["--existing-source", str(source_path)])

    def test_same_version_same_hash_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
            source_path = write_source(
                directory,
                existing_source([version_entry("0.7.0", "60", sha256=digest)]),
            )
            result = run_generate(
                directory, ipa, ["--existing-source", str(source_path)]
            )
            self.assertEqual(result["status"], "unchanged")
            self.assertEqual(len(result["source"]["apps"][0]["versions"]), 1)

    def test_conflicting_build_version_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source_path = write_source(
                directory, existing_source([version_entry("0.7.0", "60")])
            )
            ipa = make_ipa(directory / "Oboe.ipa", version="0.7.1", build="60")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, ["--existing-source", str(source_path)])

    def test_invalid_urls_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            for bad_url in (
                "not-a-url",
                "ftp://example.com/Oboe.ipa",
                "https://",
                "https://example.com/a b.ipa",
                "http://insecure.example.com/Oboe.ipa",
            ):
                with self.assertRaises(gss.SourceError, msg=bad_url):
                    run_generate(directory, ipa, ["--download-url", bad_url])
            # http is accepted only when explicitly allowed.
            result = run_generate(
                directory,
                ipa,
                ["--download-url", "http://insecure.example.com/Oboe.ipa", "--allow-http"],
            )
            self.assertEqual(result["status"], "added")

            bad_icon = write_metadata(directory, iconURL="javascript:alert(1)")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, metadata=bad_icon)

            bad_shot = write_metadata(
                directory, screenshots=["not-a-url"]
            )
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, metadata=bad_shot)

    def test_missing_resources_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            with self.assertRaises(FileNotFoundError):
                run_generate(directory, ipa, metadata=directory / "absent.json")
            with self.assertRaises(FileNotFoundError):
                run_generate(
                    directory,
                    ipa,
                    ["--entitlements", str(directory / "absent.entitlements")],
                )
            with self.assertRaises(FileNotFoundError):
                run_generate(
                    directory,
                    ipa,
                    ["--existing-source", str(directory / "absent-source.json")],
                )

    def test_invalid_metadata_and_build_version_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            bad_category = write_metadata(directory, category="education")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, metadata=bad_category)

            missing_desc = write_metadata(directory, localizedDescription="")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa, metadata=missing_desc)

            bad_build = make_ipa(directory / "bad-build.ipa", build="60b")
            with self.assertRaises(gss.SourceError):
                run_generate(directory, bad_build)

    def test_conflicting_privacy_strings_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(
                directory / "Oboe.ipa",
                privacy={"NSPhotoLibraryUsageDescription": "甲"},
                appex={
                    "OboeShareExtension.appex": {
                        "NSPhotoLibraryUsageDescription": "乙"
                    }
                },
            )
            with self.assertRaises(gss.SourceError):
                run_generate(directory, ipa)


class CliTests(unittest.TestCase):
    def test_dry_run_prints_json_without_writing_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            metadata = write_metadata(directory)
            out_source = directory / "distribution" / "source.json"
            out_sums = directory / "SHA256SUMS"
            argv = base_argv(directory, ipa, metadata) + [
                "--out-source",
                str(out_source),
                "--out-sums",
                str(out_sums),
            ]
            code, stdout, stderr = run_cli(argv)
            self.assertEqual(code, 0, stderr)
            parsed = json.loads(stdout)
            gss.validate_source(parsed)
            self.assertIn("SHA256SUMS", stderr)
            self.assertFalse(out_source.exists())
            self.assertFalse(out_sums.exists())

    def test_write_mode_emits_source_and_sums(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            metadata = write_metadata(directory)
            out_source = directory / "distribution" / "source.json"
            out_sums = directory / "SHA256SUMS"
            argv = [
                arg
                for arg in base_argv(directory, ipa, metadata)
                if arg != "--dry-run"
            ]
            argv += [
                "--out-source",
                str(out_source),
                "--out-sums",
                str(out_sums),
            ]
            code, stdout, stderr = run_cli(argv)
            self.assertEqual(code, 0, stderr)
            self.assertIn("added", stdout)
            written = json.loads(out_source.read_text(encoding="utf-8"))
            gss.validate_source(written)
            digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
            self.assertEqual(
                out_sums.read_text(encoding="utf-8"), f"{digest}  Oboe.ipa\n"
            )

            # Re-running against the same output path merges idempotently.
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 0)
            self.assertIn("unchanged", stdout)
            written = json.loads(out_source.read_text(encoding="utf-8"))
            self.assertEqual(len(written["apps"][0]["versions"]), 1)

    def test_write_mode_requires_output_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe.ipa")
            metadata = write_metadata(directory)
            argv = [
                "--ipa",
                str(ipa),
                "--download-url",
                DOWNLOAD_URL,
                "--metadata",
                str(metadata),
            ]
            code, _, stderr = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("--out-source", stderr)


if __name__ == "__main__":
    unittest.main()
