import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:privatedeploy_mobile/core/network/api_client.dart';

// 生成 Mock 类
// 运行: flutter pub run build_runner build
@GenerateMocks([ApiClient])
import 'vpn_provider_test.mocks.dart';

void main() {
  late VpnProvider vpnProvider;
  late MockApiClient mockApiClient;

  setUp(() {
    mockApiClient = MockApiClient();
    vpnProvider = VpnProvider(mockApiClient);
  });

  group('VpnProvider Tests', () {
    test('初始状态应该是断开连接', () {
      expect(vpnProvider.status, VpnStatus.disconnected);
      expect(vpnProvider.isConnected, false);
    });

    test('启动 VPN 成功应该更新状态', () async {
      // Arrange
      when(mockApiClient.startVpn()).thenAnswer(
        (_) async => {'success': true, 'data': {'status': 'connected'}},
      );

      // Act
      final result = await vpnProvider.connect();

      // Assert
      expect(result, true);
      verify(mockApiClient.startVpn()).called(1);
    });

    test('停止 VPN 成功应该更新状态', () async {
      // Arrange
      when(mockApiClient.stopVpn()).thenAnswer(
        (_) async => {'success': true},
      );

      // Act
      final result = await vpnProvider.disconnect();

      // Assert
      expect(result, true);
      verify(mockApiClient.stopVpn()).called(1);
    });

    test('加载流量统计应该更新 stats', () async {
      // Arrange
      when(mockApiClient.getTrafficStats()).thenAnswer(
        (_) async => {
          'success': true,
          'data': {
            'upload_bytes': 1024,
            'download_bytes': 2048,
            'upload_speed': 10,
            'download_speed': 20,
            'connection_time': 60,
          }
        },
      );

      // Act
      await vpnProvider.loadStats();

      // Assert
      expect(vpnProvider.stats.uploadBytes, 1024);
      expect(vpnProvider.stats.downloadBytes, 2048);
      verify(mockApiClient.getTrafficStats()).called(1);
    });

    test('重置统计应该清空数据', () async {
      // Arrange
      when(mockApiClient.resetTrafficStats()).thenAnswer(
        (_) async => {'success': true},
      );

      // Act
      final result = await vpnProvider.resetStats();

      // Assert
      expect(result, true);
      expect(vpnProvider.stats.uploadBytes, 0);
      expect(vpnProvider.stats.downloadBytes, 0);
    });

    test('API 调用失败应该返回 false', () async {
      // Arrange
      when(mockApiClient.startVpn()).thenAnswer(
        (_) async => {'success': false, 'message': 'Connection failed'},
      );

      // Act
      final result = await vpnProvider.connect();

      // Assert
      expect(result, false);
      expect(vpnProvider.error, isNotNull);
    });

    test('重启 VPN 应该先停止再启动', () async {
      // Arrange
      when(mockApiClient.restartVpn()).thenAnswer(
        (_) async => {'success': true, 'data': {'status': 'connected'}},
      );

      // Act
      final result = await vpnProvider.restart();

      // Assert
      expect(result, true);
      verify(mockApiClient.restartVpn()).called(1);
    });
  });

  group('TrafficStats Tests', () {
    test('应该正确格式化字节数', () {
      final stats = TrafficStats(
        uploadBytes: 1024,
        downloadBytes: 1024 * 1024,
        uploadSpeed: 1024.0,
        downloadSpeed: 1024.0 * 1024,
        connectionTime: const Duration(hours: 1, minutes: 30),
      );

      expect(stats.uploadFormatted, '1.00 KB');
      expect(stats.downloadFormatted, '1.00 MB');
      expect(stats.uploadSpeedFormatted, '1.00 KB/s');
      expect(stats.downloadSpeedFormatted, '1.00 MB/s');
    });

    test('应该正确计算总流量', () {
      final stats = TrafficStats(
        uploadBytes: 1024,
        downloadBytes: 2048,
        uploadSpeed: 0,
        downloadSpeed: 0,
        connectionTime: Duration.zero,
      );

      expect(stats.totalBytes, 3072);
      expect(stats.totalFormatted, '3.00 KB');
    });

    test('应该正确格式化连接时间', () {
      final stats = TrafficStats(
        uploadBytes: 0,
        downloadBytes: 0,
        uploadSpeed: 0,
        downloadSpeed: 0,
        connectionTime: const Duration(hours: 2, minutes: 30, seconds: 45),
      );

      expect(stats.connectionTimeFormatted, '2h 30m 45s');
    });
  });

  tearDown(() {
    vpnProvider.dispose();
  });
}
