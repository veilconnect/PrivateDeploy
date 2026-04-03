import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:privatedeploy_mobile/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real API key flow', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 1. 确认主页正常
    expect(find.text('Workspace'), findsOneWidget);

    // 2. 打开 API Key 对话框
    await tester.tap(find.byIcon(Icons.key));
    await tester.pumpAndSettle();
    expect(find.text('Cloud API Key'), findsOneWidget);

    // 3. 输入真实 API Key
    await tester.enterText(
      find.byType(TextField),
      'KP4WBZ23UVVH33B6332FPWQLBLUI5SLXX4YQ',
    );
    await tester.pumpAndSettle();

    // 4. 点击 Verify & Save
    await tester.tap(find.text('Verify & Save'));

    // 等待验证完成（最多 20 秒）
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('Cloud API Key').evaluate().isEmpty) {
        break; // 对话框关闭 = 验证成功
      }
    }

    // 5. 验证成功后对话框应关闭，回到主页
    await tester.pumpAndSettle();
    expect(find.text('Cloud API Key'), findsNothing);
    expect(find.text('Workspace'), findsOneWidget);

    // 6. 等待云节点加载（最多 30 秒）
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      // 查找 Cloud Nodes section 中是否出现了节点卡片
      if (find.byType(Card).evaluate().isNotEmpty) {
        break;
      }
    }

    // 7. 验证节点区域显示
    expect(find.text('Cloud Nodes'), findsOneWidget);
    expect(find.byType(Card), findsWidgets);

    // 8. 尝试点击 Connect
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 应该出现某种反馈（连接成功、节点选择、或错误提示）
    // 只要不崩溃就算通过
  });
}
