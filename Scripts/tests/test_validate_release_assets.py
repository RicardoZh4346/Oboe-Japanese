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


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "validate_release_assets.py"
SPEC = importlib.util.spec_from_file_location("validate_release_assets", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
vra = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = vra
SPEC.loader.exec_module(vra)
gss = vra.gss


BUNDLE_ID = "org.example.Oboe"
APPEX_ID = "org.example.Oboe.ShareExtension"
DOWNLOAD_URL = "https://github.com/RicardoZh4346/Oboe-Japanese/releases/download/v0.7.0/Oboe-v0.7.0.ipa"


def make_ipa(
    path: Path,
    *,
    bundle_id: str = BUNDLE_ID,
    version: str = "0.7.0",
    build: str = "60",
    appex_id: str | None = APPEX_ID,
    payload: bytes = b"fake-oboe-binary",
) -> Path:
    plist = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": "17.0",
        "CFBundleExecutable": "Oboe",
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/Oboe.app/Oboe", payload)
        archive.writestr("Payload/Oboe.app/Info.plist", plistlib.dumps(plist))
        if appex_id is not None:
            archive.writestr(
                "Payload/Oboe.app/PlugIns/OboeShareExtension.appex/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": appex_id,
                        "CFBundleShortVersionString": version,
                        "CFBundleVersion": build,
                    }
                ),
            )
    return path


def corrupt_member(ipa_path: Path, needle: bytes = b"fake-oboe-binary") -> None:
    """Flip one payload byte without touching the stored CRC."""
    data = bytearray(ipa_path.read_bytes())
    offset = data.find(needle)
    assert offset >= 0, "payload not stored plainly in zip"
    data[offset] ^= 0xFF
    ipa_path.write_bytes(bytes(data))


def write_sums(path: Path, ipa: Path, extra: str = "") -> Path:
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    path.write_text(f"{digest}  {ipa.name}\n{extra}", encoding="utf-8")
    return path


def metadata_dict() -> dict:
    return {
        "source": {
            "name": "Oboe Sideloading Source",
            "identifier": "org.example.Oboe.sidestore-source",
            "iconURL": "https://example.com/assets/AppIcon.png",
            "tintColor": "#2563EB",
        },
        "app": {
            "name": "Oboe",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "RicardoZh4346",
            "localizedDescription": "iOS 日语学习应用",
            "iconURL": "https://example.com/assets/AppIcon.png",
        },
    }


def write_metadata(directory: Path) -> Path:
    path = directory / "metadata.json"
    path.write_text(json.dumps(metadata_dict(), ensure_ascii=False), encoding="utf-8")
    return path


def generate_source(directory: Path, ipa: Path, version: str) -> Path:
    """Run the S25 generator to produce a real source.json for merging tests."""
    metadata = write_metadata(directory)
    out = directory / "source.json"
    args = gss.parse_args(
        [
            "--ipa",
            str(ipa),
            "--download-url",
            DOWNLOAD_URL,
            "--metadata",
            str(metadata),
            "--date",
            "2026-09-27",
            "--out-source",
            str(out),
            "--out-sums",
            str(directory / "SHA256SUMS"),
        ]
    )
    result = gss.generate(args)
    source_text = json.dumps(result["source"], ensure_ascii=False, indent=2)
    gss.write_text_atomic(out, source_text + "\n")
    return out


def run_cli(argv: list[str]) -> tuple[int, str, str]:
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        code = vra.main(argv)
    return code, stdout.getvalue(), stderr.getvalue()


def base_argv(ipa: Path) -> list[str]:
    return [
        "--ipa",
        str(ipa),
        "--tag",
        "v0.7.0",
        "--expect-build-version",
        "60",
        "--expect-bundle-id",
        BUNDLE_ID,
    ]


