import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:privatedeploy_mobile/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full smoke test', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 1. Workspace 主页正常显示
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Cloud Nodes'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    // 2. API Key 对话框 + Cancel 修复验证
    await tester.tap(find.byIcon(Icons.key));
    await tester.pumpAndSettle();
    expect(find.text('Cloud API Key'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'INVALID_TEST_KEY');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify & Save'));
    await tester.pump(const Duration(milliseconds: 500));

    // Cancel 在验证中仍可点击
    final cancelButton = find.text('Cancel');
    expect(cancelButton, findsOneWidget);
    final cancelWidget = tester.widget<TextButton>(
      find.ancestor(of: cancelButton, matching: find.byType(TextButton)),
    );
    expect(cancelWidget.onPressed, isNotNull);

    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    expect(find.text('Cloud API Key'), findsNothing);
    expect(find.text('Workspace'), findsOneWidget);

    // 3. 设置页导航
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('VPN Diagnostics'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Workspace'), findsOneWidget);

    // 4. FAB 创建 Profile 对话框
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Create Profile'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Workspace'), findsOneWidget);

    // 5. Connect 无节点提示
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No ready node'), findsOneWidget);
  });
}
