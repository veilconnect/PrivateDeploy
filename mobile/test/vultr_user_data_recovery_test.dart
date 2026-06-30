import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_client.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_deploy.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_user_data_recovery.dart';

void main() {
  // Keep the Reality-target probe off the network in tests.
  setUp(() => VultrDeploymentBuilder.realityProbe = (_) async => false);
  tearDown(() => VultrDeploymentBuilder.realityProbe =
      VultrDeploymentBuilder.defaultRealityProbe);

  group('recoverVultrNodeRecordFromUserData', () {
    test('recovers lightweight script credentials', () {
      final script = PortProfileAllocator.lightweightScript(
        ssPort: 24443,
        ssPassword: 'light-pass-123',
      );

      final recovered = recoverVultrNodeRecordFromUserData(script);

      expect(recovered, isNotNull);
      expect(recovered!.ssPort, 24443);
      expect(recovered.ssPassword, 'light-pass-123');
      expect(recovered.hyPort, 0);
      expect(recovered.vlessPort, 0);
      expect(recovered.trojanPort, 0);
    });

    test('recovers multi-protocol script credentials', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 1024,
        portProfile: PortProfileAllocator.randomProfile,
      );

      final recovered = recoverVultrNodeRecordFromUserData(bundle.userData);

      expect(recovered, isNotNull);
      expect(recovered!.isUsable, isTrue);
      expect(recovered.ssPort, greaterThan(0));
      expect(recovered.ssPassword, isNotEmpty);
      expect(recovered.hyPort, greaterThan(0));
      expect(recovered.hyPassword, isNotEmpty);
      expect(recovered.hyServerName, isNotEmpty);
      expect(recovered.vlessPort, greaterThan(0));
      expect(recovered.vlessUuid, contains('-'));
      expect(recovered.vlessPublicKey, isNotEmpty);
      expect(recovered.vlessShortId, isNotEmpty);
      expect(recovered.vlessServerName, isNotEmpty);
      expect(recovered.trojanPort, greaterThan(0));
      expect(recovered.trojanPassword, isNotEmpty);
      expect(recovered.trojanServerName, isNotEmpty);
    });
  });
}
