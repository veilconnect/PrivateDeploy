import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
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

  group('CloudProvider.validateDeploymentSelection', () {
    final regions = [
      CloudRegion(
        id: 'nrt',
        city: 'Tokyo',
        country: 'Japan',
        continent: 'Asia',
      ),
      CloudRegion(
        id: 'fra',
        city: 'Frankfurt',
        country: 'Germany',
        continent: 'Europe',
      ),
    ];
    final plans = [
      CloudPlan(
        id: 'vc2-1c-1gb',
        ram: 1024,
        vcpuCount: 1,
        disk: 25,
        monthlyCost: 6.0,
        locations: ['nrt'],
      ),
      CloudPlan(
        id: 'vc2-1c-2gb',
        ram: 2048,
        vcpuCount: 1,
        disk: 55,
        monthlyCost: 12.0,
        locations: ['fra'],
      ),
    ];

    test('rejects unknown regions', () {
      expect(
        CloudProvider.validateDeploymentSelection(
          region: 'lax',
          plan: 'vc2-1c-1gb',
          regions: regions,
          plans: plans,
        ),
        'Selected region is unavailable',
      );
    });

    test('rejects plans that are unavailable in selected region', () {
      expect(
        CloudProvider.validateDeploymentSelection(
          region: 'fra',
          plan: 'vc2-1c-1gb',
          regions: regions,
          plans: plans,
        ),
        'Selected plan is not available in the chosen region',
      );
    });

    test('accepts matching region and plan selections', () {
      expect(
        CloudProvider.validateDeploymentSelection(
          region: 'nrt',
          plan: 'vc2-1c-1gb',
          regions: regions,
          plans: plans,
        ),
        isNull,
      );
    });
  });
}
