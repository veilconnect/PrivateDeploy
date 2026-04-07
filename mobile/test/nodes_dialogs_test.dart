import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_dialogs.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nodes dialogs', () {
    testWidgets('create profile dialog validates trimmed name and config',
        (tester) async {
      NodesCreateProfileRequest? request;

      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          request = await showNodesCreateProfileDialog(
            context,
            validateName: (name) {
              if (name.startsWith('Cloud: ')) {
                return 'Profile names cannot start with "Cloud: "';
              }
              return null;
            },
          );
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(find.text('Please enter a profile name'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '   ');
      await tester.enterText(find.byType(TextFormField).last, '[]');
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(find.text('Please enter a profile name'), findsOneWidget);
      expect(find.text('Invalid config: not a JSON object'), findsOneWidget);

      await tester.enterText(
        find.byType(TextFormField).first,
        '  Cloud: Manual SG  ',
      );
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(
        find.text('Profile names cannot start with "Cloud: "'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextFormField).first, '  Manual SG  ');
      await tester.enterText(
        find.byType(TextFormField).last,
        '  {"outbounds":[{"type":"direct"}]}  ',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(request?.name, 'Manual SG');
      expect(request?.config, '{"outbounds":[{"type":"direct"}]}');
    });

    testWidgets('cloud api key dialog obscures input and then saves',
        (tester) async {
      bool? saved;
      var attempts = 0;

      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          saved = await showNodesCloudApiKeyDialog(
            context: context,
            initialValue: '',
            onVerifyAndSave: (apiKey) async {
              attempts += 1;
              if (attempts == 1) {
                return 'Invalid API key';
              }
              return null;
            },
          );
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<EditableText>(find.byType(EditableText)).obscureText,
        isTrue,
      );

      await tester.enterText(find.byType(TextField), 'key-123');
      await tester.tap(find.text('Verify & Save'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Invalid API key'), findsOneWidget);
      expect(saved, isNull);

      await tester.tap(find.text('Verify & Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(saved, isTrue);
    });

    testWidgets('import dialog validates http url and trims fields',
        (tester) async {
      NodesImportProfileRequest? request;

      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          request = await showNodesImportProfileDialog(
            context,
            validateName: (name) {
              if (name == 'Sub A') {
                return 'A profile with this name already exists';
              }
              return null;
            },
          );
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import'));
      await tester.pump();
      expect(find.text('Please enter a subscription URL'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '  Sub A  ');
      await tester.enterText(find.byType(TextFormField).last, 'not-a-url');
      await tester.tap(find.text('Import'));
      await tester.pump();
      expect(
        find.text('A profile with this name already exists'),
        findsOneWidget,
      );
      expect(find.text('Must be an http(s) URL'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '  Sub B  ');
      await tester.enterText(
        find.byType(TextFormField).last,
        ' https://example.com/sub?token=1 ',
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();

      expect(request?.name, 'Sub B');
      expect(request?.url, 'https://example.com/sub?token=1');
    });

    testWidgets(
        'create cloud dialog clears stale plan selections when region changes',
        (tester) async {
      NodesCreateCloudRequest? request;
      final region = CloudRegion(
        id: 'nrt',
        city: 'Tokyo',
        country: 'Japan',
        continent: 'Asia',
      );
      final backupRegion = CloudRegion(
        id: 'fra',
        city: 'Frankfurt',
        country: 'Germany',
        continent: 'Europe',
      );
      final plan = CloudPlan(
        id: 'vc2-1c-1gb',
        ram: 1024,
        vcpuCount: 1,
        disk: 25,
        monthlyCost: 6.0,
        locations: const ['nrt'],
      );
      final backupPlan = CloudPlan(
        id: 'vc2-1c-2gb-fra',
        ram: 2048,
        vcpuCount: 1,
        disk: 55,
        monthlyCost: 12.0,
        locations: const ['fra'],
      );

      await _pumpDialogHarness(
        tester,
        provider: _FakeCloudProvider(
          regions: [region, backupRegion],
          plans: [plan, backupPlan],
        ),
        onLaunch: (context) async {
          request = await showNodesCreateCloudDialog(context);
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final deployButton = find.widgetWithText(ElevatedButton, 'Deploy');
      expect(
        tester.widget<ElevatedButton>(deployButton).onPressed,
        isNull,
      );

      await tester.enterText(find.byType(TextField).first, 'tokyo-edge');

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(region.displayName).last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(plan.displayName).last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(backupRegion.displayName).last);
      await tester.pumpAndSettle();

      expect(
        tester.widget<ElevatedButton>(deployButton).onPressed,
        isNull,
      );

      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(backupPlan.displayName).last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();

      expect(request?.label, 'tokyo-edge');
      expect(request?.region, 'fra');
      expect(request?.plan, 'vc2-1c-2gb-fra');
    });

    testWidgets('rename dialog uses custom name validator', (tester) async {
      String? result;

      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          result = await showNodesRenameProfileDialog(
            context: context,
            initialName: 'Manual A',
            validateName: (name) {
              if (name == 'Manual B') {
                return 'A profile with this name already exists';
              }
              return null;
            },
          );
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), 'Manual B');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        find.text('A profile with this name already exists'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextFormField), 'Manual C');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result, 'Manual C');
    });

    testWidgets('delete confirmation dialog returns true when confirmed',
        (tester) async {
      bool? confirmed;

      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          confirmed = await showNodesDeleteConfirmationDialog(
            context: context,
            title: 'Delete Profile',
            message: 'Delete "Manual A"?',
          );
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(confirmed, isTrue);
    });
  });
}

Future<void> _pumpDialogHarness(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onLaunch,
  CloudProvider? provider,
}) async {
  tester.view.physicalSize = const Size(1440, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  Widget child = MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return Center(
            child: ElevatedButton(
              onPressed: () => onLaunch(context),
              child: const Text('Open'),
            ),
          );
        },
      ),
    ),
  );

  if (provider != null) {
    child = ChangeNotifierProvider<CloudProvider>.value(
      value: provider,
      child: child,
    );
  }

  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(375, 812),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, _) => child,
    ),
  );
  await tester.pump();
}

class _FakeCloudProvider extends ChangeNotifier implements CloudProvider {
  _FakeCloudProvider({
    this.regions = const [],
    this.plans = const [],
  });

  @override
  final List<CloudRegion> regions;

  @override
  final List<CloudPlan> plans;

  @override
  bool get isLoadingRegions => false;

  @override
  bool get isLoadingPlans => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
