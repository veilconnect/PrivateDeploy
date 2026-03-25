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
  String? _lastError;

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

  /// 最近一次原生调用错误
  String? get lastError => _lastError;

  void _clearLastError() {
    _lastError = null;
  }

  void _recordLastError(String message) {
    _lastError = message;
  }

  /// 初始化原生服务
  Future<void> initialize() async {
    try {
      AppLogger.info('[VpnNativeService] Initializing...');
      _clearLastError();

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
      _clearLastError();
      final result = await _methodChannel.invokeMethod<bool>('startVpn', {
        'config': configJson,
      });
      AppLogger.info('[VpnNativeService] Start result: $result');
      if (result != true && _lastError == null) {
        _recordLastError('Native VPN start request was rejected');
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Native VPN start failed');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to start VPN: $e');
      AppLogger.error('[VpnNativeService] Failed to start VPN', e);
      return false;
    }
  }

  /// 停止 VPN
  Future<bool> stopVpn() async {
    try {
      AppLogger.info('[VpnNativeService] Stopping VPN...');
      _clearLastError();
      final result = await _methodChannel.invokeMethod<bool>('stopVpn');
      AppLogger.info('[VpnNativeService] Stop result: $result');
      if (result != true && _lastError == null) {
        _recordLastError('Native VPN stop request was rejected');
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Native VPN stop failed');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to stop VPN: $e');
      AppLogger.error('[VpnNativeService] Failed to stop VPN', e);
      return false;
    }
  }

  /// 重启 VPN
  Future<bool> restartVpn() async {
    try {
      AppLogger.info('[VpnNativeService] Restarting VPN...');
      _clearLastError();
      final result = await _methodChannel.invokeMethod<bool>('restartVpn');
      AppLogger.info('[VpnNativeService] Restart result: $result');
      if (result != true && _lastError == null) {
        _recordLastError('Native VPN restart request was rejected');
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Native VPN restart failed');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to restart VPN: $e');
      AppLogger.error('[VpnNativeService] Failed to restart VPN', e);
      return false;
    }
  }

  /// 检查 VPN 是否正在运行
  Future<bool> isRunning() async {
    try {
      _clearLastError();
      final result = await _methodChannel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to query VPN status');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to check VPN status: $e');
      AppLogger.error('[VpnNativeService] Failed to check VPN status', e);
      return false;
    }
  }

  /// 获取原生 VPN 能力
  Future<VpnNativeCapabilities> getCapabilities() async {
    try {
      _clearLastError();
      final result = await _methodChannel.invokeMethod<Map>('getCapabilities');
      if (result != null) {
        return VpnNativeCapabilities.fromJson(
            Map<String, dynamic>.from(result));
      }
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to get native VPN capabilities');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
    } catch (e) {
      _recordLastError('Failed to get VPN capabilities: $e');
      AppLogger.error('[VpnNativeService] Failed to get capabilities', e);
    }

    return const VpnNativeCapabilities(
      supported: false,
      reason: 'Native VPN capability is unavailable',
    );
  }

  /// 获取 VPN 状态
  Future<VpnNativeStatus?> getStatus() async {
    try {
      _clearLastError();
      final result = await _methodChannel.invokeMethod<Map>('getStatus');
      if (result != null) {
        return VpnNativeStatus.fromJson(Map<String, dynamic>.from(result));
      }
      return null;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to get native VPN status');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return null;
    } catch (e) {
      _recordLastError('Failed to get VPN status: $e');
      AppLogger.error('[VpnNativeService] Failed to get status', e);
      return null;
    }
  }

  /// 获取流量统计
  Future<VpnNativeStats?> getStats() async {
    try {
      _clearLastError();
      final result = await _methodChannel.invokeMethod<Map>('getStats');
      if (result != null) {
        return VpnNativeStats.fromJson(Map<String, dynamic>.from(result));
      }
      return null;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to get native VPN stats');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return null;
    } catch (e) {
      _recordLastError('Failed to get VPN stats: $e');
      AppLogger.error('[VpnNativeService] Failed to get stats', e);
      return null;
    }
  }

  /// 重置流量统计
  Future<bool> resetStats() async {
    try {
      AppLogger.info('[VpnNativeService] Resetting stats...');
      _clearLastError();
      final result = await _methodChannel.invokeMethod<bool>('resetStats');
      if (result != true && _lastError == null) {
        _recordLastError('Native VPN stats reset request was rejected');
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to reset native VPN stats');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to reset VPN stats: $e');
      AppLogger.error('[VpnNativeService] Failed to reset stats', e);
      return false;
    }
  }

  /// 更新 VPN 配置
  Future<bool> updateConfig(String configJson) async {
    try {
      AppLogger.info('[VpnNativeService] Updating config...');
      _clearLastError();
      final result = await _methodChannel.invokeMethod<bool>('updateConfig', {
        'config': configJson,
      });
      if (result != true && _lastError == null) {
        _recordLastError('Native VPN config update was rejected');
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to update native VPN config');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to update VPN config: $e');
      AppLogger.error('[VpnNativeService] Failed to update config', e);
      return false;
    }
  }

  /// 获取版本信息
  Future<String?> getVersion() async {
    try {
      _clearLastError();
      final result = await _methodChannel.invokeMethod<String>('getVersion');
      return result;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to get native VPN version');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return null;
    } catch (e) {
      _recordLastError('Failed to get VPN version: $e');
      AppLogger.error('[VpnNativeService] Failed to get version', e);
      return null;
    }
  }

  /// 请求 VPN 权限 (Android)
  Future<bool> requestPermission() async {
    try {
      AppLogger.info('[VpnNativeService] Requesting VPN permission...');
      _clearLastError();
      final result =
          await _methodChannel.invokeMethod<bool>('requestPermission');
      if (result != true && _lastError == null) {
        _recordLastError('Native VPN permission request was rejected');
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _recordLastError(e.message ?? 'Failed to request VPN permission');
      AppLogger.error('[VpnNativeService] Platform exception: ${e.message}', e);
      return false;
    } catch (e) {
      _recordLastError('Failed to request VPN permission: $e');
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
          final status = VpnNativeStatus.fromJson(
            Map<String, dynamic>.from(eventData['data'] as Map),
          );
          if (status.message != null && status.message!.isNotEmpty) {
            _recordLastError(status.message!);
          } else if (status.running || status.status == 'disconnected') {
            _clearLastError();
          }
          _statusController.add(status);
          break;

        case 'stats':
          final stats = VpnNativeStats.fromJson(eventData['data']);
          _statsController.add(stats);
          break;

        case 'error':
          final error = eventData['message'] as String?;
          if (error != null && error.isNotEmpty) {
            _recordLastError(error);
          }
          AppLogger.error('[VpnNativeService] Native error: $error');
          break;

        default:
          AppLogger.warning(
              '[VpnNativeService] Unknown event type: $eventType');
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

class VpnNativeCapabilities {
  final bool supported;
  final String? reason;

  const VpnNativeCapabilities({
    required this.supported,
    this.reason,
  });

  factory VpnNativeCapabilities.fromJson(Map<String, dynamic> json) {
    final supported = json['supported'] == true;
    final reason = json['reason']?.toString();
    return VpnNativeCapabilities(
      supported: supported,
      reason: reason == null || reason.isEmpty ? null : reason,
    );
  }
}

/// VPN 原生状态
class VpnNativeStatus {
  final bool running;
  final String status;
  final String? message;
  final int connectedAt;
  final int uptime;

  VpnNativeStatus({
    required this.running,
    required this.status,
    this.message,
    required this.connectedAt,
    required this.uptime,
  });

  factory VpnNativeStatus.fromJson(Map<String, dynamic> json) {
    final running = _toBool(json['running'], defaultValue: false);
    final status = (json['status'] ?? (running ? 'connected' : 'disconnected'))
        .toString()
        .toLowerCase()
        .trim();
    final message = json['message']?.toString();

    return VpnNativeStatus(
      running: running,
      status: status,
      message: message == null || message.isEmpty ? null : message,
      connectedAt: (json['connected_at'] as num?)?.toInt() ?? 0,
      uptime: (json['uptime'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'running': running,
      'status': status,
      'message': message,
      'connected_at': connectedAt,
      'uptime': uptime,
    };
  }
}

bool _toBool(dynamic value, {required bool defaultValue}) {
  if (value == null) {
    return defaultValue;
  }
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
  }
  return defaultValue;
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
