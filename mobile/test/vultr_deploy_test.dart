import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_client.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_deploy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VultrDeploymentBuilder', () {
    test('creates lightweight bundle for low-memory plans', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 512,
        portProfile: PortProfileAllocator.randomProfile,
      );

      expect(bundle.lightweight, isTrue);
      expect(bundle.nodeRecord['ssPort'], greaterThan(0));
      expect(bundle.nodeRecord['ssPassword'], isNotEmpty);
      expect(bundle.nodeRecord['hyPort'], isNull);
      expect(bundle.nodeRecord['vlessPort'], isNull);
      expect(bundle.nodeRecord['trojanPort'], isNull);
      expect(bundle.userData, contains('shadowsocks-deployed'));
      expect(bundle.userData, isNot(contains('VLESS-Reality')));
    });

    test('creates multi-protocol bundle for standard plans', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 1024,
        portProfile: PortProfileAllocator.randomProfile,
      );

      final ssPort = bundle.nodeRecord['ssPort'] as int;
      final hyPort = bundle.nodeRecord['hyPort'] as int;
      final vlessPort = bundle.nodeRecord['vlessPort'] as int;
      final trojanPort = bundle.nodeRecord['trojanPort'] as int;

      expect(bundle.lightweight, isFalse);
      expect(hyPort, ssPort + 1);
      expect(vlessPort, ssPort + 2);
      expect(trojanPort, ssPort + 3);
      expect(bundle.nodeRecord['hyPassword'], isNotEmpty);
      expect(
          bundle.nodeRecord['vlessUUID'],
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(bundle.nodeRecord['vlessPublicKey'],
          matches(RegExp(r'^[A-Za-z0-9_-]{43,44}$')));
      expect(bundle.nodeRecord['vlessShortId'],
          matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(bundle.nodeRecord['trojanPassword'], isNotEmpty);
      expect(bundle.userData, contains('Hysteria2 Server (sing-box)'));
      expect(bundle.userData, contains('VLESS-Reality Server (sing-box)'));
      expect(bundle.userData, contains('Trojan Server (sing-box)'));
      expect(bundle.userData, contains('PublicKey:'));
    });

    test('multi-protocol bundle provisions VLESS relay block', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 1024,
        portProfile: PortProfileAllocator.randomProfile,
      );

      final relayPort = bundle.nodeRecord['vlessRelayPort'] as int;
      expect(relayPort, greaterThan(0),
          reason: 'multi-protocol bundle must allocate a relay port for CDN front');

      // UFW rule lets CF Worker reach the relay listener.
      expect(bundle.userData, contains("ufw allow $relayPort/tcp comment 'VLESS-Relay (CDN)'"));
      // sing-box outbound config must include the relay listen_port.
      expect(bundle.userData, contains('"listen_port": $relayPort'));
      // systemd unit for the relay sing-box instance must be installed and enabled.
      expect(bundle.userData,
          contains('/etc/systemd/system/vless-relay-server.service'));
      expect(bundle.userData, contains(' vless-relay-server'));
    });
  });
}
