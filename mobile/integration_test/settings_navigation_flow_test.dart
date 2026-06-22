import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/settings/settings_screen.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/settings/settings_vpn_diagnostics_screen.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../test/support/nodes_test_support.dart';

class _SettingsNavigationHarness extends StatelessWidget {
  const _SettingsNavigationHarness();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          },
          child: const Text('Open Settings'),
        ),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const vpnChannel = MethodChannel('com.privatedeploy.vpn/native');

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'PrivateDeploy',
      packageName: 'com.example.privatedeploy',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, (call) async {
      switch (call.method) {
        case 'getInstalledApps':
          return [
            {
              'packageName': 'com.android.chrome',
              'label': 'Chrome',
            },
          ];
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, null);
  });

  testWidgets('navigates from settings to diagnostics and back',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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
      ],
    );

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (_, __) {
          return MultiProvider(
            providers: [
              ChangeNotifierProvider<CloudProvider>.value(
                value: TestCloudProvider(hasApiKey: false),
              ),
              ChangeNotifierProvider<VpnProvider>.value(value: vpnProvider),
              ChangeNotifierProvider<AppSettingsProvider>.value(
                value: TestAppSettingsProvider(),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: _SettingsNavigationHarness(),
            ),
          );
        },
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Open Settings'), findsOneWidget);

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);

    final diagnosticsEntry = find.byIcon(Icons.monitor_heart_outlined);
    await tester.scrollUntilVisible(
      diagnosticsEntry,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(diagnosticsEntry);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsVpnDiagnosticsScreen), findsOneWidget);
    expect(vpnProvider.activateDiagnosticsSessionCalls, 1);
    expect(vpnProvider.refreshDiagnosticsCalls, 1);

    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(vpnProvider.deactivateDiagnosticsSessionCalls, 1);

    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await tester.pumpAndSettle();

    expect(find.text('Open Settings'), findsOneWidget);
  });
}