class IpaValidationTests(unittest.TestCase):
    def test_valid_ipa_passes_all_checks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "Oboe-v0.7.0.ipa")
            code, stdout, _ = run_cli(base_argv(ipa))
            self.assertEqual(code, 0, stdout)
            self.assertIn("all", stdout)
            self.assertIn("checks passed", stdout)

    def test_missing_ipa_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "absent.ipa"
            code, stdout, _ = run_cli(base_argv(ipa))
            self.assertEqual(code, 1)
            self.assertIn("not found", stdout)

    def test_corrupt_member_fails_crc(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            # ZIP_STORED keeps the payload plainly findable for corruption.
            ipa = directory / "Oboe-v0.7.0.ipa"
            plist = {
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleShortVersionString": "0.7.0",
                "CFBundleVersion": "60",
            }
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_STORED) as archive:
                archive.writestr("Payload/Oboe.app/Oboe", b"fake-oboe-binary")
                archive.writestr(
                    "Payload/Oboe.app/Info.plist", plistlib.dumps(plist)
                )
                archive.writestr(
                    "Payload/Oboe.app/PlugIns/OboeShareExtension.appex/Info.plist",
                    plistlib.dumps({"CFBundleIdentifier": APPEX_ID}),
                )
            corrupt_member(ipa)
            code, stdout, _ = run_cli(base_argv(ipa))
            self.assertEqual(code, 1)
            self.assertIn("CRC", stdout)

    def test_tag_version_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "Oboe.ipa", version="0.6.0", build="50")
            argv = [
                "--ipa",
                str(ipa),
                "--tag",
                "v0.7.0",
                "--expect-build-version",
                "50",
            ]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("CFBundleShortVersionString", stdout)

    def test_build_version_and_bundle_id_mismatch_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "Oboe.ipa")
            argv = base_argv(ipa) + ["--expect-build-version", "61"]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("CFBundleVersion", stdout)

            argv = base_argv(ipa) + ["--expect-bundle-id", "org.example.Other"]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("CFBundleIdentifier", stdout)

    def test_missing_appex_and_foreign_appex_id_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            no_appex = make_ipa(directory / "bare.ipa", appex_id=None)
            code, stdout, _ = run_cli(base_argv(no_appex))
            self.assertEqual(code, 1)
            self.assertIn("expected appex missing", stdout)

            foreign = make_ipa(
                directory / "foreign.ipa", appex_id="com.attacker.extension"
            )
            code, stdout, _ = run_cli(base_argv(foreign))
            self.assertEqual(code, 1)
            self.assertIn("not nested", stdout)

    def test_multiple_top_level_apps_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "multi.ipa"
            plist = {
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleShortVersionString": "0.7.0",
                "CFBundleVersion": "60",
            }
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr(
                    "Payload/Oboe.app/Info.plist", plistlib.dumps(plist)
                )
                archive.writestr(
                    "Payload/Other.app/Info.plist", plistlib.dumps(plist)
                )
            code, stdout, _ = run_cli(base_argv(ipa))
            self.assertEqual(code, 1)
            self.assertIn("multiple top-level", stdout)

    def test_sha256_and_size_expectations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "Oboe.ipa")
            digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
            argv = base_argv(ipa) + [
                "--expect-sha256",
                digest,
                "--expect-size",
                str(ipa.stat().st_size),
            ]
            code, _, _ = run_cli(argv)
            self.assertEqual(code, 0)

            argv = base_argv(ipa) + ["--expect-sha256", "0" * 64]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("sha256", stdout)

            argv = base_argv(ipa) + ["--expect-size", "1"]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("size", stdout)

    def test_usage_errors_exit_2(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "Oboe.ipa")
            # Neither --tag nor --expect-version.
            code, _, stderr = run_cli(["--ipa", str(ipa)])
            self.assertEqual(code, 2)
            self.assertIn("required", stderr)
            # Malformed tag.
            code, _, stderr = run_cli(["--ipa", str(ipa), "--tag", "0.7.0"])
            self.assertEqual(code, 2)
            # Malformed sha256 expectation.
            code, _, stderr = run_cli(
                base_argv(ipa) + ["--expect-sha256", "zz"]
            )
            self.assertEqual(code, 2)
            # Tag/expect-version disagreement is a check failure, not usage.
            code, stdout, _ = run_cli(
                base_argv(ipa) + ["--expect-version", "9.9.9"]
            )
            self.assertEqual(code, 1)
            self.assertIn("disagrees", stdout)


