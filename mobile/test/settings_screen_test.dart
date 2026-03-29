import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/settings/settings_screen.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';

import 'support/nodes_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboardText;

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'PrivateDeploy',
      packageName: 'com.example.privatedeploy',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          clipboardText = args['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return <String, dynamic>{'text': clipboardText};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('SettingsScreen', () {
    testWidgets('renders masked api key, provider, vpn status and version',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        apiKey: 'abcd1234efgh',
      );
      final vpnProvider = TestVpnProvider(status: VpnStatus.connected);
      final appSettingsProvider = TestAppSettingsProvider();

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: vpnProvider,
        appSettingsProvider: appSettingsProvider,
        settle: true,
      );

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('abcd1234...'), findsOneWidget);
      expect(find.text('vultr (direct)'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Routing Mode'), findsOneWidget);
      expect(find.text('局域网直连、国内域名直连、国内 IP 直连'), findsOneWidget);
      expect(find.text('1.2.3 (45)'), findsOneWidget);
    });

    testWidgets('switches routing mode to global and updates summary',
        (tester) async {
      final appSettingsProvider = TestAppSettingsProvider();

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: appSettingsProvider,
        settle: true,
      );

      await tester.tap(find.text('全局'));
      await tester.pumpAndSettle();

      expect(
          appSettingsProvider.vpnRoutingSettings.mode, VpnRoutingMode.global);
      expect(find.textContaining('默认全部走 VPN'), findsOneWidget);
    });

    testWidgets('saves custom routing rules from dialog', (tester) async {
      final appSettingsProvider = TestAppSettingsProvider();

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: appSettingsProvider,
        settle: true,
      );

      await tester.tap(find.text('Routing Rules'));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'openai.com\ncorp.local');
      await tester.enterText(fields.at(3), '203.0.113.0/24');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        appSettingsProvider.vpnRoutingSettings.customDirectDomains,
        ['openai.com', 'corp.local'],
      );
      expect(
        appSettingsProvider.vpnRoutingSettings.customProxyCidrs,
        ['203.0.113.0/24'],
      );
      expect(find.text('Routing rules saved'), findsOneWidget);
    });

    testWidgets('shows validation errors for invalid routing CIDR',
        (tester) async {
      final appSettingsProvider = TestAppSettingsProvider();

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: appSettingsProvider,
        settle: true,
      );

      await tester.tap(find.text('Routing Rules'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(2), '10.0.0.0/99');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid CIDR prefix: 10.0.0.0/99'), findsOneWidget);
      expect(find.text('分流规则'), findsOneWidget);
    });

    testWidgets('saves api key from dialog and shows success message',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        apiKey: 'old-key',
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.tap(find.text('API Key'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  new-key  ');
      await tester.tap(find.text('Verify & Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.savedApiKey, 'new-key');
      expect(cloudProvider.loadInstancesCalls, 1);
      expect(find.text('API key saved and verified'), findsOneWidget);
    });

    testWidgets('shows api key save errors inside the dialog', (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: false,
        error: 'Invalid API key',
        setApiKeyResult: false,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.tap(find.text('API Key'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'bad-key');
      await tester.tap(find.text('Verify & Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.savedApiKey, 'bad-key');
      expect(cloudProvider.loadInstancesCalls, 0);
      expect(find.text('Invalid API key'), findsOneWidget);
      expect(find.text('Verify & Save'), findsOneWidget);
    });

    testWidgets('clears local cloud data and shows snackbar', (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        apiKey: 'abcd1234efgh',
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.tap(find.text('Clear Local Cloud Data'));
      await tester.pumpAndSettle();

      expect(cloudProvider.clearLocalCloudDataCalls, 1);
      expect(cloudProvider.apiKey, isNull);
      expect(find.text('Local cloud data cleared'), findsOneWidget);
    });

    testWidgets('exports cloud backup to clipboard and shows dialog',
        (tester) async {
      const payload = '{"provider":"vultr","apiKey":"secret"}';
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        exportBackupPayload: payload,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester
          .ensureVisible(find.widgetWithText(ListTile, 'Copy Cloud Backup'));
      await tester.tap(find.widgetWithText(ListTile, 'Copy Cloud Backup'));
      await tester.pumpAndSettle();

      expect(find.text('Cloud Backup Copied'), findsOneWidget);
      expect(find.textContaining('already been copied'), findsOneWidget);
      expect(clipboardText, payload);

      await tester.tap(find.text('Copy Again'));
      await tester.pumpAndSettle();

      expect(find.text('Backup copied again'), findsOneWidget);
      expect(clipboardText, payload);
    });

    testWidgets('restores cloud backup from clipboard', (tester) async {
      const payload = '{"provider":"vultr","apiKey":"secret"}';
      final cloudProvider = TestCloudProvider(hasApiKey: true);
      clipboardText = payload;

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.ensureVisible(
        find.widgetWithText(ListTile, 'Restore Cloud Backup'),
      );
      await tester.tap(find.widgetWithText(ListTile, 'Restore Cloud Backup'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.importedBackupPayload, payload);
      expect(find.text('Cloud backup restored'), findsOneWidget);
    });

    testWidgets('shows restore backup errors inside the dialog',
        (tester) async {
      const payload = '{"provider":"vultr","apiKey":"secret"}';
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
      )..importBackupError = 'Invalid backup';
      clipboardText = payload;

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: cloudProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.ensureVisible(
        find.widgetWithText(ListTile, 'Restore Cloud Backup'),
      );
      await tester.tap(find.widgetWithText(ListTile, 'Restore Cloud Backup'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.importedBackupPayload, payload);
      expect(find.text('Invalid backup'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    });
  });
}
