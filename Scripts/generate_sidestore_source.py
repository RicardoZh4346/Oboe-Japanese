#!/usr/bin/env python3
"""Generate a SideStore/AltStore-compatible AltSource JSON from a release IPA.

Reads the real Info.plist inside an IPA (zip member reads only, no full
extraction), verifies identity/size expectations, merges the version into an
existing source JSON (versions sorted by buildVersion descending), and emits
``source.json`` plus a ``SHA256SUMS`` checksum file.

This script only produces local artifacts. Publishing, GitHub Pages deployment
and release wiring belong to S26 (release pipeline); nothing here uploads or
claims the source is live.

Example:
    python3 Scripts/generate_sidestore_source.py \
        --ipa artifacts/Oboe-v0.7.0.ipa \
        --download-url https://github.com/RicardoZh4346/Oboe-Japanese/releases/download/v0.7.0/Oboe-v0.7.0.ipa \
        --metadata Scripts/sidestore_source_oboe.json \
        --entitlements OboeApp/Oboe.entitlements \
            OboeShareExtension/OboeShareExtension.entitlements \
        --expect-version 0.7.0 --expect-build-version 60 \
        --expect-bundle-id org.example.Oboe \
        --out-source distribution/source.json \
        --out-sums artifacts/SHA256SUMS
"""

from __future__ import annotations

import argparse
import copy
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys
import urllib.parse
import zipfile
from pathlib import Path
from typing import Any


class SourceError(ValueError):
    """Raised when the IPA, metadata, or existing source fails validation."""


# AltStore documents only eight legal app categories; "education" is not one.
ALLOWED_APP_CATEGORIES = {
    "developer",
    "entertainment",
    "games",
    "lifestyle",
    "other",
    "photo-video",
    "social",
    "utilities",
}

# Entitlements AltStore does not require to be listed because every signed app
# carries them. Everything else (app groups, keychain groups, iCloud, ...) must
# be declared even when the IPA is currently unsigned.
AUTO_ENTITLEMENT_KEYS = {
    "application-identifier",
    "com.apple.developer.team-identifier",
    # Alternate spelling seen in AltStore documentation; filtered defensively.
    "com.app.developer.team-identifier",
}

MAIN_INFO_PLIST_RE = re.compile(r"^Payload/(?P<app>[^/]+\.app)/Info\.plist$")
TINT_COLOR_RE = re.compile(r"^#?[0-9a-fA-F]{6}$")
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

