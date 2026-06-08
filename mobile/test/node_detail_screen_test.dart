import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/security/encrypted_share.dart';
import 'package:privatedeploy_mobile/features/cloud/node_detail_screen.dart';

import 'support/nodes_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? clipboardText;

  setUp(() {
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

  testWidgets('copies an encrypted protocol config from the node detail screen',
      (tester) async {
    await pumpNodesTestApp(
      tester,
      wrapInScaffold: false,
      settle: true,
      child: NodeDetailScreen(node: readyCloudTestInstance(label: 'fra-node')),
    );

    await tester.ensureVisible(find.text('Copy Encrypted Shadowsocks Config'));
    await tester.tap(find.text('Copy Encrypted Shadowsocks Config'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextFormField).first, 'share-pass');
    await tester.enterText(find.byType(TextFormField).last, 'share-pass');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      EncryptedShareCodec.looksEncrypted(clipboardText ?? ''),
      isTrue,
    );
    expect(find.text('Encrypted Shadowsocks config copied'), findsOneWidget);
  });

  testWidgets('copies an encrypted node bundle in one action', (tester) async {
    await pumpNodesTestApp(
      tester,
      wrapInScaffold: false,
      settle: true,
      child: NodeDetailScreen(node: readyCloudTestInstance(label: 'fra-node')),
    );

    await tester.ensureVisible(find.text('Copy Encrypted Node'));
    await tester.tap(find.text('Copy Encrypted Node'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextFormField).first, 'bundle-pass');
    await tester.enterText(find.byType(TextFormField).last, 'bundle-pass');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      EncryptedShareCodec.looksEncrypted(clipboardText ?? ''),
      isTrue,
    );
    expect(find.text('Encrypted node copied'), findsOneWidget);
  });
}
