import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_test_keys.dart';

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
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

  expect(find.byKey(NodesTestKeys.connectButton), findsOneWidget);
    expect(find.byKey(NodesTestKeys.importProfileFab), findsOneWidget);

    await tester.tap(find.byKey(NodesTestKeys.importProfileFab));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(NodesTestKeys.importProfileNameField),
      _profileName,
    );
    await tester.enterText(
      find.byKey(NodesTestKeys.importProfilePayloadField),
      _subscriptionUrl,
    );
    await tester.tap(find.byKey(NodesTestKeys.importProfileSubmitButton));

    await _pumpUntil(
      tester,
      description: 'imported profile to appear in the current UI',
      timeout: const Duration(seconds: 20),
      condition: () => find.text(_profileName).evaluate().isNotEmpty,
    );

    expect(find.text(_profileName), findsWidgets);

    await tester.tap(find.byKey(NodesTestKeys.connectButton));
    await tester.pump(const Duration(milliseconds: 250));

    await _pumpUntil(
      tester,
      description: 'VPN failure notice after dead-node startup probe',
      timeout: const Duration(seconds: 30),
      condition: () =>
          vpnNoticeCard.evaluate().isNotEmpty &&
          find.byKey(NodesTestKeys.connectButton).evaluate().isNotEmpty &&
          find.byKey(NodesTestKeys.restartButton).evaluate().isEmpty,
    );

    expect(vpnNoticeCard, findsOneWidget);
    expect(find.byKey(NodesTestKeys.restartButton), findsNothing);
    expect(find.byKey(NodesTestKeys.connectButton), findsOneWidget);
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
