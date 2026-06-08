import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_utils.dart';

void main() {
  group('preferredCloudOsIds', () {
    test('prioritizes supported Debian and Ubuntu images', () {
      final osIds = preferredCloudOsIds({
        'os': [
          {'id': 300, 'name': 'Custom Linux', 'family': 'linux'},
          {'id': 200, 'name': 'Ubuntu 20.04 x64', 'family': 'ubuntu'},
          {'id': 100, 'name': 'Debian 11 x64', 'family': 'debian'},
        ],
      });

      expect(osIds.take(2), orderedEquals([100, 200]));
      expect(osIds, isNot(contains(300)));
    });

    test('falls back to all valid os ids when no preferred image matches', () {
      final osIds = preferredCloudOsIds({
        'os': [
          {'id': 1, 'name': 'Arch Linux', 'family': 'linux'},
          {'id': '2', 'name': 'AlmaLinux', 'family': 'rpm'},
        ],
      });

      expect(osIds, orderedEquals([1, 2]));
    });
  });

  group('shouldKeepCloudApiKeyOnError', () {
    test('keeps key for transient network failures', () {
      expect(
        shouldKeepCloudApiKeyOnError(Exception('Socket exception: timed out')),
        isTrue,
      );
    });

    test('drops key for auth failures', () {
      expect(
        shouldKeepCloudApiKeyOnError(StateError('403 forbidden')),
        isFalse,
      );
    });
  });
}
