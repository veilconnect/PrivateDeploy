import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_profile_actions.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nodes profile actions', () {
    testWidgets('confirmDeleteProfile deletes selected profile',
        (tester) async {
      final profileProvider = _FakeProfileProvider(deleteResult: true);

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => confirmDeleteProfile(
          context: context,
          profileProvider: profileProvider,
          profile: _profile(id: 'manual-a', name: 'Manual A'),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(profileProvider.deletedProfileId, 'manual-a');
      expect(find.text('Profile deleted'), findsOneWidget);
    });

    testWidgets('showRenameProfileFlow trims updated name', (tester) async {
      final profileProvider = _FakeProfileProvider(updateResult: true);

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showRenameProfileFlow(
          context: context,
          profile: _profile(id: 'manual-a', name: 'Manual A'),
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '  Manual B  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(profileProvider.updatedProfileId, 'manual-a');
      expect(profileProvider.updatedProfileName, 'Manual B');
      expect(find.text('Profile renamed'), findsOneWidget);
    });

    testWidgets('showCreateProfileFlow blocks duplicate names before submit',
        (tester) async {
      final profileProvider = _FakeProfileProvider(
        createResult: true,
        validationError: 'A profile with this name already exists',
      );

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showCreateProfileFlow(
          context: context,
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Manual A');
      await tester.enterText(
        find.byType(TextFormField).last,
        '{"outbounds":[{"type":"direct"}]}',
      );
      await tester.tap(find.text('Create'));
      await tester.pump();

      expect(
        find.text('A profile with this name already exists'),
        findsOneWidget,
      );
      expect(profileProvider.createdName, isNull);
    });

    testWidgets('showImportProfileFlow imports parsed subscription',
        (tester) async {
      final profileProvider = _FakeProfileProvider(createResult: true);
      String? fetchedUrl;

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showImportProfileFlow(
          context: context,
          profileProvider: profileProvider,
          fetchSubscriptionData: (url) async {
            fetchedUrl = url;
            return 'raw-subscription';
          },
          parseSubscriptionData: (_) =>
              '{"outbounds":[{"type":"direct"}]}',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '  Sub A  ');
      await tester.enterText(
        find.byType(TextFormField).last,
        ' https://example.com/sub ',
      );
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(fetchedUrl, 'https://example.com/sub');
      expect(profileProvider.createdName, 'Sub A');
      expect(profileProvider.createdSubscriptionUrl, 'https://example.com/sub');
      expect(
        profileProvider.createdContent,
        '{"outbounds":[{"type":"direct"}]}',
      );
      expect(find.text('Imported successfully'), findsOneWidget);
    });

    testWidgets('showImportProfileFlow reports parser failure', (tester) async {
      final profileProvider = _FakeProfileProvider(createResult: true);

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showImportProfileFlow(
          context: context,
          profileProvider: profileProvider,
          fetchSubscriptionData: (_) async => 'raw-subscription',
          parseSubscriptionData: (_) => null,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).last,
        'https://example.com/sub',
      );
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(profileProvider.createdName, isNull);
      expect(find.text('Failed to parse subscription'), findsOneWidget);
    });

    testWidgets('showCreateProfileFlow creates a local profile',
        (tester) async {
      final profileProvider = _FakeProfileProvider(createResult: true);

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showCreateProfileFlow(
          context: context,
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '  Manual A  ');
      await tester.enterText(
        find.byType(TextFormField).last,
        ' {"outbounds":[{"type":"direct"}]} ',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(profileProvider.createdName, 'Manual A');
      expect(
        profileProvider.createdContent,
        '{"outbounds":[{"type":"direct"}]}',
      );
      expect(find.text('Profile created successfully'), findsOneWidget);
    });
  });
}

Future<void> _pumpProfileActionHarness(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onRun,
}) async {
  tester.view.physicalSize = const Size(1440, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(375, 812),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, _) {
        return MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => onRun(context),
                    child: const Text('Run'),
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
  );
  await tester.pump();
}

Profile _profile({
  required String id,
  required String name,
}) {
  return Profile(
    id: id,
    name: name,
    isActive: false,
    createdAt: DateTime(2026, 3, 29, 12, 30),
    updatedAt: DateTime(2026, 3, 29, 12, 30),
  );
}

class _FakeProfileProvider extends Fake implements ProfileProvider {
  _FakeProfileProvider({
    this.deleteResult = true,
    this.updateResult = true,
    this.createResult = true,
    this.validationError,
  });

  final bool deleteResult;
  final bool updateResult;
  final bool createResult;
  final String? validationError;

  String? deletedProfileId;
  String? updatedProfileId;
  String? updatedProfileName;
  String? createdName;
  String? createdSubscriptionUrl;
  String? createdContent;

  @override
  String? get error => null;

  @override
  Future<bool> deleteProfile(String id) async {
    deletedProfileId = id;
    return deleteResult;
  }

  @override
  Future<bool> updateProfile({
    required String id,
    String? name,
    String? subscriptionUrl,
    bool allowReservedPrefix = false,
  }) async {
    updatedProfileId = id;
    updatedProfileName = name;
    return updateResult;
  }

  @override
  Future<bool> createProfile({
    required String name,
    String? subscriptionUrl,
    String? content,
    bool allowReservedPrefix = false,
  }) async {
    createdName = name;
    createdSubscriptionUrl = subscriptionUrl;
    createdContent = content;
    return createResult;
  }

  @override
  String? validateProfileName(
    String name, {
    String? excludeId,
    bool allowReservedPrefix = false,
  }) {
    return validationError;
  }
}
