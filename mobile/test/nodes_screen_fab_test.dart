import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen_fab.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_test_keys.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NodesScreenFab', () {
    testWidgets(
        'opens action sheet for encrypted import and local create actions',
        (tester) async {
      var configureTapped = false;
      var deployTapped = false;
      var importTapped = false;
      var createTapped = false;

      await _pumpFab(
        tester,
        child: NodesScreenFab(
          cloudAccessActionLabel: 'Set Cloud Access',
          onConfigureCloudAccess: () => configureTapped = true,
          onCreateCloudNode: () => deployTapped = true,
          onImportProfile: () => importTapped = true,
          onCreateProfile: () => createTapped = true,
        ),
      );

      expect(find.byKey(NodesTestKeys.workspaceFab), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byKey(NodesTestKeys.workspaceFab));
      await tester.pumpAndSettle();
      expect(find.text('Set Cloud Access'), findsOneWidget);
      expect(find.text('Create Route'), findsOneWidget);
      expect(find.text('Import Encrypted Config'), findsOneWidget);
      expect(find.text('Create Local Config'), findsOneWidget);

      await tester.tap(find.byKey(NodesTestKeys.configureCloudAccessFab));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(NodesTestKeys.workspaceFab));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NodesTestKeys.deployCloudNodeFab));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(NodesTestKeys.workspaceFab));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NodesTestKeys.importProfileFab));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(NodesTestKeys.workspaceFab));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NodesTestKeys.createProfileFab));
      await tester.pumpAndSettle();

      expect(configureTapped, isTrue);
      expect(deployTapped, isTrue);
      expect(importTapped, isTrue);
      expect(createTapped, isTrue);
    });

    testWidgets('hides cloud actions when callbacks are absent',
        (tester) async {
      await _pumpFab(
        tester,
        child: NodesScreenFab(
          onImportProfile: () {},
          onCreateProfile: () {},
        ),
      );

      expect(find.byIcon(Icons.cloud_upload), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byKey(NodesTestKeys.workspaceFab));
      await tester.pumpAndSettle();

      expect(find.text('Set Cloud Access'), findsNothing);
      expect(find.text('Create Route'), findsNothing);
      expect(find.text('Import Encrypted Config'), findsOneWidget);
      expect(find.text('Create Local Config'), findsOneWidget);
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
