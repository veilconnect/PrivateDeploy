# Stable release checklist

This checklist separates repository automation from external approvals. A
stable release is a **NO-GO** until every required row has evidence attached to
the release record.

## Automated repository gates

- `bash scripts/check_versions.sh`
- `bash scripts/check_release_ldflags.sh`
- `scripts/secret_scan.sh`
- root, API, provider race, frontend, Flutter, and gomobile test suites
- website manifest check and post-build checksum comparison
- desktop signature verification and Apple notarization stapling
- Android/iOS package signature verification
- generated third-party component/license inventory and SBOM audit

The tag release workflow must fail closed when a signing credential or a
signature verification step is missing. Configuring a secret is not evidence
that an artifact was signed; the verification output is the evidence.

## External evidence

| Evidence | How to obtain it | Repository can provide it alone? |
| --- | --- | --- |
| Apple Developer ID + notarization credentials | Apple Developer / App Store Connect | No |
| Windows Authenticode certificate | trusted code-signing CA | No |
| Android upload/release keystore | product owner secure storage | No |
| iOS distribution certificate/profile/entitlements | Apple Developer portal | No |
| Vultr + DigitalOcean live API report | run `Stable Cloud Live Smoke` in the protected `stable-release` environment | Requires test-account secrets |
| Android/iOS real-device result | approved physical-device lab | No |
| third-party license legal approval | counsel reviews generated inventory and exceptions | No |

## Cloud live gate

The workflow `.github/workflows/cloud-live-smoke.yml` is manual and attaches to
the protected `stable-release` GitHub Environment. It performs only read-only
API operations and cannot incur resource charges. Locally:

```bash
VULTR_API_KEY=... DIGITALOCEAN_API_KEY=... \
  bash scripts/cloud_live_readonly_gate.sh
```

The generated report excludes credentials and is rejected if either raw key is
found in it. Billable create/deploy/destroy testing is intentionally not
automated without a separately approved budget and cleanup policy.

## Human sign-off

Record the exact tag, commit SHA, workflow run URLs, artifact checksums,
signature identities, notarization result, live-cloud report, device matrix,
and legal approval. Do not use a standing bypass variable as a substitute for
per-release approval.
