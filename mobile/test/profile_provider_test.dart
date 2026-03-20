import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';

void main() {
  group('Profile Model Tests', () {
    test('Profile.fromJson parses correctly', () {
      final json = {
        'id': '123',
        'name': 'Test Profile',
        'subscription_url': 'https://example.com/sub',
        'content': '{"outbounds":[]}',
        'is_active': true,
        'created_at': '2024-01-01T00:00:00.000Z',
        'updated_at': '2024-01-02T00:00:00.000Z',
      };

      final profile = Profile.fromJson(json);
      expect(profile.id, '123');
      expect(profile.name, 'Test Profile');
      expect(profile.subscriptionUrl, 'https://example.com/sub');
      expect(profile.content, '{"outbounds":[]}');
      expect(profile.isActive, true);
    });

    test('Profile.copyWith works', () {
      final profile = Profile(
        id: '1',
        name: 'Original',
        isActive: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final updated = profile.copyWith(name: 'Updated', isActive: true);
      expect(updated.name, 'Updated');
      expect(updated.isActive, true);
      expect(updated.id, '1');
    });

    test('Profile.toJson roundtrip', () {
      final profile = Profile(
        id: '1',
        name: 'Test',
        subscriptionUrl: 'https://test.com',
        content: '{}',
        isActive: false,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 2),
      );

      final json = profile.toJson();
      final restored = Profile.fromJson(json);
      expect(restored.id, profile.id);
      expect(restored.name, profile.name);
      expect(restored.subscriptionUrl, profile.subscriptionUrl);
      expect(restored.content, profile.content);
    });

    test('normalizeConfigForCurrentPlatform rewrites Android tun stack', () {
      const config = '''
{
  "inbounds": [
    {
      "type": "tun",
      "stack": "system"
    }
  ]
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final inbounds = json['inbounds'] as List<dynamic>;
      expect((inbounds.first as Map<String, dynamic>)['stack'], 'gvisor');
    });
  });
}
