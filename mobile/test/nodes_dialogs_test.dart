import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cdn/cdn_provider.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_dialogs.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nodes dialogs', () {
    testWidgets('create profile dialog validates trimmed name and JSON config',
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

    testWidgets('create profile dialog rejects proxy links', (tester) async {
      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          await showNodesCreateProfileDialog(context);
        },
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Manual SG');
      await tester.enterText(
        find.byType(TextFormField).last,
        'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:443#SS',
      );
      await tester.tap(find.text('Create'));
      await tester.pump();

      expect(find.text('Invalid config: not valid JSON'), findsOneWidget);
    });

    testWidgets('encrypted import dialog validates payload fields',
        (tester) async {
      await _pumpDialogHarness(
        tester,
        onLaunch: (context) async {
          await showNodesImportProfileDialog(
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
      expect(
        find.text('Please paste encrypted config content'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextFormField).first, '  Sub A  ');
      await tester.enterText(find.byType(TextFormField).at(1), 'not-a-url');
      await tester.enterText(find.byType(TextFormField).last, 'shared-pass');
      await tester.tap(find.text('Import'));
      await tester.pump();
      expect(
        find.text('A profile with this name already exists'),
        findsOneWidget,
      );
      expect(
        find.text('Paste encrypted content copied from PrivateDeploy'),
        findsOneWidget,
      );
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
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
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
    child = MultiProvider(
      providers: [
        ChangeNotifierProvider<CloudProvider>.value(value: provider),
        ChangeNotifierProvider<CdnProvider>.value(value: CdnProvider()),
      ],
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
  CloudProviderId get providerId => CloudProviderId.vultr;

  @override
  String get providerDisplayName => providerId.displayName;

  @override
  Map<String, String> get providerExtra => const {};

  @override
  bool get isBenchmarkingAll => false;

  @override
  bool get benchmarkAbortRequested => false;

  @override
  CloudAccountStatus? get accountStatus => null;

  @override
  bool get isProbingRegions => false;

  @override
  CloudLatencyCheck? regionLatencyFor(String regionId) => null;

  @override
  String? fastestReachableRegionId() => null;

  @override
  Future<void> probeRegionLatencies({bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
