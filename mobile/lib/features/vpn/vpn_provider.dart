import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../services/vpn_native_service.dart';
import '../../shared/utils/logger.dart';
import 'vpn_diagnostics.dart';
import 'vpn_models.dart';
import 'vpn_status_helpers.dart';

export 'vpn_models.dart';
export 'vpn_diagnostics.dart';

class VpnProvider with ChangeNotifier, WidgetsBindingObserver {
  static const String vpnConflictMessage =
      'VPN permission was revoked or another VPN app/system VPN interrupted this connection. Disable the other VPN and try again.';
  static const String egressProbeFailureMessage =
      'Could not reach public IP probe endpoints through the current VPN route. Recent routing decisions below may still be valid.';
  static const Duration nativeEgressProbeTimeout = Duration(seconds: 3);

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
  StreamSubscription? _logSub;
  Future<void>? _initializeTask;
  bool _initialized = false;
  bool _disposed = false;
  final VpnRuntimeLogParser _runtimeLogParser = VpnRuntimeLogParser();
  final Future<String?> Function() _fetchEgressIp;
  String? _diagnosticsEgressIp;
  String? _diagnosticsError;
  bool _isRefreshingDiagnostics = false;
  DateTime? _diagnosticsUpdatedAt;

  VpnStatus get status => _status;
  String? get activeProfile => _activeProfile;
  TrafficStats get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConnected => _status == VpnStatus.connected;
  bool get isSupported => _isSupported;
  String? get unsupportedReason => _unsupportedReason;
  String? get diagnosticsEgressIp => _diagnosticsEgressIp;
  String? get diagnosticsError => _diagnosticsError;
  bool get isRefreshingDiagnostics => _isRefreshingDiagnostics;
  DateTime? get diagnosticsUpdatedAt => _diagnosticsUpdatedAt;
  List<VpnRouteDecision> get recentRouteDecisions =>
      _runtimeLogParser.recentDecisions;

