import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen_fab.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NodesScreenFab', () {
    testWidgets('shows import and create actions',
        (tester) async {
      var importTapped = false;
      var createTapped = false;

      await _pumpFab(
        tester,
        child: NodesScreenFab(
          onImportProfile: () => importTapped = true,
          onCreateProfile: () => createTapped = true,
        ),
      );

      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byIcon(Icons.link));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(importTapped, isTrue);
      expect(createTapped, isTrue);
    });

    testWidgets('does not render deploy action shortcut',
        (tester) async {
      await _pumpFab(
        tester,
        child: NodesScreenFab(
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          floatingActionButton: child,
          body: const SizedBox.shrink(),
        ),
      ),
    ),
  );
}
