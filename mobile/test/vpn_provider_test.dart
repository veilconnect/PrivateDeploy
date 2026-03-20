import 'package:flutter/services.dart';
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
  });
}
