import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../shared/utils/logger.dart';
import 'dart:async';

class DashboardProvider with ChangeNotifier {
  final ApiClient apiClient;

  SystemInfo? _systemInfo;
  List<TrafficDataPoint> _trafficHistory = [];
  bool _isLoading = false;
  String? _error;
  Timer? _refreshTimer;

  SystemInfo? get systemInfo => _systemInfo;
  List<TrafficDataPoint> get trafficHistory => _trafficHistory;
  bool get isLoading => _isLoading;
  String? get error => _error;

  DashboardProvider(this.apiClient);

  String _extractError(Map<String, dynamic> response, String fallback) {
    final message = response['message'];
    if (message is String && message.isNotEmpty) return message;
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      final errMsg = error['message'];
      if (errMsg is String && errMsg.isNotEmpty) return errMsg;
    }
    return fallback;
  }

  /// 初始化
  Future<void> initialize() async {
    await loadSystemInfo();
    _startAutoRefresh();
  }

  /// 加载系统信息
  Future<void> loadSystemInfo() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[DashboardProvider] Loading system info...');
      final response = await apiClient.getSystemInfo();

      if (response['success'] == true) {
        _systemInfo = SystemInfo.fromJson(response['data']);
        AppLogger.info('[DashboardProvider] System info loaded');
      } else {
        _error = _extractError(response, 'Failed to load system info');
        AppLogger.error('[DashboardProvider] Load failed: $_error');
      }
    } catch (e) {
      _error = 'Failed to load system info: ${e.toString()}';
      AppLogger.error('[DashboardProvider] Load error', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 加载流量历史数据
  Future<void> loadTrafficHistory() async {
    try {
      AppLogger.info('[DashboardProvider] Loading traffic history...');
      final response = await apiClient.getTrafficStats();

      if (response['success'] == true) {
        final dataPoint = TrafficDataPoint(
          timestamp: DateTime.now(),
          uploadBytes: response['data']['upload_bytes'] ?? 0,
          downloadBytes: response['data']['download_bytes'] ?? 0,
        );

        _trafficHistory.add(dataPoint);

        // 只保留最近100个数据点
        if (_trafficHistory.length > 100) {
          _trafficHistory.removeAt(0);
        }

        AppLogger.debug('[DashboardProvider] Traffic history updated: ${_trafficHistory.length} points');
        notifyListeners();
      }
    } catch (e) {
      AppLogger.error('[DashboardProvider] Failed to load traffic history', e);
    }
  }

  /// 刷新所有数据
  Future<void> refreshAll() async {
    await Future.wait([
      loadSystemInfo(),
      loadTrafficHistory(),
    ]);
  }

  /// 开始自动刷新
  void _startAutoRefresh() {
    _stopAutoRefresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      loadTrafficHistory();
    });
  }

  /// 停止自动刷新
  void _stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    super.dispose();
  }
}

/// 系统信息数据模型
class SystemInfo {
  final String version;
  final String platform;
  final int uptime;
  final MemoryInfo memory;
  final CpuInfo cpu;

  SystemInfo({
    required this.version,
    required this.platform,
    required this.uptime,
    required this.memory,
    required this.cpu,
  });

  factory SystemInfo.fromJson(Map<String, dynamic> json) {
    int toInt(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return SystemInfo(
      version: json['version'] ?? 'Unknown',
      platform: json['platform'] ?? json['os'] ?? 'Unknown',
      uptime: toInt(json['uptime']),
      memory: MemoryInfo.fromJson(json['memory'] ?? {}),
      cpu: CpuInfo.fromJson(json['cpu'] ?? {}),
    );
  }

  String get uptimeFormatted {
    final duration = Duration(seconds: uptime);
    final days = duration.inDays;
    final hours = duration.inHours % 24;
    final minutes = duration.inMinutes % 60;

    if (days > 0) {
      return '${days}d ${hours}h ${minutes}m';
    } else if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }
}

/// 内存信息
class MemoryInfo {
  final int total;
  final int used;
  final int free;

  MemoryInfo({
    required this.total,
    required this.used,
    required this.free,
  });

  factory MemoryInfo.fromJson(Map<String, dynamic> json) {
    int toInt(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return MemoryInfo(
      total: toInt(json['total']),
      used: toInt(json['used']),
      free: toInt(json['free']),
    );
  }

  double get usagePercent => total > 0 ? (used / total) * 100 : 0;

  String get totalFormatted => _formatBytes(total);
  String get usedFormatted => _formatBytes(used);
  String get freeFormatted => _formatBytes(free);

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}

/// CPU 信息
class CpuInfo {
  final int cores;
  final double usage;

  CpuInfo({
    required this.cores,
    required this.usage,
  });

  factory CpuInfo.fromJson(Map<String, dynamic> json) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    int toInt(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return CpuInfo(
      cores: toInt(json['cores']),
      usage: toDouble(json['usage']),
    );
  }

  String get usageFormatted => '${usage.toStringAsFixed(1)}%';
}

/// 流量数据点
class TrafficDataPoint {
  final DateTime timestamp;
  final int uploadBytes;
  final int downloadBytes;

  TrafficDataPoint({
    required this.timestamp,
    required this.uploadBytes,
    required this.downloadBytes,
  });

  int get totalBytes => uploadBytes + downloadBytes;
}
