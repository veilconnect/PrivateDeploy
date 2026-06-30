import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_client.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_deploy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Keep the Reality-target probe off the network in tests; deterministically
  // fall back to the default (dl.google.com).
  setUp(() => VultrDeploymentBuilder.realityProbe = (_) async => false);
  tearDown(() => VultrDeploymentBuilder.realityProbe =
      VultrDeploymentBuilder.defaultRealityProbe);

  group('VultrDeploymentBuilder reality target selection', () {
    test('probes preferred first, then the vetted pool', () async {
      VultrDeploymentBuilder.realityProbe =
          (host) async => host == 'addons.mozilla.org';
      expect(
        await VultrDeploymentBuilder.selectVlessRealityTarget('dl.google.com'),
        'addons.mozilla.org',
      );
    });

    test('honours a reachable preferred target', () async {
      VultrDeploymentBuilder.realityProbe = (host) async => true;
      expect(
        await VultrDeploymentBuilder.selectVlessRealityTarget('www.python.org'),
        'www.python.org',
      );
    });

    test('falls back to the default when nothing responds', () async {
      VultrDeploymentBuilder.realityProbe = (_) async => false;
      expect(
        await VultrDeploymentBuilder.selectVlessRealityTarget(''),
        defaultVlessServerName,
      );
    });

    test('pool never contains www.microsoft.com', () {
      expect(vlessRealityTargetPool, isNot(contains('www.microsoft.com')));
      expect(defaultVlessServerName, isNot('www.microsoft.com'));
    });
  });

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
      expect(bundle.userData, contains('SINGBOX_VERSION="1.12.12"'));
    });

    test('multi-protocol script is hardened to match desktop', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 1024,
        portProfile: PortProfileAllocator.randomProfile,
      );
      final s = bundle.userData;
      // fail2ban installed + enabled
      expect(s, contains('fail2ban'));
      expect(s, contains('systemctl enable fail2ban'));
      // SSH rate-limited + hardened
      expect(s, contains("ufw limit 22/tcp comment 'SSH (rate-limited)'"));
      expect(s, contains('/etc/ssh/sshd_config.d/99-privatedeploy.conf'));
      expect(s, contains('MaxAuthTries 3'));
      // sing-box download integrity-checked with a fallback + graceful skip
      expect(s, contains('verify_checksum'));
      expect(
          s, contains('SINGBOX_FALLBACK_VERSION="1.11.0"')); // proven fallback
      expect(s, contains('SKIP_SINGBOX'));
      // Integrity check verifies against a pinned hash (not the non-existent
      // upstream .sha256sum file, which 404s and made the check a no-op).
      expect(s,
          contains('SINGBOX_SHA256="${singBoxSha256(defaultSingBoxVersion)}"'));
      expect(
        s,
        contains(
            'SINGBOX_FALLBACK_SHA256="${singBoxSha256(defaultSingBoxFallbackVersion)}"'),
      );
      expect(s, contains(r'''actual="$(sha256sum "$file" | cut -d' ' -f1)"'''));
      expect(s, isNot(contains('sha256sum -c')));
      expect(s, isNot(contains('SINGBOX_CHECKSUM_URL')));
      // Pinned hashes are real 64-hex SHA-256 values.
      expect(singBoxSha256(defaultSingBoxVersion),
          matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(singBoxSha256(defaultSingBoxFallbackVersion),
          matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('lightweight script is hardened to match desktop', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 512,
        portProfile: PortProfileAllocator.randomProfile,
      );
      final s = bundle.userData;
      expect(s, contains('fail2ban'));
      expect(s, contains("ufw limit 22/tcp comment 'SSH (rate-limited)'"));
      expect(s, contains('/etc/ssh/sshd_config.d/99-privatedeploy.conf'));
    });

    test('multi-protocol bundle provisions VLESS relay block', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 1024,
        portProfile: PortProfileAllocator.randomProfile,
      );

      final relayPort = bundle.nodeRecord['vlessRelayPort'] as int;
      expect(relayPort, greaterThan(0),
          reason:
              'multi-protocol bundle must allocate a relay port for CDN front');

      // UFW rule lets CF Worker reach the relay listener.
      expect(bundle.userData,
          contains("ufw allow $relayPort/tcp comment 'VLESS-Relay (CDN)'"));
      // sing-box outbound config must include the relay listen_port.
      expect(bundle.userData, contains('"listen_port": $relayPort'));
      // systemd unit for the relay sing-box instance must be installed and enabled.
      expect(bundle.userData,
          contains('/etc/systemd/system/vless-relay-server.service'));
      expect(bundle.userData, contains(' vless-relay-server'));
    });

    test('edge443 services can bind privileged ports as non-root', () async {
      final bundle = await VultrDeploymentBuilder.build(
        planRam: 1024,
        portProfile: 'edge443',
      );

      expect(bundle.nodeRecord['hyPort'], 443);
      expect(bundle.nodeRecord['trojanPort'], 443);
      expect(
        RegExp(r'^AmbientCapabilities=CAP_NET_BIND_SERVICE$', multiLine: true)
            .allMatches(bundle.userData)
            .length,
        4,
      );
      expect(
        RegExp(r'^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$', multiLine: true)
            .allMatches(bundle.userData)
            .length,
        4,
      );
    });
  });
}
