# Release Signing & Notarization

The stable-tag workflow (`.github/workflows/release.yml`) is wired for mandatory
Windows Authenticode signing and macOS Developer ID signing/notarization. It
accepts only stable `vX.Y.Z` tags and has **no unsigned-release bypass**. A
stable release stops at preflight if any required secret is absent; each
platform job also stops before packaging if signing or verification fails.

Linux zip archives are not platform code-signed. They remain covered by the
published `checksums.sha256`; signing that checksum manifest with a project GPG
release key is a separate future hardening step and is not required by the
current release gate.

After all platform archives and `checksums.sha256` pass manifest verification,
the release job uses `actions/attest-build-provenance@v4` to issue GitHub/Sigstore
SLSA provenance for every zip and the checksum file. The OIDC and attestation
write permissions are scoped to the release job. Consumers can verify a
download with `gh attestation verify <file> --repo veilconnect/PrivateDeploy`;
this provenance complements, but does not replace, platform code signing.

## Required repository secrets

Configure all ten values as GitHub Actions repository or release-environment
secrets. Use single-line base64 for binary/key files; never paste raw private
key material into workflow files, logs, artifacts, repository variables, or
issue comments.

| Secret | Format and purpose |
| --- | --- |
| `MACOS_SIGNING_CERT_P12` | Single-line base64 of a Developer ID Application certificate and private key (`.p12`) |
| `MACOS_SIGNING_CERT_PASSWORD` | Password protecting that `.p12` |
| `MACOS_SIGNING_CERT_SHA256` | Pinned 64-hex SHA-256 fingerprint of the Developer ID certificate |
| `APPLE_DEVELOPER_TEAM_ID` | Team ID that must appear in the single Developer ID Application identity |
| `APPLE_NOTARY_API_KEY` | Single-line base64 of an App Store Connect API private key (`AuthKey_*.p8`) |
| `APPLE_NOTARY_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_API_ISSUER` | App Store Connect API issuer ID |
| `WINDOWS_SIGNING_CERT_PFX` | Single-line base64 of a trusted Authenticode code-signing certificate and private key (`.pfx`) |
| `WINDOWS_SIGNING_CERT_PASSWORD` | Password protecting that `.pfx` |
| `WINDOWS_SIGNING_CERT_SHA256` | Pinned 64-hex SHA-256 fingerprint of the Authenticode certificate |

Encode files locally without printing their contents to a shared terminal log:

```bash
openssl base64 -A -in DeveloperIDApplication.p12 > macos-signing.p12.b64
openssl base64 -A -in AuthKey_EXAMPLE.p8 > notary-api-key.p8.b64
openssl base64 -A -in Authenticode.pfx > windows-signing.pfx.b64
```

Copy each generated file's contents directly into the corresponding GitHub
secret, then securely delete the temporary `.b64` files. The macOS P12 should
contain exactly one usable `Developer ID Application` identity. The Windows
PFX must contain a private key and the Code Signing EKU
(`1.3.6.1.5.5.7.3.3`).

## What the workflow enforces

### macOS

The macOS job decodes credentials into runner-temporary files, imports the P12
into a randomly passworded temporary keychain, and selects a Developer ID
Application identity, requires its Team ID and SHA-256 fingerprint to match
the pinned secrets, and for each architecture then:

1. signs the `.app` with a secure timestamp and Hardened Runtime;
2. runs strict `codesign` verification and checks the runtime flag;
3. submits a temporary zip to `xcrun notarytool submit --wait` using the App
   Store Connect API key;
4. staples and validates the notarization ticket;
5. runs final `codesign` and Gatekeeper (`spctl`) assessments; and
6. creates the release zip with macOS metadata-preserving `ditto`; and
7. extracts that final zip and repeats `codesign`, stapler, and Gatekeeper
   validation on the exact app users will download.

The temporary P12, API key, notarization archives and keychain are deleted by
an `always()` cleanup step. GitHub-hosted runners are ephemeral, but this
cleanup is retained as defense in depth.

### Windows

The Windows job decodes the PFX into a runner-temporary file, imports it into
the current user's certificate store using a `SecureString`, records only its
non-secret thumbprint, and immediately removes the temporary PFX. For every
architecture it:

1. signs the executable with SHA-256 Authenticode and an RFC 3161 DigiCert
   timestamp;
2. verifies Windows Authenticode policy with `signtool verify`;
3. checks `Get-AuthenticodeSignature` is `Valid` and matches the imported
certificate thumbprint and pinned SHA-256 fingerprint; and
4. only then creates the release zip.

An `always()` cleanup step removes the imported private-key certificate from
the runner certificate store.

## Credential and first-release validation

Before creating the first production tag:

1. restrict secret administration and release approval to designated
   maintainers; use a protected GitHub release environment if available;
2. run `bash scripts/check_release_signing.sh` locally;
3. create a disposable test repository or temporary correctly versioned tag
   and observe both platform jobs with real credentials;
4. download the produced archives on clean macOS and Windows machines;
5. verify macOS with `codesign --verify --deep --strict`, `xcrun stapler
   validate`, and `spctl --assess --type execute`;
6. verify Windows with `signtool verify /pa /all /v PrivateDeploy.exe`; and
7. revoke/delete any test tag and assets rather than reusing them as a stable
   release.

Credential expiry, revocation, Apple agreement changes, timestamp-service
availability and notarization-service failures are external operational risks.
The workflow cannot validate those without real credentials and a live run;
its stable gate intentionally fails closed when they occur.
