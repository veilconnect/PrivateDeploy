import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privatedeploy_mobile/core/subscription/parser.dart';
import 'package:privatedeploy_mobile/core/subscription/subscription_fetcher.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_backup.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:provider/provider.dart';

import 'package:privatedeploy_mobile/main.dart' as app;

const _mode = String.fromEnvironment('PD_IT_MODE', defaultValue: 'noop');
const _backupB64 = String.fromEnvironment('PD_BACKUP_B64', defaultValue: '');
const _subscriptionUrl = String.fromEnvironment('PD_SUB_URL', defaultValue: '');
const _profileName = String.fromEnvironment('PD_PROFILE_NAME', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone interop harness', (tester) async {
    app.main();
    await _pumpFor(tester, const Duration(seconds: 8));

    final context = tester.element(find.byType(MaterialApp));
    final cloud = Provider.of<CloudProvider>(context, listen: false);
    final profiles = Provider.of<ProfileProvider>(context, listen: false);

    switch (_mode) {
      case 'export-cloud-backup':
        await _exportCloudBackup(cloud);
        break;
      case 'import-cloud-backup':
        await _importCloudBackup(cloud);
        break;
      case 'import-subscription':
        await _importSubscription(profiles);
        break;
      default:
        fail('Unsupported PD_IT_MODE="$_mode"');
    }
  });
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final steps = duration.inMilliseconds ~/ 200;
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

Future<void> _exportCloudBackup(CloudProvider cloud) async {
  final payload = await cloud.exportBackupJson();
  final preview = inspectCloudBackupJson(
    payload,
    expectedProvider: cloud.providerName,
  );

  expect(preview.provider, cloud.providerName);
  print('PD_BACKUP_PROVIDER=${preview.provider}');
  print('PD_BACKUP_NODE_COUNT=${preview.nodeCount}');
  print('PD_BACKUP_HAS_API_KEY=${preview.includesApiKey}');
  print('PD_BACKUP_B64=${base64Encode(utf8.encode(payload))}');
}

Future<void> _importCloudBackup(CloudProvider cloud) async {
  expect(_backupB64, isNotEmpty, reason: 'PD_BACKUP_B64 is required');

  final raw = utf8.decode(base64Decode(_backupB64));
  final preview = inspectCloudBackupJson(
    raw,
    expectedProvider: cloud.providerName,
  );

  await cloud.importBackupJson(raw);

  expect(cloud.hasApiKey, isTrue);
  expect(cloud.instances.length, preview.nodeCount);

  print('PD_IMPORTED_PROVIDER=${cloud.providerName}');
  print('PD_IMPORTED_NODE_COUNT=${cloud.instances.length}');
  print('PD_IMPORTED_HAS_API_KEY=${cloud.hasApiKey}');
}

Future<void> _importSubscription(ProfileProvider profiles) async {
  expect(_subscriptionUrl, isNotEmpty, reason: 'PD_SUB_URL is required');

  final response = await fetchSubscriptionResponseData(_subscriptionUrl);
  final config = SubscriptionParser.parseResponseDataToSingboxConfig(response);
  expect(config, isNotNull, reason: 'subscription parser returned null');

  final profileName = _profileName.isNotEmpty
      ? _profileName
      : 'IT-${DateTime.now().millisecondsSinceEpoch}';

  final created = await profiles.createProfile(
    name: profileName,
    subscriptionUrl: _subscriptionUrl,
    content: config,
  );
  expect(created, isTrue, reason: profiles.error);

  final profile = profiles.getProfileByName(profileName);
  expect(profile, isNotNull);

  final activated = await profiles.activateProfile(profile!.id);
  expect(activated, isTrue, reason: profiles.error);

  print('PD_IMPORTED_PROFILE=$profileName');
  print('PD_IMPORTED_PROFILE_ID=${profile.id}');
  print('PD_IMPORTED_CONFIG_LEN=${config!.length}');
}
