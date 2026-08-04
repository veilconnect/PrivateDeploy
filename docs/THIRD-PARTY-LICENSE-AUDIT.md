# Third-party license and SBOM audit

PrivateDeploy maintains a conservative, lockfile-derived dependency inventory
at `third_party/sbom.spdx.json`. The inventory covers all checksum entries in
the three Go modules, all package resolutions in `frontend/pnpm-lock.yaml`, and
all packages in `mobile/pubspec.lock`.

That component inventory is not described as a complete mobile SBOM.
`third_party/release-inventory-scope.json` separately tracks mandatory release
surfaces. Android Gradle/Maven/SDK artifacts, iOS CocoaPods artifacts, and the
pinned Flutter engine/native redistribution notices currently remain explicit
`blocked` scopes. The audit fails even if every existing component finding is
resolved, until those resolved graphs and their legal texts are checked in.

The release-ready legal-text output is
`third_party/THIRD_PARTY_NOTICES.txt`. It begins with an exact component purl to
text-SHA256 map, followed by each distinct LICENSE/COPYING/COPYRIGHT/NOTICE text
once. This avoids copying dependency source trees or repeating identical MIT,
BSD, and other standard texts for every component.

## Design and reproducibility

`scripts/license_audit.py` separates two concerns:

1. Component identity and version come only from committed locks/checksums.
2. License observations come from `third_party/license-evidence.json`, keyed by
   an exact versioned package URL (purl).
3. Normalized original legal texts are stored by content hash in
   `third_party/license-texts.json`; evidence entries reference those hashes.

This makes `--check` deterministic and offline. It does not invoke Go, pnpm,
Flutter, or any network client. The generated SPDX document uses a fixed
creation timestamp and includes the combined lockfile digest in its namespace.
Go checksum files are intentionally treated conservatively: superseded module
versions can remain in `go.sum`, and those versions stay in the inventory.

## Updating dependencies

After the normal package-manager install has completed, refresh the evidence
from local caches and regenerate the outputs:

```bash
FLUTTER_ROOT=/path/to/flutter \
  python3 scripts/license_audit.py --refresh-evidence
python3 scripts/license_audit.py --check
python3 -m unittest discover -s scripts/tests -p 'test_license_audit.py'
```

The refresh operation only reads installed package metadata, top-level license
files, Go module cache zip files, and the Flutter SDK license. It never
downloads missing packages. A missing observation remains `NOASSERTION` and is
blocked by policy rather than guessed.

Only locally available top-level LICENSE, LICENCE, COPYING, COPYRIGHT, and
NOTICE files are copied into the legal-text store. UTF-8 BOMs and CRLF/CR line
endings are normalized so identical wording deduplicates across platforms; the
wording itself is not rewritten. Non-UTF-8 or missing text is not guessed from
an SPDX identifier or package description: the affected component remains a
`missing-license-text` release blocker.

Review the evidence diff. In particular, do not acknowledge an unknown or
copyleft component merely to make CI green. An acknowledgement must name the
exact purl in `third_party/license-policy.json` and provide a non-empty review
reason. The reason records why the exception exists; it is not a legal opinion.
`missing-license-text` is intentionally not acknowledgeable: the release must
obtain the actual local legal text or remain blocked.

## Gate policy and legal boundary

The default policy fails on:

- components without a locally evidenced, distributable license/notice text;
- unknown or missing license evidence;
- strong-copyleft observations;
- markers for known incompatible or source-available/noncommercial terms.
- any required release inventory scope still marked `blocked`.

Weak-copyleft licenses are reported and require contextual review, but the
script does not automatically declare them incompatible. Likewise, a clean
result is evidence that the repository's mechanical policy passed; it is not a
legal opinion, a complete notice bundle, or a guarantee of GPL-3.0
compatibility. Final release approval remains a qualified human decision.

Stable archives include the generated `THIRD_PARTY_LICENSES.md` summary,
`third_party/sbom.spdx.json`, and `third_party/THIRD_PARTY_NOTICES.txt` legal
text bundle. The stable tag workflow reruns this audit before packaging, so
stale or unacknowledged findings cannot ship.
