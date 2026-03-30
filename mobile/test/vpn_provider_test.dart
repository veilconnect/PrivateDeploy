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
    vpnProvider = VpnProvider();
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

    test('connect fails when connection cannot stay stable during startup',
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

    test('refreshDiagnostics fails fast on native probe error', () async {
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

      expect(vpnProvider.diagnosticsEgressIp, isNull);
      expect(
        vpnProvider.diagnosticsError,
        VpnProvider.egressProbeFailureMessage,
      );
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
}
