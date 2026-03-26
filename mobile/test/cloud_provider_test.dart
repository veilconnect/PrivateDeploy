import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';

void main() {
  group('CloudProvider.normalizeInstanceLabel', () {
    test('keeps non-empty labels after trimming', () {
      expect(
        CloudProvider.normalizeInstanceLabel('  fra-node-1  '),
        'fra-node-1',
      );
    });

    test('generates fallback label when left blank', () {
      final label = CloudProvider.normalizeInstanceLabel(
        '   ',
        now: DateTime.utc(2026, 3, 26, 10, 45, 12),
      );

      expect(label, 'node-260326104512');
    });
  });
}
