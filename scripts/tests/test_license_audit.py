import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "license_audit.py"
SPEC = importlib.util.spec_from_file_location("license_audit", SCRIPT)
audit = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(audit)


class LicenseAuditTest(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        (root / "api").mkdir()
        (root / "mobile/gomobile").mkdir(parents=True)
        (root / "frontend").mkdir()
        (root / "mobile").mkdir(exist_ok=True)
        (root / "go.sum").write_text("example.com/a v1.0.0 h1:aaa=\n", encoding="utf-8")
        (root / "api/go.sum").write_text("example.com/a v1.0.0 h1:aaa=\nexample.com/b v2.0.0/go.mod h1:x=\n", encoding="utf-8")
        (root / "mobile/gomobile/go.sum").write_text("", encoding="utf-8")
        (root / "frontend/pnpm-lock.yaml").write_text(
            "lockfileVersion: '9.0'\npackages:\n\n  '@scope/pkg@2.1.0(peer@1.0.0)':\n"
            "    resolution: {integrity: sha512-YWJj}\n\nsnapshots:\n",
            encoding="utf-8",
        )
        (root / "mobile/pubspec.lock").write_text(
            "packages:\n  useful:\n    dependency: direct main\n    description:\n"
            "      sha256: abcdef\n    source: hosted\n    version: '3.2.1'\n",
            encoding="utf-8",
        )

    def test_inventory_is_deduplicated_and_lock_based(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repo(root)
            components, digest = audit.inventory(root)
            self.assertEqual(3, len(components))
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
            go = next(item for item in components if item["ecosystem"] == "go")
            self.assertEqual("api/go.sum,go.sum", go["lockSource"])
            npm = next(item for item in components if item["ecosystem"] == "npm")
            self.assertEqual("@scope/pkg", npm["name"])
            self.assertEqual("2.1.0", npm["version"])
            self.assertEqual("pkg:npm/%40scope/pkg@2.1.0", npm["purl"])
            pub = next(item for item in components if item["ecosystem"] == "pub")
            self.assertEqual("direct main", pub["scope"])

    def test_unknown_is_blocked_unless_exact_purl_acknowledged(self):
        component = {"purl": "pkg:npm/a@1", "name": "a", "version": "1", "ecosystem": "npm"}
        policy = {"failOn": ["unknown"], "licenseMarkers": {}, "acknowledgements": {"unknown": {}}}
        _, violations = audit.audit([component], {"entries": {}}, policy)
        self.assertEqual(1, len(violations))
        policy["acknowledgements"]["unknown"] = {component["purl"]: "reviewed test fixture"}
        _, violations = audit.audit([component], {"entries": {}}, policy)
        self.assertEqual([], violations)

    def test_incompatible_precedes_copyleft_and_spdx_is_deterministic(self):
        policy = {
            "failOn": ["incompatible"],
            "licenseMarkers": {"incompatible": ["AGPL-"], "strong-copyleft": ["GPL-"]},
            "acknowledgements": {},
        }
        self.assertEqual("incompatible", audit.classify("AGPL-3.0-only", policy))
        policy["licenseMarkers"]["weak-copyleft"] = ["LGPL-"]
        self.assertEqual("weak-copyleft", audit.classify("LGPL-3.0-only", policy))
        component = {
            "ecosystem": "pub", "name": "a", "version": "1", "purl": "pkg:pub/a@1",
            "lockSource": "mobile/pubspec.lock", "license": "MIT",
            "licenseCategory": "permissive-or-notice", "evidence": "test",
            "noticeStatus": "collected",
        }
        first = audit.canonical_json(audit.make_sbom([component], "a" * 64))
        second = audit.canonical_json(audit.make_sbom([component], "a" * 64))
        self.assertEqual(first, second)
        self.assertEqual(audit.SPDX_CREATED, json.loads(first)["creationInfo"]["created"])

    def test_license_text_detection(self):
        self.assertEqual("MIT", audit.detect_license_text("Permission is hereby granted, free of charge"))
        self.assertEqual("Apache-2.0", audit.detect_license_text("Apache License Version 2.0"))
        self.assertEqual("NOASSERTION", audit.detect_license_text("custom terms"))

    def test_stale_or_unverifiable_evidence_is_rejected(self):
        component = {"purl": "pkg:npm/a@1"}
        valid = {
            "entries": {
                component["purl"]: {
                    "license": "MIT", "source": "fixture",
                    "evidenceSha256": "a" * 64,
                    "textSha256s": [],
                }
            }
        }
        texts = {"texts": {}}
        audit.validate_evidence([component], valid, texts)
        with self.assertRaisesRegex(RuntimeError, "absent from current locks"):
            audit.validate_evidence([component], {"entries": {"pkg:npm/stale@1": {}}}, texts)
        valid["entries"][component["purl"]]["evidenceSha256"] = "not-a-digest"
        with self.assertRaisesRegex(RuntimeError, "invalid evidence SHA-256"):
            audit.validate_evidence([component], valid, texts)

    def test_license_texts_are_deduplicated_mapped_and_hash_checked(self):
        store = {}
        first = audit.add_legal_text(store, "LICENSE", b"same terms\r\n")
        second = audit.add_legal_text(store, "COPYING", b"same terms\n")
        self.assertEqual(first, second)
        self.assertEqual(["COPYING", "LICENSE"], store[first]["observedFilenames"])
        component = {
            "purl": "pkg:npm/a@1", "licenseTextSha256s": [first],
        }
        bundle = audit.make_license_bundle([component], {"texts": store})
        self.assertIn(f"pkg:npm/a@1 -> {first}", bundle)
        self.assertEqual(1, bundle.count("same terms"))
        evidence = {
            "entries": {
                component["purl"]: {
                    "license": "MIT", "source": "fixture", "evidenceSha256": "a" * 64,
                    "textSha256s": [first],
                }
            }
        }
        audit.validate_evidence([component], evidence, {"texts": store})
        store[first]["text"] = "tampered\n"
        with self.assertRaisesRegex(RuntimeError, "license text SHA-256 mismatch"):
            audit.validate_evidence([component], evidence, {"texts": store})

    def test_missing_license_text_is_not_acknowledgeable(self):
        component = {"purl": "pkg:npm/a@1", "name": "a", "version": "1", "ecosystem": "npm"}
        evidence = {
            "entries": {
                component["purl"]: {
                    "license": "MIT", "source": "metadata", "evidenceSha256": "a" * 64,
                    "textSha256s": [],
                }
            }
        }
        policy = {
            "failOn": ["missing-license-text"], "licenseMarkers": {},
            "acknowledgements": {"missing-license-text": {component["purl"]: "do not honor"}},
        }
        _, violations = audit.audit([component], evidence, policy)
        self.assertEqual("missing-license-text", violations[0]["violationCategory"])

    def test_generated_bundle_participates_in_stale_check(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "THIRD_PARTY_NOTICES.txt"
            path.write_text("old\n", encoding="utf-8")
            errors = []
            audit.write_or_check(path, "new\n", True, errors)
            self.assertEqual([f"stale generated file: {path}"], errors)
            self.assertEqual("old\n", path.read_text(encoding="utf-8"))

    def test_release_scope_is_explicit_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            covered_files = {
                "go-desktop": "go.sum",
                "go-api": "api/go.sum",
                "go-mobile": "mobile/gomobile/go.sum",
                "npm-frontend": "frontend/pnpm-lock.yaml",
                "pub-mobile": "mobile/pubspec.lock",
            }
            for evidence in covered_files.values():
                path = root / evidence
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n", encoding="utf-8")
            scopes = []
            for identifier in audit.REQUIRED_RELEASE_SCOPES:
                if identifier in covered_files:
                    scopes.append({
                        "id": identifier,
                        "status": "covered",
                        "evidenceFiles": [covered_files[identifier]],
                    })
                else:
                    scopes.append({"id": identifier, "status": "blocked", "reason": "fixture gap"})
            gaps = audit.validate_release_scope(root, {"schemaVersion": 1, "scopes": scopes})
            self.assertEqual(
                {"android-native", "ios-native", "flutter-engine-native"},
                {item["id"] for item in gaps},
            )
            scopes = [item for item in scopes if item["id"] != "ios-native"]
            with self.assertRaisesRegex(RuntimeError, "missing required release inventory scopes: ios-native"):
                audit.validate_release_scope(root, {"schemaVersion": 1, "scopes": scopes})


if __name__ == "__main__":
    unittest.main()
