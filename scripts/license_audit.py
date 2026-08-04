#!/usr/bin/env python3
"""Build and audit PrivateDeploy's lockfile-based third-party SBOM.

The inventory is derived exclusively from checked-in lock/checksum files.  A
separate, checked-in evidence file records license observations from locally
installed package metadata.  Normal generation and CI checks never access the
network and never mutate package-manager state.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.parse
import zipfile


SCHEMA_VERSION = 1
SPDX_CREATED = "1970-01-01T00:00:00Z"
LICENSE_FILE_RE = re.compile(r"^(licen[cs]e|copying|copyright|notice)([._-].*)?$", re.I)
REQUIRED_RELEASE_SCOPES = {
    "go-desktop": "Desktop Go module",
    "go-api": "API Go module",
    "go-mobile": "gomobile Go module",
    "npm-frontend": "Desktop frontend npm graph",
    "pub-mobile": "Flutter/Dart pub graph",
    "android-native": "Resolved Android Gradle/Maven/SDK runtime graph",
    "ios-native": "Resolved iOS CocoaPods runtime graph",
    "flutter-engine-native": "Pinned Flutter engine/native redistribution notices",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def unquote_yaml_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        if value[0] == "'":
            return value[1:-1].replace("''", "'")
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    return value


def purl(ecosystem: str, name: str, version: str) -> str:
    ptype = {"go": "golang", "npm": "npm", "pub": "pub"}[ecosystem]
    # Purl path separators remain structural; npm's leading scope marker is
    # data and must be encoded (pkg:npm/%40scope/name@version).
    safe_name = urllib.parse.quote(name, safe="/")
    safe_version = urllib.parse.quote(version, safe="")
    return f"pkg:{ptype}/{safe_name}@{safe_version}"


def parse_go_sum(path: Path, lock_source: str | None = None) -> list[dict[str, str]]:
    components: dict[str, dict[str, str]] = {}
    for line in read_text(path).splitlines():
        fields = line.split()
        if len(fields) != 3 or fields[1].endswith("/go.mod"):
            continue
        name, version, checksum = fields
        key = purl("go", name, version)
        components[key] = {
            "ecosystem": "go",
            "name": name,
            "version": version,
            "purl": key,
            "lockSource": lock_source or path.as_posix(),
            "integrity": checksum,
        }
    return list(components.values())


def split_pnpm_key(raw: str) -> tuple[str, str] | None:
    raw = unquote_yaml_scalar(raw)
    if raw.startswith(("http:", "https:", "file:", "link:")) or "@" not in raw:
        return None
    raw = raw.split("(", 1)[0]
    name, version = raw.rsplit("@", 1)
    if not name or not version:
        return None
    return name, version


def parse_pnpm_lock(path: Path, lock_source: str | None = None) -> list[dict[str, str]]:
    lines = read_text(path).splitlines()
    in_packages = False
    components: dict[str, dict[str, str]] = {}
    current: dict[str, str] | None = None
    for line in lines:
        if line == "packages:":
            in_packages = True
            continue
        if in_packages and line and not line.startswith(" "):
            break
        match = re.match(r"^  (.+):$", line) if in_packages else None
        if match:
            parsed = split_pnpm_key(match.group(1))
            current = None
            if parsed:
                name, version = parsed
                key = purl("npm", name, version)
                current = {
                    "ecosystem": "npm",
                    "name": name,
                    "version": version,
                    "purl": key,
                    "lockSource": lock_source or path.as_posix(),
                }
                components[key] = current
            continue
        if current:
            integrity = re.search(r"integrity:\s*([^,}\s]+)", line)
            if integrity:
                current["integrity"] = integrity.group(1)
    return list(components.values())


def parse_pub_lock(path: Path, lock_source: str | None = None) -> list[dict[str, str]]:
    lines = read_text(path).splitlines()
    in_packages = False
    current_name: str | None = None
    fields: dict[str, str] = {}
    components: list[dict[str, str]] = []

    def flush() -> None:
        nonlocal current_name, fields
        if current_name and fields.get("version"):
            version = fields["version"]
            component = {
                "ecosystem": "pub",
                "name": current_name,
                "version": version,
                "purl": purl("pub", current_name, version),
                "lockSource": lock_source or path.as_posix(),
                "scope": fields.get("dependency", "unknown"),
                "source": fields.get("source", "unknown"),
            }
            if "sha256" in fields:
                component["integrity"] = "sha256:" + fields["sha256"]
            components.append(component)
        current_name = None
        fields = {}

    for line in lines:
        if line == "packages:":
            in_packages = True
            continue
        if in_packages and line and not line.startswith(" "):
            flush()
            break
        match = re.match(r"^  ([^ ].*):$", line) if in_packages else None
        if match:
            flush()
            current_name = unquote_yaml_scalar(match.group(1))
            continue
        if current_name:
            match = re.match(r"^    (dependency|source|version):\s*(.+)$", line)
            if match:
                fields[match.group(1)] = unquote_yaml_scalar(match.group(2))
            match = re.match(r"^      sha256:\s*(.+)$", line)
            if match:
                fields["sha256"] = unquote_yaml_scalar(match.group(1))
    flush()
    return components


def inventory(root: Path) -> tuple[list[dict[str, str]], str]:
    inputs = [
        root / "go.sum",
        root / "api/go.sum",
        root / "mobile/gomobile/go.sum",
        root / "frontend/pnpm-lock.yaml",
        root / "mobile/pubspec.lock",
    ]
    missing = [str(path.relative_to(root)) for path in inputs if not path.is_file()]
    if missing:
        raise RuntimeError("missing dependency lock files: " + ", ".join(missing))

    components: dict[str, dict[str, str]] = {}
    for path in inputs[:3]:
        for component in parse_go_sum(path, path.relative_to(root).as_posix()):
            existing = components.get(component["purl"])
            if existing:
                sources = set(existing["lockSource"].split(","))
                sources.add(component["lockSource"])
                existing["lockSource"] = ",".join(sorted(sources))
            else:
                components[component["purl"]] = component
    for parser, path in ((parse_pnpm_lock, inputs[3]), (parse_pub_lock, inputs[4])):
        relative = path.relative_to(root).as_posix()
        for component in parser(path, relative):
            components[component["purl"]] = component

    digest = hashlib.sha256()
    for path in inputs:
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return sorted(components.values(), key=lambda item: item["purl"]), digest.hexdigest()


def normalize_license(value: object) -> str:
    if isinstance(value, dict):
        value = value.get("type") or value.get("name") or ""
    if isinstance(value, list):
        parts = sorted({normalize_license(item) for item in value} - {"NOASSERTION"})
        return " OR ".join(parts) if parts else "NOASSERTION"
    if not isinstance(value, str) or not value.strip():
        return "NOASSERTION"
    text = value.strip()
    aliases = {
        "apache 2.0": "Apache-2.0",
        "apache-2": "Apache-2.0",
        "apache license 2.0": "Apache-2.0",
        "bsd": "BSD-3-Clause",
        "bsd*": "BSD-3-Clause",
        "bsd-2-clause-freebsd": "BSD-2-Clause-FreeBSD",
        "cc0": "CC0-1.0",
        "public domain": "Unlicense",
        "unlicensed": "Unlicense",
        "wtfpl": "WTFPL",
    }
    if text.lower() in aliases:
        return aliases[text.lower()]
    if text.startswith("SEE LICENSE IN "):
        return "NOASSERTION"
    return text.replace("Licence", "License")


def detect_license_text(text: str) -> str:
    lower = " ".join(text.lower().split())
    # MPL's definition of "Secondary License" names GPL/AGPL, so detect MPL
    # before looking for GNU license titles elsewhere in the document.
    if "mozilla public license" in lower and "2.0" in lower:
        return "MPL-2.0"
    if "gnu affero general public license" in lower:
        return "AGPL-3.0-only" if "version 3" in lower else "AGPL-1.0-only"
    if "gnu lesser general public license" in lower:
        if "version 3" in lower:
            return "LGPL-3.0-only"
        return "LGPL-2.1-only" if "2.1" in lower else "LGPL-2.0-only"
    if "gnu general public license" in lower:
        if "version 3" in lower:
            return "GPL-3.0-only"
        return "GPL-2.0-only" if "version 2" in lower else "GPL-1.0-only"
    if "apache license" in lower and "version 2.0" in lower:
        return "Apache-2.0"
    if "permission is hereby granted, free of charge" in lower:
        return "MIT"
    if "redistribution and use in source and binary forms" in lower:
        if "neither the name" in lower or "contributors may be used to endorse" in lower:
            return "BSD-3-Clause"
        return "BSD-2-Clause"
    if "permission to use, copy, modify, and/or distribute this software" in lower:
        return "ISC"
    if "creative commons zero" in lower or "cc0 1.0 universal" in lower:
        return "CC0-1.0"
    if "this is free and unencumbered software released into the public domain" in lower:
        return "Unlicense"
    if "zlib license" in lower or ("altered source versions must be plainly marked" in lower and "misrepresented" in lower):
        return "Zlib"
    return "NOASSERTION"


def license_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    return sorted(
        path for path in directory.iterdir()
        if path.is_file() and LICENSE_FILE_RE.match(path.name)
    )


def normalized_legal_text(data: bytes) -> str | None:
    """Decode a legal text losslessly and normalize line endings for bundling."""
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text if text.endswith("\n") else text + "\n"


def add_legal_text(store: dict[str, dict], filename: str, data: bytes) -> str | None:
    text = normalized_legal_text(data)
    if text is None:
        return None
    digest = sha256_bytes(text.encode("utf-8"))
    record = store.setdefault(digest, {"observedFilenames": [], "text": text})
    if record.get("text") != text:
        raise RuntimeError(f"SHA-256 collision while collecting license text: {digest}")
    filenames = set(record.get("observedFilenames", []))
    filenames.add(filename)
    record["observedFilenames"] = sorted(filenames)
    return digest


def evidence_from_directory(
    directory: Path, metadata_license: object = None
) -> tuple[dict[str, object], dict[str, dict]]:
    normalized = normalize_license(metadata_license)
    candidates = license_files(directory)
    evidence_parts: list[bytes] = []
    detected: list[str] = []
    texts: dict[str, dict] = {}
    text_ids: list[str] = []
    for path in candidates:
        data = path.read_bytes()
        evidence_parts.append(path.name.encode() + b"\0" + data)
        text_id = add_legal_text(texts, path.name, data)
        if text_id:
            text_ids.append(text_id)
        detected_license = detect_license_text(data.decode("utf-8", errors="replace"))
        if detected_license != "NOASSERTION":
            detected.append(detected_license)
    if normalized == "NOASSERTION" and detected:
        normalized = " AND ".join(sorted(set(detected)))
    metadata = json.dumps(metadata_license, sort_keys=True).encode() if metadata_license else b""
    evidence_parts.append(b"metadata\0" + metadata)
    return {
        "license": normalized,
        "evidenceSha256": sha256_bytes(b"\0".join(evidence_parts)),
        "evidenceFiles": ", ".join(path.name for path in candidates) or "package metadata only",
        "textSha256s": sorted(set(text_ids)),
    }, texts


def npm_directories(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    store = root / "frontend/node_modules/.pnpm"
    if not store.is_dir():
        return result
    for package_json in store.glob("*/node_modules/*/package.json"):
        try:
            metadata = json.loads(read_text(package_json))
        except (OSError, json.JSONDecodeError):
            continue
        name, version = metadata.get("name"), metadata.get("version")
        if isinstance(name, str) and isinstance(version, str):
            result[purl("npm", name, version)] = package_json.parent
    for package_json in store.glob("*/node_modules/@*/*/package.json"):
        try:
            metadata = json.loads(read_text(package_json))
        except (OSError, json.JSONDecodeError):
            continue
        name, version = metadata.get("name"), metadata.get("version")
        if isinstance(name, str) and isinstance(version, str):
            result[purl("npm", name, version)] = package_json.parent
    return result


def pub_directories() -> dict[str, Path]:
    result: dict[str, Path] = {}
    pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))
    hosted = pub_cache / "hosted/pub.dev"
    if not hosted.is_dir():
        return result
    for pubspec in hosted.glob("*/pubspec.yaml"):
        name = version = None
        for line in read_text(pubspec).splitlines():
            match = re.match(r"^(name|version):\s*(.+)$", line)
            if match:
                if match.group(1) == "name":
                    name = unquote_yaml_scalar(match.group(2))
                else:
                    version = unquote_yaml_scalar(match.group(2))
        if name and version:
            result[purl("pub", name, version)] = pubspec.parent
    return result


def go_zip_evidence() -> tuple[dict[str, dict[str, object]], dict[str, dict]]:
    result: dict[str, dict[str, str]] = {}
    texts: dict[str, dict] = {}
    caches: set[Path] = set()
    go_module_cache = os.environ.get("GOMODCACHE")
    if go_module_cache:
        caches.add(Path(go_module_cache) / "cache/download")
    go_path = os.environ.get("GOPATH")
    if go_path:
        caches.update(Path(part) / "pkg/mod/cache/download" for part in go_path.split(os.pathsep))
    # Keep refresh useful in shells where GOPATH is configured through `go
    # env` but is not exported. This is a local read-only discovery step.
    caches.add(Path.home() / "go/pkg/mod/cache/download")
    caches.update(Path.home().glob("go*/pkg/mod/cache/download"))
    for cache in sorted(caches):
        if not cache.is_dir():
            continue
        for archive in cache.rglob("*.zip"):
            try:
                with zipfile.ZipFile(archive) as zf:
                    names = zf.namelist()
                    relative_parts = archive.relative_to(cache).parts
                    if "@v" not in relative_parts:
                        continue
                    version_index = relative_parts.index("@v")
                    module = "/".join(relative_parts[:version_index])
                    version = archive.name.removesuffix(".zip")
                    # Go's module cache escapes uppercase characters as !x.
                    module = re.sub(r"!([a-z])", lambda match: match.group(1).upper(), module)
                    key = purl("go", module, version)
                    archive_prefix = names[0].split("@" + version + "/", 1)[0] + "@" + version + "/" if names else ""
                    matches = sorted(
                        name for name in names
                        if name.startswith(archive_prefix)
                        and "/" not in name[len(archive_prefix):]
                        and LICENSE_FILE_RE.match(name[len(archive_prefix):])
                    )
                    payloads: list[bytes] = []
                    detected: list[str] = []
                    text_ids: list[str] = []
                    for name in matches:
                        data = zf.read(name)
                        filename = name.rsplit("/", 1)[1]
                        payloads.append(filename.encode() + b"\0" + data)
                        text_id = add_legal_text(texts, filename, data)
                        if text_id:
                            text_ids.append(text_id)
                        license_id = detect_license_text(data.decode("utf-8", errors="replace"))
                        if license_id != "NOASSERTION":
                            detected.append(license_id)
                    result[key] = {
                        "license": " AND ".join(sorted(set(detected))) if detected else "NOASSERTION",
                        "evidenceSha256": sha256_bytes(b"\0".join(payloads)),
                        "evidenceFiles": ", ".join(name.rsplit("/", 1)[1] for name in matches) or "none found",
                        "textSha256s": sorted(set(text_ids)),
                    }
            except (OSError, zipfile.BadZipFile):
                continue
    return result, texts


def merge_text_stores(target: dict[str, dict], incoming: dict[str, dict]) -> None:
    for digest, record in incoming.items():
        existing = target.get(digest)
        if existing and existing.get("text") != record.get("text"):
            raise RuntimeError(f"SHA-256 collision while merging license texts: {digest}")
        filenames = set(existing.get("observedFilenames", []) if existing else [])
        filenames.update(record.get("observedFilenames", []))
        target[digest] = {
            "observedFilenames": sorted(filenames),
            "text": record["text"],
        }


def refresh_evidence(
    root: Path,
    components: list[dict[str, str]],
    previous: dict,
    previous_texts: dict,
) -> tuple[dict, dict]:
    entries = dict(previous.get("entries", {}))
    texts = dict(previous_texts.get("texts", {}))
    npm_dirs = npm_directories(root)
    pub_dirs = pub_directories()
    go_evidence, go_texts = go_zip_evidence()
    merge_text_stores(texts, go_texts)
    flutter_license = None
    flutter_home = os.environ.get("FLUTTER_ROOT")
    if flutter_home and (Path(flutter_home) / "LICENSE").is_file():
        flutter_license = Path(flutter_home) / "LICENSE"

    for component in components:
        key = component["purl"]
        observed: dict[str, object] | None = None
        observed_texts: dict[str, dict] = {}
        source = ""
        if component["ecosystem"] == "npm" and key in npm_dirs:
            directory = npm_dirs[key]
            metadata = json.loads(read_text(directory / "package.json"))
            observed, observed_texts = evidence_from_directory(
                directory, metadata.get("license") or metadata.get("licenses")
            )
            source = "installed package metadata/license file"
        elif component["ecosystem"] == "pub" and key in pub_dirs:
            observed, observed_texts = evidence_from_directory(pub_dirs[key])
            source = "pub cache license file"
        elif component["ecosystem"] == "pub" and component.get("source") == "sdk" and flutter_license:
            data = flutter_license.read_bytes()
            text_id = add_legal_text(observed_texts, "Flutter SDK LICENSE", data)
            observed = {
                "license": detect_license_text(data.decode("utf-8", errors="replace")),
                "evidenceSha256": sha256_bytes(data),
                "evidenceFiles": "Flutter SDK LICENSE",
                "textSha256s": [text_id] if text_id else [],
            }
            source = "local Flutter SDK license"
        elif component["ecosystem"] == "go" and key in go_evidence:
            observed = go_evidence[key]
            source = "Go module cache archive license file"
        if observed:
            observed["source"] = source
            entries[key] = observed
            merge_text_stores(texts, observed_texts)

    live = {component["purl"] for component in components}
    entries = {key: entries[key] for key in sorted(entries) if key in live}
    for entry in entries.values():
        entry.setdefault("textSha256s", [])
    referenced = {
        text_id
        for entry in entries.values()
        for text_id in entry.get("textSha256s", [])
    }
    texts = {digest: texts[digest] for digest in sorted(referenced) if digest in texts}
    return (
        {"schemaVersion": SCHEMA_VERSION, "entries": entries},
        {"schemaVersion": SCHEMA_VERSION, "texts": texts},
    )


def classify(license_expression: str, policy: dict) -> str:
    expression = license_expression.upper()
    if license_expression == "NOASSERTION" or not license_expression:
        return "unknown"
    for category in ("incompatible", "strong-copyleft", "weak-copyleft"):
        for marker in policy.get("licenseMarkers", {}).get(category, []):
            # A bare substring would incorrectly classify LGPL as GPL and
            # AGPL as GPL. SPDX identifiers are token-like, so require a
            # non-alphanumeric boundary before each configured marker.
            if re.search(r"(?<![A-Z0-9])" + re.escape(marker.upper()), expression):
                return category
    return "permissive-or-notice"


def audit(components: list[dict[str, str]], evidence: dict, policy: dict) -> tuple[list[dict], list[dict]]:
    audited: list[dict] = []
    violations: list[dict] = []
    acknowledgements = policy.get("acknowledgements", {})
    fail_on = set(policy.get("failOn", []))
    for component in components:
        item = dict(component)
        observation = evidence.get("entries", {}).get(component["purl"], {})
        item["license"] = normalize_license(observation.get("license"))
        item["licenseCategory"] = classify(item["license"], policy)
        item["evidence"] = observation.get("source", "missing")
        item["evidenceSha256"] = observation.get("evidenceSha256", "")
        item["licenseTextSha256s"] = observation.get("textSha256s", [])
        item["noticeStatus"] = "collected" if item["licenseTextSha256s"] else "missing-license-text"
        audited.append(item)
        category = item["licenseCategory"]
        category_acknowledgements = acknowledgements.get(category, {})
        acknowledged = (
            isinstance(category_acknowledgements, dict)
            and bool(category_acknowledgements.get(component["purl"], "").strip())
        )
        if category in fail_on and not acknowledged:
            violation = dict(item)
            violation["violationCategory"] = category
            violations.append(violation)
        if item["noticeStatus"] in fail_on:
            # Package metadata is not a substitute for the legal text needed
            # in a distributable notice bundle. Missing text cannot be waived
            # into existence by a policy acknowledgement.
            violation = dict(item)
            violation["violationCategory"] = item["noticeStatus"]
            violations.append(violation)
    return audited, violations


def spdx_id(index: int) -> str:
    return f"SPDXRef-Package-{index:04d}"


def make_sbom(components: list[dict], lock_digest: str, scope_gaps: list[dict] | None = None) -> dict:
    packages = []
    relationships = []
    for index, component in enumerate(components, start=1):
        identifier = spdx_id(index)
        package = {
            "SPDXID": identifier,
            "name": component["name"],
            "versionInfo": component["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": component["license"],
            "copyrightText": "NOASSERTION",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": component["purl"],
            }],
            "comment": (
                f"Inventory source: {component['lockSource']}; "
                f"policy category: {component['licenseCategory']}; "
                f"license evidence: {component['evidence']}; "
                f"license text: {component['noticeStatus']}"
            ),
        }
        integrity = component.get("integrity", "")
        if integrity.startswith("sha256:") and re.fullmatch(r"[0-9a-fA-F]{64}", integrity[7:]):
            package["checksums"] = [{"algorithm": "SHA256", "checksumValue": integrity[7:].lower()}]
        elif integrity.startswith("sha512-"):
            try:
                package["checksums"] = [{"algorithm": "SHA512", "checksumValue": base64.b64decode(integrity[7:]).hex()}]
            except ValueError:
                pass
        packages.append(package)
        relationships.append({
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": identifier,
        })
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "PrivateDeploy third-party dependency inventory",
        "documentNamespace": f"https://privatedeploy.invalid/sbom/{lock_digest}",
        "creationInfo": {
            "created": SPDX_CREATED,
            "creators": ["Tool: scripts/license_audit.py"],
            "comment": "Deterministic timestamp; lock digest is encoded in the document namespace.",
        },
        "documentComment": (
            "Generated from checked-in dependency locks. go.sum entries are a conservative "
            "inventory and can include superseded module versions. License identifiers are "
            "observations, not legal conclusions. "
            + (
                "This document is not a complete release SBOM while release inventory scope "
                "gaps remain; see third_party/release-inventory-scope.json."
                if scope_gaps else
                "All required release inventory scopes are marked covered."
            )
        ),
        "packages": packages,
        "relationships": relationships,
    }


def make_notice(
    components: list[dict],
    lock_digest: str,
    violations: list[dict],
    release_scope: dict | None = None,
    scope_gaps: list[dict] | None = None,
) -> str:
    release_scope = release_scope or {"scopes": []}
    scope_gaps = scope_gaps or []
    counts: dict[str, int] = {}
    ecosystems: dict[str, int] = {}
    for component in components:
        counts[component["licenseCategory"]] = counts.get(component["licenseCategory"], 0) + 1
        ecosystems[component["ecosystem"]] = ecosystems.get(component["ecosystem"], 0) + 1
    text_count = sum(component["noticeStatus"] == "collected" for component in components)
    issue_rows = [
        component for component in components
        if component["licenseCategory"] != "permissive-or-notice"
        or component["noticeStatus"] != "collected"
    ]
    blocking_components = len({item["purl"] for item in violations})
    lines = [
        "# Third-party licensing notice",
        "",
        "PrivateDeploy is licensed under GPL-3.0. Third-party packages retain",
        "their upstream licenses; see [LICENSE](LICENSE) for PrivateDeploy's terms.",
        "",
        "> This file is generated by `python3 scripts/license_audit.py`. License",
        "> identifiers are automated observations from package metadata/license files,",
        "> not legal advice or a GPL compatibility determination.",
        "",
        "## Inventory summary",
        "",
        f"- Lock digest: `{lock_digest}`",
        f"- Components: {len(components)} (Go {ecosystems.get('go', 0)}, npm {ecosystems.get('npm', 0)}, pub {ecosystems.get('pub', 0)})",
        f"- Permissive/notice: {counts.get('permissive-or-notice', 0)}",
        f"- Weak copyleft: {counts.get('weak-copyleft', 0)}",
        f"- Strong copyleft: {counts.get('strong-copyleft', 0)}",
        f"- Incompatible policy matches: {counts.get('incompatible', 0)}",
        f"- Unknown/no evidence: {counts.get('unknown', 0)}",
        f"- Components with collected LICENSE/NOTICE text: {text_count}",
        f"- Components missing distributable license text: {len(components) - text_count}",
        f"- Blocking findings: {len(violations)} across {blocking_components} components",
        f"- Release inventory scope gaps: {len(scope_gaps)}",
        "",
        "The machine-readable component list is",
        "[`third_party/sbom.spdx.json`](third_party/sbom.spdx.json). The Go list is",
        "conservative: `go.sum` may retain superseded versions, which are included rather",
        "than silently omitted.",
        "The distributable, deduplicated original-text bundle is",
        "[`third_party/THIRD_PARTY_NOTICES.txt`](third_party/THIRD_PARTY_NOTICES.txt).",
        "",
        "## Release inventory coverage",
        "",
        "The component count above covers checked-in Go, npm and pub locks. Native",
        "mobile resolution and toolchain redistribution notices are separate required",
        "scopes; a blocked row means this notice and SPDX document are intentionally",
        "incomplete for that release artifact and the stable gate must remain red.",
        "",
        "| Scope | Status | Evidence or blocker |",
        "|---|---|---|",
    ]
    for item in release_scope.get("scopes", []):
        detail = ", ".join(item.get("evidenceFiles", [])) if item.get("status") == "covered" else item.get("reason", "")
        lines.append(f"| `{item['id']}` | {item['status']} | {detail} |")
    lines.extend([
        "",
        "## Findings requiring attention",
        "",
    ])
    if issue_rows:
        lines.extend([
            "| License category | Notice text | Component | Observed license | Evidence |",
            "|---|---|---|---|---|",
        ])
        for item in issue_rows:
            lines.append(
                f"| {item['licenseCategory']} | {item['noticeStatus']} | `{item['purl']}` | "
                f"`{item['license']}` | {item['evidence']} |"
            )
    else:
        lines.append("No non-permissive or unknown observations were detected.")
    lines.extend([
        "",
        "## Gate policy",
        "",
        "The checked-in policy unconditionally blocks missing license text. It also blocks",
        "unknown, strong-copyleft, and known-incompatible observations unless the exact",
        "versioned purl is explicitly acknowledged with a non-empty review reason in",
        "`third_party/license-policy.json`. Weak-copyleft observations",
        "are reported but are not automatically declared incompatible. A passing gate",
        "means only that the declared policy was satisfied; final distribution decisions",
        "still require qualified legal review.",
        "",
        "## Reproduce offline",
        "",
        "```bash",
        "python3 scripts/license_audit.py --check",
        "```",
        "",
        "To refresh evidence after dependencies are already installed locally:",
        "",
        "```bash",
        "FLUTTER_ROOT=/path/to/flutter python3 scripts/license_audit.py --refresh-evidence",
        "```",
        "",
        "The script never invokes a package manager and never downloads dependencies.",
        "",
    ])
    return "\n".join(lines)


def make_license_bundle(components: list[dict], texts: dict) -> str:
    """Render one distributable bundle with a purl-to-deduplicated-text map."""
    text_records = texts.get("texts", {})
    references: dict[str, list[str]] = {digest: [] for digest in text_records}
    lines = [
        "PRIVATEDEPLOY THIRD-PARTY LICENSE AND NOTICE BUNDLE",
        "",
        "Generated deterministically by scripts/license_audit.py.",
        "Texts are copied only from locally available top-level LICENSE, COPYING,",
        "COPYRIGHT, or NOTICE files. UTF-8 BOMs and line endings are normalized;",
        "the wording is otherwise unchanged. Absence from this bundle is not a",
        "license conclusion and is a release-blocking audit finding.",
        "",
        "COMPONENT TO TEXT MAP",
        "=====================",
    ]
    for component in components:
        text_ids = component.get("licenseTextSha256s", [])
        rendered = ", ".join(text_ids) if text_ids else "MISSING"
        lines.append(f"{component['purl']} -> {rendered}")
        for digest in text_ids:
            references.setdefault(digest, []).append(component["purl"])

    lines.extend(["", "DEDUPLICATED LICENSE AND NOTICE TEXTS", "=====================================", ""])
    for digest in sorted(text_records):
        record = text_records[digest]
        lines.extend([
            "=" * 80,
            f"Text-SHA256: {digest}",
            "Observed-Filenames: " + ", ".join(record.get("observedFilenames", [])),
            "Applies-To:",
        ])
        for component_purl in sorted(references.get(digest, [])):
            lines.append(f"  - {component_purl}")
        lines.extend(["-" * 80, record["text"].rstrip("\n"), ""])
    return "\n".join(lines) + "\n"


def load_json(path: Path, default: dict | None = None) -> dict:
    if not path.is_file():
        if default is not None:
            return default
        raise RuntimeError(f"missing required file: {path}")
    value = json.loads(read_text(path))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object: {path}")
    return value


def validate_release_scope(root: Path, release_scope: dict) -> list[dict]:
    if release_scope.get("schemaVersion") != SCHEMA_VERSION:
        raise RuntimeError("unsupported release inventory scope schema version")
    scopes = release_scope.get("scopes")
    if not isinstance(scopes, list):
        raise RuntimeError("release inventory scope must contain a scopes array")
    by_id: dict[str, dict] = {}
    for item in scopes:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise RuntimeError("invalid release inventory scope entry")
        identifier = item["id"]
        if identifier in by_id:
            raise RuntimeError(f"duplicate release inventory scope: {identifier}")
        if identifier not in REQUIRED_RELEASE_SCOPES:
            raise RuntimeError(f"unknown release inventory scope: {identifier}")
        status = item.get("status")
        if status not in {"covered", "blocked"}:
            raise RuntimeError(f"release inventory scope {identifier} has invalid status: {status}")
        if status == "covered":
            evidence_files = item.get("evidenceFiles")
            if (
                not isinstance(evidence_files, list)
                or not evidence_files
                or not all(isinstance(path, str) and path for path in evidence_files)
            ):
                raise RuntimeError(f"covered release inventory scope {identifier} needs evidenceFiles")
            missing = [path for path in evidence_files if not (root / path).is_file()]
            if missing:
                raise RuntimeError(
                    f"covered release inventory scope {identifier} has missing evidence: {', '.join(missing)}"
                )
        elif not isinstance(item.get("reason"), str) or not item["reason"].strip():
            raise RuntimeError(f"blocked release inventory scope {identifier} needs a reason")
        by_id[identifier] = item
    missing_scopes = sorted(set(REQUIRED_RELEASE_SCOPES) - set(by_id))
    if missing_scopes:
        raise RuntimeError("missing required release inventory scopes: " + ", ".join(missing_scopes))
    return [
        by_id[identifier]
        for identifier in REQUIRED_RELEASE_SCOPES
        if by_id[identifier]["status"] == "blocked"
    ]


def validate_evidence(components: list[dict[str, str]], evidence: dict, texts: dict) -> None:
    entries = evidence.get("entries")
    if not isinstance(entries, dict):
        raise RuntimeError("license evidence entries must be a JSON object")
    live = {component["purl"] for component in components}
    stale = sorted(set(entries) - live)
    if stale:
        raise RuntimeError(
            "license evidence contains components absent from current locks: "
            + ", ".join(stale[:5])
            + (" ..." if len(stale) > 5 else "")
        )
    text_records = texts.get("texts")
    if not isinstance(text_records, dict):
        raise RuntimeError("license text store must contain a JSON object named texts")
    for digest, record in text_records.items():
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RuntimeError(f"invalid license text key: {digest}")
        if not isinstance(record, dict) or not isinstance(record.get("text"), str):
            raise RuntimeError(f"invalid license text record: {digest}")
        if sha256_bytes(record["text"].encode("utf-8")) != digest:
            raise RuntimeError(f"license text SHA-256 mismatch: {digest}")
        filenames = record.get("observedFilenames")
        if not isinstance(filenames, list) or not all(isinstance(name, str) for name in filenames):
            raise RuntimeError(f"invalid observed filenames for license text: {digest}")
    referenced: set[str] = set()
    for key, entry in entries.items():
        if not isinstance(entry, dict):
            raise RuntimeError(f"invalid license evidence object: {key}")
        if not isinstance(entry.get("license"), str) or not entry["license"].strip():
            raise RuntimeError(f"missing observed license in evidence: {key}")
        if not isinstance(entry.get("source"), str) or not entry["source"].strip():
            raise RuntimeError(f"missing evidence source: {key}")
        if not re.fullmatch(r"[0-9a-f]{64}", entry.get("evidenceSha256", "")):
            raise RuntimeError(f"invalid evidence SHA-256: {key}")
        text_ids = entry.get("textSha256s")
        if not isinstance(text_ids, list) or not all(isinstance(value, str) for value in text_ids):
            raise RuntimeError(f"invalid license text references: {key}")
        missing_texts = sorted(set(text_ids) - set(text_records))
        if missing_texts:
            raise RuntimeError(f"missing referenced license text for {key}: {missing_texts[0]}")
        referenced.update(text_ids)
    orphaned = sorted(set(text_records) - referenced)
    if orphaned:
        raise RuntimeError(f"unreferenced license text record: {orphaned[0]}")


def write_or_check(path: Path, content: str, check: bool, errors: list[str]) -> None:
    if check:
        if not path.is_file() or read_text(path) != content:
            errors.append(f"stale generated file: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--evidence", type=Path, default=Path("third_party/license-evidence.json"))
    parser.add_argument("--texts", type=Path, default=Path("third_party/license-texts.json"))
    parser.add_argument("--policy", type=Path, default=Path("third_party/license-policy.json"))
    parser.add_argument("--scope", type=Path, default=Path("third_party/release-inventory-scope.json"))
    parser.add_argument("--output", type=Path, default=Path("third_party/sbom.spdx.json"))
    parser.add_argument("--notice", type=Path, default=Path("THIRD_PARTY_LICENSES.md"))
    parser.add_argument("--bundle", type=Path, default=Path("third_party/THIRD_PARTY_NOTICES.txt"))
    parser.add_argument("--refresh-evidence", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    root = args.root.resolve()

    def rooted(path: Path) -> Path:
        return path if path.is_absolute() else root / path

    evidence_path, texts_path, policy_path = rooted(args.evidence), rooted(args.texts), rooted(args.policy)
    scope_path = rooted(args.scope)
    output_path, notice_path, bundle_path = rooted(args.output), rooted(args.notice), rooted(args.bundle)
    try:
        components, lock_digest = inventory(root)
        evidence = load_json(evidence_path, {"schemaVersion": SCHEMA_VERSION, "entries": {}})
        texts = load_json(texts_path, {"schemaVersion": SCHEMA_VERSION, "texts": {}})
        policy = load_json(policy_path)
        release_scope = load_json(scope_path)
        scope_gaps = validate_release_scope(root, release_scope)
        lock_digest = sha256_bytes(
            (lock_digest + "\0" + canonical_json(release_scope)).encode("utf-8")
        )
        if evidence.get("schemaVersion") != SCHEMA_VERSION or texts.get("schemaVersion") != SCHEMA_VERSION:
            raise RuntimeError("unsupported license evidence/text schema version")
        if args.refresh_evidence:
            if args.check:
                raise RuntimeError("--refresh-evidence and --check are mutually exclusive")
            evidence, texts = refresh_evidence(root, components, evidence, texts)
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(canonical_json(evidence), encoding="utf-8")
            texts_path.parent.mkdir(parents=True, exist_ok=True)
            texts_path.write_text(canonical_json(texts), encoding="utf-8")
        validate_evidence(components, evidence, texts)
        audited, violations = audit(components, evidence, policy)
        sbom = make_sbom(audited, lock_digest, scope_gaps)
        notice = make_notice(audited, lock_digest, violations, release_scope, scope_gaps)
        bundle = make_license_bundle(audited, texts)
        errors: list[str] = []
        write_or_check(output_path, canonical_json(sbom), args.check, errors)
        write_or_check(notice_path, notice, args.check, errors)
        write_or_check(bundle_path, bundle, args.check, errors)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
        if violations:
            for item in violations:
                print(
                    f"ERROR: {item['violationCategory']}: {item['purl']} "
                    f"({item['license']}, evidence={item['evidence']})",
                    file=sys.stderr,
                )
        for item in scope_gaps:
            print(
                f"ERROR: release-scope-gap: {item['id']} "
                f"({REQUIRED_RELEASE_SCOPES[item['id']]}: {item['reason']})",
                file=sys.stderr,
            )
        print(
            f"Audited {len(audited)} locked components; "
            f"{len(violations)} blocking component finding(s); "
            f"{len(scope_gaps)} release inventory scope gap(s)."
        )
        return 1 if errors or violations or scope_gaps else 0
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
