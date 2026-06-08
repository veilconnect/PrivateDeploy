# PrivateDeploy Mobile

**English** | [中文](README.zh-CN.md)

The Flutter mobile client for PrivateDeploy. The current focus is to make the "manage and use self-hosted nodes directly from your phone" pipeline complete.

## Current Status

- The main entry point is a workbench page that aggregates VPN status, cloud nodes, and local configurations.
- The Android native VPN path is wired up, supporting direct connect, disconnect, restart, and reading basic traffic statistics.
- The iOS project, plugin, and `VPNExtension` already exist, but the native VPN requires additionally embedding `VPNCore.framework` at build time.
- `flutter analyze` and `flutter test` both currently pass.

## Implemented Capabilities

- VPN connection management
  - Connect, disconnect, restart
  - Connection status and basic traffic statistics
  - Native capability probing and unsupported notices
- Vultr cloud node management
  - Save and validate API Key
  - Fetch region, plan, and instance lists
  - Create and delete nodes directly on the phone
  - Convert node information into locally usable sing-box configurations
- Configuration file management
  - Create local configurations
  - Edit and view configuration content
  - Activate and delete local configurations
- Subscription import
  - Fetch subscriptions from a URL
  - Parse common proxy URIs / response content and convert them into sing-box configurations
- Cloud backup
  - Export API Key and locally saved node records
  - Restore from a backup JSON
- Node details
  - View Shadowsocks / Hysteria2 / VLESS / Trojan parameters
  - Copy individual parameters and the entire group of links

## Cloud Provider Support

- **Vultr** — full flow (list region/plan, create, delete, node recovery)
- **DigitalOcean** — full flow (aligned with Vultr); you can switch the currently active provider at the top of the Settings → API Key dialog. Each provider's API Key and node records are namespace-isolated locally (`mobile_cloud_<provider>_api_key` / `..._nodes`), so switching does not lose data on the other side.

## Parts Not Yet Landed or Not Yet Productized

