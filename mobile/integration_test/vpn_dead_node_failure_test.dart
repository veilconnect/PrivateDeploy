import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_test_keys.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';

import 'package:privatedeploy_mobile/main.dart' as app;

const _subscriptionUrl = String.fromEnvironment(
  'PD_TEST_SUBSCRIPTION_URL',
  defaultValue: 'http://10.0.2.2:8765/sub.txt',
);
const _profileName = String.fromEnvironment(
  'PD_TEST_PROFILE_NAME',
  defaultValue: 'sstest',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dead node returns to disconnected with failure notice',
      (tester) async {
    final vpnNoticeCard = find.byKey(NodesTestKeys.vpnNoticeCard);
    final startupFailureText = find.descendant(
      of: vpnNoticeCard,
      matching: find.text(VpnProvider.startupConnectivityFailureMessage),
    );

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('Workspace'), findsOneWidget);
    expect(find.byKey(NodesTestKeys.importProfileFab), findsOneWidget);

    await tester.tap(find.byKey(NodesTestKeys.importProfileFab));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(NodesTestKeys.importProfileNameField),
      _profileName,
    );
    await tester.enterText(
      find.byKey(NodesTestKeys.importProfileUrlField),
      _subscriptionUrl,
    );
    await tester.tap(find.byKey(NodesTestKeys.importProfileSubmitButton));

    await _pumpUntil(
      tester,
      description: 'imported profile to appear as selected',
      timeout: const Duration(seconds: 20),
      condition: () =>
          find.text('Selected node: $_profileName').evaluate().isNotEmpty,
    );

    expect(find.text('Selected node: $_profileName'), findsOneWidget);

    await tester.tap(find.byKey(NodesTestKeys.connectButton));
    await tester.pump(const Duration(milliseconds: 250));

    await _pumpUntil(
      tester,
      description: 'VPN failure notice after dead-node startup probe',
      timeout: const Duration(seconds: 30),
      condition: () =>
          vpnNoticeCard.evaluate().isNotEmpty &&
          find.text('Disconnected').evaluate().isNotEmpty &&
          startupFailureText.evaluate().isNotEmpty &&
          find.text('Connect').evaluate().isNotEmpty &&
          find.text('Disconnect').evaluate().isEmpty &&
          find.text('Restart VPN').evaluate().isEmpty,
    );

    expect(find.text('Disconnected'), findsOneWidget);
    expect(vpnNoticeCard, findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Restart VPN'), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
    expect(startupFailureText, findsWidgets);
  });
}

Future<void> _pumpUntil(
  WidgetTester tester, {
  required String description,
  required Duration timeout,
  required bool Function() condition,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) {
      return;
    }
  }

  fail('Timed out waiting for $description after ${timeout.inSeconds}s');
}
