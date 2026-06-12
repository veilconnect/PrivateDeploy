import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:privatedeploy_mobile/services/vpn_native_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('com.privatedeploy.vpn/native');
  late VpnProvider vpnProvider;

  setUp(() {
    vpnProvider = VpnProvider(fetchEgressIp: () async => '203.0.113.42');
  });

  tearDown(() async {
    vpnProvider.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    await VpnNativeService.instance.dispose();
  });

  group('VpnProvider Tests', () {
    test('initial state is disconnected', () {
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.isConnected, false);
      expect(vpnProvider.isLoading, false);
      expect(vpnProvider.error, isNull);
    });

    test('traffic stats start at zero', () {
      expect(vpnProvider.stats.uploadBytes, 0);
      expect(vpnProvider.stats.downloadBytes, 0);
      expect(vpnProvider.stats.totalBytes, 0);
    });

    test('TrafficStats formatting works', () {
      final stats = TrafficStats(
        uploadBytes: 1024 * 1024,
        downloadBytes: 1024 * 1024 * 500,
        uploadSpeed: 1024 * 100,
        downloadSpeed: 1024 * 1024 * 2,
        connectionTime: const Duration(hours: 1, minutes: 30, seconds: 45),
      );

      expect(stats.uploadFormatted, '1.00 MB');
      expect(stats.downloadFormatted, '500.00 MB');
      expect(stats.totalFormatted, '501.00 MB');
      expect(stats.connectionTimeFormatted, '1h 30m 45s');
      expect(stats.uploadSpeedFormatted, '100.00 KB/s');
      expect(stats.downloadSpeedFormatted, '2.00 MB/s');
    });

    test('TrafficStats.zero returns zeroed stats', () {
      final stats = TrafficStats.zero();
      expect(stats.uploadBytes, 0);
      expect(stats.downloadBytes, 0);
      expect(stats.uploadSpeed, 0);
      expect(stats.downloadSpeed, 0);
      expect(stats.connectionTime, Duration.zero);
    });

    test('connect applies native uptime to session stats', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getStats':
            return {
              'upload_bytes': 1024,
              'download_bytes': 2048,
              'upload_speed': 0,
              'download_speed': 0,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');
      expect(success, true);

      await vpnProvider.loadStats();

      expect(vpnProvider.stats.connectionTime,
          greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(vpnProvider.stats.connectionTimeFormatted, isNot('0s'));
    });

    test(
        'loadStats advances session time locally when native uptime starts at zero',
        () async {
      var statusCallCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            statusCallCount += 1;
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 0,
            };
          case 'getStats':
            return {
              'upload_bytes': 1024,
              'download_bytes': 2048,
              'upload_speed': 0,
              'download_speed': 0,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Test',
      );
      expect(success, true);
      expect(statusCallCount, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await vpnProvider.loadStats();

      expect(vpnProvider.stats.connectionTime,
          greaterThanOrEqualTo(const Duration(seconds: 1)));
      expect(vpnProvider.stats.connectionTimeFormatted, isNot('0s'));
    });

    test('connect returns false when native start does not reach running state',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': false,
              'status': 'error',
              'message': 'boom',
              'connected_at': 0,
              'uptime': 0,
            };
          case 'isRunning':
            return false;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, false);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.isConnected, false);
      expect(vpnProvider.error, 'boom');
    });

    test('connect surfaces a friendly message when VPN permission is denied',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            throw PlatformException(
              code: 'PERMISSION_DENIED',
              message: 'VPN permission denied',
            );
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, false);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.isConnected, false);
      expect(
        vpnProvider.error,
        VpnProvider.vpnPermissionDeniedMessage,
      );
    });

    test('already-running start rejection preserves the live session',
        () async {
      var startCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            startCalls += 1;
            if (startCalls == 1) {
              return true;
            }
            throw PlatformException(
              code: 'ALREADY_RUNNING',
              message: 'VPN is already running',
            );
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
              'proxyless': true,
            };
          case 'getStats':
            return {
              'upload_bytes': 1024,
              'download_bytes': 2048,
              'upload_speed': 0,
              'download_speed': 0,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final first = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Live WG',
        proxyless: true,
      );
      expect(first, true);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.activeProfile, 'Live WG');
      expect(vpnProvider.isProxylessTunnel, isTrue);

      final second = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Other profile',
      );

      expect(second, false);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.activeProfile, 'Live WG');
      expect(vpnProvider.isProxylessTunnel, isTrue);
      expect(vpnProvider.error, contains('already running'));
    });

    test('connect only reports success after confirmed running status',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.isConnected, true);
      expect(vpnProvider.activeProfile, 'Test');
    });

    test('connect waits for the stability window before reporting success',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final stopwatch = Stopwatch()..start();
      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Test',
        stabilityCheckDuration: const Duration(milliseconds: 250),
        statusPollInterval: const Duration(milliseconds: 25),
      );
      stopwatch.stop();

      expect(success, true);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
      expect(vpnProvider.isLoading, false);
      expect(vpnProvider.status, VpnStatus.connected);
    });

    test(
        'treats connected status as connected even when running field is malformed',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': '0',
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.isConnected, true);
    });

    test('maps unknown status to running signal when connected state is set',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': '1',
              'status': 'running',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.isConnected, true);
    });

    test('proxy tunnel: an upstream-degraded message DOES mark degraded',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': '1',
              'status': 'connected',
              'message': VpnProvider.tunnelUpstreamDegradedMessage,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(vpnProvider.isConnected, true);
      expect(vpnProvider.isDegraded, true,
          reason: 'a proxy tunnel must still surface upstream degradation');
    });

    test('proxyless (WG-only) tunnel: upstream-degraded message is ignored',
        () async {
      // The native probe is proxy-oriented; for a WG-only tunnel (egress =
      // direct) its "upstream degraded" verdict is meaningless and must NOT
      // mark degraded or arm the restart watchdog (which would drop WireGuard
      // every ~30-60s).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': '1',
              'status': 'connected',
              'message': VpnProvider.tunnelUpstreamDegradedMessage,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Intranet WireGuard',
        proxyless: true,
      );

      expect(vpnProvider.isConnected, true);
      expect(vpnProvider.isDegraded, false,
          reason: 'WG-only tunnel must not be judged by the proxy probe');
    });

    test('native proxyless echo rebuilds the Dart flag after a process restart',
        () async {
      // The Dart process died before its session state landed; the surviving
      // native WG-only tunnel echoes proxyless=true in its status, and a
      // fresh provider must adopt it — otherwise the home screen mislabels
      // the tunnel as a proxy and the WG-off toggle would connect a proxy.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
              'proxyless': true,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      expect(vpnProvider.isProxylessTunnel, false);
      await vpnProvider.loadStatus();
      expect(vpnProvider.isProxylessTunnel, true,
          reason: 'the native echo is authoritative for the tunnel mode');
      expect(vpnProvider.intranetWireguardLive, true,
          reason: 'a WG-only tunnel always carries the intranet WireGuard');
    });

    test('a rejected native start rolls the proxyless flag back', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return false; // native refused (e.g. another session running)
          case 'getStatus':
            return {
              'running': false,
              'status': 'disconnected',
              'message': null,
              'connected_at': 0,
              'uptime': 0,
            };
          case 'isRunning':
            return false;
          default:
            return null;
        }
      });

      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Intranet WireGuard',
        proxyless: true,
      );

      expect(success, false);
      expect(vpnProvider.isProxylessTunnel, false,
          reason: 'native never adopted the start — the optimistic flip '
              'must not survive');
    });

    test('intranetWireguardLive tracks the config actually connected',
        () async {
      var running = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'stopVpn':
            running = false;
            return true;
          case 'getStatus':
            return {
              'running': running,
              'status': running ? 'connected' : 'disconnected',
              'message': null,
              'connected_at': running ? 123 : 0,
              'uptime': running ? 5 : 0,
            };
          case 'isRunning':
            return running;
          default:
            return null;
        }
      });

      final overlayConfig = jsonEncode({
        'endpoints': [
          {
            'type': 'wireguard',
            'tag': 'wireguard-intranet',
            'private_key': 'x',
            'peers': <Map<String, dynamic>>[],
          },
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });

      await vpnProvider.connect(
          configJson: overlayConfig, profileName: 'Proxy+WG');
      expect(vpnProvider.intranetWireguardLive, true,
          reason: 'the connected config carries the overlay endpoint');

      await vpnProvider.disconnect();
      expect(vpnProvider.intranetWireguardLive, false,
          reason: 'cleared with the session');
    });

    test('shows explicit conflict message when another VPN revokes connection',
        () async {
      var statusCallCount = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            statusCallCount += 1;
            if (statusCallCount == 1) {
              return {
                'running': true,
                'status': 'connected',
                'message': null,
                'connected_at': 123,
                'uptime': 5,
              };
            }
            return {
              'running': false,
              'status': 'revoked',
              'message': null,
              'connected_at': 123,
              'uptime': 0,
            };
          case 'isRunning':
            return statusCallCount == 1;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.connected);

      await vpnProvider.loadStatus();

      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.error, VpnProvider.vpnConflictMessage);
    });

    test('preserves conflict message after follow-up disconnected status',
        () async {
      var statusCallCount = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            statusCallCount += 1;
            if (statusCallCount == 1) {
              return {
                'running': true,
                'status': 'connected',
                'message': null,
                'connected_at': 123,
                'uptime': 5,
              };
            }
            if (statusCallCount == 2) {
              return {
                'running': false,
                'status': 'revoked',
                'message': null,
                'connected_at': 123,
                'uptime': 0,
              };
            }
            return {
              'running': false,
              'status': 'disconnected',
              'message': null,
              'connected_at': 123,
              'uptime': 0,
            };
          case 'isRunning':
            return statusCallCount == 1;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Test');

      expect(success, true);

      await vpnProvider.loadStatus();
      await vpnProvider.loadStatus();

      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.error, VpnProvider.vpnConflictMessage);
    });

    test('connect fails when startup verification catches a connection drop',
        () async {
      var statusCallCount = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            statusCallCount += 1;
            if (statusCallCount == 1) {
              return {
                'running': true,
                'status': 'connected',
                'message': null,
                'connected_at': 123,
                'uptime': 5,
              };
            }
            return {
              'running': false,
              'status': 'revoked',
              'message': null,
              'connected_at': 123,
              'uptime': 0,
            };
          case 'isRunning':
            return statusCallCount == 1;
          default:
            return null;
        }
      });

      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Test',
        stabilityCheckDuration: const Duration(milliseconds: 5),
        statusPollInterval: const Duration(milliseconds: 1),
      );

      expect(success, false);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.error, VpnProvider.vpnConflictMessage);
    });

    test(
        'connect fails when the startup egress probe cannot reach the node in hard-fail mode',
        () async {
      var stopVpnCalls = 0;
      var tunnelStopped = false;

      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
        softFailStartupConnectivityProbe: false,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'stopVpn':
            stopVpnCalls += 1;
            tunnelStopped = true;
            return true;
          case 'getStatus':
            if (tunnelStopped) {
              return {
                'running': false,
                'status': 'disconnected',
                'message': null,
                'connected_at': 0,
                'uptime': 0,
              };
            }
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return !tunnelStopped;
          default:
            return null;
        }
      });

      final success =
          await vpnProvider.connect(configJson: '{}', profileName: 'Dead Node');

      expect(success, false);
      expect(stopVpnCalls, 1);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.activeProfile, isNull);
      expect(vpnProvider.isLoading, false);
      expect(
        vpnProvider.error,
        VpnProvider.startupConnectivityFailureMessage,
      );
    });

    test(
        'restart fails when the startup egress probe cannot reach the node in hard-fail mode',
        () async {
      var stopVpnCalls = 0;
      var tunnelStopped = false;

      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
        softFailStartupConnectivityProbe: false,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'restartVpn':
            return true;
          case 'stopVpn':
            stopVpnCalls += 1;
            tunnelStopped = true;
            return true;
          case 'getStatus':
            if (tunnelStopped) {
              return {
                'running': false,
                'status': 'disconnected',
                'message': null,
                'connected_at': 0,
                'uptime': 0,
              };
            }
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return !tunnelStopped;
          default:
            return null;
        }
      });

      final success = await vpnProvider.restart();

      expect(success, false);
      expect(stopVpnCalls, 1);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.activeProfile, isNull);
      expect(vpnProvider.isLoading, false);
      expect(
        vpnProvider.error,
        VpnProvider.startupConnectivityFailureMessage,
      );
    });

    test(
        'connect keeps Android VPN up and marks degraded when startup egress probe is inconclusive',
        () async {
      var stopVpnCalls = 0;

      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
        softFailStartupConnectivityProbe: true,
        androidStartupRetryDelay: const Duration(milliseconds: 30),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'stopVpn':
            stopVpnCalls += 1;
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Good Android Node',
      );

      expect(success, true);
      expect(stopVpnCalls, 0);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.activeProfile, 'Good Android Node');
      expect(vpnProvider.isDegraded, true);
      expect(
        vpnProvider.error,
        VpnProvider.startupProbeInconclusiveMessage,
      );
      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.startupProbeInconclusiveMessage,
      );

      await vpnProvider.loadStatus();

      expect(vpnProvider.isDegraded, true);
      expect(
        vpnProvider.error,
        VpnProvider.startupProbeInconclusiveMessage,
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.startupProbeInconclusiveMessage,
      );
    });

    test(
        'connect uses Dart startup fallback before a slow native probe times out on Android',
        () async {
      vpnProvider = VpnProvider(
        fetchEgressIp: () async => '198.51.100.24',
        softFailStartupConnectivityProbe: true,
        androidStartupFallbackProbeDelay: const Duration(milliseconds: 1),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final stopwatch = Stopwatch()..start();
      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Fast Fallback Node',
      );
      stopwatch.stop();

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.activeProfile, 'Fast Fallback Node');
      expect(vpnProvider.diagnosticsEgressIp, '198.51.100.24');
      expect(vpnProvider.diagnosticsError, isNull);
      expect(vpnProvider.isDegraded, false);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 200)),
      );
    });

    test(
        'restart keeps Android VPN up and marks degraded when startup egress probe is inconclusive',
        () async {
      var stopVpnCalls = 0;

      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
        softFailStartupConnectivityProbe: true,
        androidStartupRetryDelay: const Duration(milliseconds: 30),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'restartVpn':
            return true;
          case 'stopVpn':
            stopVpnCalls += 1;
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success = await vpnProvider.restart();

      expect(success, true);
      expect(stopVpnCalls, 0);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.isDegraded, true);
      expect(
        vpnProvider.error,
        VpnProvider.startupProbeInconclusiveMessage,
      );
      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.startupProbeInconclusiveMessage,
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.startupProbeInconclusiveMessage,
      );
    });

    test(
        'connect clears the deferred warning when Android startup retry later confirms egress',
        () async {
      var egressProbeCalls = 0;

      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
        softFailStartupConnectivityProbe: true,
        androidStartupRetryDelay: const Duration(milliseconds: 30),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            egressProbeCalls += 1;
            if (egressProbeCalls == 1) {
              return {
                'ip': null,
                'source': 'android_native',
                'error': 'Timed out contacting public IP probe endpoints.',
              };
            }
            return {
              'ip': '203.0.113.42',
              'source': 'android_native',
              'error': null,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Slow Android Node',
      );

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.connected);
      expect(vpnProvider.isDegraded, true);
      expect(
        vpnProvider.error,
        VpnProvider.startupProbeInconclusiveMessage,
      );
      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.startupProbeInconclusiveMessage,
      );
      expect(vpnProvider.diagnosticsEgressIp, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(vpnProvider.diagnosticsEgressIp, '203.0.113.42');
      expect(vpnProvider.diagnosticsError, isNull);
      expect(vpnProvider.error, isNull);
      expect(vpnProvider.isDegraded, false);
    });

    test(
        'connect normalizes benign Android Private DNS probe errors on hard startup verification failure',
        () async {
      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
        softFailStartupConnectivityProbe: false,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'stopVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error':
                  'connection: open outbound connection: operation not permitted',
            };
          case 'isRunning':
            return false;
          default:
            return null;
        }
      });

      final success = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Hard Failure Node',
      );

      expect(success, false);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(
        vpnProvider.error,
        VpnProvider.startupConnectivityFailureMessage,
      );
    });

    test('initializes unsupported native VPN capability explicitly', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getCapabilities':
            return {
              'supported': false,
              'reason': 'iOS VPN core is not available in this build.',
            };
          default:
            return null;
        }
      });

      await vpnProvider.initialize();

      expect(vpnProvider.isSupported, false);
      expect(
        vpnProvider.unsupportedReason,
        'iOS VPN core is not available in this build.',
      );
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.error, 'iOS VPN core is not available in this build.');
    });

    test('initialize is idempotent and refreshes status on resume', () async {
      var capabilitiesCalls = 0;
      var statusCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getCapabilities':
            capabilitiesCalls += 1;
            return {
              'supported': true,
              'reason': null,
            };
          case 'getStatus':
            statusCalls += 1;
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.initialize();
      await vpnProvider.initialize();
      vpnProvider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(capabilitiesCalls, 1);
      expect(statusCalls, greaterThanOrEqualTo(2));
      expect(vpnProvider.status, VpnStatus.connected);
    });

    test('refreshDiagnostics loads egress IP and recent route decisions',
        () async {
      vpnProvider = VpnProvider(fetchEgressIp: () async => '203.0.113.42');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getRecentLogs':
            return [
              {
                'message':
                    'dns: exchanged A www.wikipedia.org. 180 IN A 103.102.166.224',
                'timestamp': 1,
              },
              {
                'message':
                    'outbound/shadowsocks[新加坡-SS]: outbound connection to 103.102.166.224:443',
                'timestamp': 2,
              },
            ];
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.loadStatus();
      await vpnProvider.refreshDiagnostics();

      expect(vpnProvider.diagnosticsEgressIp, '203.0.113.42');
      expect(vpnProvider.diagnosticsError, isNull);
      expect(vpnProvider.recentRouteDecisions, hasLength(1));
      expect(
        vpnProvider.recentRouteDecisions.single.domain,
        'www.wikipedia.org',
      );
      expect(
        vpnProvider.recentRouteDecisions.single.type,
        VpnRouteDecisionType.proxy,
      );
    });

    test('refreshDiagnostics prefers native egress probe when available',
        () async {
      var fallbackCalls = 0;
      vpnProvider = VpnProvider(
        fetchEgressIp: () async {
          fallbackCalls += 1;
          return '198.51.100.10';
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getRecentLogs':
            return const [];
          case 'getEgressIp':
            return {
              'ip': '203.0.113.42',
              'source': 'android_native',
              'error': null,
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.loadStatus();
      await vpnProvider.refreshDiagnostics();

      expect(vpnProvider.diagnosticsEgressIp, '203.0.113.42');
      expect(vpnProvider.diagnosticsError, isNull);
      expect(fallbackCalls, 0);
    });

    test('refreshDiagnostics falls back to Dart probe on native probe error',
        () async {
      var fallbackCalls = 0;
      vpnProvider = VpnProvider(
        fetchEgressIp: () async {
          fallbackCalls += 1;
          return '198.51.100.10';
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getRecentLogs':
            return const [];
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.loadStatus();
      await vpnProvider.refreshDiagnostics();

      expect(vpnProvider.diagnosticsEgressIp, '198.51.100.10');
      expect(vpnProvider.diagnosticsError, isNull);
      expect(fallbackCalls, 1);
    });

    test(
        'refreshDiagnostics normalizes benign Android Private DNS probe errors when fallback also fails',
        () async {
      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getRecentLogs':
            return const [];
          case 'getEgressIp':
            return {
              'ip': null,
              'source': 'android_native',
              'error':
                  'connection: open outbound connection: operation not permitted',
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.loadStatus();
      await vpnProvider.refreshDiagnostics();

      expect(vpnProvider.diagnosticsEgressIp, isNull);
      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.egressProbeFailureMessage,
      );
    });

    test(
        'refreshDiagnostics falls back to active cloud node IP when probes fail',
        () async {
      var fallbackCalls = 0;
      var egressProbeCalls = 0;
      vpnProvider = VpnProvider(
        fetchEgressIp: () async {
          fallbackCalls += 1;
          throw Exception('probe failed');
        },
      );
      vpnProvider.setFallbackEgressIpResolver((activeProfile) {
        if (activeProfile == 'Cloud: smoke-2603302014') {
          return '95.179.178.229';
        }
        return null;
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getRecentLogs':
            return const [];
          case 'getEgressIp':
            egressProbeCalls += 1;
            if (egressProbeCalls == 1) {
              return {
                'ip': '203.0.113.42',
                'source': 'android_native',
                'error': null,
              };
            }
            return {
              'ip': null,
              'source': 'android_native',
              'error': 'Timed out contacting public IP probe endpoints.',
            };
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      final connected = await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Cloud: smoke-2603302014',
      );

      expect(connected, true);

      await vpnProvider.refreshDiagnostics();

      expect(vpnProvider.diagnosticsEgressIp, '95.179.178.229');
      expect(vpnProvider.diagnosticsError, isNull);
      expect(fallbackCalls, 0);
    });

    test('refreshDiagnostics keeps route decisions when egress IP probe fails',
        () async {
      vpnProvider = VpnProvider(
        fetchEgressIp: () async => throw Exception('probe failed'),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getRecentLogs':
            return [
              {
                'message':
                    'outbound/direct[direct]: outbound connection to 1.1.1.1:443',
                'timestamp': 2,
              },
            ];
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      await vpnProvider.loadStatus();
      await vpnProvider.refreshDiagnostics();

      expect(vpnProvider.diagnosticsEgressIp, isNull);
      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.egressProbeFailureMessage,
      );
      expect(vpnProvider.recentRouteDecisions, hasLength(1));
      expect(vpnProvider.diagnosticsUpdatedAt, isNotNull);
    });

    test('disconnect waits for native shutdown before returning', () async {
      var statusCalls = 0;
      var isRunningCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'stopVpn':
            return true;
          case 'getStatus':
            statusCalls += 1;
            if (statusCalls == 1) {
              return {
                'running': true,
                'status': 'disconnecting',
                'message': null,
                'connected_at': 123,
                'uptime': 5,
              };
            }
            return {
              'running': false,
              'status': 'disconnected',
              'message': null,
              'connected_at': 0,
              'uptime': 0,
            };
          case 'isRunning':
            isRunningCalls += 1;
            return false;
          default:
            return null;
        }
      });

      final success = await vpnProvider.disconnect();

      expect(success, true);
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(statusCalls, greaterThanOrEqualTo(2));
      expect(isRunningCalls, 0);
    });
  });

  group('Upstream-degraded watchdog', () {
    VpnNativeStatus connectedDegraded() => VpnNativeStatus(
          running: true,
          status: 'connected',
          message: 'Tunnel is up but offshore probe is failing',
          connectedAt: 1,
          uptime: 30,
        );

    VpnNativeStatus disconnected() => VpnNativeStatus(
          running: false,
          status: 'disconnected',
          message: null,
          connectedAt: 0,
          uptime: 0,
        );

    test(
        'attempt counter persists across watchdog-driven '
        'connected→disconnected→connected cycles', () async {
      var restartCalls = 0;
      var stopCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'restartVpn':
            restartCalls += 1;
            return true;
          case 'stopVpn':
            stopCalls += 1;
            return true;
          default:
            return null;
        }
      });

      // First degraded cycle: counter goes from 0 → 1.
      vpnProvider.debugApplyNativeStatus(connectedDegraded());
      await vpnProvider.debugFireUpstreamDegradedWatchdog();
      expect(vpnProvider.debugUpstreamDegradedRestartAttempts, 1);
      expect(restartCalls, 1);

      // The watchdog's restartVpn() forces the tunnel through
      // disconnected → connected. Before the fix, the disconnected step
      // reset the counter back to 0, so the next watchdog fire would
      // log "attempt 1/2" again forever.
      vpnProvider.debugApplyNativeStatus(disconnected());
      vpnProvider.debugApplyNativeStatus(connectedDegraded());
      await vpnProvider.debugFireUpstreamDegradedWatchdog();
      expect(vpnProvider.debugUpstreamDegradedRestartAttempts, 2);
      expect(restartCalls, 2);

      // Cap reached — the fast same-node restart budget is spent. With no
      // failover candidate registered, the watchdog now keeps the tunnel UP
      // and issues a slower recovery restart instead of tearing the session
      // down (which used to force a manual reconnect on every transient
      // upstream hiccup — the "总是断线" complaint).
      vpnProvider.debugApplyNativeStatus(disconnected());
      vpnProvider.debugApplyNativeStatus(connectedDegraded());
      await vpnProvider.debugFireUpstreamDegradedWatchdog();
      expect(vpnProvider.debugUpstreamDegradedRestartAttempts, 2);
      expect(restartCalls, 3);
      expect(stopCalls, 0);
      expect(vpnProvider.status, VpnStatus.connected);
    });

    test('does not restart while a connect attempt is still pending', () async {
      final startCompleter = Completer<bool>();
      var restartCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return startCompleter.future;
          case 'restartVpn':
            restartCalls += 1;
            return true;
          default:
            return null;
        }
      });

      final connectFuture = vpnProvider.connect(
        configJson: '{}',
        profileName: 'Cloud: primary-node',
      );
      await Future<void>.delayed(Duration.zero);
      expect(vpnProvider.isLoading, true);

      vpnProvider.debugApplyNativeStatus(connectedDegraded());
      await vpnProvider.debugFireUpstreamDegradedWatchdog();

      expect(restartCalls, 0);
      startCompleter.complete(false);
      expect(await connectFuture, false);
    });

    test(
        'cellular connectivity failure invokes the auto-CDN-deploy handler exactly '
        'once per profile name and clears the guidance banner on success',
        () async {
      // Connect first so the provider has an active profile name to
      // pass into the handler.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'startVpn':
            return true;
          case 'isRunning':
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 1,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {'ip': '8.8.8.8', 'source': 'android_native'};
          default:
            return null;
        }
      });
      await vpnProvider.connect(
        configJson: '{}',
        profileName: 'Cloud: blocked-node',
      );
      // Connect leaves _activeProfile set so the handler can be invoked.
      expect(vpnProvider.activeProfile, 'Cloud: blocked-node');

      final invocations = <String?>[];
      var handlerResult = true;
      vpnProvider.setOnAutoCdnDeployRequest((activeProfileName) async {
        invocations.add(activeProfileName);
        return handlerResult;
      });

      // First connectivity failure broadcast: handler must fire.
      vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
        running: false,
        status: 'error',
        message: VpnProvider.cellularCarrierSynBlockMessage,
        connectedAt: 0,
        uptime: 0,
      ));
      // Yield so the inflight Future inside _maybeAttemptAutoCdnDeploy
      // completes.
      await Future<void>.delayed(Duration.zero);
      expect(invocations, ['Cloud: blocked-node'],
          reason: 'auto-CDN handler must fire on connectivity failure');
      expect(vpnProvider.needsCdnGuidance, false,
          reason: 'handler returning true clears the banner');

      // Repeat broadcast on the same profile must NOT re-fire — the
      // attempt was already recorded for this episode.
      vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
        running: false,
        status: 'error',
        message: VpnProvider.cellularCarrierSynBlockMessage,
        connectedAt: 0,
        uptime: 0,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(invocations, ['Cloud: blocked-node'],
          reason:
              'second connectivity failure on same profile must not re-invoke the handler');
    });

    test(
        'cellular connectivity failure error sets needsCdnGuidance until a healthy '
        'connect (or explicit dismiss) clears it', () async {
      expect(vpnProvider.needsCdnGuidance, false);

      // Native side reports the carrier-connectivity failure flavor of start failure.
      vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
        running: false,
        status: 'error',
        message: VpnProvider.cellularCarrierSynBlockMessage,
        connectedAt: 0,
        uptime: 0,
      ));
      expect(vpnProvider.needsCdnGuidance, true,
          reason: 'banner must rise on carrier-connectivity failure error broadcast');

      // A healthy connected transition resolves the situation — the user
      // (or auto-CDN-deploy) made the tunnel work, banner goes away.
      vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
        running: true,
        status: 'connected',
        message: null,
        connectedAt: 1,
        uptime: 5,
      ));
      expect(vpnProvider.needsCdnGuidance, false,
          reason: 'banner must drop after healthy connect');

      // Raise it again and check explicit dismiss path.
      vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
        running: false,
        status: 'error',
        message: VpnProvider.cellularCarrierSynBlockMessage,
        connectedAt: 0,
        uptime: 0,
      ));
      expect(vpnProvider.needsCdnGuidance, true);
      vpnProvider.dismissCdnGuidance();
      expect(vpnProvider.needsCdnGuidance, false,
          reason: 'dismissCdnGuidance() must clear the flag');
    });

    test(
        'DirectRouteDegraded message marks UI degraded but does NOT arm '
        'the upstream watchdog (post-handover settle window self-resolves)',
        () async {
      var restartCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'restartVpn':
            restartCalls += 1;
            return true;
          default:
            return null;
        }
      });

      vpnProvider.debugApplyNativeStatus(VpnNativeStatus(
        running: true,
        status: 'connected',
        message: VpnProvider.tunnelDirectRouteDegradedMessage,
        connectedAt: 1,
        uptime: 5,
      ));

      // UI should reflect degraded health so the user gets an honest badge.
      expect(vpnProvider.health, VpnHealth.degraded);
      expect(vpnProvider.isDegraded, true);

      // But firing the watchdog after the configured delay must be a no-op:
      // direct-route degradation is transient handover settling, not a dead
      // node, so we don't burn the same-node restart budget on it.
      await vpnProvider.debugFireUpstreamDegradedWatchdog();
      expect(restartCalls, 0);
      expect(vpnProvider.debugUpstreamDegradedRestartAttempts, 0);
    });

    test('user-initiated restart() resets the watchdog budget', () async {
      var restartCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'restartVpn':
            restartCalls += 1;
            return true;
          case 'getStatus':
            return {
              'running': true,
              'status': 'connected',
              'message': null,
              'connected_at': 123,
              'uptime': 5,
            };
          case 'getEgressIp':
            return {'ip': '198.13.46.144', 'source': 'android_native'};
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });

      // Burn the budget via the watchdog.
      vpnProvider.debugApplyNativeStatus(connectedDegraded());
      await vpnProvider.debugFireUpstreamDegradedWatchdog();
      vpnProvider.debugApplyNativeStatus(disconnected());
      vpnProvider.debugApplyNativeStatus(connectedDegraded());
      await vpnProvider.debugFireUpstreamDegradedWatchdog();
      expect(vpnProvider.debugUpstreamDegradedRestartAttempts, 2);

      // User explicitly restarts — budget should be back to 0 so future
      // degraded signals get a fresh pair of attempts.
      final restarted = await vpnProvider.restart();
      expect(restarted, true);
      expect(vpnProvider.debugUpstreamDegradedRestartAttempts, 0);
      // restartCalls is now 3 (2 watchdog + 1 user).
      expect(restartCalls, 3);
    });
  });
}