REQUIRED_VERSION_KEYS = {
    "version",
    "buildVersion",
    "date",
    "downloadURL",
    "size",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_plist_member(archive: zipfile.ZipFile, member: str) -> dict[str, Any]:
    try:
        raw = archive.read(member)
    except KeyError as error:
        raise SourceError(f"IPA is missing expected member {member}") from error
    try:
        plist = plistlib.loads(raw)
    except Exception as error:
        raise SourceError(f"{member} is not a readable plist: {error}") from error
    if not isinstance(plist, dict):
        raise SourceError(f"{member} does not contain a plist dictionary")
    return plist


def collect_privacy_permissions(
    plist: dict[str, Any], origin: str, privacy: dict[str, str]
) -> None:
    """Merge *UsageDescription entries from one plist into ``privacy``.

    A conflicting description for the same key is an error rather than a silent
    overwrite, because the AltSource privacy map has exactly one string per key.
    """
    for key, value in plist.items():
        if not isinstance(key, str) or not key.endswith("UsageDescription"):
            continue
        if not isinstance(value, str) or not value.strip():
            raise SourceError(f"{origin}: {key} must be a non-empty string")
        previous = privacy.get(key)
        if previous is not None and previous != value:
            raise SourceError(
                f"conflicting {key} strings between plists "
                f"({origin} disagrees with an earlier plist)"
            )
        privacy[key] = value


def load_ipa_bundle_info(ipa_path: Path) -> dict[str, Any]:
    """Read the main app plist and merged privacy keys out of an IPA.

    Only Info.plist members are decompressed; the rest of the zip is untouched.
    """
    if not ipa_path.is_file():
        raise FileNotFoundError(f"IPA file not found: {ipa_path}")
    try:
        archive = zipfile.ZipFile(ipa_path)
    except zipfile.BadZipFile as error:
        raise SourceError(f"IPA is not a readable zip archive: {ipa_path}") from error
    with archive:
        names = archive.namelist()
        main_members = sorted(n for n in names if MAIN_INFO_PLIST_RE.match(n))
        if not main_members:
            raise SourceError(
                f"IPA contains no Payload/<App>.app/Info.plist: {ipa_path.name}"
            )
        if len(main_members) > 1:
            raise SourceError(
                "IPA contains multiple top-level .app bundles, "
                f"cannot pick the main app: {main_members}"
            )
        plist_member = main_members[0]
        app_dir = plist_member.split("/")[1]
        plist = read_plist_member(archive, plist_member)

        privacy: dict[str, str] = {}
        collect_privacy_permissions(plist, plist_member, privacy)

        appex_re = re.compile(
            r"^Payload/"
            + re.escape(app_dir)
            + r"/PlugIns/[^/]+\.appex/Info\.plist$"
        )
        for member in sorted(n for n in names if appex_re.match(n)):
            appex_plist = read_plist_member(archive, member)
            collect_privacy_permissions(appex_plist, member, privacy)

    return {"plist": plist, "privacy": privacy, "app_dir": app_dir}


def require_plist_string(plist: dict[str, Any], key: str, ipa_name: str) -> str:
    value = plist.get(key)
    if not isinstance(value, str) or not value:
        raise SourceError(f"{ipa_name}: Info.plist is missing string key {key}")
    return value


def load_entitlements(paths: list[Path]) -> list[str]:
    """Union entitlement keys across the app and its extensions."""
    keys: set[str] = set()
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(f"entitlements file not found: {path}")
        try:
            plist = plistlib.loads(path.read_bytes())
        except Exception as error:
            raise SourceError(f"{path} is not a readable plist: {error}") from error
        if not isinstance(plist, dict):
            raise SourceError(f"{path} does not contain a plist dictionary")
        for key in plist:
            if key not in AUTO_ENTITLEMENT_KEYS:
                keys.add(key)
    return sorted(keys)


def validate_url(value: Any, field: str, allow_http: bool = False) -> str:
    if not isinstance(value, str) or not value:
        raise SourceError(f"{field} must be a non-empty URL string")
    if value != value.strip() or any(char.isspace() for char in value):
        raise SourceError(f"{field} must not contain whitespace: {value!r}")
    parsed = urllib.parse.urlparse(value)
    allowed = {"http", "https"} if allow_http else {"https"}
    if parsed.scheme not in allowed:
        schemes = "/".join(sorted(allowed))
        raise SourceError(f"{field} must be a {schemes} URL: {value}")
    if not parsed.netloc:
        raise SourceError(f"{field} is missing a host: {value}")
    return value


def normalize_tint_color(value: Any, field: str) -> str:
    if not isinstance(value, str) or not TINT_COLOR_RE.match(value):
        raise SourceError(f"{field} must be a 6-digit hex color: {value!r}")
    return value if value.startswith("#") else f"#{value}"


def parse_iso_date(value: Any, field: str) -> str:
    """Validate ISO-8601 input; date-only values normalize to YYYY-MM-DD."""
    if not isinstance(value, str) or not value:
        raise SourceError(f"{field} must be a non-empty ISO 8601 string")
    try:
        return datetime.date.fromisoformat(value).isoformat()
    except ValueError:
        pass
    try:
        datetime.datetime.fromisoformat(value)
    except ValueError as error:
        raise SourceError(f"{field} is not valid ISO 8601: {value!r}") from error
    return value


def build_version_sort_key(build_version: str) -> tuple[int, ...]:
    """CFBundleVersion ordering key; Apple requires (dotted) numeric builds."""
    if not isinstance(build_version, str) or not build_version:
        raise SourceError("buildVersion must be a non-empty string")
    parts = build_version.split(".")
    if not all(part.isdigit() for part in parts):
        raise SourceError(
            f"buildVersion must be numeric dot-separated integers: {build_version!r}"
        )
    return tuple(int(part, 10) for part in parts)


def require_non_empty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SourceError(f"metadata field {field} must be a non-empty string")
    return value


def normalize_screenshots(value: Any, field: str, allow_http: bool) -> Any:
    """Accept AltSource screenshot forms and validate every image URL.

    Supported shapes: ``["https://...", ...]``, ``[{"imageURL": ...}, ...]``,
    or the device-keyed ``{"iphone": [...], "ipad": [...]}`` object.
    """
    def one(item: Any, item_field: str) -> Any:
        if isinstance(item, str):
            return {"imageURL": validate_url(item, item_field, allow_http)}
        if isinstance(item, dict):
            url = validate_url(item.get("imageURL"), f"{item_field}.imageURL", allow_http)
            normalized = dict(item)
            normalized["imageURL"] = url
            return normalized
        raise SourceError(f"{item_field} must be a URL string or object")

    if isinstance(value, list):
        return [one(item, f"{field}[{index}]") for index, item in enumerate(value)]
    if isinstance(value, dict):
        normalized = {}
        for device, items in value.items():
            if device not in ("iphone", "ipad"):
                raise SourceError(
                    f"{field} device key must be iphone/ipad: {device!r}"
                )
            if not isinstance(items, list):
                raise SourceError(f"{field}.{device} must be a list")
            normalized[device] = [
                one(item, f"{field}.{device}[{index}]")
                for index, item in enumerate(items)
            ]
        return normalized
    raise SourceError(f"{field} must be a list or a device-keyed object")


def load_metadata(path: Path, allow_http: bool) -> dict[str, Any]:
    """Load and strictly validate the source/app metadata config JSON."""
    if not path.is_file():
        raise FileNotFoundError(f"metadata file not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SourceError(f"metadata is not valid JSON: {path}: {error}") from error
    if not isinstance(data, dict):
        raise SourceError("metadata root must be a JSON object")

    source_meta = data.get("source")
    app_meta = data.get("app")
    if not isinstance(source_meta, dict):
        raise SourceError("metadata is missing the 'source' object")
    if not isinstance(app_meta, dict):
        raise SourceError("metadata is missing the 'app' object")

    source: dict[str, Any] = {
        "name": require_non_empty_string(source_meta.get("name"), "source.name"),
        "identifier": require_non_empty_string(
            source_meta.get("identifier"), "source.identifier"
        ),
    }
    for key in ("subtitle", "description"):
        if key in source_meta:
            source[key] = require_non_empty_string(
                source_meta.get(key), f"source.{key}"
            )
    for key in ("iconURL", "headerURL", "website"):
        if key in source_meta:
            source[key] = validate_url(source_meta.get(key), f"source.{key}", allow_http)
    if "tintColor" in source_meta:
        source["tintColor"] = normalize_tint_color(
            source_meta.get("tintColor"), "source.tintColor"
        )

    app: dict[str, Any] = {
        "name": require_non_empty_string(app_meta.get("name"), "app.name"),
        "bundleIdentifier": require_non_empty_string(
            app_meta.get("bundleIdentifier"), "app.bundleIdentifier"
        ),
        "developerName": require_non_empty_string(
            app_meta.get("developerName"), "app.developerName"
        ),
        "localizedDescription": require_non_empty_string(
            app_meta.get("localizedDescription"), "app.localizedDescription"
        ),
        "iconURL": validate_url(app_meta.get("iconURL"), "app.iconURL", allow_http),
    }
    if not BUNDLE_ID_RE.match(app["bundleIdentifier"]):
        raise SourceError(
            f"app.bundleIdentifier is not a reverse-DNS identifier: "
            f"{app['bundleIdentifier']!r}"
        )
    if "subtitle" in app_meta:
        app["subtitle"] = require_non_empty_string(
            app_meta.get("subtitle"), "app.subtitle"
        )
    if "tintColor" in app_meta:
        app["tintColor"] = normalize_tint_color(
            app_meta.get("tintColor"), "app.tintColor"
        )
    if "category" in app_meta:
        category = app_meta["category"]
        if category not in ALLOWED_APP_CATEGORIES:
            raise SourceError(
                f"app.category must be one of {sorted(ALLOWED_APP_CATEGORIES)}: "
                f"{category!r}"
            )
        app["category"] = category
    if "screenshots" in app_meta:
        app["screenshots"] = normalize_screenshots(
            app_meta["screenshots"], "app.screenshots", allow_http
        )
    if not BUNDLE_ID_RE.match(source["identifier"]):
        raise SourceError(
            f"source.identifier is not a reverse-DNS identifier: "
            f"{source['identifier']!r}"
        )

    return {"source": source, "app": app}


def build_app_entry(
    app_meta: dict[str, Any], entitlements: list[str], privacy: dict[str, str]
) -> dict[str, Any]:
    """Build the ``apps[]`` element; ``versions`` is filled by the caller."""
    entry: dict[str, Any] = {
        "name": app_meta["name"],
        "bundleIdentifier": app_meta["bundleIdentifier"],
        "developerName": app_meta["developerName"],
    }
    if "subtitle" in app_meta:
        entry["subtitle"] = app_meta["subtitle"]
    entry["localizedDescription"] = app_meta["localizedDescription"]
    entry["iconURL"] = app_meta["iconURL"]
    if "tintColor" in app_meta:
        entry["tintColor"] = app_meta["tintColor"]
    if "category" in app_meta:
        entry["category"] = app_meta["category"]
    if "screenshots" in app_meta:
        entry["screenshots"] = copy.deepcopy(app_meta["screenshots"])
    entry["versions"] = []
    entry["appPermissions"] = {
        "entitlements": list(entitlements),
        "privacy": dict(privacy),
    }
    return entry


def merge_version_entry(versions: list[dict[str, Any]], entry: dict[str, Any]) -> str:
    """Insert ``entry`` into ``versions`` keeping buildVersion-desc order.

    Returns ``"added"`` or ``"unchanged"``. Refuses to overwrite an existing
    version+buildVersion pair whose SHA-256 differs, and refuses to append a
    build lower than the newest already-published build (version rollback).
    """
    for existing in versions:
        if not isinstance(existing, dict):
            raise SourceError("existing source has a non-object version entry")
        same_build = existing.get("buildVersion") == entry["buildVersion"]
        same_version = existing.get("version") == entry["version"]
        if same_build and same_version:
            if existing.get("sha256") == entry["sha256"]:
                return "unchanged"
            raise SourceError(
                f"refusing to overwrite version {entry['version']} "
                f"(build {entry['buildVersion']}): existing SHA-256 "
                f"{existing.get('sha256')!r} differs from {entry['sha256']!r}"
            )
        if same_build:
            raise SourceError(
                f"buildVersion {entry['buildVersion']} is already used by "
                f"version {existing.get('version')!r}; refusing conflicting entry"
            )
    if versions:
        keyed = [
            (build_version_sort_key(existing.get("buildVersion")), existing)
            for existing in versions
        ]
        newest_key, newest_entry = max(keyed, key=lambda item: item[0])
        if build_version_sort_key(entry["buildVersion"]) < newest_key:
            raise SourceError(
                f"version rollback refused: new buildVersion "
                f"{entry['buildVersion']} sorts below the already-published "
                f"{newest_entry.get('version')} "
                f"(build {newest_entry.get('buildVersion')})"
            )
    versions.append(entry)
    versions.sort(
        key=lambda item: build_version_sort_key(item["buildVersion"]),
        reverse=True,
    )
    return "added"


def validate_source(source: Any, allow_http: bool = False) -> None:
    """Strict AltSource schema check over the final document.

    Enforces the official required keys plus this distribution's ``sha256``
    per-version integrity field, and verifies the published ordering rule
    (versions sorted by buildVersion, newest first).
    """
    if not isinstance(source, dict):
        raise SourceError("source root must be a JSON object")
    require_non_empty_string(source.get("name"), "source.name")
    require_non_empty_string(source.get("identifier"), "source.identifier")
    for key in ("iconURL", "headerURL", "website", "patreonURL"):
        if key in source:
            validate_url(source[key], f"source.{key}", allow_http)
    if "tintColor" in source:
        normalize_tint_color(source["tintColor"], "source.tintColor")
    apps = source.get("apps")
    if not isinstance(apps, list):
        raise SourceError("source.apps must be a list")
    news = source.get("news")
    if not isinstance(news, list):
        raise SourceError("source.news must be a list")

    seen_bundle_ids: set[str] = set()
    for app_index, app in enumerate(apps):
        field = f"apps[{app_index}]"
        if not isinstance(app, dict):
            raise SourceError(f"{field} must be an object")
        for key in (
            "name",
            "bundleIdentifier",
            "developerName",
            "localizedDescription",
        ):
            require_non_empty_string(app.get(key), f"{field}.{key}")
        bundle_id = app["bundleIdentifier"]
        if bundle_id in seen_bundle_ids:
            raise SourceError(f"duplicate bundleIdentifier in apps[]: {bundle_id}")
        seen_bundle_ids.add(bundle_id)
        validate_url(app.get("iconURL"), f"{field}.iconURL", allow_http)
        if "category" in app and app["category"] not in ALLOWED_APP_CATEGORIES:
            raise SourceError(
                f"{field}.category is not an allowed value: {app['category']!r}"
            )
        if "screenshots" in app:
            normalize_screenshots(app["screenshots"], f"{field}.screenshots", allow_http)

        permissions = app.get("appPermissions")
        if not isinstance(permissions, dict):
            raise SourceError(f"{field}.appPermissions must be an object")
        entitlements = permissions.get("entitlements")
        privacy = permissions.get("privacy")
        if not isinstance(entitlements, list) or not all(
            isinstance(item, str) for item in entitlements
        ):
            raise SourceError(f"{field}.appPermissions.entitlements must be strings")
        if not isinstance(privacy, dict) or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in privacy.items()
        ):
            raise SourceError(f"{field}.appPermissions.privacy must be a string map")

        versions = app.get("versions")
        if not isinstance(versions, list) or not versions:
            raise SourceError(f"{field}.versions must be a non-empty list")
        seen_pairs: set[tuple[str, str]] = set()
        sort_keys: list[tuple[int, ...]] = []
        for version_index, version in enumerate(versions):
            version_field = f"{field}.versions[{version_index}]"
            if not isinstance(version, dict):
                raise SourceError(f"{version_field} must be an object")
            missing = REQUIRED_VERSION_KEYS - set(version)
            if missing:
                raise SourceError(
                    f"{version_field} is missing keys: {sorted(missing)}"
                )
            require_non_empty_string(version["version"], f"{version_field}.version")
            require_non_empty_string(
                version["buildVersion"], f"{version_field}.buildVersion"
            )
            parse_iso_date(version["date"], f"{version_field}.date")
            validate_url(version["downloadURL"], f"{version_field}.downloadURL", allow_http)
            size = version["size"]
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                raise SourceError(f"{version_field}.size must be a positive integer")
            sha256 = version.get("sha256")
            if not isinstance(sha256, str) or not SHA256_RE.match(sha256):
                raise SourceError(
                    f"{version_field}.sha256 must be 64 lowercase hex chars"
                )
            if "minOSVersion" in version:
                require_non_empty_string(
                    version["minOSVersion"], f"{version_field}.minOSVersion"
                )
            pair = (version["version"], version["buildVersion"])
            if pair in seen_pairs:
                raise SourceError(
                    f"duplicate version entry in {field}: {pair[0]} ({pair[1]})"
                )
            seen_pairs.add(pair)
            sort_keys.append(build_version_sort_key(version["buildVersion"]))
        if sort_keys != sorted(sort_keys, reverse=True):
            raise SourceError(
                f"{field}.versions must be sorted by buildVersion descending"
            )


def write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def generate(args: argparse.Namespace) -> dict[str, Any]:
    if not args.dry_run and (not args.out_source or not args.out_sums):
        raise SourceError(
            "--out-source and --out-sums are required unless --dry-run is set"
        )

    ipa_path = Path(args.ipa)
    info = load_ipa_bundle_info(ipa_path)
    plist = info["plist"]
    bundle_id = require_plist_string(plist, "CFBundleIdentifier", ipa_path.name)
    version = require_plist_string(
        plist, "CFBundleShortVersionString", ipa_path.name
    )
    build_version = require_plist_string(plist, "CFBundleVersion", ipa_path.name)
    build_version_sort_key(build_version)

    metadata = load_metadata(Path(args.metadata), args.allow_http)
    if metadata["app"]["bundleIdentifier"] != bundle_id:
        raise SourceError(
            f"bundleIdentifier mismatch: metadata declares "
            f"{metadata['app']['bundleIdentifier']} but the IPA reports {bundle_id}"
        )

    for flag, actual, label in (
        (args.expect_bundle_id, bundle_id, "bundle ID"),
        (args.expect_version, version, "version"),
        (args.expect_build_version, build_version, "buildVersion"),
    ):
        if flag is not None and flag != actual:
            raise SourceError(f"expected {label} {flag} but IPA reports {actual}")

    size = ipa_path.stat().st_size
    if size <= 0:
        raise SourceError(f"IPA is empty (size 0): {ipa_path}")
    if args.expect_size is not None and args.expect_size != size:
        raise SourceError(f"expected size {args.expect_size} bytes but IPA is {size}")
    digest = sha256_file(ipa_path)
    if args.expect_sha256 is not None and args.expect_sha256.lower() != digest:
        raise SourceError(
            f"expected SHA-256 {args.expect_sha256} but IPA hashes to {digest}"
        )

    download_url = validate_url(args.download_url, "downloadURL", args.allow_http)
    min_os_version = args.min_os_version or plist.get("MinimumOSVersion")
    if not isinstance(min_os_version, str) or not min_os_version:
        raise SourceError(
            "MinimumOSVersion missing from Info.plist; pass --min-os-version"
        )
    release_date = (
        parse_iso_date(args.date, "--date")
        if args.date
        else datetime.date.today().isoformat()
    )
    entitlements = load_entitlements([Path(p) for p in args.entitlements or []])

    version_entry: dict[str, Any] = {
        "version": version,
        "buildVersion": build_version,
        "date": release_date,
    }
    if args.release_notes:
        version_entry["localizedDescription"] = args.release_notes
    version_entry["downloadURL"] = download_url
    version_entry["size"] = size
    version_entry["sha256"] = digest
    version_entry["minOSVersion"] = min_os_version

    existing_path: Path | None = None
    if args.existing_source:
        existing_path = Path(args.existing_source)
    elif args.out_source and Path(args.out_source).is_file():
        # Re-running with the same output path merges into the previous source.
        existing_path = Path(args.out_source)

    if existing_path is not None:
        if not existing_path.is_file():
            raise FileNotFoundError(
                f"existing source not found: {existing_path}"
            )
        try:
            source = json.loads(existing_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise SourceError(
                f"existing source is not valid JSON: {existing_path}: {error}"
            ) from error
        if not isinstance(source, dict) or not isinstance(source.get("apps"), list):
            raise SourceError(
                f"existing source must be an object with an apps list: "
                f"{existing_path}"
            )
        source.setdefault("news", [])
        # Refresh source-level metadata so description/icon edits propagate.
        for key, value in metadata["source"].items():
            source[key] = value
        source.setdefault("nsfw", False)
    else:
        source = {"nsfw": False, "apps": [], "news": []}
        for key in ("name", "identifier", "subtitle", "description",
                    "iconURL", "headerURL", "website", "tintColor"):
            if key in metadata["source"]:
                source[key] = metadata["source"][key]
        # Keep the canonical top-level order for new sources.
        source = {
            key: source[key]
            for key in ("name", "identifier", "subtitle", "description",
                        "iconURL", "headerURL", "website", "tintColor",
                        "nsfw", "apps", "news")
            if key in source
        }

    app_meta = metadata["app"]
    app_entry = next(
        (
            app
            for app in source["apps"]
            if isinstance(app, dict)
            and app.get("bundleIdentifier") == bundle_id
        ),
        None,
    )
    if app_entry is None:
        app_entry = build_app_entry(app_meta, entitlements, info["privacy"])
        source["apps"].append(app_entry)
    else:
        merged = build_app_entry(app_meta, entitlements, info["privacy"])
        versions = app_entry.get("versions")
        if not isinstance(versions, list):
            raise SourceError(
                f"existing app entry for {bundle_id} has no versions list"
            )
        merged["versions"] = versions
        app_index = source["apps"].index(app_entry)
        source["apps"][app_index] = merged
        app_entry = merged

    status = merge_version_entry(app_entry["versions"], version_entry)

    validate_source(source, args.allow_http)

    return {
        "source": source,
        "sha256sums": f"{digest}  {ipa_path.name}\n",
        "status": status,
        "version": version,
        "build_version": build_version,
        "bundle_id": bundle_id,
        "size": size,
        "sha256": digest,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, help="path to the release .ipa")
    parser.add_argument(
        "--download-url",
        required=True,
        help="published URL of the IPA (GitHub Release asset or Pages mirror)",
    )
    parser.add_argument(
        "--metadata",
        required=True,
        help="JSON file with 'source' and 'app' metadata objects",
    )
    parser.add_argument(
        "--entitlements",
        nargs="*",
        default=[],
        help="project .entitlements plist files (app plus each extension)",
    )
    parser.add_argument(
        "--existing-source",
        help="source.json to merge into; defaults to --out-source when it exists",
    )
    parser.add_argument("--out-source", help="path to write source.json")
    parser.add_argument("--out-sums", help="path to write SHA256SUMS")
    parser.add_argument("--date", help="release date (ISO 8601); default: today")
    parser.add_argument("--release-notes", help="per-version localizedDescription")
    parser.add_argument(
        "--min-os-version",
        help="override MinimumOSVersion read from the IPA plist",
    )
    parser.add_argument("--expect-version", help="expected CFBundleShortVersionString")
    parser.add_argument("--expect-build-version", help="expected CFBundleVersion")
    parser.add_argument("--expect-bundle-id", help="expected CFBundleIdentifier")
    parser.add_argument("--expect-size", type=int, help="expected IPA byte size")
    parser.add_argument("--expect-sha256", help="expected IPA SHA-256 hex digest")
    parser.add_argument(
        "--allow-http",
        action="store_true",
        help="permit http:// URLs (local testing only; sources must be https)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate and print the resulting source JSON without writing files",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv or sys.argv[1:])
        result = generate(args)
        if args.dry_run:
            print(json.dumps(result["source"], ensure_ascii=False, indent=2))
            print("--- SHA256SUMS ---", file=sys.stderr)
            print(result["sha256sums"], file=sys.stderr, end="")
        else:
            source_text = (
                json.dumps(result["source"], ensure_ascii=False, indent=2) + "\n"
            )
            write_text_atomic(Path(args.out_source), source_text)
            write_text_atomic(Path(args.out_sums), result["sha256sums"])
            print(
                f"{result['status']}: {result['bundle_id']} "
                f"{result['version']} (build {result['build_version']}), "
                f"{result['size']} bytes, sha256 {result['sha256']}"
            )
            print(f"wrote {args.out_source}")
            print(f"wrote {args.out_sums}")
        return 0
    except Exception as error:
        print(f"generate_sidestore_source.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
