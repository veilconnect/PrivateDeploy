import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_test_keys.dart';
import 'package:privatedeploy_mobile/features/settings/settings_screen.dart';

import 'package:privatedeploy_mobile/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full smoke test', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 1. 首页核心控件正常显示
    expect(find.byKey(NodesTestKeys.connectButton), findsOneWidget);
    expect(find.byKey(NodesTestKeys.importProfileFab), findsOneWidget);
    expect(find.byKey(NodesTestKeys.createProfileFab), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    // 2. API Key 对话框 + Cancel 在保存时仍可点击
    await tester.tap(find.byIcon(Icons.key));
    await tester.pumpAndSettle();
    final apiKeyDialog = find.byType(AlertDialog);
    expect(apiKeyDialog, findsOneWidget);
    expect(find.descendant(of: apiKeyDialog, matching: find.byType(TextField)),
        findsOneWidget);

    await tester.enterText(
      find.descendant(of: apiKeyDialog, matching: find.byType(TextField)),
      'INVALID_TEST_KEY',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: apiKeyDialog, matching: find.byType(FilledButton)),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final cancelButton =
        find.descendant(of: apiKeyDialog, matching: find.byType(TextButton));
    expect(cancelButton, findsOneWidget);
    final cancelWidget = tester.widget<TextButton>(
      cancelButton,
    );
    expect(cancelWidget.onPressed, isNotNull);

    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(NodesTestKeys.connectButton), findsOneWidget);

    // 3. 设置页导航
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('API Key'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byKey(NodesTestKeys.connectButton), findsOneWidget);

    // 4. FAB 创建 Profile 对话框
    await tester.tap(find.byKey(NodesTestKeys.createProfileFab));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
    expect(find.byKey(NodesTestKeys.connectButton), findsOneWidget);

    // 5. Connect 在无可用节点时给出反馈
    await tester.tap(find.byKey(NodesTestKeys.connectButton));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
