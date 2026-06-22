import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/security/encrypted_share.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_backup.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/settings/settings_backup_preview_card.dart';
import 'package:privatedeploy_mobile/features/settings/settings_screen.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';

import 'support/nodes_test_support.dart';

class _NoisyTestVpnProvider extends TestVpnProvider {
  _NoisyTestVpnProvider({
    required super.status,
    super.diagnosticsEgressIp,
    super.diagnosticsUpdatedAt,
  });

  Timer? _timer;

  void startNotifications({
    Duration interval = const Duration(milliseconds: 16),
  }) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => notifyListeners());
  }

  void stopNotifications() {
    _timer?.cancel();
    _timer = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboardText;
  final vpnChannel = const MethodChannel('com.privatedeploy.vpn/native');

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, (call) async {
      switch (call.method) {
        case 'getInstalledApps':
          return [
            {
              'packageName': 'com.android.chrome',
              'label': 'Chrome',
            },
            {
              'packageName': 'org.telegram.messenger',
              'label': 'Telegram',
            },
          ];
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, null);
  });

  group('SettingsScreen', () {
    testWidgets('renders masked api key, routing controls and version',
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
      // Bug J fix: API key list view now masks the value entirely instead of
      // exposing the first 8 characters in plain text.
      expect(find.text('abcd1234...'), findsNothing);
      expect(find.textContaining('abcd1234'), findsNothing);
      expect(find.text('•••• (12 chars)'), findsOneWidget);
      expect(find.text('Vultr · direct access'), findsNothing);
      expect(find.textContaining('Saved cloud access stays'), findsNothing);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Routing Mode'), findsOneWidget);
      expect(find.text('VPN Diagnostics'), findsOneWidget);
      expect(find.text('Routing Rules'), findsOneWidget);
      expect(
          find.text(
              'LAN direct · regional apps direct · CN domains direct · CN IPs direct · regional optimized DNS'),
          findsOneWidget);
      expect(find.text('1.2.3 (45)'), findsOneWidget);
    });

    testWidgets(
        'renders provider-specific settings copy for the active cloud provider',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        apiKey: 'do1234567890',
        providerId: CloudProviderId.digitalocean,
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

      await tester.ensureVisible(find.text('Clear Local Cloud Data'));
      await tester.tap(find.text('Clear Local Cloud Data'));
      await tester.pumpAndSettle();

      expect(find.textContaining('saved DigitalOcean access'), findsOneWidget);
    });

    testWidgets(
        'does not preselect Vultr in the API key dialog on a fresh install',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: false,
        hasPersistedActiveProviderSelection: false,
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

      expect(find.text('Vultr'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Verify & Save'), findsOneWidget);
      final verifyButton = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Verify & Save'));
      expect(verifyButton.onPressed, isNull);
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

      await tester.tap(find.text('Global'));
      await tester.pumpAndSettle();

      expect(
          appSettingsProvider.vpnRoutingSettings.mode, VpnRoutingMode.global);
      expect(find.textContaining('All traffic via VPN'), findsOneWidget);
    });

    testWidgets('opens diagnostics screen and renders diagnostics content',
        (tester) async {
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.connected,
        diagnosticsEgressIp: '203.0.113.42',
        diagnosticsUpdatedAt: DateTime(2026, 3, 30, 7, 10, 0),
        recentRouteDecisions: [
          VpnRouteDecision(
            timestamp: DateTime(2026, 3, 30, 7, 10, 1),
            type: VpnRouteDecisionType.direct,
            outboundType: 'direct',
            outboundTag: 'direct',
            target: '198.51.100.11:443',
            domain: 'www.baidu.com',
          ),
          VpnRouteDecision(
            timestamp: DateTime(2026, 3, 30, 7, 10, 2),
            type: VpnRouteDecisionType.proxy,
            outboundType: 'shadowsocks',
            outboundTag: '新加坡-SS',
            target: '198.51.100.13:443',
            domain: 'www.wikipedia.org',
          ),
        ],
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        vpnProvider: vpnProvider,
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.ensureVisible(find.text('VPN Diagnostics'));
      await tester.tap(find.text('VPN Diagnostics'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(vpnProvider.activateDiagnosticsSessionCalls, 1);
      expect(vpnProvider.refreshDiagnosticsCalls, 1);
      expect(find.text('VPN Diagnostics'), findsWidgets);
      expect(find.text('Exit IP'), findsOneWidget);
      expect(find.text('203.0.113.42'), findsOneWidget);
      expect(find.text('Apps bypassing VPN'), findsOneWidget);
      expect(find.text('WeChat'), findsOneWidget);
      expect(find.text('Alipay'), findsOneWidget);
      expect(find.text('+22 more'), findsOneWidget);
      expect(find.text('www.baidu.com -> 198.51.100.11:443'), findsOneWidget);
      expect(
        find.text('www.wikipedia.org -> 198.51.100.13:443'),
        findsOneWidget,
      );
      expect(find.text('DIRECT'), findsOneWidget);
      expect(find.text('PROXY'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(vpnProvider.deactivateDiagnosticsSessionCalls, 1);
    });

    testWidgets(
        'still opens diagnostics while connected provider keeps notifying',
        (tester) async {
      final vpnProvider = _NoisyTestVpnProvider(
        status: VpnStatus.connected,
        diagnosticsEgressIp: '203.0.113.42',
        diagnosticsUpdatedAt: DateTime(2026, 3, 30, 7, 10, 0),
      );

      addTearDown(vpnProvider.stopNotifications);

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        vpnProvider: vpnProvider,
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      vpnProvider.startNotifications();

      await tester.ensureVisible(find.text('VPN Diagnostics'));
      await tester.tap(find.text('VPN Diagnostics'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      vpnProvider.stopNotifications();

      expect(find.text('Exit IP'), findsOneWidget);
      expect(vpnProvider.activateDiagnosticsSessionCalls, 1);
      expect(vpnProvider.refreshDiagnosticsCalls, 1);
    });

    testWidgets('shows clearer diagnostics copy when egress probe fails',
        (tester) async {
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.connected,
        diagnosticsEgressIp: null,
        diagnosticsError: VpnProvider.egressProbeFailureMessage,
        diagnosticsUpdatedAt: DateTime(2026, 3, 30, 7, 10, 0),
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const SettingsScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        vpnProvider: vpnProvider,
        appSettingsProvider: TestAppSettingsProvider(),
        settle: true,
      );

      await tester.ensureVisible(find.text('VPN Diagnostics'));
      await tester.tap(find.text('VPN Diagnostics'));
      await tester.pump();
      await tester.pumpAndSettle();

      // When no IP has ever been confirmed, show "Checking egress..." rather
      // than a scary "unavailable" label — the VPN tunnel is up and still
      // forwarding traffic; only the probe hasn't landed a result yet. The
      // underlying diagnostic error stays in the hint.
      expect(find.text('Checking egress...'), findsOneWidget);
      expect(
        find.text(VpnProvider.egressProbeFailureMessage),
        findsOneWidget,
      );
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
      await tester.tap(find.text('Save'));
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

    testWidgets('saves DNS mode from routing rules dialog', (tester) async {
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

      await tester.tap(find.text('regional optimized DNS').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Strict proxy DNS').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        appSettingsProvider.vpnRoutingSettings.dnsMode,
        VpnDnsMode.strictProxy,
      );
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
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid CIDR prefix: 10.0.0.0/99'), findsOneWidget);
      expect(find.text('Routing Rules'), findsOneWidget);
    });

    testWidgets('saves app-based routing selections from dialog',
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

      await tester.tap(find.text('Direct apps'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chrome'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Proxied apps'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telegram'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        appSettingsProvider.vpnRoutingSettings.customDirectPackages,
        ['com.android.chrome'],
      );
      expect(
        appSettingsProvider.vpnRoutingSettings.customProxyPackages,
        ['org.telegram.messenger'],
      );
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
      expect(find.text('Cloud access saved and verified'), findsOneWidget);
    });

    testWidgets('shows api key save errors inside the dialog', (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: false,
        error: 'Invalid API key',
        hasPersistedActiveProviderSelection: true,
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

    testWidgets('confirms before clearing local cloud data', (tester) async {
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

      await tester.tap(find.widgetWithText(ListTile, 'Clear Local Cloud Data'));
      await tester.pumpAndSettle();

      expect(find.text('Clear Local Cloud Data?'), findsOneWidget);
      expect(cloudProvider.clearLocalCloudDataCalls, 0);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(cloudProvider.clearLocalCloudDataCalls, 0);
      expect(cloudProvider.apiKey, 'abcd1234efgh');

      await tester.tap(find.widgetWithText(ListTile, 'Clear Local Cloud Data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(cloudProvider.clearLocalCloudDataCalls, 1);
      expect(cloudProvider.apiKey, isNull);
      expect(find.text('Local cloud data cleared'), findsOneWidget);
    });

    testWidgets(
        'reviews backup summary before copying sensitive payload to clipboard',
        (tester) async {
      const payload =
          '{"version":1,"provider":"vultr","exportedAt":"2026-03-30T10:00:00.000Z","apiKey":"secret","nodeRecords":{"node-1":{"label":"ams-node"}}}';
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

      await tester.ensureVisible(
        find.widgetWithText(ListTile, 'Export Encrypted Cloud Backup'),
      );
      await tester.tap(
        find.widgetWithText(ListTile, 'Export Encrypted Cloud Backup'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cloud Backup Ready'), findsOneWidget);
      expect(find.textContaining('Review the backup summary'), findsOneWidget);
      expect(find.byType(SettingsBackupPreviewCard), findsOneWidget);
      expect(find.textContaining('"apiKey"'), findsNothing);
      expect(clipboardText, isNull);

      await tester.tap(find.text('Copy Encrypted Backup'));
      await tester.pumpAndSettle();
      expect(find.text('Copy Encrypted Backup?'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, 'backup-pass');
      await tester.enterText(find.byType(TextFormField).last, 'backup-pass');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Encrypted backup copied to clipboard'), findsOneWidget);
      expect(clipboardText, isNot(payload));
      expect(EncryptedShareCodec.looksEncrypted(clipboardText ?? ''), isTrue);

      await tester.tap(find.text('Reveal Encrypted Text'));
      await tester.pumpAndSettle();

      expect(find.text('Reveal Encrypted Backup?'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, 'backup-pass');
      await tester.enterText(find.byType(TextFormField).last, 'backup-pass');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.textContaining('PDENC1:'), findsOneWidget);
      expect(find.textContaining('"apiKey":"secret"'), findsNothing);
    });

    testWidgets('restores encrypted cloud backup from clipboard after preview',
        (tester) async {
      final payload = createCloudBackupJson(
        provider: vultrCloudBackupProvider,
        apiKey: 'secret',
        exportedAt: DateTime.utc(2026, 3, 30, 10),
        nodeRecords: const {
          'node-1': {'label': 'ams-node'},
        },
      );
      final encrypted = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.cloudBackup,
        content: payload,
        passphrase: 'backup-pass',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );
      final cloudProvider = TestCloudProvider(hasApiKey: true);
      clipboardText = encrypted;

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
        find.widgetWithText(ListTile, 'Import Encrypted Cloud Backup'),
      );
      await tester.tap(
        find.widgetWithText(ListTile, 'Import Encrypted Cloud Backup'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'backup-pass');
      await tester.pumpAndSettle();

      expect(find.byType(SettingsBackupPreviewCard), findsOneWidget);
      expect(find.textContaining('Nodes: ams-node'), findsOneWidget);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.text('Restore This Backup?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(cloudProvider.importedBackupPayload, isNull);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.importedBackupPayload, payload);
      expect(find.text('Cloud backup restored'), findsOneWidget);
    });

    testWidgets('shows restore backup errors inside the dialog',
        (tester) async {
      final payload = createCloudBackupJson(
        provider: vultrCloudBackupProvider,
        apiKey: 'secret',
        exportedAt: DateTime.utc(2026, 3, 30, 10),
        nodeRecords: const {
          'node-1': {'label': 'ams-node'},
        },
      );
      final encrypted = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.cloudBackup,
        content: payload,
        passphrase: 'backup-pass',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
      )..importBackupError = 'Invalid backup';
      clipboardText = encrypted;

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
        find.widgetWithText(ListTile, 'Import Encrypted Cloud Backup'),
      );
      await tester.tap(
        find.widgetWithText(ListTile, 'Import Encrypted Cloud Backup'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'backup-pass');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.importedBackupPayload, payload);
      expect(find.text('Invalid backup'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    });

    testWidgets('validates encrypted backup before allowing restore',
        (tester) async {
      clipboardText = 'not-encrypted';
      final cloudProvider = TestCloudProvider(hasApiKey: true);

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
        find.widgetWithText(ListTile, 'Import Encrypted Cloud Backup'),
      );
      await tester.tap(
        find.widgetWithText(ListTile, 'Import Encrypted Cloud Backup'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'backup-pass');
      await tester.pumpAndSettle();

      expect(
        find.text(
            'Encrypted content must start with the PrivateDeploy share prefix'),
        findsOneWidget,
      );
      expect(find.byType(SettingsBackupPreviewCard), findsNothing);
      expect(cloudProvider.importedBackupPayload, isNull);
    });
  });
}