- Displaying nodes from multiple cloud providers simultaneously (currently a "single active provider"; the UI only shows the currently active provider's nodes at a time)
- A standalone rule-set management page
- Full multi-language UI integration
- Charts, notifications, etc. that depend on the corresponding product features
- Finer page splitting and navigation structure

## Tech Stack

- Flutter + Material 3
- `provider` state management
- `dio` network requests
- `hive` + `shared_preferences` + `flutter_secure_storage` local storage
- Flutter Platform Channel + native Android/iOS VPN plugins

## Directory Overview

```text
mobile/
├── android/
├── ios/
├── lib/
│   ├── main.dart
│   ├── core/
│   │   ├── storage/
│   │   └── subscription/
│   ├── features/
│   │   ├── cloud/
│   │   ├── home/
│   │   ├── nodes/
│   │   ├── profiles/
│   │   ├── settings/
│   │   └── vpn/
│   ├── services/
│   └── shared/
└── test/
```

## Development Requirements

- Flutter 3.x
- Dart 3.x
- Android Studio / Android SDK
- Xcode 15+ (iOS only)

This repository is currently validated locally with Flutter `3.35.7`.

## Common Commands

```bash
cd mobile
~/flutter/bin/flutter pub get
~/flutter/bin/flutter analyze
~/flutter/bin/flutter test
~/flutter/bin/flutter run
```

Android Release example:

```bash
cd mobile
~/flutter/bin/flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
```

## Platform Notes

### Android

- The VPN Service is located at `android/app/src/main/kotlin/com/privatedeploy/mobile/`
- Debug builds allow cleartext traffic; the main manifest no longer enables cleartext traffic globally by default
- Release build signing can be injected via `key.properties` or environment variables

#### Emulator Debugging Image Choice (Important)

When running a **Flutter debug APK** on the Android emulator, use the `google_apis/x86_64` system image, **do not** use `default/x86_64`.

In practice, on the default x86_64 images for API 33 / API 34, Flutter fails to load `kernel_blob.bin`:

```
E flutter : Dart Error: Can't load Kernel binary: Invalid kernel binary: Indicated size is invalid.
E flutter : Could not prepare isolate.
E flutter : Could not create root isolate.
```

Symptom: the native process stays alive, but the app remains stuck on the Splash Logo forever, looking like a slow startup. You can see the above error in `flutter run` / `adb logcat`.

- Only affects **debug** builds (JIT, loading dill at runtime); release uses AOT (`libapp.so`), does not read kernel_blob, and is **not affected**
- APIs verified as not affected: 31 / 32 / 35 / 36 (regardless of image type) and API 34 google_apis
- AVDs verified as having the problem: API 33 default, API 34 default
- Troubleshooting approach: if the UI is stuck on Splash, first run `adb logcat | grep "Could not create root isolate"`; if it hits, switch to a google_apis image or switch to a release build

### iOS

iOS is a **beta / build-dependent** platform: the Swift plugin and PacketTunnel extension skeleton are both in place, but all native VPN entry points are wrapped in `#if canImport(VPNCore)`, and without the `VPNCore.framework` embedded they only return an explicit unsupported error (they will not pretend to be able to connect). To make the VPN actually usable on iOS, you need to run through the gomobile framework build and configure signing and entitlements as described in [`IOS_INTEGRATION.md`](IOS_INTEGRATION.md):

1. **Compile VPNCore.framework with gomobile**

   ```bash
   cd mobile/gomobile
   ./build-ios.sh
   ```

   The artifact is written to `mobile/ios/VPNCore.framework`; drag it into the Runner target in Xcode and select *Embed & Sign*.

2. **App Group**: Enable `App Groups` on both the main App and the `VPNExtension` targets, and add `group.com.privatedeploy.mobile` (or customize it and then change `PrivateDeployVPNAppGroup` in `Info.plist`).

3. **Network Extension**: Enable `Network Extensions → Packet Tunnel` for both targets.

4. **Signing capability**: Use an Apple Developer account that has the `Network Extensions` entitlement enabled, otherwise `NETunnelProviderManager.saveToPreferences` will fail.

5. In the main App's `Info.plist`, confirm that `PrivateDeployVPNExtensionBundleIdentifier` points to the actual bundle id of `VPNExtension`.

Features not covered on the iOS platform (compared to desktop):

- There is no counterpart to the `RepairCloudInstance` desktop RPC: the iOS side can only go through delete + recreate (`cloud_provider.dart.repairInstance` is internally `_createInstance(redeployLabel)`), and cannot repair the same machine in place like the desktop SSH provider can
- The VPN system status stream only returns a static unsupported event when there is no `VPNCore.framework`, and will not proactively push status changes

> Account status probing (DO locked / Vultr firewall 50/50) is already covered on all platforms (iOS + Android) via `CloudApiClient.getAccountStatus` (a pure Dart implementation).

## Testing

### Unit + Widget Tests

```bash
cd mobile
~/flutter/bin/flutter analyze
~/flutter/bin/flutter test
```

The current `test/` mainly covers:

- `vpn_provider_test.dart` — VPN state transitions, the startup probe degraded path, `stopDegradedSession`
- `nodes_vpn_actions_test.dart` — all branches of `connectSelectedProfile` / `handleNodesConnect` / `autoFailoverToNextCloudNode`
  - Including Hive saved-archive failover, upstream-degraded node cycling, and the startup probe inconclusive case not retrying nodes
- `nodes_cloud_actions_test.dart` — `confirmRepairCloudNode` node repair confirmation + active SSH route disconnecting first
- `cloud_provider_test.dart` — `redeployInstanceLabel` uniquification + `selectFastestConnectableInstance` caching
- `cloud_node_config_builder_test.dart` — sing-box outbound construction + the CDN-fronted vless+ws variant
- `vultr_client_test.dart` / `digitalocean_client_test.dart` — the REST clients' request shape and error normalization
- `profile_provider_test.dart` / `cloud_backup_test.dart` — Profile storage and configuration normalization, cloud backup restore
- `subscription_parser_test.dart` — the subscription parser

### Integration Tests

Require a connected Android/iOS device or emulator. Run:

```bash
cd mobile
~/flutter/bin/flutter test integration_test/<file>.dart -d <device-id>
```

The current `integration_test/` covers:

- `smoke_test.dart` — home page core controls, API Key dialog, settings navigation, Profile creation, empty-node connect feedback
- `apikey_test.dart` — the instance list loads correctly after saving in the API Key dialog (`TestCloudProvider` stand-in)
- `settings_navigation_flow_test.dart` — settings page routing and back navigation
- `phone_interop_test.dart` — device interoperability
- `vpn_dead_node_failure_test.dart` — import a dead-node subscription → connection fails → returns to disconnected state and shows a failure notice

### Out of Scope

The following scenarios are currently out of the automated testing scope and require local manual testing or building dedicated mock infrastructure later:

- **Full connect success path**: the sing-box side actually establishes the tunnel, egress IP verification. Requires starting a local mock proxy server as the `PD_TEST_SUBSCRIPTION_URL` upstream.
- **Real cloud deployment**: the end-to-end flow of Vultr/DigitalOcean instance creation currently relies on manual verification (cost and time are not suitable for CI).
- **iOS on-device integration tests**: `integration_test/` has so far only been verified on Android devices; iOS needs to be run by local Xcode after embedding `VPNCore.framework`.

## Known Improvement Directions

- Continue splitting `features/nodes/nodes_screen.dart`
- Split the workbench page into a clearer navigation structure
- Keep the README in sync with the product's actual capabilities to avoid the documentation drifting again
