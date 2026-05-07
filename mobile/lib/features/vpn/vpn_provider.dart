import 'dart:async';
import 'dart:io' show Platform;

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
  static const String vpnPermissionDeniedMessage =
      'VPN permission was not granted. Allow VPN access and try again.';
  static const String egressProbeFailureMessage =
      'Could not reach public IP probe endpoints through the current VPN route. Recent routing decisions below may still be valid.';
  static const String startupConnectivityFailureMessage =
      'VPN tunnel started, but traffic could not reach public IP probe endpoints through the selected node. The node may be unreachable or misconfigured.';
  static const String startupProbeInconclusiveMessage =
      'VPN connected, but Android could not confirm the public IP during startup. Traffic may still be available.';
  // Mirrors the canonical English string emitted by PrivateDeployVpnService
  // when checkTunnelHealth() classifies the route as UpstreamDegraded
  // (tunnel forwards traffic, but the upstream node itself is unreachable —
  // typically because a cellular carrier is dropping SYNs to the VPS IP).
  // localizeVpnStatusMessage() switches on this exact value to render the
  // user-facing translated banner copy, so the Kotlin side MUST emit a
  // bit-identical string. See PrivateDeployVpnService.describeTunnelHealth().
  static const String tunnelUpstreamDegradedMessage =
      "Tunnel is up, but this node's upstream can't be reached from your current network. Try Wi-Fi or switching to a different node — cellular carriers sometimes block VPS IPs.";
  static const Duration nativeEgressProbeTimeout = Duration(seconds: 3);
  static const Duration startupEgressProbeTimeout = Duration(seconds: 5);
  static const Duration androidStartupRetryDelay = Duration(seconds: 3);
  static const Duration androidStartupFallbackProbeDelay =
      Duration(milliseconds: 1500);

  // How long we tolerate a sustained UpstreamDegraded broadcast before
  // restarting the tunnel ourselves. The native VpnService only re-runs its
  // health probe at startup, so a route that comes up partially blocked stays
  // partially blocked until the user notices and taps "重启 VPN" — observed in
  // production where urltest's `tolerance: 200ms` keeps a marginal first
  // member selected even when a sibling pool member would carry traffic
  // cleanly. The watchdog kicks core.restart() to force urltest to re-probe
  // every member from scratch and pick a healthy one.
  static const Duration upstreamDegradedRestartDelay = Duration(seconds: 30);
  static const int maxUpstreamDegradedRestartAttempts = 2;

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
  Timer? _logNotifyTimer;
  Timer? _deferredStartupDiagnosticsTimer;
  int _startupVerificationGeneration = 0;
  Future<void>? _initializeTask;
  bool _initialized = false;
  bool _disposed = false;
  Duration _connectionTimeBase = Duration.zero;
  DateTime? _connectionTimeBaseAt;
  bool _diagnosticsSessionActive = false;
  final VpnRuntimeLogParser _runtimeLogParser = VpnRuntimeLogParser();
  final Future<String?> Function() _fetchEgressIp;
  final bool _softFailStartupConnectivityProbe;
  final Duration _androidStartupRetryDelay;
  final Duration _androidStartupFallbackProbeDelay;
  String? Function(String? activeProfile)? _resolveFallbackEgressIp;
  String? _diagnosticsEgressIp;
  String? _diagnosticsError;
  bool _isRefreshingDiagnostics = false;
  DateTime? _diagnosticsUpdatedAt;
  // Last egress IP that we successfully observed during the current tunnel
  // session. We keep it around across intermittent probe failures so the
  // diagnostics panel can still show a meaningful value while the VPN is
  // actually forwarding traffic — otherwise a flaky probe during a Wi-Fi ↔
  // cellular hand-off would wipe the displayed IP and mislead the user into
  // thinking the VPN is broken. Cleared only on explicit disconnect, not on
  // per-probe failure.
  String? _lastKnownEgressIp;
  DateTime? _lastKnownEgressIpAt;
  Timer? _upstreamDegradedWatchdog;
  int _upstreamDegradedRestartAttempts = 0;

  VpnStatus get status => _status;
  String? get activeProfile => _activeProfile;
  TrafficStats get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Clears any sticky error banner. Call this when the cause of the error
  /// has been resolved (e.g. the offending profile was deleted, or the user
  /// dismissed a transient probe failure).
  void clearError() {
    if (_error == null) {
      return;
    }
    _error = null;
    notifyListeners();
  }
  bool get isConnected => _status == VpnStatus.connected;
  bool get isSupported => _isSupported;
  String? get unsupportedReason => _unsupportedReason;
  String? get diagnosticsEgressIp => _diagnosticsEgressIp;
  String? get diagnosticsError => _diagnosticsError;
  bool get isRefreshingDiagnostics => _isRefreshingDiagnostics;
  DateTime? get diagnosticsUpdatedAt => _diagnosticsUpdatedAt;
  String? get lastKnownEgressIp => _lastKnownEgressIp;
  DateTime? get lastKnownEgressIpAt => _lastKnownEgressIpAt;
  List<VpnRouteDecision> get recentRouteDecisions =>
      _runtimeLogParser.recentDecisions;

  VpnProvider({
    Future<String?> Function()? fetchEgressIp,
    bool? softFailStartupConnectivityProbe,
    Duration? androidStartupRetryDelay,
    Duration? androidStartupFallbackProbeDelay,
  })  : _fetchEgressIp = fetchEgressIp ?? fetchVpnEgressIp,
        _softFailStartupConnectivityProbe =
            softFailStartupConnectivityProbe ?? Platform.isAndroid,
        _androidStartupRetryDelay =
            androidStartupRetryDelay ?? VpnProvider.androidStartupRetryDelay,
        _androidStartupFallbackProbeDelay = androidStartupFallbackProbeDelay ??
            VpnProvider.androidStartupFallbackProbeDelay {
    WidgetsBinding.instance.addObserver(this);
  }

  void setFallbackEgressIpResolver(
    String? Function(String? activeProfile)? resolver,
  ) {
    _resolveFallbackEgressIp = resolver;
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
        _stats = trafficStatsFromNative(
          nativeStats,
          connectionTime: _currentConnectionTime(),
        );
        _safeNotifyListeners();
      });
      if (_diagnosticsSessionActive) {
        _logSub = _nativeService.logStream.listen(_applyNativeLogEntry);
      }
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

    _cancelStartupVerification();
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
          final generation = ++_startupVerificationGeneration;
          final verified = await _runStartupVerification(
            generation: generation,
            stabilityCheckDuration: stabilityCheckDuration,
            statusPollInterval: statusPollInterval,
          );
          if (!verified) {
            return false;
          }
          _isLoading = false;
          _safeNotifyListeners();
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
    _cancelStartupVerification();
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
        _lastKnownEgressIp = null;
        _lastKnownEgressIpAt = null;
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
    _cancelStartupVerification();
    _isLoading = true;
    _error = null;
    _safeNotifyListeners();

    try {
      final success = await _nativeService.restartVpn();
      if (success) {
        await loadStatus();
        if (_status == VpnStatus.connected) {
          final generation = ++_startupVerificationGeneration;
          final verified = await _runStartupVerification(
            generation: generation,
            stabilityCheckDuration: Duration.zero,
            statusPollInterval: const Duration(milliseconds: 250),
          );
          if (!verified) {
            return false;
          }
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
        _stats = trafficStatsFromNative(
          nativeStats,
          connectionTime: _currentConnectionTime(),
        );
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

  Future<void> activateDiagnosticsSession() async {
    _diagnosticsSessionActive = true;
    if (!_isSupported || _logSub != null) {
      return;
    }
    _logSub = _nativeService.logStream.listen(_applyNativeLogEntry);
  }

  Future<void> deactivateDiagnosticsSession() async {
    _diagnosticsSessionActive = false;
    await _logSub?.cancel();
    _logSub = null;
    _logNotifyTimer?.cancel();
    _logNotifyTimer = null;
  }

  Future<void> _refreshConnectedDiagnosticsEgressIp() async {
    final nativeProbe = await _nativeService.getEgressIp().timeout(
          nativeEgressProbeTimeout,
          onTimeout: () => const VpnNativeEgressProbeResult(
            error: egressProbeFailureMessage,
          ),
        );
    if (nativeProbe?.hasIp == true) {
      _recordEgressIpSuccess(nativeProbe!.ip);
      return;
    }

    final nativeError = nativeProbe?.error;
    final normalizedProbeError = nativeError != null && nativeError.isNotEmpty
        ? _normalizeEgressProbeError(nativeError)
        : egressProbeFailureMessage;
    final fallbackEgressIp = _resolveFallbackEgressIp?.call(_activeProfile);
    if (fallbackEgressIp != null && fallbackEgressIp.trim().isNotEmpty) {
      _recordEgressIpSuccess(fallbackEgressIp);
      return;
    }

    try {
      final fetched = await _fetchEgressIp();
      if (fetched != null && fetched.trim().isNotEmpty) {
        _recordEgressIpSuccess(fetched);
        return;
      }
      _diagnosticsEgressIp = null;
      _diagnosticsError = normalizedProbeError;
    } catch (_) {
      _diagnosticsEgressIp = null;
      _diagnosticsError = normalizedProbeError;
    }
  }

  void _recordEgressIpSuccess(String? rawIp) {
    final normalized = rawIp?.trim();
    if (normalized == null || normalized.isEmpty) {
      return;
    }
    _diagnosticsEgressIp = normalized;
    _diagnosticsError = null;
    _lastKnownEgressIp = normalized;
    _lastKnownEgressIpAt = DateTime.now();
  }

  void _startStatsPolling() {
    _stopStatsPolling();
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_status == VpnStatus.connected) {
        loadStats();
      }
    });
  }

  void _cancelStartupVerification() {
    _deferredStartupDiagnosticsTimer?.cancel();
    _deferredStartupDiagnosticsTimer = null;
    _startupVerificationGeneration += 1;
  }

  Future<bool> _runStartupVerification({
    required int generation,
    required Duration stabilityCheckDuration,
    required Duration statusPollInterval,
  }) async {
    final stable = await _verifyStableConnection(
      generation: generation,
      stabilityCheckDuration: stabilityCheckDuration,
      statusPollInterval: statusPollInterval,
    );
    if (!_isActiveStartupVerification(generation)) {
      return false;
    }
    if (!stable) {
      await _failStartupVerification(
        generation: generation,
        fallbackMessage: 'VPN connection was interrupted during startup',
      );
      return false;
    }

    final egressReachable = await _verifyStartupEgressConnectivity(
      generation: generation,
    );
    if (!_isActiveStartupVerification(generation)) {
      return false;
    }
    if (!egressReachable) {
      await _failStartupVerification(
        generation: generation,
        fallbackMessage: startupConnectivityFailureMessage,
      );
      return false;
    }

    AppLogger.info('[VpnProvider] VPN startup verified');
    return true;
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<bool> _verifyStableConnection({
    required int generation,
    required Duration stabilityCheckDuration,
    required Duration statusPollInterval,
  }) async {
    if (stabilityCheckDuration <= Duration.zero) {
      return true;
    }

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < stabilityCheckDuration) {
      if (!_isActiveStartupVerification(generation)) {
        return true;
      }
      final remaining = stabilityCheckDuration - stopwatch.elapsed;
      final nextDelay =
          remaining < statusPollInterval ? remaining : statusPollInterval;
      if (nextDelay > Duration.zero) {
        await Future<void>.delayed(nextDelay);
      }

      if (!_isActiveStartupVerification(generation)) {
        return true;
      }
      await loadStatus();
      if (!_isActiveStartupVerification(generation)) {
        return true;
      }
      if (_status != VpnStatus.connected) {
        _error = _normalizeVpnError(_error ?? _nativeService.lastError) ??
            'VPN connection was interrupted during startup';
        _safeNotifyListeners();
        return false;
      }
    }

    return true;
  }

  Future<bool> _verifyStartupEgressConnectivity({
    required int generation,
  }) async {
    if (_softFailStartupConnectivityProbe) {
      final egressReachable = await _attemptStartupEgressConfirmation(
        generation: generation,
      );
      if (!_isActiveStartupVerification(generation)) {
        return false;
      }
      if (egressReachable) {
        return true;
      }

      // Android startup probes are advisory only. We have observed false
      // negatives here even when the node is healthy and browsing works, so
      // keep the tunnel up and retry once shortly after connection before we
      // surface any warning through diagnostics.
      _diagnosticsEgressIp = null;
      _diagnosticsError = null;
      _diagnosticsUpdatedAt = null;
      // Preserve any diagnostic message the native VpnService already
      // broadcast (e.g. "upstream blocked, switch nodes" from
      // checkTunnelHealth) — clearing it here would hide the orange banner
      // that tells the user the chosen node can't reach offshore traffic
      // even though the tunnel itself is up. Only clear if _error is the
      // generic startup-failure placeholder, which is what gets set when
      // dart's own cloudflare-fronted probe times out from CN — that one
      // is genuinely advisory and shouldn't clutter the UI.
      if (_error == startupConnectivityFailureMessage) {
        _error = null;
      }
      _scheduleDeferredStartupEgressConfirmation(generation: generation);
      AppLogger.info(
        '[VpnProvider] Android startup probe was inconclusive; deferring diagnostics retry while keeping VPN connected',
      );
      return true;
    }

    VpnNativeEgressProbeResult? nativeProbe;
    try {
      nativeProbe = await _nativeService.getEgressIp().timeout(
            startupEgressProbeTimeout,
            onTimeout: () => const VpnNativeEgressProbeResult(
              error: startupConnectivityFailureMessage,
            ),
          );
      if (!_isActiveStartupVerification(generation)) {
        return false;
      }
      if (nativeProbe?.hasIp == true) {
        _recordEgressIpSuccess(nativeProbe!.ip);
        _diagnosticsUpdatedAt = DateTime.now();
        return true;
      }
    } catch (_) {}

    try {
      final fallbackEgressIp = await _fetchEgressIp().timeout(
        startupEgressProbeTimeout,
      );
      if (!_isActiveStartupVerification(generation)) {
        return false;
      }
      if (fallbackEgressIp != null && fallbackEgressIp.trim().isNotEmpty) {
        _recordEgressIpSuccess(fallbackEgressIp);
        _diagnosticsUpdatedAt = DateTime.now();
        return true;
      }
    } catch (_) {}

    _diagnosticsEgressIp = null;
    _diagnosticsError = _normalizeStartupConnectivityError(nativeProbe?.error);
    _diagnosticsUpdatedAt = DateTime.now();
    _error = _diagnosticsError;
    return false;
  }

  Future<VpnNativeEgressProbeResult?> _runNativeStartupEgressProbe({
    required int generation,
  }) async {
    try {
      final nativeProbe = await _nativeService.getEgressIp().timeout(
            startupEgressProbeTimeout,
            onTimeout: () => const VpnNativeEgressProbeResult(
              error: startupConnectivityFailureMessage,
            ),
          );
      if (!_isActiveStartupVerification(generation)) {
        return null;
      }
      return nativeProbe;
    } catch (error) {
      AppLogger.warning(
        '[VpnProvider] Native startup egress probe failed: $error',
      );
      return const VpnNativeEgressProbeResult(
        error: startupConnectivityFailureMessage,
      );
    }
  }

  Future<bool> _attemptStartupEgressConfirmation({
    required int generation,
  }) async {
    var resolutionChosen = false;
    final nativeProbeFuture = _runNativeStartupEgressProbe(
      generation: generation,
    );
    final earlyNativeProbe = await nativeProbeFuture.timeout(
      _androidStartupFallbackProbeDelay,
      onTimeout: () => null,
    );
    if (!_isActiveStartupVerification(generation)) {
      return false;
    }
    if (_recordSuccessfulStartupProbe(
      ip: earlyNativeProbe?.ip,
      sourceLabel: 'native HTTP',
    )) {
      return true;
    }

    final pendingAttempts =
        <Object, Future<({Object token, String? ip, String source})>>{};
    if (earlyNativeProbe == null) {
      final token = Object();
      pendingAttempts[token] = nativeProbeFuture.then(
        (probe) => (
          token: token,
          ip: probe?.ip?.trim(),
          source: 'native HTTP',
        ),
      );
    }

    final dartToken = Object();
    pendingAttempts[dartToken] = _runDartStartupEgressProbe(
      generation: generation,
      shouldSuppressFailureLog: () =>
          resolutionChosen || !_isActiveStartupVerification(generation),
    ).then(
      (ip) => (
        token: dartToken,
        ip: ip,
        source: 'Dart sockets',
      ),
    );

    while (pendingAttempts.isNotEmpty) {
      final result = await Future.any(pendingAttempts.values);
      pendingAttempts.remove(result.token);
      if (!_isActiveStartupVerification(generation)) {
        resolutionChosen = true;
        return false;
      }
      if (_recordSuccessfulStartupProbe(
        ip: result.ip,
        sourceLabel: result.source,
      )) {
        resolutionChosen = true;
        return true;
      }
    }

    resolutionChosen = true;
    return false;
  }

  Future<String?> _runDartStartupEgressProbe({
    required int generation,
    bool Function()? shouldSuppressFailureLog,
  }) async {
    try {
      final fallbackEgressIp = await _fetchEgressIp().timeout(
        startupEgressProbeTimeout,
      );
      if (!_isActiveStartupVerification(generation)) {
        return null;
      }
      final normalizedIp = fallbackEgressIp?.trim();
      if (normalizedIp == null || normalizedIp.isEmpty) {
        return null;
      }
      return normalizedIp;
    } catch (error) {
      if (!(shouldSuppressFailureLog?.call() ?? false)) {
        AppLogger.warning(
          '[VpnProvider] Android startup egress probe failed via Dart sockets: $error',
        );
      }
      return null;
    }
  }

  bool _recordSuccessfulStartupProbe({
    required String? ip,
    required String sourceLabel,
  }) {
    final normalizedIp = ip?.trim();
    if (normalizedIp == null || normalizedIp.isEmpty) {
      return false;
    }
    _recordEgressIpSuccess(normalizedIp);
    _diagnosticsUpdatedAt = DateTime.now();
    AppLogger.info(
      '[VpnProvider] Android startup egress probe succeeded via $sourceLabel',
    );
    return true;
  }

  void _scheduleDeferredStartupEgressConfirmation({
    required int generation,
  }) {
    _deferredStartupDiagnosticsTimer?.cancel();
    _deferredStartupDiagnosticsTimer = Timer(
      _androidStartupRetryDelay,
      () async {
        _deferredStartupDiagnosticsTimer = null;
        if (!_isActiveStartupVerification(generation) ||
            _status != VpnStatus.connected) {
          return;
        }

        final egressReachable = await _attemptStartupEgressConfirmation(
          generation: generation,
        );
        if (!_isActiveStartupVerification(generation) ||
            _status != VpnStatus.connected) {
          return;
        }

        if (egressReachable) {
          _safeNotifyListeners();
          AppLogger.info(
            '[VpnProvider] Android startup egress probe succeeded during deferred retry',
          );
          return;
        }

        _diagnosticsEgressIp = null;
        _diagnosticsError = startupProbeInconclusiveMessage;
        _diagnosticsUpdatedAt = DateTime.now();
        // Same rationale as the synchronous branch in
        // _verifyStartupEgressConnectivity: don't wipe an _error message
        // that came from the native VpnService (e.g. UpstreamDegraded
        // "switch nodes" warning) just because dart's own Cloudflare-fronted
        // probe couldn't confirm an egress IP — that probe failure is
        // expected from CN. Only reset _error if it's the placeholder
        // startup-failure string, which is genuinely advisory.
        if (_error == startupConnectivityFailureMessage) {
          _error = null;
        }
        _safeNotifyListeners();
        AppLogger.warning(
          '[VpnProvider] Android startup probe could not confirm egress after deferred retry; keeping VPN connected',
        );
      },
    );
  }

  bool _isActiveStartupVerification(int generation) {
    return !_disposed && generation == _startupVerificationGeneration;
  }

  Future<void> _failStartupVerification({
    required int generation,
    required String fallbackMessage,
  }) async {
    if (!_isActiveStartupVerification(generation)) {
      return;
    }

    _error = _normalizeVpnError(
          _error ?? _nativeService.lastError ?? fallbackMessage,
        ) ??
        fallbackMessage;

    try {
      await _nativeService.stopVpn();
      await _waitForNativeDisconnect();
    } catch (_) {}

    if (!_isActiveStartupVerification(generation)) {
      return;
    }

    _status = VpnStatus.disconnected;
    _activeProfile = null;
    _stopStatsPolling();
    _isLoading = false;
    _safeNotifyListeners();
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
    final normalizedMessage = message?.trim().toLowerCase();
    if (normalizedMessage == null || normalizedMessage.isEmpty) {
      return message;
    }
    if (normalizedMessage.contains('permission denied') ||
        normalizedMessage.contains('permission was not granted') ||
        normalizedMessage.contains('permission request was rejected')) {
      return vpnPermissionDeniedMessage;
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
        _isBenignAndroidPrivateDnsProbeError(lower) ||
        lower.contains('could not reach public ip probe endpoints') ||
        lower.contains('unable to determine current egress ip')) {
      return egressProbeFailureMessage;
    }
    return normalized;
  }

  String _normalizeStartupConnectivityError(String? message) {
    if (message == null) {
      return startupConnectivityFailureMessage;
    }

    final normalized = message.trim();
    if (normalized.isEmpty) {
      return startupConnectivityFailureMessage;
    }

    final lower = normalized.toLowerCase();
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        _isBenignAndroidPrivateDnsProbeError(lower) ||
        lower.contains('could not reach public ip probe endpoints') ||
        lower.contains('unable to determine current egress ip')) {
      return startupConnectivityFailureMessage;
    }
    return normalized;
  }

  bool _isBenignAndroidPrivateDnsProbeError(String message) {
    return message.contains('operation not permitted') &&
        message.contains('open outbound connection');
  }

  Duration _currentConnectionTime() {
    if (_status != VpnStatus.connected) {
      return Duration.zero;
    }
    if (_connectionTimeBaseAt == null) {
      return _connectionTimeBase;
    }
    final elapsed = DateTime.now().difference(_connectionTimeBaseAt!);
    final total = _connectionTimeBase + elapsed;
    return total.isNegative ? Duration.zero : total;
  }

  void _updateConnectionClock(
    VpnNativeStatus nativeStatus, {
    required VpnStatus previousStatus,
  }) {
    if (_status != VpnStatus.connected) {
      _connectionTimeBase = Duration.zero;
      _connectionTimeBaseAt = null;
      _stats = _stats.copyWith(connectionTime: Duration.zero);
      return;
    }

    if (nativeStatus.uptime > 0) {
      _connectionTimeBase = Duration(seconds: nativeStatus.uptime);
      _connectionTimeBaseAt = DateTime.now();
    } else if (previousStatus != VpnStatus.connected ||
        _connectionTimeBaseAt == null) {
      _connectionTimeBase = Duration.zero;
      _connectionTimeBaseAt = DateTime.now();
    }

    _stats = _stats.copyWith(connectionTime: _currentConnectionTime());
  }

  void _applyNativeStatus(VpnNativeStatus nativeStatus, {bool notify = true}) {
    final previousStatus = _status;
    _status = vpnStatusFromNative(nativeStatus);
    _updateConnectionClock(nativeStatus, previousStatus: previousStatus);

    final message = nativeStatus.message?.trim();
    final normalizedStatus = nativeStatus.status.trim().toLowerCase();
    final preserveConflictMessage = _error == vpnConflictMessage &&
        (normalizedStatus == 'disconnecting' ||
            normalizedStatus == 'disconnected') &&
        (message == null || message.isEmpty);
    final preserveStartupFailureMessage =
        _error == startupConnectivityFailureMessage &&
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
        !preserveConflictMessage &&
        !preserveStartupFailureMessage) {
      _error = null;
    }

    if (_status == VpnStatus.connected) {
      _startStatsPolling();
      // When the tunnel comes back up after an underlying-network handover
      // (e.g. Wi-Fi ↔ cellular), the cached egress IP from the previous
      // underlying network is stale. The "（上次探测）" suffix would otherwise
      // stick around indefinitely. Trigger a one-shot probe to refresh it.
      // Skipped on the very first connect transition (initial connect already
      // probes inside _runStartupVerification).
      if (previousStatus == VpnStatus.connecting && _lastKnownEgressIp != null) {
        unawaited(_refreshConnectedDiagnosticsEgressIp());
      }
      _handleUpstreamDegradedSignal(
        degraded: message != null && message.isNotEmpty,
      );
    } else {
      _stopStatsPolling();
      _deferredStartupDiagnosticsTimer?.cancel();
      _deferredStartupDiagnosticsTimer = null;
      _diagnosticsEgressIp = null;
      _handleUpstreamDegradedSignal(degraded: false);
      if (previousStatus == VpnStatus.connected) {
        // Fresh tunnel session next time → reset the budget. A user-initiated
        // reconnect should get its full attempt count back.
        _upstreamDegradedRestartAttempts = 0;
      }
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
    _scheduleLogUpdateNotification();
  }

  void _scheduleLogUpdateNotification() {
    if (_logNotifyTimer?.isActive ?? false) {
      return;
    }
    _logNotifyTimer = Timer(const Duration(milliseconds: 250), () {
      _logNotifyTimer = null;
      _safeNotifyListeners();
    });
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Reacts to whether the current `connected` broadcast carries a non-null
  /// statusMessage from the native VpnService. The native side only sets a
  /// message on the `connected` channel for `TunnelHealth.UpstreamDegraded`,
  /// so any non-empty message while connected = "tunnel is up but can't reach
  /// offshore". When that signal persists past [upstreamDegradedRestartDelay]
  /// we kick a native restart so urltest re-probes every pool member from
  /// scratch and (hopefully) lands on a healthy one.
  void _handleUpstreamDegradedSignal({required bool degraded}) {
    if (!degraded) {
      _upstreamDegradedWatchdog?.cancel();
      _upstreamDegradedWatchdog = null;
      return;
    }
    if (_upstreamDegradedWatchdog?.isActive ?? false) {
      return;
    }
    _upstreamDegradedWatchdog = Timer(
      upstreamDegradedRestartDelay,
      _runUpstreamDegradedRestart,
    );
  }

  Future<void> _runUpstreamDegradedRestart() async {
    _upstreamDegradedWatchdog = null;
    if (_disposed || _status != VpnStatus.connected) {
      return;
    }
    if (_error == null || _error!.isEmpty) {
      // The signal cleared on its own between scheduling and firing.
      return;
    }
    if (_upstreamDegradedRestartAttempts >= maxUpstreamDegradedRestartAttempts) {
      AppLogger.warning(
        '[VpnProvider] Upstream-degraded watchdog: budget exhausted '
        '(${_upstreamDegradedRestartAttempts}/${maxUpstreamDegradedRestartAttempts}); '
        'leaving the tunnel up so the user can choose to switch nodes.',
      );
      return;
    }

    _upstreamDegradedRestartAttempts += 1;
    AppLogger.info(
      '[VpnProvider] Upstream-degraded watchdog firing restart attempt '
      '${_upstreamDegradedRestartAttempts}/${maxUpstreamDegradedRestartAttempts} '
      'after ${upstreamDegradedRestartDelay.inSeconds}s of sustained warning',
    );
    try {
      await _nativeService.restartVpn();
    } catch (e) {
      AppLogger.warning(
        '[VpnProvider] Upstream-degraded watchdog restart failed: $e',
      );
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
    _cancelStartupVerification();
    WidgetsBinding.instance.removeObserver(this);
    _stopStatsPolling();
    _logNotifyTimer?.cancel();
    _deferredStartupDiagnosticsTimer?.cancel();
    _upstreamDegradedWatchdog?.cancel();
    _statusSub?.cancel();
    _statsSub?.cancel();
    _logSub?.cancel();
    super.dispose();
  }
}
