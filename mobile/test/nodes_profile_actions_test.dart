import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/security/encrypted_share.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_profile_actions.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
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

    testWidgets('confirmDeleteProfile shows delete failure message',
        (tester) async {
      final profileProvider = _FakeProfileProvider(
        deleteResult: false,
        errorMessage: 'Delete failed',
      );

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
      expect(find.text('Delete failed'), findsOneWidget);
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

    testWidgets('showRenameProfileFlow reports rename failure', (tester) async {
      final profileProvider = _FakeProfileProvider(
        updateResult: false,
        errorMessage: 'Rename failed',
      );

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
      await tester.enterText(find.byType(TextFormField), 'Manual B');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(profileProvider.updatedProfileId, 'manual-a');
      expect(profileProvider.updatedProfileName, 'Manual B');
      expect(find.text('Rename failed'), findsOneWidget);
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

    testWidgets('showImportProfileFlow imports encrypted proxy links',
        (tester) async {
      final profileProvider = _FakeProfileProvider(createResult: true);
      final payload = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.proxyLinks,
        content: 'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:443#SS',
        passphrase: 'shared-pass',
        label: 'Shared Node',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showImportProfileFlow(
          context: context,
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(1),
        ' $payload ',
      );
      await tester.enterText(find.byType(TextFormField).last, 'shared-pass');
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(profileProvider.createdName, 'Shared Node');
      expect(profileProvider.createdSubscriptionUrl, isNull);
      expect(profileProvider.createdContent, contains('"outbounds"'));
      expect(find.text('Import failed'), findsNothing);
    });

    testWidgets('showImportProfileFlow reports create failure after decrypting',
        (tester) async {
      final profileProvider = _FakeProfileProvider(
        createResult: false,
        errorMessage: 'Import failed',
      );
      final payload = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.proxyLinks,
        content: 'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:443#SS',
        passphrase: 'shared-pass',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showImportProfileFlow(
          context: context,
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(1),
        payload,
      );
      await tester.enterText(find.byType(TextFormField).last, 'shared-pass');
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(profileProvider.createdContent, isNotNull);
      expect(find.text('Import failed'), findsOneWidget);
    });

    testWidgets('showImportProfileFlow reports decrypt failures',
        (tester) async {
      final profileProvider = _FakeProfileProvider(createResult: true);
      final payload = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.proxyLinks,
        content: 'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:443#SS',
        passphrase: 'shared-pass',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showImportProfileFlow(
          context: context,
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(1),
        payload,
      );
      await tester.enterText(find.byType(TextFormField).last, 'wrong-pass');
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(profileProvider.createdName, isNull);
      expect(
        find.textContaining('Failed to import encrypted config'),
        findsOneWidget,
      );
    });

    testWidgets(
        'showImportProfileFlow rejects unsupported encrypted share kinds',
        (tester) async {
      final profileProvider = _FakeProfileProvider(createResult: true);
      final payload = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.cloudBackup,
        content: '{"provider":"vultr"}',
        passphrase: 'shared-pass',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );

      await _pumpProfileActionHarness(
        tester,
        onRun: (context) => showImportProfileFlow(
          context: context,
          profileProvider: profileProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(1),
        payload,
      );
      await tester.enterText(find.byType(TextFormField).last, 'shared-pass');
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(profileProvider.createdName, isNull);
      expect(
        find.textContaining('Failed to import encrypted config'),
        findsOneWidget,
      );
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
        '{\n  "outbounds": [\n    {\n      "type": "direct"\n    }\n  ]\n}',
      );
      expect(find.text('Profile created successfully'), findsOneWidget);
    });

    testWidgets('showCreateProfileFlow rejects proxy links', (tester) async {
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
      await tester.enterText(find.byType(TextFormField).first, 'Manual A');
      await tester.enterText(
        find.byType(TextFormField).last,
        'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:443#SS',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(profileProvider.createdName, isNull);
      expect(find.text('Invalid config: not valid JSON'), findsOneWidget);
    });

    testWidgets('showCreateProfileFlow reports create failures',
        (tester) async {
      final profileProvider = _FakeProfileProvider(
        createResult: false,
        errorMessage: 'Create failed',
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
      await tester.pumpAndSettle();

      expect(profileProvider.createdName, 'Manual A');
      expect(find.text('Create failed'), findsOneWidget);
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
    this.errorMessage,
  });

  final bool deleteResult;
  final bool updateResult;
  final bool createResult;
  final String? validationError;
  final String? errorMessage;

  String? deletedProfileId;
  String? updatedProfileId;
  String? updatedProfileName;
  String? createdName;
  String? createdSubscriptionUrl;
  String? createdContent;

  @override
  String? get error => errorMessage;

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
