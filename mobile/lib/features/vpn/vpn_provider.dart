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
  // Mirrors PrivateDeployVpnService.cellularCarrierSynBlockMessage() — the
  // native side emits this exact string when every start attempt failed AND
  // the active underlying transport was cellular. That's the classic
  // China-Mobile-RST-to-Vultr-IP scenario (see CDN-ACCELERATION-DESIGN.md).
  // The Dart side flips `_needsCdnGuidance` true on this message so the
  // nodes screen can surface the "需要 CDN 加速" banner without
  // free-form-string scraping.
  static const String cellularCarrierSynBlockMessage =
      "Cellular carrier appears to be SYN-dropping the configured node's IP — the tunnel started but no probe endpoint responded through it. Enable CDN acceleration to route via a Cloudflare edge IP instead.";
  // Mirrors PrivateDeployVpnService.TunnelHealth.DirectRouteDegraded — the
  // tunnel's offshore-proxy path verified fine, but the domestic-direct path
  // didn't (e.g. baidu/qq probe timed out). Normally this clears itself within
  // 30-90 s as Wi-Fi DHCP/routes and sing-box's outbound dialers settle after
  // a handover, so we surface the degraded UI badge but DO NOT engage the
  // upstream-degraded watchdog (which would force a node restart / failover).
  static const String tunnelDirectRouteDegradedMessage =
      "Tunnel is up and the upstream node responds, but the direct-route path (used for domestic sites) is still settling. Some traffic may stall for up to a minute — common right after switching between Wi-Fi and cellular.";
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
  // Refines `_status == connected` with whether the native upstream probe
  // succeeded. Tracked separately from `_error` because `_error` doubles as
  // a generic failure-reason field; we want a single boolean for "is the
  // active session actually working" that the UI can switch on without
  // string-matching.
  VpnHealth _health = VpnHealth.healthy;
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
  // Set when the user wires up an auto-failover handler (typically in
  // main.dart, which has access to CloudProvider + ProfileProvider). The
  // watchdog calls this once its same-node restart budget is exhausted,
  // letting the UI layer cycle through remaining ready cloud nodes
  // instead of leaving the user stranded on a degraded tunnel.
  Future<bool> Function(Set<String> triedProfileNames)? _onDegradedExhausted;
  // Profiles we've already tried during the current auto-failover
  // episode. Cleared on user-initiated connect/disconnect — a new manual
  // session starts with an empty history.
  final Set<String> _failoverTriedProfiles = {};
  bool _failoverInFlight = false;
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
  // Set by _applyNativeStatus when the native side emits the
  // cellularCarrierSynBlockMessage error — i.e. every start attempt failed
  // while the underlying was cellular. UI uses it to surface the "需要 CDN
  // 加速" guidance banner. Cleared on successful connect, disconnect, or
  // explicit dismissal.
  bool _needsCdnGuidance = false;

  VpnStatus get status => _status;
  VpnHealth get health => _health;
  bool get isDegraded =>
      _status == VpnStatus.connected && _health == VpnHealth.degraded;
  bool get needsCdnGuidance => _needsCdnGuidance;
  String? get activeProfile => _activeProfile;
  TrafficStats get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;

  void dismissCdnGuidance() {
    if (!_needsCdnGuidance) return;
    _needsCdnGuidance = false;
    _safeNotifyListeners();
  }

  // Gate ① — auto-deploy CDN Worker when carrier SYN-block is detected.
  // Wired in main.dart against CdnProvider + CloudProvider. Receives the
  // current active profile name so the handler can resolve it to a cloud
  // instance, decide if auto-deploy is feasible (CF creds + node has
  // vlessRelayPort + no existing deployment), and if so call
  // CdnProvider.deployWorkerForNode + trigger VPN restart. Returns true
  // when the deploy completed and a reconnect was kicked; false (with
  // banner left up) otherwise so the user can still set CDN up manually.
  Future<bool> Function(String? activeProfileName)? _onAutoCdnDeployRequest;
  bool _autoCdnDeployInFlight = false;
  // Profile names we've already attempted auto-deploy on during this
  // failover episode, so we don't loop on the same node when the CF API
  // refused (e.g. quota, transient 5xx). Reset on any healthy connect.
  final Set<String> _autoCdnDeployAttempted = {};

  void setOnAutoCdnDeployRequest(
    Future<bool> Function(String? activeProfileName) handler,
  ) {
    _onAutoCdnDeployRequest = handler;
  }

  void _maybeAttemptAutoCdnDeploy() {
    if (_autoCdnDeployInFlight) return;
    final handler = _onAutoCdnDeployRequest;
    if (handler == null) return;
    final activeName = _activeProfile;
    if (activeName == null || activeName.isEmpty) return;
    if (_autoCdnDeployAttempted.contains(activeName)) return;
    _autoCdnDeployAttempted.add(activeName);
    _autoCdnDeployInFlight = true;
    () async {
      try {
        final ok = await handler(activeName);
        if (ok) {
          // Successful deploy + reconnect — drop the banner so the user
          // doesn't see a stale "需要 CDN 加速" prompt while the new
          // CDN-fronted profile is healthy.
          _needsCdnGuidance = false;
          _safeNotifyListeners();
        }
      } catch (e) {
        AppLogger.warning('[VpnProvider] Auto-CDN-deploy handler threw: $e');
      } finally {
        _autoCdnDeployInFlight = false;
      }
    }();
  }

  /// Clears any sticky error banner. Call this when the cause of the error
  /// has been resolved (e.g. the offending profile was deleted, or the user
  /// dismissed a transient probe failure).
  void clearError() {
    if (_error == null) {
      return;
    }
    final wasStartupProbeWarning = _isStartupProbeWarning(_error);
    _error = null;
    if (wasStartupProbeWarning && !_isStartupProbeWarning(_diagnosticsError)) {
      _health = VpnHealth.healthy;
    }
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

  /// Register the auto-failover handler. The watchdog calls this when the
  /// same-node restart budget for an UpstreamDegraded condition is exhausted.
  /// The handler should pick another ready cloud node that's not in
  /// `triedProfileNames`, switch to it, and return `true` if a switch was
  /// initiated. Returning `false` (or no handler set) leaves the tunnel in
  /// the orange degraded state — the original give-up behaviour.
  void setOnDegradedExhausted(
    Future<bool> Function(Set<String> triedProfileNames)? handler,
  ) {
    _onDegradedExhausted = handler;
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
        if (running) {
          if (!_hasStartupProbeWarning) {
            _error = null;
            _health = VpnHealth.healthy;
          } else {
            _health = VpnHealth.degraded;
          }
          _startStatsPolling();
        } else {
          _error = _nativeService.lastError;
          _health = VpnHealth.healthy;
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
    _upstreamDegradedRestartAttempts = 0;
    // Failover history is scoped to a single auto-failover episode. A new
    // connect() call (either user-initiated or from the failover handler
    // itself) starts fresh — except when the failover handler is the one
    // calling us, in which case it preserves the tried set by keeping
    // _failoverInFlight true (the watchdog re-entry guard).
    if (!_failoverInFlight) {
      _failoverTriedProfiles.clear();
    }
    _safeNotifyListeners();

    try {
      final config = configJson ?? '{}';
      // Set _activeProfile *before* awaiting the native start so a
      // failure path (e.g. cellular SYN-block where the native side
      // refuses to install a black-hole tun) still leaves the profile
      // name observable to Gate ①'s auto-CDN-deploy handler. The
      // disconnect path clears it anyway, so the only downside is that
      // a transient connecting state reports activeProfile != null —
      // which is the more useful semantic for any caller asking
      // "which profile is the user trying to use".
      _activeProfile = profileName;
      final success = await _nativeService.startVpn(config);

      if (success) {
        // Keep the explicit assignment on success too so we stay
        // resilient if the early-assignment is ever moved.
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
      if (_status == VpnStatus.connected && _health == VpnHealth.degraded) {
        _handleUpstreamDegradedSignal(degraded: true);
      }
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
    // Same scoping rule as connect(): clear the auto-failover memory on a
    // user-initiated stop, but preserve it while the failover handler is
    // doing its own disconnect+connect dance.
    if (!_failoverInFlight) {
      _failoverTriedProfiles.clear();
    }
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
      if (_status == VpnStatus.connected && _health == VpnHealth.degraded) {
        _handleUpstreamDegradedSignal(degraded: true);
      }
      _safeNotifyListeners();
    }
  }

  Future<bool> stopDegradedSession({String? reason}) async {
    if (!_isSupported) {
      _error = _unsupportedReason ?? 'Native VPN is unavailable on this build';
      _safeNotifyListeners();
      return false;
    }

    final preservedReason = _normalizeVpnError(
          reason ?? _error ?? _diagnosticsError,
        ) ??
        startupConnectivityFailureMessage;

    _cancelStartupVerification();
    _upstreamDegradedWatchdog?.cancel();
    _upstreamDegradedWatchdog = null;
    _isLoading = true;
    _safeNotifyListeners();

    try {
      final success = await _nativeService.stopVpn();
      if (success) {
        await _waitForNativeDisconnect();
        _status = VpnStatus.disconnected;
        _activeProfile = null;
        _lastKnownEgressIp = null;
        _lastKnownEgressIpAt = null;
        _diagnosticsEgressIp = null;
        _health = VpnHealth.healthy;
        _stopStatsPolling();
        _error = preservedReason;
      } else {
        _error = _normalizeVpnError(_nativeService.lastError) ??
            'Failed to stop unreachable VPN session';
      }
      return success;
    } catch (e) {
      _error = 'Failed to stop unreachable VPN session: ${e.toString()}';
      AppLogger.error('[VpnProvider] Stop degraded session error', e);
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
    _upstreamDegradedRestartAttempts = 0;
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
      if (_status == VpnStatus.connected && _health == VpnHealth.degraded) {
        _handleUpstreamDegradedSignal(degraded: true);
      }
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
    final hadStartupProbeWarning = _hasStartupProbeWarning;
    _diagnosticsEgressIp = normalized;
    _diagnosticsError = null;
    _lastKnownEgressIp = normalized;
    _lastKnownEgressIpAt = DateTime.now();
    if (hadStartupProbeWarning && _isStartupProbeWarning(_error)) {
      _error = null;
    }
    final hasNonStartupError =
        _error != null && !_isStartupProbeWarning(_error);
    if (hadStartupProbeWarning &&
        _status == VpnStatus.connected &&
        !hasNonStartupError) {
      _health = VpnHealth.healthy;
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
      // keep the tunnel up, but show the session as degraded until a retry
      // confirms the public egress IP. The UI must not show a green success
      // state while the app still has no route-level proof.
      _markStartupProbeInconclusive();
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
        _markStartupProbeInconclusive();
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

  bool get _hasStartupProbeWarning =>
      _isStartupProbeWarning(_error) ||
      _isStartupProbeWarning(_diagnosticsError);

  bool _isStartupProbeWarning(String? message) {
    return message == startupProbeInconclusiveMessage ||
        message == startupConnectivityFailureMessage;
  }

  void _markStartupProbeInconclusive() {
    _diagnosticsEgressIp = null;
    _diagnosticsError = startupProbeInconclusiveMessage;
    _diagnosticsUpdatedAt = DateTime.now();
    if (_error == null || _isStartupProbeWarning(_error)) {
      _error = startupProbeInconclusiveMessage;
    }
    if (_status == VpnStatus.connected) {
      _health = VpnHealth.degraded;
    }
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
        !preserveStartupFailureMessage &&
        !(_status == VpnStatus.connected && _isStartupProbeWarning(_error))) {
      _error = null;
    }

    // Cellular-carrier SYN-block: every start attempt failed AND the
    // active underlying was cellular. Raise the guidance banner so the
    // user gets a clear path forward instead of staring at a generic
    // error. Cleared by the user via dismissCdnGuidance(), by a later
    // healthy connect transition (see below), or when CDN auto-deploy
    // succeeds (gate ①).
    if (_error == cellularCarrierSynBlockMessage) {
      _needsCdnGuidance = true;
      // Gate ① — fire the auto-deploy handler so we attempt to recover
      // without making the user navigate to CDN settings. Banner stays
      // up until the deploy either succeeds (clears it) or completes
      // unsuccessfully (user falls back to manual flow).
      _maybeAttemptAutoCdnDeploy();
    }

    if (_status == VpnStatus.connected) {
      _startStatsPolling();
      // Connected + non-empty statusMessage = native checkTunnelHealth came
      // back UpstreamDegraded, DirectRouteDegraded, or Unreachable. Track
      // separately so the UI can render an honest "degraded" badge instead of
      // a green checkmark while routing is actually broken (bug filed
      // 2026-05-12: cellular-only session showed "VPN 连接成功" snackbar even
      // though nothing routed).
      final hasNativeDegradedMessage = message != null && message.isNotEmpty;
      // DirectRouteDegraded is the transient handover settle window — the
      // tunnel's proxy path is healthy, only the direct-route path is still
      // stabilising. Surface the degraded UI but skip the upstream watchdog
      // (which would force a same-node restart / failover) because the
      // condition self-resolves once domestic probes start passing on the
      // next health-monitor cycle (~30 s).
      final isDirectRouteDegraded = message == tunnelDirectRouteDegradedMessage;
      _health = (hasNativeDegradedMessage || _hasStartupProbeWarning)
          ? VpnHealth.degraded
          : VpnHealth.healthy;
      // A healthy connected transition resolves the previous SYN-block:
      // either the user manually fixed it (switched networks, deployed
      // CDN themselves), or auto-failover/auto-CDN-deploy did. Either
      // way, drop the guidance banner — the problem isn't current
      // anymore.
      if (_health == VpnHealth.healthy) {
        _needsCdnGuidance = false;
        // Reset auto-deploy attempt history so a future SYN-block (e.g.
        // user roams to a different blocked node tomorrow) can fire
        // auto-deploy fresh.
        _autoCdnDeployAttempted.clear();
      }
      // When the tunnel comes back up after an underlying-network handover
      // (e.g. Wi-Fi ↔ cellular), the cached egress IP from the previous
      // underlying network is stale. The "（上次探测）" suffix would otherwise
      // stick around indefinitely. Trigger a one-shot probe to refresh it.
      // Skipped on the very first connect transition (initial connect already
      // probes inside _runStartupVerification).
      if (previousStatus == VpnStatus.connecting &&
          _lastKnownEgressIp != null) {
        unawaited(_refreshConnectedDiagnosticsEgressIp());
      }
      _handleUpstreamDegradedSignal(
        degraded: hasNativeDegradedMessage && !isDirectRouteDegraded,
      );
    } else {
      _stopStatsPolling();
      _deferredStartupDiagnosticsTimer?.cancel();
      _deferredStartupDiagnosticsTimer = null;
      _diagnosticsEgressIp = null;
      _health = VpnHealth.healthy;
      _handleUpstreamDegradedSignal(degraded: false);
      // Don't reset _upstreamDegradedRestartAttempts here. The watchdog's own
      // restartVpn() forces a connected→disconnected transition; resetting on
      // that transition gives the next watchdog cycle a fresh budget and
      // defeats the cap (the budget is exhausted only after the user steps
      // in via connect() / restart()).
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
    if (_isLoading) {
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
    if (_disposed || _isLoading || _status != VpnStatus.connected) {
      return;
    }
    if (_error == null || _error!.isEmpty) {
      // The signal cleared on its own between scheduling and firing.
      return;
    }
    if (_error == tunnelDirectRouteDegradedMessage) {
      // DirectRouteDegraded is the post-handover settle window: the proxy
      // path is healthy and the direct path will clear itself within a
      // health-monitor cycle. Restarting the tunnel here would only churn
      // the same-node restart budget without addressing the real condition.
      return;
    }
    if (_upstreamDegradedRestartAttempts >=
        maxUpstreamDegradedRestartAttempts) {
      // Same-node restart budget is exhausted. Before giving up, ask the
      // failover handler (wired by main.dart against CloudProvider) to try
      // another ready cloud node. The current active profile counts as
      // "already tried" — record it so the handler skips it. If no handler
      // is registered, no cloud alternatives exist, or the handler returns
      // false, fall through to the original "leave degraded" behaviour.
      final activeName = _activeProfile;
      if (activeName != null && activeName.isNotEmpty) {
        _failoverTriedProfiles.add(activeName);
      }
      if (_onDegradedExhausted != null && !_failoverInFlight) {
        _failoverInFlight = true;
        AppLogger.info(
          '[VpnProvider] Upstream-degraded budget exhausted on '
          '"${activeName ?? '(unknown)'}"; invoking failover handler with '
          'tried=$_failoverTriedProfiles',
        );
        try {
          final switched =
              await _onDegradedExhausted!(Set.of(_failoverTriedProfiles));
          if (switched) {
            // The handler initiated a switch (disconnect+connect to a new
            // node). The new connection runs its own startup verification;
            // if it lands Healthy, _health resets, the new active profile
            // is recorded by connect(), and this watchdog cycle is done.
            // Reset the same-node restart counter so the new node gets its
            // own fresh budget.
            _upstreamDegradedRestartAttempts = 0;
            return;
          }
        } catch (e) {
          AppLogger.warning('[VpnProvider] Failover handler threw: $e');
        } finally {
          _failoverInFlight = false;
        }
      }
      AppLogger.warning(
        '[VpnProvider] Upstream-degraded watchdog: budget exhausted '
        '(${_upstreamDegradedRestartAttempts}/${maxUpstreamDegradedRestartAttempts}) '
        'and no working failover candidate; stopping the unreachable tunnel '
        'so device traffic does not stay routed into a dead TUN interface.',
      );
      await stopDegradedSession(
        reason: _error ?? _diagnosticsError ?? tunnelUpstreamDegradedMessage,
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

  @visibleForTesting
  int get debugUpstreamDegradedRestartAttempts =>
      _upstreamDegradedRestartAttempts;

  /// Synchronously runs one watchdog cycle so tests don't need to wait for
  /// the 30-second [upstreamDegradedRestartDelay] timer. Mirrors what the
  /// scheduled callback does, including the "tunnel is connected and the
  /// degraded signal is still set" preconditions.
  @visibleForTesting
  Future<void> debugFireUpstreamDegradedWatchdog() {
    _upstreamDegradedWatchdog?.cancel();
    _upstreamDegradedWatchdog = null;
    return _runUpstreamDegradedRestart();
  }

  @visibleForTesting
  void debugApplyNativeStatus(VpnNativeStatus nativeStatus) {
    _applyNativeStatus(nativeStatus);
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
