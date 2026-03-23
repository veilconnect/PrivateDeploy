import 'package:flutter/foundation.dart';
import '../../services/vpn_native_service.dart';
import '../../shared/utils/logger.dart';
import 'dart:async';

class VpnProvider with ChangeNotifier {
  static const String vpnConflictMessage =
      'Another VPN app or system VPN interrupted this connection. Disable the other VPN and try again.';

  final VpnNativeService _nativeService = VpnNativeService.instance;

  VpnStatus _status = VpnStatus.disconnected;
  String? _activeProfile;
  TrafficStats _stats = TrafficStats.zero();
  bool _isLoading = false;
  String? _error;
  Timer? _statsTimer;
  StreamSubscription? _statusSub;
  StreamSubscription? _statsSub;

  VpnStatus get status => _status;
  String? get activeProfile => _activeProfile;
  TrafficStats get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConnected => _status == VpnStatus.connected;

  VpnProvider();

  Future<void> initialize() async {
    try {
      await _nativeService.initialize();

      _statusSub = _nativeService.statusStream.listen((nativeStatus) {
        _applyNativeStatus(nativeStatus);
      });

      _statsSub = _nativeService.statsStream.listen((nativeStats) {
        _stats = TrafficStats(
          uploadBytes: nativeStats.uploadBytes,
          downloadBytes: nativeStats.downloadBytes,
          uploadSpeed: nativeStats.uploadSpeed.toDouble(),
          downloadSpeed: nativeStats.downloadSpeed.toDouble(),
          connectionTime: Duration.zero,
        );
        notifyListeners();
      });
    } catch (e) {
      AppLogger.error('[VpnProvider] Initialize error', e);
    }

    await loadStatus();
    if (_status == VpnStatus.connected) {
      _startStatsPolling();
    }
  }

  Future<void> loadStatus() async {
    try {
      final nativeStatus = await _nativeService.getStatus();
      if (nativeStatus != null) {
        _applyNativeStatus(nativeStatus, notify: false);
      } else {
        final running = await _nativeService.isRunning();
        _status = running ? VpnStatus.connected : VpnStatus.disconnected;
        _error = running ? null : _nativeService.lastError;
        if (running) {
          _startStatsPolling();
        } else {
          _stopStatsPolling();
        }
      }
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load status: ${e.toString()}';
      AppLogger.error('[VpnProvider] Load status error', e);
      notifyListeners();
    }
  }

  Future<bool> connect({String? configJson, String? profileName}) async {
    _isLoading = true;
    _error = null;
    _status = VpnStatus.connecting;
    notifyListeners();

    try {
      final config = configJson ?? '{}';
      final success = await _nativeService.startVpn(config);

      if (success) {
        _activeProfile = profileName;
        await loadStatus();
        if (_status == VpnStatus.connected) {
          AppLogger.info('[VpnProvider] VPN connected');
          return true;
        }

        _status = VpnStatus.disconnected;
        _error = _nativeService.lastError ??
            _error ??
            'VPN did not reach connected state';
        return false;
      } else {
        _status = VpnStatus.disconnected;
        _stopStatsPolling();
        _error = _nativeService.lastError ?? 'Failed to start VPN';
        return false;
      }
    } catch (e) {
      _error = 'Failed to start VPN: ${e.toString()}';
      _status = VpnStatus.disconnected;
      _stopStatsPolling();
      AppLogger.error('[VpnProvider] Start error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> disconnect() async {
    _isLoading = true;
    _error = null;
    _status = VpnStatus.disconnecting;
    notifyListeners();

    try {
      final success = await _nativeService.stopVpn();
      if (success) {
        _status = VpnStatus.disconnected;
        _activeProfile = null;
        _stopStatsPolling();
      } else {
        _status = VpnStatus.connected;
        _error = _nativeService.lastError ?? 'Failed to stop VPN';
      }
      return success;
    } catch (e) {
      _error = 'Failed to stop VPN: ${e.toString()}';
      AppLogger.error('[VpnProvider] Stop error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> restart() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final success = await _nativeService.restartVpn();
      if (success) {
        await loadStatus();
        if (_status == VpnStatus.connected) {
          return true;
        }
        _error = _nativeService.lastError ??
            _error ??
            'VPN did not restart successfully';
        return false;
      } else {
        _error = _nativeService.lastError ?? 'Failed to restart VPN';
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

  Future<void> loadStats() async {
    try {
      final nativeStats = await _nativeService.getStats();
      if (nativeStats != null) {
        _stats = TrafficStats(
          uploadBytes: nativeStats.uploadBytes,
          downloadBytes: nativeStats.downloadBytes,
          uploadSpeed: nativeStats.uploadSpeed.toDouble(),
          downloadSpeed: nativeStats.downloadSpeed.toDouble(),
          connectionTime: Duration.zero,
        );
        notifyListeners();
      }
    } catch (e) {
      AppLogger.error('[VpnProvider] Failed to load stats', e);
    }
  }

  Future<bool> resetStats() async {
    try {
      final success = await _nativeService.resetStats();
      if (success) {
        _stats = TrafficStats.zero();
        notifyListeners();
      } else {
        _error = _nativeService.lastError ?? 'Failed to reset stats';
      }
      return success;
    } catch (e) {
      _error = 'Failed to reset stats: ${e.toString()}';
      return false;
    }
  }

  void _startStatsPolling() {
    _stopStatsPolling();
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_status == VpnStatus.connected) {
        loadStats();
      }
    });
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _applyNativeStatus(VpnNativeStatus nativeStatus, {bool notify = true}) {
    final previousStatus = _status;

    switch (nativeStatus.status) {
      case 'connecting':
        _status = VpnStatus.connecting;
        break;
      case 'disconnecting':
        _status = VpnStatus.disconnecting;
        break;
      default:
        _status =
            nativeStatus.running ? VpnStatus.connected : VpnStatus.disconnected;
        break;
    }

    final message = nativeStatus.message?.trim();
    if (_isVpnConflict(previousStatus, nativeStatus, message)) {
      _error = vpnConflictMessage;
    } else if (message != null && message.isNotEmpty) {
      _error = message;
    } else if (nativeStatus.status != 'error' &&
        nativeStatus.status != 'revoked') {
      _error = null;
    }

    if (_status == VpnStatus.connected) {
      _startStatsPolling();
    } else {
      _stopStatsPolling();
    }

    if (notify) {
      notifyListeners();
    }
  }

  bool _isVpnConflict(
    VpnStatus previousStatus,
    VpnNativeStatus nativeStatus,
    String? message,
  ) {
    if (nativeStatus.status == 'revoked' &&
        previousStatus == VpnStatus.connected) {
      return true;
    }

    if (previousStatus != VpnStatus.connected) {
      return false;
    }

    final normalizedMessage = message?.toLowerCase();
    return normalizedMessage?.contains('permission revoked') == true;
  }

  @override
  void dispose() {
    _stopStatsPolling();
    _statusSub?.cancel();
    _statsSub?.cancel();
    super.dispose();
  }
}

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

class TrafficStats {
  final int uploadBytes;
  final int downloadBytes;
  final double uploadSpeed;
  final double downloadSpeed;
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

  int get totalBytes => uploadBytes + downloadBytes;

  String get uploadFormatted => _formatBytes(uploadBytes);
  String get downloadFormatted => _formatBytes(downloadBytes);
  String get totalFormatted => _formatBytes(totalBytes);
  String get uploadSpeedFormatted => '${_formatBytes(uploadSpeed.toInt())}/s';
  String get downloadSpeedFormatted =>
      '${_formatBytes(downloadSpeed.toInt())}/s';

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
}
