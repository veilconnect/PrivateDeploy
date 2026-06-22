import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';

void main() {
  group('CloudInstance.fromJson', () {
    test('treats 0.0.0.0 as missing ipv4', () {
      final instance = CloudInstance.fromJson({
        'id': 'node-1',
        'label': 'pending-node',
        'status': 'active',
        'region': 'fra',
        'plan': 'vc2-1c-1gb',
        'main_ip': '0.0.0.0',
      });

      expect(instance.ipv4, isNull);
      expect(instance.hasIp, isFalse);
    });

    test('prefers real public main_ip when present', () {
      final instance = CloudInstance.fromJson({
        'id': 'node-2',
        'label': 'ready-node',
        'status': 'active',
        'region': 'fra',
        'plan': 'vc2-1c-1gb',
        'main_ip': '198.51.100.12',
      });

      expect(instance.ipv4, '198.51.100.12');
      expect(instance.hasIp, isTrue);
    });
  });
}
