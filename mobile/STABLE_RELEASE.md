# Mobile stable-release runbook

The only stable mobile artifact path is
`.github/workflows/mobile-release.yml`. It is manual by design and must be run
from the exact `vX.Y.Z` tag matching `VERSION`. Branch builds and the ordinary
mobile CI workflows are not release channels.

The workflow fails closed: missing credentials, an unsigned output, a debug
certificate, a certificate fingerprint mismatch, an expired/wrong provisioning
profile, a missing VPN extension, or a checksum mismatch stops the release.

## Android repository secrets

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the release JKS/keystore (single line) |
| `ANDROID_KEY_ALIAS` | Release key alias |
| `ANDROID_KEY_PASSWORD` | Alias password |
| `ANDROID_STORE_PASSWORD` | Keystore password |
| `ANDROID_SIGNING_CERT_SHA256` | 64-hex SHA-256 fingerprint of the release certificate |

Generate the fingerprint without exposing a private key:

```bash
keytool -list -v -keystore release.jks -alias YOUR_ALIAS \
  | sed -n 's/.*SHA256: //p'
```

The keystore is decoded only under `RUNNER_TEMP`, Gradle is run with
`PRIVATEDEPLOY_REQUIRE_RELEASE_SIGNING=true`, and both the APK and AAB are
checked against the pinned certificate. The handoff artifact contains a
versioned APK, AAB, GPL license, dependency summary, complete third-party
notice bundle, SPDX SBOM, and
`checksums-android.sha256`.

## iOS repository secrets

| Secret | Value |
| --- | --- |
| `IOS_DISTRIBUTION_CERT_P12_BASE64` | Base64 of an Apple Distribution `.p12` |
| `IOS_DISTRIBUTION_CERT_PASSWORD` | Password for the `.p12` |
| `IOS_SIGNING_CERT_SHA256` | 64-hex SHA-256 certificate fingerprint |
| `IOS_APP_PROFILE_BASE64` | Distribution profile for `com.privatedeploy.mobile` |
| `IOS_VPN_EXTENSION_PROFILE_BASE64` | Distribution profile for `com.privatedeploy.mobile.VPNExtension` |
| `IOS_EXPORT_OPTIONS_BASE64` | Completed `ExportOptions.plist`, base64 encoded |
| `APPLE_TEAM_ID` | Apple Developer team ID used by all three files |

Start from [`ios/ExportOptions.example.plist`](ios/ExportOptions.example.plist).
Both provisioning profiles must be explicit (no wildcard), belong to the same
team, be unexpired, and contain the Network Extension/App Group capabilities
approved in the Apple Developer portal. The workflow installs them and the
certificate in runner-scoped locations, archives the app plus
`VPNExtension.appex`, exports the IPA, verifies both signatures and bundle IDs,
and then removes the temporary signing material.
`ExportOptions.plist` must omit `destination` or set it to `export`;
`destination=upload` is rejected so this signing workflow cannot upload to App
Store Connect as an implicit side effect.
The iOS handoff likewise includes the GPL license, third-party notices, SPDX
SBOM, and checksums alongside the IPA and dSYMs.

To compute a SHA-256 certificate fingerprint from the public certificate:

```bash
openssl x509 -in distribution.cer.pem -noout -fingerprint -sha256
```

## Running and publishing

1. Create and push the stable tag only after all normal CI gates pass.
2. In GitHub Actions, select **Mobile - Stable Release** and choose that tag.
   The `stable-release` GitHub Environment must have required reviewers and
   should hold all signing secrets listed above.
3. A `publish_assets=false` run is only a dry-run for checking configuration;
   its binaries must never be approved for a later run.
4. For the real release, start one run with `publish_assets=true`. After its
   Android/iOS build jobs finish, leave that same run's `publish` job waiting at
   the protected `stable-release` environment. Download the exact artifacts
   from that run and perform physical-device acceptance testing.
5. Approve the waiting `publish` job in that same workflow run. It re-downloads
   those exact artifacts, verifies their checksums, creates provenance, and only
   then uploads them. Do not re-run to publish: a rebuild is a different binary
   and invalidates the device acceptance result.

This workflow does **not** claim to exercise a real VPN tunnel, App Store
review, Play Console policy checks, staged rollout, or upgrade/migration on
user devices; those remain explicit human/device gates before publish approval.

The Linux-safe structural gate can be run locally without credentials:

```bash
bash mobile/scripts/check_stable_release_readiness.sh
```

That gate validates repository structure and secret hygiene only. A green local
result is not evidence of Apple/Android signing or device compatibility.
