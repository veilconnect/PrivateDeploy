import 'package:flutter/services.dart';
import '../shared/utils/logger.dart';
import 'dart:async';

/// VPN 原生服务接口
/// 通过 Platform Channel 与 Android/iOS 原生 VPN 实现通信
class VpnNativeService {
  static const _methodChannel = MethodChannel('com.privatedeploy.vpn/native');
  static const _eventChannel = EventChannel('com.privatedeploy.vpn/events');

  static VpnNativeService? _instance;
  StreamSubscription? _eventSubscription;
  final _statusController = StreamController<VpnNativeStatus>.broadcast();
  final _statsController = StreamController<VpnNativeStats>.broadcast();

  VpnNativeService._();

  /// 获取单例实例
  static VpnNativeService get instance {
    _instance ??= VpnNativeService._();
    return _instance!;
  }

  /// VPN 状态变化流
  Stream<VpnNativeStatus> get statusStream => _statusController.stream;

  /// 流量统计变化流
  Stream<VpnNativeStats> get statsStream => _statsController.stream;

  /// 初始化原生服务
  Future<void> initialize() async {
    try {
      AppLogger.info('[VpnNativeService] Initializing...');

      // 监听原生事件
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (error) {
          AppLogger.error('[VpnNativeService] Event stream error', error);
        },
      );

      AppLogger.info('[VpnNativeService] Initialized successfully');
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to initialize', e);
      rethrow;
    }
  }

  /// 启动 VPN
  Future<bool> startVpn(String configJson) async {
    try {
      AppLogger.info('[VpnNativeService] Starting VPN...');
      final result = await _methodChannel.invokeMethod<bool>('startVpn', {
        'config': configJson,
      });
      AppLogger.info('[VpnNativeService] Start result: $result');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to start VPN', e);
      return false;
    }
  }

  /// 停止 VPN
  Future<bool> stopVpn() async {
    try {
      AppLogger.info('[VpnNativeService] Stopping VPN...');
      final result = await _methodChannel.invokeMethod<bool>('stopVpn');
      AppLogger.info('[VpnNativeService] Stop result: $result');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to stop VPN', e);
      return false;
    }
  }

  /// 重启 VPN
  Future<bool> restartVpn() async {
    try {
      AppLogger.info('[VpnNativeService] Restarting VPN...');
      final result = await _methodChannel.invokeMethod<bool>('restartVpn');
      AppLogger.info('[VpnNativeService] Restart result: $result');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to restart VPN', e);
      return false;
    }
  }

  /// 检查 VPN 是否正在运行
  Future<bool> isRunning() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to check VPN status', e);
      return false;
    }
  }

  /// 获取 VPN 状态
  Future<VpnNativeStatus?> getStatus() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getStatus');
      if (result != null) {
        return VpnNativeStatus.fromJson(Map<String, dynamic>.from(result));
      }
      return null;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return null;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to get status', e);
      return null;
    }
  }

  /// 获取流量统计
  Future<VpnNativeStats?> getStats() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getStats');
      if (result != null) {
        return VpnNativeStats.fromJson(Map<String, dynamic>.from(result));
      }
      return null;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return null;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to get stats', e);
      return null;
    }
  }

  /// 重置流量统计
  Future<bool> resetStats() async {
    try {
      AppLogger.info('[VpnNativeService] Resetting stats...');
      final result = await _methodChannel.invokeMethod<bool>('resetStats');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to reset stats', e);
      return false;
    }
  }

  /// 更新 VPN 配置
  Future<bool> updateConfig(String configJson) async {
    try {
      AppLogger.info('[VpnNativeService] Updating config...');
      final result = await _methodChannel.invokeMethod<bool>('updateConfig', {
        'config': configJson,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to update config', e);
      return false;
    }
  }

  /// 获取版本信息
  Future<String?> getVersion() async {
    try {
      final result = await _methodChannel.invokeMethod<String>('getVersion');
      return result;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return null;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to get version', e);
      return null;
    }
  }

  /// 请求 VPN 权限 (Android)
  Future<bool> requestPermission() async {
    try {
      AppLogger.info('[VpnNativeService] Requesting VPN permission...');
      final result = await _methodChannel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to request permission', e);
      return false;
    }
  }

  /// 处理原生事件
  void _handleNativeEvent(dynamic event) {
    try {
      if (event is! Map) return;

      final eventData = Map<String, dynamic>.from(event);
      final eventType = eventData['type'] as String?;

      AppLogger.debug('[VpnNativeService] Received event: $eventType');

      switch (eventType) {
        case 'status':
          final status = VpnNativeStatus.fromJson(eventData['data']);
          _statusController.add(status);
          break;

        case 'stats':
          final stats = VpnNativeStats.fromJson(eventData['data']);
          _statsController.add(stats);
          break;

        case 'error':
          final error = eventData['message'] as String?;
          AppLogger.error('[VpnNativeService] Native error: $error');
          break;

        default:
          AppLogger.warning('[VpnNativeService] Unknown event type: $eventType');
      }
    } catch (e) {
      AppLogger.error('[VpnNativeService] Failed to handle event', e);
    }
  }

  /// 清理资源
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    await _statusController.close();
    await _statsController.close();
    _instance = null;
  }
}

/// VPN 原生状态
class VpnNativeStatus {
  final bool running;
  final int connectedAt;
  final int uptime;

  VpnNativeStatus({
    required this.running,
    required this.connectedAt,
    required this.uptime,
  });

  factory VpnNativeStatus.fromJson(Map<String, dynamic> json) {
    return VpnNativeStatus(
      running: json['running'] ?? false,
      connectedAt: json['connected_at'] ?? 0,
      uptime: json['uptime'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'running': running,
      'connected_at': connectedAt,
      'uptime': uptime,
    };
  }
}

/// VPN 流量统计
class VpnNativeStats {
  final int uploadBytes;
  final int downloadBytes;
  final int uploadSpeed;
  final int downloadSpeed;

  VpnNativeStats({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.uploadSpeed,
    required this.downloadSpeed,
  });

  factory VpnNativeStats.fromJson(Map<String, dynamic> json) {
    return VpnNativeStats(
      uploadBytes: json['upload_bytes'] ?? 0,
      downloadBytes: json['download_bytes'] ?? 0,
      uploadSpeed: json['upload_speed'] ?? 0,
      downloadSpeed: json['download_speed'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'upload_bytes': uploadBytes,
      'download_bytes': downloadBytes,
      'upload_speed': uploadSpeed,
      'download_speed': downloadSpeed,
    };
  }
}
