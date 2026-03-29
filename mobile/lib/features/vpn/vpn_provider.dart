import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../services/vpn_native_service.dart';
import '../../shared/utils/logger.dart';
import 'vpn_models.dart';
import 'vpn_status_helpers.dart';

export 'vpn_models.dart';

class VpnProvider with ChangeNotifier, WidgetsBindingObserver {
  static const String vpnConflictMessage =
      'Another VPN app or system VPN interrupted this connection. Disable the other VPN and try again.';

  final VpnNativeService _nativeService = VpnNativeService.instance;

  VpnStatus _status = VpnStatus.disconnected;
  String? _activeProfile;
  TrafficStats _stats = TrafficStats.zero();
  bool _isLoading = false;
  String? _error;
  bool _isSupported = true;
  String? _unsupportedReason;
  Timer? _statsTimer;
  StreamSubscription? _statusSub;
  StreamSubscription? _statsSub;
  Future<void>? _initializeTask;
  bool _initialized = false;
  bool _disposed = false;

  VpnStatus get status => _status;
  String? get activeProfile => _activeProfile;
  TrafficStats get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConnected => _status == VpnStatus.connected;
  bool get isSupported => _isSupported;
  String? get unsupportedReason => _unsupportedReason;

  VpnProvider() {
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> initialize() async {
    if (_initialized) {
      await loadStatus();
      return;
    }
    if (_initializeTask != null) {
      await _initializeTask;
      return;
    }

    _initializeTask = _initializeInternal();
    await _initializeTask;
  }

  Future<void> _initializeInternal() async {
    var initializedNow = false;
    try {
      await _nativeService.initialize();

      final capabilities = await _nativeService.getCapabilities();
      _isSupported = capabilities.supported;
      _unsupportedReason = capabilities.reason;
      if (!_isSupported) {
        _status = VpnStatus.disconnected;
        _error = _unsupportedReason;
        _stopStatsPolling();
        initializedNow = true;
        _safeNotifyListeners();
        return;
      }

      await _statusSub?.cancel();
      await _statsSub?.cancel();
      _statusSub = _nativeService.statusStream.listen((nativeStatus) {
        _applyNativeStatus(nativeStatus);
      });

      _statsSub = _nativeService.statsStream.listen((nativeStats) {
        _stats = trafficStatsFromNative(nativeStats);
        _safeNotifyListeners();
      });
      initializedNow = true;
    } catch (e) {
      AppLogger.error('[VpnProvider] Initialize error', e);
    } finally {
      _initialized = initializedNow;
      _initializeTask = null;
    }

    await loadStatus();
    if (_status == VpnStatus.connected) {
      _startStatsPolling();
    }
  }

  Future<void> loadStatus() async {
    if (!_isSupported) {
      _status = VpnStatus.disconnected;
      _error = _unsupportedReason;
      _stopStatsPolling();
      _safeNotifyListeners();
      return;
    }
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
      _safeNotifyListeners();
    } catch (e) {
      _error = 'Failed to load status: ${e.toString()}';
      AppLogger.error('[VpnProvider] Load status error', e);
      _safeNotifyListeners();
    }
  }

  Future<bool> connect({String? configJson, String? profileName}) async {
    if (!_isSupported) {
      _error = _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return false;
    }
    _isLoading = true;
    _error = null;
    _status = VpnStatus.connecting;
    _safeNotifyListeners();

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
      _safeNotifyListeners();
    }
  }

  Future<bool> disconnect() async {
    if (!_isSupported) {
      _error = _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return false;
    }
    _isLoading = true;
    _error = null;
    _status = VpnStatus.disconnecting;
    _safeNotifyListeners();

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
      _safeNotifyListeners();
    }
  }

  Future<bool> restart() async {
    if (!_isSupported) {
      _error = _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return false;
    }
    _isLoading = true;
    _error = null;
    _safeNotifyListeners();

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
      _safeNotifyListeners();
    }
  }

  Future<void> loadStats() async {
    if (!_isSupported) {
      return;
    }
    try {
      final nativeStats = await _nativeService.getStats();
      if (nativeStats != null) {
        _stats = trafficStatsFromNative(nativeStats);
        _safeNotifyListeners();
      }
    } catch (e) {
      AppLogger.error('[VpnProvider] Failed to load stats', e);
    }
  }

  Future<bool> resetStats() async {
    if (!_isSupported) {
      _error = _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return false;
    }
    try {
      final success = await _nativeService.resetStats();
      if (success) {
        _stats = TrafficStats.zero();
        _safeNotifyListeners();
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
    _status = vpnStatusFromNative(nativeStatus);

    final message = nativeStatus.message?.trim();
    if (isVpnConflictTransition(
      previousStatus: previousStatus,
      nativeStatus: nativeStatus,
      message: message,
    )) {
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
      _safeNotifyListeners();
    }
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(loadStatus());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopStatsPolling();
    _statusSub?.cancel();
    _statsSub?.cancel();
    super.dispose();
  }
}
