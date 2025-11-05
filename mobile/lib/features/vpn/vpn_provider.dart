import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../shared/utils/logger.dart';
import 'dart:async';

class VpnProvider with ChangeNotifier {
  final ApiClient apiClient;

  VpnStatus _status = VpnStatus.disconnected;
  String? _activeProfile;
  TrafficStats _stats = TrafficStats.zero();
  bool _isLoading = false;
  String? _error;
  Timer? _statsTimer;

  VpnStatus get status => _status;
  String? get activeProfile => _activeProfile;
  TrafficStats get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConnected => _status == VpnStatus.connected;

  VpnProvider(this.apiClient);

  /// 初始化 - 加载当前状态
  Future<void> initialize() async {
    await loadStatus();
    if (_status == VpnStatus.connected) {
      _startStatsPolling();
    }
  }

  /// 加载 VPN 状态
  Future<void> loadStatus() async {
    try {
      AppLogger.info('[VpnProvider] Loading VPN status...');
      final response = await apiClient.getVpnStatus();

      if (response['success'] == true) {
        final data = response['data'];
        _status = _parseStatus(data['status']);
        _activeProfile = data['active_profile'];

        if (data['stats'] != null) {
          _stats = TrafficStats.fromJson(data['stats']);
        }

        AppLogger.info('[VpnProvider] Status: $_status, Profile: $_activeProfile');
        notifyListeners();
      }
    } catch (e) {
      _error = 'Failed to load VPN status: ${e.toString()}';
      AppLogger.error('[VpnProvider] Load status error', e);
      notifyListeners();
    }
  }

  /// 启动 VPN
  Future<bool> connect() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[VpnProvider] Starting VPN...');
      final response = await apiClient.startVpn();

      if (response['success'] == true) {
        _status = VpnStatus.connecting;
        notifyListeners();

        // 等待连接建立
        await Future.delayed(const Duration(seconds: 2));
        await loadStatus();

        if (_status == VpnStatus.connected) {
          AppLogger.info('[VpnProvider] VPN connected successfully');
          _startStatsPolling();
          return true;
        } else {
          _error = 'VPN failed to connect';
          AppLogger.error('[VpnProvider] Connect failed: $_error');
          return false;
        }
      } else {
        _error = response['message'] ?? 'Failed to start VPN';
        _status = VpnStatus.disconnected;
        AppLogger.error('[VpnProvider] Start failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to start VPN: ${e.toString()}';
      _status = VpnStatus.disconnected;
      AppLogger.error('[VpnProvider] Start error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 停止 VPN
  Future<bool> disconnect() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[VpnProvider] Stopping VPN...');
      final response = await apiClient.stopVpn();

      if (response['success'] == true) {
        _status = VpnStatus.disconnecting;
        notifyListeners();

        // 等待断开完成
        await Future.delayed(const Duration(seconds: 1));

        _status = VpnStatus.disconnected;
        _activeProfile = null;
        _stopStatsPolling();

        AppLogger.info('[VpnProvider] VPN disconnected successfully');
        return true;
      } else {
        _error = response['message'] ?? 'Failed to stop VPN';
        AppLogger.error('[VpnProvider] Stop failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to stop VPN: ${e.toString()}';
      AppLogger.error('[VpnProvider] Stop error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 重启 VPN
  Future<bool> restart() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[VpnProvider] Restarting VPN...');
      final response = await apiClient.restartVpn();

      if (response['success'] == true) {
        _status = VpnStatus.connecting;
        notifyListeners();

        await Future.delayed(const Duration(seconds: 2));
        await loadStatus();

        if (_status == VpnStatus.connected) {
          AppLogger.info('[VpnProvider] VPN restarted successfully');
          return true;
        } else {
          _error = 'VPN failed to restart';
          return false;
        }
      } else {
        _error = response['message'] ?? 'Failed to restart VPN';
        AppLogger.error('[VpnProvider] Restart failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to restart VPN: ${e.toString()}';
      AppLogger.error('[VpnProvider] Restart error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 获取流量统计
  Future<void> loadStats() async {
    try {
      final response = await apiClient.getTrafficStats();

      if (response['success'] == true) {
        _stats = TrafficStats.fromJson(response['data']);
        notifyListeners();
      }
    } catch (e) {
      AppLogger.error('[VpnProvider] Failed to load stats', e);
    }
  }

  /// 重置流量统计
  Future<bool> resetStats() async {
    try {
      AppLogger.info('[VpnProvider] Resetting traffic stats...');
      final response = await apiClient.resetTrafficStats();

      if (response['success'] == true) {
        _stats = TrafficStats.zero();
        AppLogger.info('[VpnProvider] Stats reset successfully');
        notifyListeners();
        return true;
      } else {
        _error = response['message'] ?? 'Failed to reset stats';
        AppLogger.error('[VpnProvider] Reset stats failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to reset stats: ${e.toString()}';
      AppLogger.error('[VpnProvider] Reset stats error', e);
      return false;
    }
  }

  /// 开始定时轮询流量统计
  void _startStatsPolling() {
    _stopStatsPolling();
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_status == VpnStatus.connected) {
        loadStats();
      }
    });
  }

  /// 停止定时轮询
  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  VpnStatus _parseStatus(dynamic status) {
    if (status == null) return VpnStatus.disconnected;

    final statusStr = status.toString().toLowerCase();
    switch (statusStr) {
      case 'connected':
        return VpnStatus.connected;
      case 'connecting':
        return VpnStatus.connecting;
      case 'disconnecting':
        return VpnStatus.disconnecting;
      default:
        return VpnStatus.disconnected;
    }
  }

  @override
  void dispose() {
    _stopStatsPolling();
    super.dispose();
  }
}

/// VPN 连接状态
enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// 流量统计数据模型
class TrafficStats {
  final int uploadBytes;
  final int downloadBytes;
  final double uploadSpeed;   // bytes per second
  final double downloadSpeed; // bytes per second
  final Duration connectionTime;

  TrafficStats({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.connectionTime,
  });

  factory TrafficStats.zero() {
    return TrafficStats(
      uploadBytes: 0,
      downloadBytes: 0,
      uploadSpeed: 0,
      downloadSpeed: 0,
      connectionTime: Duration.zero,
    );
  }

  factory TrafficStats.fromJson(Map<String, dynamic> json) {
    return TrafficStats(
      uploadBytes: json['upload_bytes'] ?? 0,
      downloadBytes: json['download_bytes'] ?? 0,
      uploadSpeed: (json['upload_speed'] ?? 0).toDouble(),
      downloadSpeed: (json['download_speed'] ?? 0).toDouble(),
      connectionTime: Duration(seconds: json['connection_time'] ?? 0),
    );
  }

  int get totalBytes => uploadBytes + downloadBytes;

  String get uploadFormatted => _formatBytes(uploadBytes);
  String get downloadFormatted => _formatBytes(downloadBytes);
  String get totalFormatted => _formatBytes(totalBytes);
  String get uploadSpeedFormatted => '${_formatBytes(uploadSpeed.toInt())}/s';
  String get downloadSpeedFormatted => '${_formatBytes(downloadSpeed.toInt())}/s';

  String get connectionTimeFormatted {
    final hours = connectionTime.inHours;
    final minutes = connectionTime.inMinutes % 60;
    final seconds = connectionTime.inSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'upload_bytes': uploadBytes,
      'download_bytes': downloadBytes,
      'upload_speed': uploadSpeed,
      'download_speed': downloadSpeed,
      'connection_time': connectionTime.inSeconds,
    };
  }
}
