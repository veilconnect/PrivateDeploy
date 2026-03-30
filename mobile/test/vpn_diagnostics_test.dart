import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_diagnostics.dart';
import 'package:privatedeploy_mobile/services/vpn_native_service.dart';

void main() {
  group('VpnRuntimeLogParser', () {
    test('resolves DNS records and classifies direct/proxy decisions', () {
      final parser = VpnRuntimeLogParser();

      parser.replaceWith([
        VpnNativeLogEntry(
          message: 'dns: exchanged A www.baidu.com. 1 IN A 45.113.192.102',
          timestamp: DateTime(2026, 3, 30, 7, 0, 0),
        ),
        VpnNativeLogEntry(
          message:
              'outbound/direct[direct]: outbound connection to 45.113.192.102:443',
          timestamp: DateTime(2026, 3, 30, 7, 0, 1),
        ),
        VpnNativeLogEntry(
          message:
              'dns: exchanged A dyna.wikimedia.org. 180 IN A 103.102.166.224',
          timestamp: DateTime(2026, 3, 30, 7, 0, 2),
        ),
        VpnNativeLogEntry(
          message:
              'outbound/shadowsocks[新加坡-SS]: outbound connection to 103.102.166.224:443',
          timestamp: DateTime(2026, 3, 30, 7, 0, 3),
        ),
      ]);

      expect(parser.recentDecisions, hasLength(2));

      final latest = parser.recentDecisions.first;
      expect(latest.type, VpnRouteDecisionType.proxy);
      expect(latest.domain, 'dyna.wikimedia.org');
      expect(latest.outboundTag, '新加坡-SS');

      final previous = parser.recentDecisions.last;
      expect(previous.type, VpnRouteDecisionType.direct);
      expect(previous.domain, 'www.baidu.com');
      expect(previous.target, '45.113.192.102:443');
    });

    test('deduplicates repeated noisy decisions', () {
      final parser = VpnRuntimeLogParser();

      parser.replaceWith([
        VpnNativeLogEntry(
          message:
              'outbound/direct[direct]: outbound connection to 45.113.192.102:443',
          timestamp: DateTime(2026, 3, 30, 7, 1, 0),
        ),
        VpnNativeLogEntry(
          message:
              'outbound/direct[direct]: outbound connection to 45.113.192.102:443',
          timestamp: DateTime(2026, 3, 30, 7, 1, 1),
        ),
        VpnNativeLogEntry(
          message:
              'outbound/direct[direct]: outbound connection to 45.113.192.102:443',
          timestamp: DateTime(2026, 3, 30, 7, 1, 4),
        ),
      ]);

      expect(parser.recentDecisions, hasLength(2));
    });
  });

  group('extractVpnEgressIp', () {
    test('parses JSON payloads', () {
      expect(
        extractVpnEgressIp('{"ip":"203.0.113.42"}'),
        '203.0.113.42',
      );
    });

    test('parses plain text payloads', () {
      expect(
        extractVpnEgressIp('203.0.113.43\n'),
        '203.0.113.43',
      );
    });

    test('parses Cloudflare trace payloads without DNS', () {
      expect(
        extractVpnEgressIp('fl=29f117\nh=1.1.1.1\nip=198.51.100.10\nts=123'),
        '198.51.100.10',
      );
    });
  });
}
