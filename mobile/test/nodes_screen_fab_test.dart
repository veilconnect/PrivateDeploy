import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen_fab.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NodesScreenFab', () {
    testWidgets('shows deploy action when cloud deploy is enabled',
        (tester) async {
      var deployTapped = false;
      var importTapped = false;
      var createTapped = false;

      await _pumpFab(
        tester,
        child: NodesScreenFab(
          showDeployNode: true,
          onDeployNode: () => deployTapped = true,
          onImportProfile: () => importTapped = true,
          onCreateProfile: () => createTapped = true,
        ),
      );

      expect(find.byIcon(Icons.cloud_upload), findsOneWidget);
      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byIcon(Icons.cloud_upload));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.link));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(deployTapped, isTrue);
      expect(importTapped, isTrue);
      expect(createTapped, isTrue);
    });

    testWidgets('hides deploy action when cloud deploy is disabled',
        (tester) async {
      await _pumpFab(
        tester,
        child: NodesScreenFab(
          showDeployNode: false,
          onDeployNode: () {},
          onImportProfile: () {},
          onCreateProfile: () {},
        ),
      );

      expect(find.byIcon(Icons.cloud_upload), findsNothing);
      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });
  });
}

Future<void> _pumpFab(
  WidgetTester tester, {
  required Widget child,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          floatingActionButton: child,
          body: const SizedBox.shrink(),
        ),
      ),
    ),
  );
}
