import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privatedeploy_mobile/features/settings/settings_api_key_dialog.dart';

import '../test/support/nodes_test_support.dart';

class _ApiKeyDialogHarness extends StatelessWidget {
  final TestCloudProvider cloud;

  const _ApiKeyDialogHarness({required this.cloud});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton(
        onPressed: () =>
            showSettingsApiKeyDialog(context: context, cloud: cloud),
        child: const Text('Open API Key'),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('api key dialog saves and loads cloud instances', (tester) async {
    final cloudProvider = TestCloudProvider(
      hasApiKey: false,
      loadedInstances: [readyCloudTestInstance(label: 'node-260414050401')],
    );

    await pumpNodesTestApp(
      tester,
      child: _ApiKeyDialogHarness(cloud: cloudProvider),
      cloudProvider: cloudProvider,
      settle: true,
    );

    expect(find.text('Open API Key'), findsOneWidget);

    await tester.tap(find.text('Open API Key'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final apiKeyDialog = find.byType(AlertDialog);
    expect(apiKeyDialog, findsOneWidget);

    final apiKeyField = find.descendant(
      of: apiKeyDialog,
      matching: find.byType(TextField),
    );
    expect(apiKeyField, findsOneWidget);

    await tester.enterText(apiKeyField, 'TEST_API_KEY');
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: apiKeyDialog, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(cloudProvider.savedApiKey, 'TEST_API_KEY');
    expect(cloudProvider.loadInstancesCalls, 1);
    expect(cloudProvider.hasApiKey, isTrue);
    expect(cloudProvider.instances, isNotEmpty);
  });
}