class SumsValidationTests(unittest.TestCase):
    def test_sums_matching_ipa_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe-v0.7.0.ipa")
            sums = write_sums(directory / "SHA256SUMS", ipa)
            code, stdout, _ = run_cli(base_argv(ipa) + ["--sums", str(sums)])
            self.assertEqual(code, 0, stdout)

    def test_sums_wrong_digest_or_missing_entry_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe-v0.7.0.ipa")
            bad = directory / "SHA256SUMS"
            bad.write_text(f"{'0' * 64}  {ipa.name}\n", encoding="utf-8")
            code, stdout, _ = run_cli(base_argv(ipa) + ["--sums", str(bad)])
            self.assertEqual(code, 1)
            self.assertIn("hashes to", stdout)

            other = directory / "SHA256SUMS2"
            other.write_text(f"{'a' * 64}  unrelated.ipa\n", encoding="utf-8")
            code, stdout, _ = run_cli(base_argv(ipa) + ["--sums", str(other)])
            self.assertEqual(code, 1)
            self.assertIn("does not list", stdout)

    def test_sums_malformed_line_and_colocated_mismatch_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe-v0.7.0.ipa")
            sums = write_sums(
                directory / "SHA256SUMS", ipa, extra="not-a-checksum-line\n"
            )
            code, stdout, _ = run_cli(base_argv(ipa) + ["--sums", str(sums)])
            self.assertEqual(code, 1)
            self.assertIn("malformed", stdout)

            # A colocated listed file whose content diverged from the sums.
            sibling = directory / "notes.txt"
            sibling.write_text("tampered", encoding="utf-8")
            sums = write_sums(
                directory / "SHA256SUMS2",
                ipa,
                extra=f"{'b' * 64}  notes.txt\n",
            )
            code, stdout, _ = run_cli(base_argv(ipa) + ["--sums", str(sums)])
            self.assertEqual(code, 1)
            self.assertIn("notes.txt", stdout)


class SourceValidationTests(unittest.TestCase):
    def test_source_with_matching_entry_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe-v0.7.0.ipa")
            source = generate_source(directory, ipa, "0.7.0")
            argv = base_argv(ipa) + [
                "--source",
                str(source),
                "--require-source-entry",
                "--expect-download-url",
                DOWNLOAD_URL,
            ]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 0, stdout)

    def test_source_missing_entry_requires_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe-v0.7.0.ipa")
            # Seed an unrelated but schema-valid source via the generator.
            other = make_ipa(directory / "old.ipa", version="0.6.0", build="50")
            source = generate_source(directory, other, "0.6.0")

            argv = base_argv(ipa) + ["--source", str(source)]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 0, stdout)
            self.assertIn("no entry", stdout)

            code, stdout, _ = run_cli(
                argv + ["--require-source-entry"]
            )
            self.assertEqual(code, 1)
            self.assertIn("missing the entry", stdout)

    def test_source_entry_with_different_sha256_fails(self) -> None:
        """Same tag rebuilt differently must be caught as a hash mismatch."""
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa_a = make_ipa(directory / "A.ipa", payload=b"binary-A")
            source = generate_source(directory, ipa_a, "0.7.0")
            ipa_b = make_ipa(directory / "B.ipa", payload=b"binary-B")
            argv = base_argv(ipa_b) + [
                "--source",
                str(source),
                "--require-source-entry",
            ]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("sha256", stdout)

    def test_stale_run_downgrade_guard(self) -> None:
        """A source already publishing a newer build rejects an older IPA."""
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            new_ipa = make_ipa(directory / "new.ipa", version="0.7.0", build="60")
            source = generate_source(directory, new_ipa, "0.7.0")
            old_ipa = make_ipa(directory / "old.ipa", version="0.6.0", build="50")
            argv = [
                "--ipa",
                str(old_ipa),
                "--tag",
                "v0.6.0",
                "--expect-build-version",
                "50",
                "--source",
                str(source),
            ]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("downgrade", stdout)

    def test_conflicting_build_version_in_source_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa_a = make_ipa(directory / "A.ipa", version="0.7.0", build="60")
            source = generate_source(directory, ipa_a, "0.7.0")
            ipa_b = make_ipa(directory / "B.ipa", version="0.7.1", build="60")
            argv = [
                "--ipa",
                str(ipa_b),
                "--tag",
                "v0.7.1",
                "--expect-build-version",
                "60",
                "--source",
                str(source),
            ]
            code, stdout, _ = run_cli(argv)
            self.assertEqual(code, 1)
            self.assertIn("same-build", stdout)

    def test_source_schema_violation_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ipa = make_ipa(directory / "Oboe-v0.7.0.ipa")
            source = generate_source(directory, ipa, "0.7.0")
            broken = json.loads(source.read_text(encoding="utf-8"))
            del broken["apps"][0]["versions"][0]["size"]
            source.write_text(json.dumps(broken), encoding="utf-8")
            code, stdout, _ = run_cli(
                base_argv(ipa) + ["--source", str(source)]
            )
            self.assertEqual(code, 1)
            self.assertIn("schema", stdout)

    def test_missing_source_file_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "Oboe-v0.7.0.ipa")
            code, stdout, _ = run_cli(
                base_argv(ipa) + ["--source", str(Path(tmp) / "absent.json")]
            )
            self.assertEqual(code, 1)
            self.assertIn("not found", stdout)


if __name__ == "__main__":
    unittest.main()
