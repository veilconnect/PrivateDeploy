import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/digitalocean_client.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_client.dart';

void main() {
  group('mapDigitalOceanAccountStatus', () {
    test('active maps to canDeploy=true and empty default message', () {
      final status = mapDigitalOceanAccountStatus('active', '');
      expect(status.state, CloudAccountState.active);
      expect(status.canDeploy, true);
      expect(status.message, '');
      expect(status.checkedAt.isUtc, true);
    });

    test('warning fills a default message when DO omits one', () {
      final status = mapDigitalOceanAccountStatus('warning', '');
      expect(status.state, CloudAccountState.warning);
      expect(status.canDeploy, true);
      expect(status.message, isNotEmpty);
    });

    test('warning preserves the upstream message when present', () {
      final status = mapDigitalOceanAccountStatus('warning', 'balance low');
      expect(status.message, 'balance low');
    });

    test('locked refuses deploys and fills a hint when no message provided',
        () {
      final status = mapDigitalOceanAccountStatus('locked', '');
      expect(status.state, CloudAccountState.locked);
      expect(status.canDeploy, false);
      expect(status.message, isNotEmpty);
    });

    test('case-insensitive and whitespace-tolerant parsing', () {
      final upper = mapDigitalOceanAccountStatus('ACTIVE', '');
      final padded = mapDigitalOceanAccountStatus('  locked  ', '');
      expect(upper.state, CloudAccountState.active);
      expect(padded.state, CloudAccountState.locked);
    });

    test('unrecognized status falls back to unknown but still permits deploys',
        () {
      final status = mapDigitalOceanAccountStatus('frozen', '');
      expect(status.state, CloudAccountState.unknown);
      expect(status.canDeploy, true);
      expect(status.message, isNotEmpty);
    });
  });

  group('classifyVultrFirewallQuota', () {
    test('empty account is active', () {
      final status = classifyVultrFirewallQuota(0, 0);
      expect(status.state, CloudAccountState.active);
      expect(status.canDeploy, true);
    });

    test('well under warn threshold stays active', () {
      final status = classifyVultrFirewallQuota(12, 1);
      expect(status.state, CloudAccountState.active);
    });

    test('boundary 44 is still active', () {
      final status = classifyVultrFirewallQuota(44, 1);
      expect(status.state, CloudAccountState.active);
    });

    test('45 hits the warning threshold', () {
      final status = classifyVultrFirewallQuota(45, 1);
      expect(status.state, CloudAccountState.warning);
      expect(status.canDeploy, true);
      expect(status.message, isNotEmpty);
    });

    test('cap reached with a reusable group is soft-locked (canDeploy=true)',
        () {
      final status = classifyVultrFirewallQuota(50, 2);
      expect(status.state, CloudAccountState.locked);
      expect(status.canDeploy, true);
    });

    test('cap reached with no reusable group blocks deploys', () {
      final status = classifyVultrFirewallQuota(50, 0);
      expect(status.state, CloudAccountState.locked);
      expect(status.canDeploy, false);
    });

    test('cap exceeded behaves the same as cap reached', () {
      final status = classifyVultrFirewallQuota(52, 1);
      expect(status.state, CloudAccountState.locked);
      expect(status.canDeploy, true);
    });
  });
}