  VpnProvider({
    Future<String?> Function()? fetchEgressIp,
  }) : _fetchEgressIp = fetchEgressIp ?? fetchVpnEgressIp {
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
      await _logSub?.cancel();
      _statusSub = _nativeService.statusStream.listen((nativeStatus) {
        _applyNativeStatus(nativeStatus);
      });

      _statsSub = _nativeService.statsStream.listen((nativeStats) {
        _stats = trafficStatsFromNative(nativeStats);
        _safeNotifyListeners();
      });
      _logSub = _nativeService.logStream.listen(_applyNativeLogEntry);
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

  Future<bool> connect({
    String? configJson,
    String? profileName,
    Duration stabilityCheckDuration = Duration.zero,
    Duration statusPollInterval = const Duration(milliseconds: 250),
  }) async {
    if (!_isSupported) {
      _error = _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return false;
    }
    _isLoading = true;
    _error = null;
    _status = VpnStatus.connecting;
    _runtimeLogParser.reset();
    _diagnosticsEgressIp = null;
    _diagnosticsError = null;
    _diagnosticsUpdatedAt = null;
    _safeNotifyListeners();

    try {
      final config = configJson ?? '{}';
      final success = await _nativeService.startVpn(config);

      if (success) {
        _activeProfile = profileName;
        await loadStatus();
        if (_status == VpnStatus.connected) {
          final stable = await _verifyStableConnection(
            stabilityCheckDuration: stabilityCheckDuration,
            statusPollInterval: statusPollInterval,
          );
          if (!stable) {
            return false;
          }
          AppLogger.info('[VpnProvider] VPN connected');
          return true;
        }

        _status = VpnStatus.disconnected;
        _error = _normalizeVpnError(
              _nativeService.lastError ??
                  _error ??
                  'VPN did not reach connected state',
            ) ??
            'VPN did not reach connected state';
        return false;
      } else {
        _status = VpnStatus.disconnected;
        _stopStatsPolling();
        _error = _normalizeVpnError(_nativeService.lastError) ??
            'Failed to start VPN';
        return false;
      }
    } catch (e) {
      _error = _normalizeVpnError(e.toString()) ??
          'Failed to start VPN: ${e.toString()}';
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
        await _waitForNativeDisconnect();
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

  Future<void> refreshDiagnostics() async {
    if (!_isSupported) {
      _diagnosticsError =
          _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return;
    }

    _isRefreshingDiagnostics = true;
    _diagnosticsError = null;
    _safeNotifyListeners();

    try {
      final logs = await _nativeService.getRecentLogs();
      _runtimeLogParser.replaceWith(logs);
      _diagnosticsUpdatedAt = DateTime.now();

      if (_status == VpnStatus.connected) {
        await _refreshConnectedDiagnosticsEgressIp();
      } else {
        _diagnosticsEgressIp = null;
      }
    } catch (e) {
      _diagnosticsError = 'Failed to refresh diagnostics: $e';
    } finally {
      _isRefreshingDiagnostics = false;
      _safeNotifyListeners();
    }
  }

  Future<void> _refreshConnectedDiagnosticsEgressIp() async {
    final nativeProbe = await _nativeService.getEgressIp().timeout(
          nativeEgressProbeTimeout,
          onTimeout: () => const VpnNativeEgressProbeResult(
            error: egressProbeFailureMessage,
          ),
        );
    if (nativeProbe?.hasIp == true) {
      _diagnosticsEgressIp = nativeProbe!.ip;
      _diagnosticsError = null;
      return;
    }

    final nativeError = nativeProbe?.error;
    if (nativeError != null && nativeError.isNotEmpty) {
      _diagnosticsEgressIp = null;
      _diagnosticsError = _normalizeEgressProbeError(nativeError);
      return;
    }

    try {
      _diagnosticsEgressIp = await _fetchEgressIp();
      _diagnosticsError = null;
    } catch (_) {
      _diagnosticsEgressIp = null;
      _diagnosticsError = egressProbeFailureMessage;
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

  Future<bool> _verifyStableConnection({
    required Duration stabilityCheckDuration,
    required Duration statusPollInterval,
  }) async {
    if (stabilityCheckDuration <= Duration.zero) {
      return true;
    }

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < stabilityCheckDuration) {
      final remaining = stabilityCheckDuration - stopwatch.elapsed;
      final nextDelay =
          remaining < statusPollInterval ? remaining : statusPollInterval;
      if (nextDelay > Duration.zero) {
        await Future<void>.delayed(nextDelay);
      }

      await loadStatus();
      if (_status != VpnStatus.connected) {
        _error = _normalizeVpnError(_error ?? _nativeService.lastError) ??
            'VPN connection was interrupted during startup';
        return false;
      }
    }

    return true;
  }

  Future<void> _waitForNativeDisconnect({
    Duration timeout = const Duration(seconds: 3),
    Duration pollInterval = const Duration(milliseconds: 100),
    Duration settleDelay = const Duration(milliseconds: 150),
  }) async {
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsed < timeout) {
      final nativeStatus = await _nativeService.getStatus();
      final isRunning =
          nativeStatus?.running ?? await _nativeService.isRunning();
      final normalizedStatus =
          nativeStatus?.status.trim().toLowerCase() ?? 'disconnected';
      if (!isRunning &&
          (normalizedStatus == 'disconnected' ||
              normalizedStatus == 'error' ||
              normalizedStatus == 'revoked')) {
        if (settleDelay > Duration.zero) {
          await Future<void>.delayed(settleDelay);
        }
        return;
      }
      await Future<void>.delayed(pollInterval);
    }

    if (settleDelay > Duration.zero) {
      await Future<void>.delayed(settleDelay);
    }
  }

  String? _normalizeVpnError(String? message) {
    if (isVpnConflictMessage(message)) {
      return vpnConflictMessage;
    }
    return message;
  }

  String _normalizeEgressProbeError(String message) {
    final normalized = message.trim();
    if (normalized.isEmpty) {
      return egressProbeFailureMessage;
    }

    final lower = normalized.toLowerCase();
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('could not reach public ip probe endpoints') ||
        lower.contains('unable to determine current egress ip')) {
      return egressProbeFailureMessage;
    }
    return normalized;
  }

  void _applyNativeStatus(VpnNativeStatus nativeStatus, {bool notify = true}) {
    final previousStatus = _status;
    _status = vpnStatusFromNative(nativeStatus);

    final message = nativeStatus.message?.trim();
    final normalizedStatus = nativeStatus.status.trim().toLowerCase();
    final preserveConflictMessage = _error == vpnConflictMessage &&
        (normalizedStatus == 'disconnecting' ||
            normalizedStatus == 'disconnected') &&
        (message == null || message.isEmpty);
    if (isVpnConflictTransition(
      previousStatus: previousStatus,
      nativeStatus: nativeStatus,
      message: message,
    )) {
      _error = vpnConflictMessage;
    } else if (message != null && message.isNotEmpty) {
      _error = _normalizeVpnError(message);
    } else if (nativeStatus.status != 'error' &&
        nativeStatus.status != 'revoked' &&
        !preserveConflictMessage) {
      _error = null;
    }

    if (_status == VpnStatus.connected) {
      _startStatsPolling();
    } else {
      _stopStatsPolling();
      _diagnosticsEgressIp = null;
    }

    if (notify) {
      _safeNotifyListeners();
    }
  }

  void _applyNativeLogEntry(VpnNativeLogEntry entry) {
    final decision = _runtimeLogParser.ingest(entry);
    if (decision == null) {
      return;
    }
    _diagnosticsUpdatedAt = entry.timestamp;
    _safeNotifyListeners();
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
    _logSub?.cancel();
    super.dispose();
  }
}
