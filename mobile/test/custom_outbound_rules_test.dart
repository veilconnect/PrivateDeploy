import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> normalize(VpnRoutingSettings settings) {
    final baseConfig = jsonEncode({
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
      ],
      'route': {'final': 'direct', 'rules': <dynamic>[]},
    });
    final result = normalizeProfileConfigForCurrentPlatform(
      baseConfig,
      targetPlatform: TargetPlatform.android,
      routingSettings: settings,
    );
    return jsonDecode(result) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> rulesOf(Map<String, dynamic> decoded) =>
      ((decoded['route'] as Map)['rules'] as List)
          .cast<Map<String, dynamic>>();

  group('custom outbounds and rules', () {
    test('drops rules whose target outbound does not exist', () {
      const settings = VpnRoutingSettings(
        customRules: [
          CustomRoutingRule(
            matcher: CustomRuleMatcher.ipCidr,
            value: '10.0.0.0/24',
            outbound: 'missing-tag',
          ),
        ],
      );
      final decoded = normalize(settings);
      final rules = rulesOf(decoded);
      expect(rules.any((r) => r['outbound'] == 'missing-tag'), isFalse);
    });
  });
}
