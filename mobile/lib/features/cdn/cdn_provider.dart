import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/storage/storage_service.dart';
import '../cloud/cloud_backup.dart';
import '../cloud/cloud_provider_utils.dart' show shouldKeepCloudApiKeyOnError;

/// Holds Cloudflare account state for the optional CDN-front feature.
///
/// Status is one of:
///  - [CdnStatus.disabled]   — no token configured (default for new installs)
///  - [CdnStatus.unverified] — token saved but never successfully verified
///                             (e.g. saved offline or token revoked since)
///  - [CdnStatus.verified]   — token validates against /user/tokens/verify
///                             and we have an accessible account
///
/// The provider does NOT yet auto-deploy Workers; that's phase 4. For now it
/// just safeguards the token, surfaces the current account email + workers.dev
/// subdomain so the user can manually deploy via the steps in
/// docs/cdn-acceleration/README.md.
class CdnProvider with ChangeNotifier {
  static const _kTokenKey = 'cdn.cf_api_token';
  static const _kAccountIdKey = 'cdn.cf_account_id';
  static const _kAccountEmailKey = 'cdn.cf_account_email';
  static const _kWorkersSubdomainKey = 'cdn.cf_workers_subdomain';
  // Stores a JSON map<nodeId, CdnDeployment.toJson()> in shared prefs. Not
  // sensitive (just URLs and timestamps), so we don't use secure storage.
  static const _kDeploymentsKey = 'cdn.cf_deployments_v1';
  // M1: Workers Custom Domains binding config. Stored as a single global
  // entry — every deploy uses the same zone+subdomain prefix and a per-
  // script-hash suffix to keep hostnames unique across nodes.
  static const _kCustomDomainKey = 'cdn.cf_custom_domain_v1';
  // 优选IP: a user-picked Cloudflare edge IP the CDN outbound dials directly
  // (SNI/Host stay the custom domain). Plain (non-secret) prefs string.
  static const _kPreferredEdgeIpKey = 'cdn.preferred_edge_ip';
  // Compatibility date the Worker is deployed with. Bumping this can change
  // runtime behavior, so it lives next to the worker template.
  static const _kCompatDate = '2024-09-23';

  static const _verifyEndpoint =
      'https://api.cloudflare.com/client/v4/user/tokens/verify';
  static const _accountsEndpoint =
      'https://api.cloudflare.com/client/v4/accounts';
  static const _zonesEndpoint = 'https://api.cloudflare.com/client/v4/zones';

  CdnStatus _status = CdnStatus.disabled;
  String? _accountId;
  String? _accountEmail;
  String? _workersSubdomain;
  String? _lastError;
  bool _isVerifying = false;
  bool _isDeploying = false;
  Map<String, CdnDeployment> _deployments = {};
  // Last WS-upgrade status the readiness probe saw per node (in-memory only;
  // repopulated by the probe on each run). Lets the UI tell a backend failure
  // (Worker up, VPS relay 502/504) apart from a CDN-layer failure, so it can
  // point the user at the right fix (redeploy the node, not repair the Worker).
  final Map<String, int> _lastProbeStatus = {};
  CdnCustomDomain? _customDomain;
  List<CdnZone> _zones = const [];
  bool _zonesLoading = false;
  bool _isSavingCustomDomain = false;
  String? _preferredEdgeIp;

  CdnStatus get status => _status;
  String? get accountId => _accountId;
  String? get accountEmail => _accountEmail;
  String? get workersSubdomain => _workersSubdomain;
  String? get lastError => _lastError;

  /// User-picked Cloudflare 优选IP, or null. When set, generated node configs
  /// add a CDN outbound that dials this IP directly (custom host as SNI/Host).
  String? get preferredEdgeIp => _preferredEdgeIp;

  /// Persist (or clear, when [ip] is blank) the 优选IP and notify listeners so
  /// the next connect rebuilds the config. Light validation: must look like a
  /// bare IPv4/IPv6 literal — a hostname here would defeat the purpose.
  Future<void> setPreferredEdgeIp(String? ip) async {
    final trimmed = (ip ?? '').trim();
    if (trimmed.isEmpty) {
      _preferredEdgeIp = null;
      await StorageService.remove(_kPreferredEdgeIpKey);
    } else {
      _preferredEdgeIp = trimmed;
      await StorageService.saveString(_kPreferredEdgeIpKey, trimmed);
    }
    notifyListeners();
  }

  bool get isVerifying => _isVerifying;
  bool get isDeploying => _isDeploying;
  bool get isConfigured => _status != CdnStatus.disabled;
  Map<String, CdnDeployment> get deployments => Map.unmodifiable(_deployments);
  CdnDeployment? deploymentFor(String nodeId) => _deployments[nodeId];

  /// Last WS-upgrade status the probe recorded for [nodeId] (null if never
  /// probed this session). 502/504 here on a 'failed' node means the Worker
  /// is fine but its VPS relay backend is unreachable — redeploy the node.
  int? lastProbeStatusFor(String nodeId) => _lastProbeStatus[nodeId];
  CdnCustomDomain? get customDomain => _customDomain;
  List<CdnZone> get zones => List.unmodifiable(_zones);
  bool get isZonesLoading => _zonesLoading;
  bool get isSavingCustomDomain => _isSavingCustomDomain;

  /// Diagnostic-only: hit the deployed Worker with the stored
  /// pathSecret and report whether the WS upgrade returns 101. Returns
  /// null if no deployment / no customHost. Used by the auto-CDN
  /// handler's trace path to distinguish "secret matches but probe
  /// still fails" from "secret doesn't match the deployed Worker".
  Future<bool?> debugTestCdnWorkerReachable(String nodeId) async {
    final dep = _deployments[nodeId];
    if (dep == null) return null;
    final host = dep.customHost ?? dep.workerHost;
    final secret = dep.pathSecret;
    if (host.isEmpty || secret == null || secret.isEmpty) return null;
    return (await _customHostUpgradeStatus(host, secret)) == 101;
  }

  /// True when every precondition for [deployWorkerForNode] is in place
  /// without going to the network: token verified, account scoped, and
  /// at least one routable destination (workers.dev subdomain or a bound
  /// custom domain). Used by the VPN auto-deploy gate in main.dart to
  /// decide whether to attempt automatic recovery after a cellular
  /// connectivity failure; mirrors the same checks deployWorkerForNode runs
  /// internally so the caller can fail fast without firing an HTTP
  /// request that's going to bounce on missing-prerequisite errors.
  bool canAutoDeployForNode() {
    if (_status != CdnStatus.verified) return false;
    if ((_accountId ?? '').isEmpty) return false;
    final hasSubdomain = (_workersSubdomain ?? '').isNotEmpty;
    final hasCustomDomain = _customDomain != null;
    return hasSubdomain || hasCustomDomain;
  }

  /// Whether a CDN deploy is structurally possible given the current
  /// account state. Differs from [canAutoDeployForNode] in that it also
  /// returns true for [CdnStatus.verifiedButIncomplete] — that state
  /// already means "token + account good but no destination" which is
  /// exactly the prerequisite check, so re-asserting it would short-
  /// circuit the manual flow and hide the actionable hint from users
  /// who could fix it (e.g. by binding a custom domain).
  bool get isReadyForDeploy =>
      _status == CdnStatus.verified &&
      (_accountId ?? '').isNotEmpty &&
      ((_workersSubdomain ?? '').isNotEmpty || _customDomain != null);

  /// Did the provider previously have a saved + validated token? Used by
  /// failure paths in [verifyAndPersist] to decide whether to fall back
  /// to [unverified] (keep token on disk, just mark stale) or
  /// [disabled] (no token was ever known to work). Both verifiedButIncomplete
  /// and verified count: they only differ on the *destination* prerequisite,
  /// not on whether the token itself ever passed verify.
  bool _hadValidTokenBefore(CdnStatus prior) =>
      prior == CdnStatus.verified || prior == CdnStatus.verifiedButIncomplete;

  /// Build the workers.dev URL fragment we display in the UI as
  /// "<your-name>.<subdomain>.workers.dev". Returns null if not yet known.
  String? get workersDevExample {
    final s = _workersSubdomain;
    if (s == null || s.isEmpty) return null;
    return 'pd-relay-<your-name>.$s.workers.dev';
  }

  Future<void> load() async {
    // Independent of the CF token — load it up front so it survives the
    // no-token early return below.
    _preferredEdgeIp = StorageService.getString(_kPreferredEdgeIpKey);
    final saved = await StorageService.getSecureString(_kTokenKey);
    if (saved == null || saved.isEmpty) {
      _status = CdnStatus.disabled;
      _accountId = null;
      _accountEmail = null;
      _workersSubdomain = null;
      notifyListeners();
      return;
    }
    _accountId = StorageService.getString(_kAccountIdKey);
    _accountEmail = StorageService.getString(_kAccountEmailKey);
    _workersSubdomain = StorageService.getString(_kWorkersSubdomainKey);
    // Load custom domain BEFORE deriving status so the incomplete-vs-
    // verified split sees the same hasCustomDomain hint that the live
    // verify path uses.
    _loadCustomDomain();
    if (_accountId != null && _accountId!.isNotEmpty) {
      final hasSubdomain = (_workersSubdomain ?? '').isNotEmpty;
      final hasCustomDomain = _customDomain != null;
      _status = (hasSubdomain || hasCustomDomain)
          ? CdnStatus.verified
          : CdnStatus.verifiedButIncomplete;
      // Reinstate the hint after a cold start. verifyAndPersist sets
      // this; load() didn't, which left a yellow "Verified · setup
      // incomplete" badge with no explanation under it. Same string as
      // verifyAndPersist on purpose so the user sees a consistent
      // message across "I just verified" and "I came back tomorrow".
      _lastError = _status == CdnStatus.verifiedButIncomplete
          ? 'Token verified, but no workers.dev subdomain claimed yet — '
              'visit the Workers dashboard once to claim one, or bind a '
              'custom domain below.'
          : null;
    } else {
      _status = CdnStatus.unverified;
    }
    _loadDeployments();
    notifyListeners();
    // Resume readiness probes for any deployment not yet Active (pending
    // OR failed) from a previous launch. If CF cert issuance / edge
    // propagation / VPS relay boot finished while we were closed, the
    // retry flips it Active — see [_resumeIncompleteProbes] for why
    // 'failed' must be retried rather than treated as terminal.
    _resumeIncompleteProbes();
  }

  void _loadCustomDomain() {
    final raw = StorageService.getString(_kCustomDomainKey);
    if (raw == null || raw.isEmpty) {
      _customDomain = null;
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _customDomain = CdnCustomDomain.fromJson(decoded);
      } else {
        _customDomain = null;
      }
    } catch (_) {
      _customDomain = null;
    }
  }

  Future<void> _persistCustomDomain() async {
    if (_customDomain == null) {
      await StorageService.saveString(_kCustomDomainKey, '');
      return;
    }
    await StorageService.saveString(
      _kCustomDomainKey,
      jsonEncode(_customDomain!.toJson()),
    );
  }

  void _loadDeployments() {
    final raw = StorageService.getString(_kDeploymentsKey);
    if (raw == null || raw.isEmpty) {
      _deployments = {};
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _deployments = {};
        return;
      }
      _deployments = decoded.map(
          (k, v) => MapEntry(k.toString(), CdnDeployment.fromJson(v as Map)));
    } catch (_) {
      _deployments = {};
    }
  }

  Future<void> _persistDeployments() async {
    final encoded = jsonEncode(
      _deployments.map((k, v) => MapEntry(k, v.toJson())),
    );
    await StorageService.saveString(_kDeploymentsKey, encoded);
  }

  /// Run /user/tokens/verify, then list accounts and fetch the workers.dev
  /// subdomain. On success, persist all of the above and switch to
  /// [CdnStatus.verified].
  ///
  /// Throws nothing — errors are reported via [lastError].
  Future<bool> verifyAndPersist(String token) async {
    if (_isVerifying) return false;
    // Snapshot the prior status so a failed verify on a fresh setup goes back
    // to disabled (no token saved) rather than the half-truth "saved, not
    // verified" — that label only makes sense when we actually have a token
    // on disk that we couldn't validate.
    final priorStatus = _status;
    _isVerifying = true;
    _lastError = null;
    notifyListeners();

    final dio = Dio(BaseOptions(
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      validateStatus: (_) => true,
    ));

    try {
      // 1. Verify the token.
      final verify = await dio.get(_verifyEndpoint);
      final verifyOk = (verify.statusCode == 200) &&
          (verify.data is Map) &&
          (verify.data['success'] == true) &&
          ((verify.data['result'] as Map?)?['status'] == 'active');
      if (!verifyOk) {
        _lastError = _extractCloudflareError(verify.data) ??
            'Token verification failed (HTTP ${verify.statusCode}).';
        _status = _hadValidTokenBefore(priorStatus)
            ? CdnStatus.unverified
            : CdnStatus.disabled;
        return false;
      }

      // 2. List accounts. Token-scoped tokens typically return one entry.
      final acc = await dio.get(_accountsEndpoint);
      final accounts = (acc.data is Map)
          ? (acc.data['result'] as List? ?? const [])
          : const [];
      if (accounts.isEmpty) {
        _lastError = 'Token has no accessible Cloudflare accounts.';
        _status = _hadValidTokenBefore(priorStatus)
            ? CdnStatus.unverified
            : CdnStatus.disabled;
        return false;
      }
      final account = accounts.first as Map;
      final accountId = (account['id'] as String?) ?? '';
      if (accountId.isEmpty) {
        _lastError = 'Could not parse account id from Cloudflare response.';
        _status = _hadValidTokenBefore(priorStatus)
            ? CdnStatus.unverified
            : CdnStatus.disabled;
        return false;
      }
      // The verify response includes the email of the issuing user when the
      // token is bound to a user (not a service token).
      final verifyResult = verify.data['result'] as Map? ?? const {};
      final email = (verifyResult['email'] as String?) ??
          (account['name'] as String?) ??
          '';

      // 3. Fetch the workers.dev subdomain. New accounts that haven't claimed
      // one yet return 404 — we surface that as a softer warning rather than
      // a hard fail, since the user can still set one up in the dashboard.
      String workersSub = '';
      final sub = await dio.get(
        '$_accountsEndpoint/$accountId/workers/subdomain',
      );
      if (sub.statusCode == 200 && sub.data is Map) {
        final r = sub.data['result'];
        if (r is Map) {
          workersSub = (r['subdomain'] as String?) ?? '';
        }
      }

      // Persist + announce.
      await StorageService.saveSecureString(_kTokenKey, token);
      await StorageService.saveString(_kAccountIdKey, accountId);
      await StorageService.saveString(_kAccountEmailKey, email);
      await StorageService.saveString(_kWorkersSubdomainKey, workersSub);

      // Re-verify with a different account drops the saved CustomDomain
      // — the zoneId is account-scoped and would silently 404 when the
      // next deploy tried to attach. Same-account re-verify (token
      // rotation) preserves the binding so the user doesn't have to
      // re-pick zone every time their token expires.
      final oldAccount = _accountId ?? '';
      if (oldAccount.isNotEmpty && oldAccount != accountId) {
        _customDomain = null;
        await _persistCustomDomain();
      }
      // Always invalidate the zone cache on a successful verify. Either
      // the account changed (zones in the prior cache belong to a
      // different account and would 404 on attach), or the token was
      // rotated for the same account (zones may have been added/removed
      // out-of-band). Either way the cached list is suspect and the
      // next picker render should re-fetch.
      _zones = const [];

      _accountId = accountId;
      _accountEmail = email;
      _workersSubdomain = workersSub;
      // Token is good and the account is reachable, but a deploy needs a
      // destination — either workers.dev subdomain or a bound custom
      // domain. Without either the deploy API would return 400 every
      // time. Promote to [verified] only when the destination exists;
      // otherwise sit in [verifiedButIncomplete] so the UI can render a
      // yellow "almost there" state with a clear action item instead of
      // a misleading green check.
      final hasCustomDomain = _customDomain != null;
      _status = (workersSub.isEmpty && !hasCustomDomain)
          ? CdnStatus.verifiedButIncomplete
          : CdnStatus.verified;
      _lastError = workersSub.isEmpty && !hasCustomDomain
          ? 'Token verified, but no workers.dev subdomain claimed yet — '
              'visit the Workers dashboard once to claim one, or bind a '
              'custom domain below.'
          : null;
      return true;
    } on DioException catch (e) {
      // Save-first / verify-later on transient network failures. Same
      // motivation as CloudProvider.setApiKey: on regional mobile network where this
      // CDN feature is most needed, api.cloudflare.com gets timed out
      // alongside everything else. Refusing to save the token forces
      // the user to find a Wi-Fi access point first — exactly the
      // chicken-and-egg the feature is supposed to break. So when the
      // failure shape says "couldn't reach", we save what we have
      // (the token), park the status at `unverified` (existing state
      // for "token on disk, never confirmed"), and surface a message
      // explaining the deferred verification. Auth failures
      // (401/403/"invalid api key") still fall through to the strict
      // path below — no save, no false hope.
      final message = e.message ?? e.type.name;
      if (shouldKeepCloudApiKeyOnError(e)) {
        await StorageService.saveSecureString(_kTokenKey, token);
        _lastError =
            'Token saved. Could not reach Cloudflare to verify yet ($message) — '
            'we will retry when the network reaches it. Account details and '
            'deployment will only work once verification completes.';
        _status = CdnStatus.unverified;
        return false;
      }
      _lastError = 'Network error verifying token: $message';
      _status = _hadValidTokenBefore(priorStatus)
          ? CdnStatus.unverified
          : CdnStatus.disabled;
      return false;
    } catch (e) {
      _lastError = 'Unexpected error: $e';
      _status = _hadValidTokenBefore(priorStatus)
          ? CdnStatus.unverified
          : CdnStatus.disabled;
      return false;
    } finally {
      _isVerifying = false;
      notifyListeners();
    }
  }

  /// Snapshot CDN state for inclusion in an encrypted cloud backup.
  /// Caller (export dialog) merges this into the CloudBackupPayload.
  /// Returns null when nothing useful is loaded — no token, no
  /// deployments, no custom domain — so the backup omits the cdn block
  /// entirely instead of carrying an empty stub.
  Future<CdnBackup?> exportSnapshot() async {
    final token = await StorageService.getSecureString(_kTokenKey);
    final hasToken = token != null && token.isNotEmpty;
    final hasDeployments = _deployments.isNotEmpty;
    final hasCustomDomain = _customDomain != null;
    if (!hasToken && !hasDeployments && !hasCustomDomain) {
      return null;
    }
    final snap = CdnBackup(
      token: hasToken ? token : null,
      accountId: _accountId,
      accountEmail: _accountEmail,
      workersSubdomain: _workersSubdomain,
      customDomain: hasCustomDomain ? _customDomain!.toJson() : null,
      deployments: hasDeployments
          ? _deployments.map((k, v) => MapEntry(k, v.toJson()))
          : null,
    );
    return snap.isEmpty ? null : snap;
  }

  /// Apply a previously-exported [CdnBackup] to local storage. Overwrites
  /// any in-place CDN state — symmetric with the cloud-side import which
  /// also replaces nodeRecords. The status flips to verified iff the
  /// backup carried a token + accountId. Pending deployments resume
  /// their readiness probe on the next [load].
  Future<void> restoreSnapshot(CdnBackup snap) async {
    if (snap.token != null && snap.token!.isNotEmpty) {
      await StorageService.saveSecureString(_kTokenKey, snap.token!);
    } else {
      await StorageService.removeSecure(_kTokenKey);
    }
    if (snap.accountId != null && snap.accountId!.isNotEmpty) {
      await StorageService.saveString(_kAccountIdKey, snap.accountId!);
    } else {
      await StorageService.remove(_kAccountIdKey);
    }
    if (snap.accountEmail != null && snap.accountEmail!.isNotEmpty) {
      await StorageService.saveString(_kAccountEmailKey, snap.accountEmail!);
    } else {
      await StorageService.remove(_kAccountEmailKey);
    }
    if (snap.workersSubdomain != null && snap.workersSubdomain!.isNotEmpty) {
      await StorageService.saveString(
        _kWorkersSubdomainKey,
        snap.workersSubdomain!,
      );
    } else {
      await StorageService.remove(_kWorkersSubdomainKey);
    }
    _accountId = snap.accountId;
    _accountEmail = snap.accountEmail;
    _workersSubdomain = snap.workersSubdomain;

    _customDomain = snap.customDomain == null
        ? null
        : CdnCustomDomain.fromJson(snap.customDomain!);
    // Derive status from what's actually restorable: a token + accountId
    // is verified-class, but we additionally need a subdomain OR a custom
    // domain to be deploy-ready. Without either, the snapshot left the
    // user mid-setup and the UI should keep nagging until one is bound.
    if (snap.token != null &&
        snap.token!.isNotEmpty &&
        snap.accountId != null &&
        snap.accountId!.isNotEmpty) {
      final hasSubdomain = (snap.workersSubdomain ?? '').isNotEmpty;
      final hasCustomDomain = _customDomain != null;
      _status = (hasSubdomain || hasCustomDomain)
          ? CdnStatus.verified
          : CdnStatus.verifiedButIncomplete;
    } else if (snap.token != null && snap.token!.isNotEmpty) {
      _status = CdnStatus.unverified;
    } else {
      _status = CdnStatus.disabled;
    }
    await _persistCustomDomain();

    final imported = <String, CdnDeployment>{};
    final deps = snap.deployments;
    if (deps != null) {
      for (final entry in deps.entries) {
        imported[entry.key] = CdnDeployment.fromJson(entry.value);
      }
    }
    _deployments = imported;
    await _persistDeployments();

    _lastError = null;
    notifyListeners();

    // Kick the readiness probe on any imported deployment not yet Active
    // (pending OR failed), matching what [load] does on a cold start. A
    // 'failed' imported from another phone is very often just a probe that
    // timed out there before CF/VPS settled — re-probing here can clear it
    // without a manual re-deploy. See [_resumeIncompleteProbes].
    _resumeIncompleteProbes();
  }

  Future<void> clear() async {
    // Best-effort remote cleanup of every Worker + custom-domain binding
    // we know about, while credentials are still loaded. Failures don't
    // block the local wipe — the user explicitly asked to clear, so we
    // honour that even if CF is unreachable. Otherwise an offline "clear"
    // would orphan remote resources forever.
    final ids = _deployments.keys.toList();
    for (final id in ids) {
      try {
        await deleteWorkerForNode(id);
      } catch (_) {
        // Swallow — local wipe still proceeds below.
      }
    }
    await StorageService.removeSecure(_kTokenKey);
    await StorageService.remove(_kAccountIdKey);
    await StorageService.remove(_kAccountEmailKey);
    await StorageService.remove(_kWorkersSubdomainKey);
    await StorageService.remove(_kDeploymentsKey);
    await StorageService.remove(_kCustomDomainKey);
    _accountId = null;
    _accountEmail = null;
    _workersSubdomain = null;
    _deployments = {};
    _customDomain = null;
    _status = CdnStatus.disabled;
    _lastError = null;
    notifyListeners();
  }

  /// Deploy a Worker for the given node. The Worker is named
  /// `pd-relay-<nodeShortId>-<rand>` and configured with
  /// `BACKEND = "<nodeIp>:<vlessPort>"` so it forwards WS frames to the
  /// node's existing VLESS port over plain TCP.
  ///
  /// Note: Phase 4 deploys the Worker but the *client* still cannot use it
  /// directly until Phase 5 lands a server-side change adding a non-Reality
  /// VLESS-WS endpoint to the VPS. The deploy is still useful: it confirms
  /// CF API integration works end-to-end and pre-stages the Worker URL.
  Future<bool> deployWorkerForNode({
    required String nodeId,
    required String nodeLabel,
    required String backendHost,
    required int backendPort,

    /// Whether this call originated from a user tap on the manual
    /// "Deploy Worker" button ('manual') or from Gate ① recovering
    /// from a cellular connectivity failure ('auto'). Persisted on the resulting
    /// [CdnDeployment] so the UI can show provenance without forcing
    /// the user to remember whether they did this on purpose.
    String deployedBy = 'manual',
  }) async {
    if (_isDeploying) return false;
    if (_status != CdnStatus.verified || (_accountId ?? '').isEmpty) {
      _lastError = 'Token not verified — verify it first.';
      notifyListeners();
      return false;
    }
    // Hard requirement only when no M1 custom-domain is bound. A claimed
    // workers.dev subdomain is one of two ways to reach the Worker — when
    // the user has bound a custom hostname we can ship without it, which
    // lets accounts that have never visited the Workers dashboard still
    // use M1.
    final hasCustomDomain = _customDomain != null;
    if ((_workersSubdomain ?? '').isEmpty && !hasCustomDomain) {
      _lastError =
          'No workers.dev subdomain claimed and no custom domain bound — '
          'claim a workers.dev subdomain in the Cloudflare dashboard, or '
          'bind a custom hostname under CDN settings, then retry.';
      notifyListeners();
      return false;
    }
    // Defence in depth against the auto-deploy race: a node whose IPv4 has
    // not been populated yet renders BACKEND=":$backendPort" (empty host),
    // which makes worker.js return 502 on every relay forever (the secret
    // check passes, then `!host` trips the bad-gateway guard before connect).
    // Refuse to ship such a Worker so callers fail loudly instead of
    // stranding the node in a permanent "verifying" state.
    if (backendHost.trim().isEmpty) {
      _lastError =
          'Node IP not available yet — refusing to deploy a Worker with an '
          'empty backend host (would be BACKEND=":$backendPort" and 502 '
          'forever). Wait for the node IPv4 to populate, then retry.';
      notifyListeners();
      return false;
    }

    _isDeploying = true;
    _lastError = null;
    notifyListeners();

    try {
      final token = await StorageService.getSecureString(_kTokenKey);
      if (token == null || token.isEmpty) {
        _lastError = 'Token missing from storage.';
        return false;
      }

      // Load the worker template + render BACKEND + PATH_SECRET.
      // 16 random bytes = 128 bits of entropy as 32 hex chars; same budget
      // as the Go bridge's randomHex(16) so per-deployment secrets have
      // identical strength on both platforms.
      final template = await rootBundle.loadString('assets/cdn/worker.js');
      final backend = '$backendHost:$backendPort';
      final pathSecret = _randomHex(16);
      var scriptBody = template.replaceAll(
        "'__BACKEND_PLACEHOLDER__'",
        "'${_escapeJsString(backend)}'",
      );
      scriptBody = scriptBody.replaceAll(
        "'__PATH_SECRET_PLACEHOLDER__'",
        "'${_escapeJsString(pathSecret)}'",
      );
      // Both placeholders MUST resolve. Match the *quoted* form: it's
      // the exact replaceAll target. The unquoted form also appears in
      // the template's doc-comment block, which is fine to keep
      // post-render — checking the unquoted form would always fire.
      if (scriptBody.contains("'__BACKEND_PLACEHOLDER__'")) {
        _lastError = 'Worker template missing BACKEND placeholder.';
        return false;
      }
      if (scriptBody.contains("'__PATH_SECRET_PLACEHOLDER__'")) {
        _lastError = 'Worker template missing PATH_SECRET placeholder.';
        return false;
      }

      final scriptName = _safeWorkerName(nodeId, nodeLabel);
      final dio = Dio(BaseOptions(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
      ));

      // PUT script as a multipart upload (modules format).
      final form = _buildWorkerUploadForm(scriptBody);

      final put = await dio.put(
        '$_accountsEndpoint/$_accountId/workers/scripts/$scriptName',
        data: form,
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/form-data; boundary=${form.boundary}',
        }),
      );
      if (put.statusCode! >= 400) {
        _lastError = _extractCloudflareError(put.data) ??
            'Worker upload failed (HTTP ${put.statusCode}).';
        return false;
      }

      // Enable the workers.dev subdomain for the script — only meaningful
      // when a subdomain has been claimed. When we're shipping via
      // custom-domain only, skip the POST; sending it would 404 against
      // the nonexistent subdomain and surface a confusing error even
      // though the deploy is fine.
      String url = '';
      if ((_workersSubdomain ?? '').isNotEmpty) {
        final sub = await dio.post(
          '$_accountsEndpoint/$_accountId/workers/scripts/$scriptName/subdomain',
          data: jsonEncode({'enabled': true}),
          options: Options(headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          }),
        );
        if (sub.statusCode! >= 400) {
          _lastError = _extractCloudflareError(sub.data) ??
              'Worker uploaded but subdomain enable failed '
                  '(HTTP ${sub.statusCode}).';
          return false;
        }
        url = '$scriptName.$_workersSubdomain.workers.dev';
      }
      String? customHost;
      String? customDomainId;
      if (_customDomain != null) {
        // M1: bind the same script to the user's Workers Custom Domain.
        // Failure here is non-fatal — the workers.dev path still works
        // and the error surfaces through lastError so the user can
        // re-deploy after fixing token scope. The earlier flow continues
        // with a partial deployment record (workerHost only).
        final host = _customHostFor(scriptName);
        if (host != null) {
          final binding = await _attachWorkerCustomDomain(
            dio,
            host,
            scriptName,
            _customDomain!.zoneId,
          );
          if (binding != null) {
            customHost = binding.hostname;
            customDomainId = binding.id;
          }
        }
      }
      _deployments[nodeId] = CdnDeployment(
        nodeId: nodeId,
        scriptName: scriptName,
        workerHost: url,
        backend: backend,
        deployedAt: DateTime.now().toUtc(),
        customHost: customHost,
        customDomainId: customDomainId,
        // Mark Pending the moment we attach. The readiness probe (kicked
        // below) will flip to Active once CF answers TLS, or Failed after
        // its retry budget. Subscription emission and share-link
        // generation are gated on Active so users never connect through
        // a half-cooked cert.
        customHostStatus: customHost != null ? 'pending' : null,
        accountId: _accountId,
        pathSecret: pathSecret,
        deployedBy: deployedBy,
      );
      await _persistDeployments();
      if (customHost != null) {
        // Kick off readiness probe in the background. Status flips happen
        // via _markCustomHostStatus → notifyListeners so the UI reacts
        // when CF settles.
        unawaited(_probeCustomHostReadiness(nodeId, customHost));
      }
      // (First-upload CF 1101 self-heal lives in _probeCustomHostReadiness:
      // it rides the DoH + custom-domain path, so it works even though the
      // phone can't reach the DNS-altered *.workers.dev host.)
      // Preserve _lastError if the M1 step failed (so the UI can show it)
      // but clear it when everything succeeded.
      if (_customDomain != null && customHost == null && _lastError == null) {
        _lastError =
            'workers.dev path live, but custom-domain binding produced no host.';
      } else if (customHost != null && url.isEmpty) {
        // Single-point-of-failure guard: a custom-domain-only deploy (no
        // workers.dev subdomain claimed) leaves no sibling in the client's
        // urltest pool. If the custom hostname stalls in provisioning or
        // gets DNS-altered, the node has ZERO working CDN entry points —
        // which is exactly how nodes ended up stranded behind a 522 host.
        // Surface it so the user claims a workers.dev subdomain; a later
        // repair/redeploy then wires the fallback in automatically.
        _lastError = 'CDN deployed via custom domain only — no workers.dev '
            'fallback exists. Claim a workers.dev subdomain so the node keeps '
            'a backup route if the custom hostname ever stalls.';
      } else if (customHost != null) {
        _lastError = null;
      }
      return true;
    } on DioException catch (e) {
      _lastError =
          'Network error deploying Worker: ${e.message ?? e.type.name}';
      return false;
    } catch (e) {
      _lastError = 'Unexpected error: $e';
      return false;
    } finally {
      _isDeploying = false;
      notifyListeners();
    }
  }

  /// Delete a previously-deployed Worker. Removes from CF and clears local
  /// state. If CF returns 404, treat as success (the Worker was already gone).
  Future<bool> deleteWorkerForNode(String nodeId) async {
    final dep = _deployments[nodeId];
    if (dep == null) return true;
    // Pin to the deployment's recorded account; only fall back to the
    // current verified account for legacy records pre-dating that field.
    // Otherwise a re-verified-with-different-account user would 404
    // against the new account and orphan resources on the old one.
    final targetAccount = (dep.accountId != null && dep.accountId!.isNotEmpty)
        ? dep.accountId!
        : (_accountId ?? '');
    if (targetAccount.isEmpty) {
      _lastError = 'Account id missing — re-verify token first.';
      notifyListeners();
      return false;
    }
    final token = await StorageService.getSecureString(_kTokenKey);
    if (token == null || token.isEmpty) {
      _lastError = 'Token missing from storage.';
      notifyListeners();
      return false;
    }
    final dio = Dio(BaseOptions(
      headers: {'Authorization': 'Bearer $token'},
      validateStatus: (_) => true,
    ));

    // Detach the M1 custom-domain binding first. Best-effort: 404 is
    // success (already gone). Non-fatal — proceed with script delete
    // even if detach fails, so we don't leak the script when the
    // custom-domain binding was edited externally.
    final domainId = dep.customDomainId;
    String? detachWarning;
    if (domainId != null && domainId.isNotEmpty) {
      final detached = await _detachWorkerCustomDomain(
        dio,
        targetAccount,
        domainId,
      );
      if (!detached) {
        // Capture the error before script-delete clears _lastError.
        detachWarning = _lastError ?? 'custom-domain detach failed';
      }
    }

    final r = await dio.delete(
      '$_accountsEndpoint/$targetAccount/workers/scripts/${dep.scriptName}',
    );
    final ok = r.statusCode! < 400 || r.statusCode == 404;
    if (!ok) {
      _lastError = _extractCloudflareError(r.data) ??
          'Worker delete failed (HTTP ${r.statusCode}).';
      notifyListeners();
      return false;
    }
    _deployments.remove(nodeId);
    await _persistDeployments();
    // Surface the detach failure even when script delete succeeded — an
    // orphan custom-domain binding in CF is far worse than a stale local
    // record and the user needs to know to clean it up via dashboard.
    _lastError = detachWarning;
    notifyListeners();
    return true;
  }

  /// List active CF zones the verified token can see. Drives the M1
  /// custom-domain zone picker. Active filter is applied here so the UI
  /// doesn't need to think about pending/initializing zones (CF won't
  /// accept Worker domain bindings on those anyway).
  Future<List<CdnZone>> listZones() async {
    // Accept verifiedButIncomplete too — that state means "token is
    // good, account known, but no destination (subdomain OR custom
    // domain) is bound yet". Binding a custom domain is one of the
    // two ways to clear the incomplete state, so we MUST allow zone
    // listing in that state. Previously the strict == verified gate
    // locked the user out: dropdown returned empty zones, UI showed
    // "no zones visible" orange warning, user reported "无法选择域名".
    if (!_hadValidTokenBefore(_status)) {
      _lastError = 'Token not verified — verify it first';
      notifyListeners();
      return const [];
    }
    final token = await StorageService.getSecureString(_kTokenKey);
    if (token == null || token.isEmpty) {
      _lastError = 'Token missing from storage.';
      notifyListeners();
      return const [];
    }
    _zonesLoading = true;
    notifyListeners();
    try {
      final dio = Dio(BaseOptions(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
      ));
      // Filter on the verified account so multi-account tokens don't leak
      // zones from accounts the user didn't intend to bind.
      final aid = (_accountId ?? '').trim();
      const perPage = 50;
      const maxPages = 40; // safety cap: 40 * 50 = 2000 zones
      final out = <CdnZone>[];
      // Walk every page. Earlier code stopped at the first 50, silently
      // hiding zones from users with >50 of them.
      for (var page = 1; page <= maxPages; page++) {
        final base = aid.isNotEmpty
            ? '$_zonesEndpoint?per_page=$perPage&account.id=$aid'
            : '$_zonesEndpoint?per_page=$perPage';
        final url = '$base&page=$page';
        final r = await dio.get(url);
        if (r.statusCode == null || r.statusCode! >= 400) {
          _lastError = _extractCloudflareError(r.data) ??
              'Listing zones failed (HTTP ${r.statusCode}).';
          return const [];
        }
        final body = r.data;
        if (body is! Map || body['result'] is! List) {
          _lastError = 'Unexpected /zones response shape.';
          return const [];
        }
        final raw = body['result'] as List;
        for (final z in raw) {
          if (z is! Map) continue;
          if (z['status'] != 'active') continue;
          final id = z['id']?.toString();
          final name = z['name']?.toString();
          if (id == null || id.isEmpty || name == null || name.isEmpty) {
            continue;
          }
          out.add(CdnZone(id: id, name: name));
        }
        // Terminate on result_info.total_pages, falling back to
        // short-page detection so a missing total_pages still exits.
        final info = body['result_info'];
        var totalPages = 0;
        if (info is Map) {
          final tp = info['total_pages'];
          if (tp is int) {
            totalPages = tp;
          } else if (tp is num) {
            totalPages = tp.toInt();
          }
        }
        if (totalPages > 0 && page >= totalPages) break;
        if (raw.length < perPage) break;
      }
      _zones = out;
      _lastError = null;
      return List.unmodifiable(out);
    } on DioException catch (e) {
      _lastError = 'Network error listing zones: ${e.message ?? e.type.name}';
      return const [];
    } finally {
      _zonesLoading = false;
      notifyListeners();
    }
  }

  /// Persist the M1 binding config. Subsequent [deployWorkerForNode] calls
  /// also attach the script to a Workers Custom Domain on this zone, with
  /// hostname = "<subdomain>-<scriptHash>.<zoneName>". Existing deployments
  /// are NOT re-bound — the user must re-deploy them to pick up the change.
  Future<bool> setCustomDomain(String zoneId, String subdomain) async {
    final cleanZone = zoneId.trim();
    final cleanSub = subdomain.trim();
    if (cleanZone.isEmpty) {
      _lastError = 'Zone id required.';
      notifyListeners();
      return false;
    }
    final subError = _validateDnsLabel(cleanSub);
    if (subError != null) {
      _lastError = subError;
      notifyListeners();
      return false;
    }
    // Same logic as listZones: verifiedButIncomplete is allowed here
    // because binding a custom domain is how the user EXITS the
    // incomplete state. The strict == verified gate would make the
    // save button silently fail with "Token not verified" even
    // though the token is fine.
    if (!_hadValidTokenBefore(_status)) {
      _lastError = 'Token not verified — verify it first.';
      notifyListeners();
      return false;
    }
    _isSavingCustomDomain = true;
    notifyListeners();
    try {
      // Fail-fast probe: verify the token can read Workers Custom Domains
      // on the verified account *before* persisting the binding config.
      // Catches the most common missed-scope case at save time instead of
      // surfacing as a mysterious deploy failure later.
      final scopeError = await _probeCustomDomainScope();
      if (scopeError != null) {
        _lastError = scopeError;
        return false;
      }
      // Validate the zone is reachable with the current token. Reuses the
      // listZones result to avoid an extra round-trip if we just fetched.
      // listZones is now account-filtered so visibility means
      // "in the verified account", not just "in any account this token can see".
      final available = _zones.isNotEmpty ? _zones : await listZones();
      CdnZone? matched;
      for (final z in available) {
        if (z.id == cleanZone) {
          matched = z;
          break;
        }
      }
      if (matched == null) {
        _lastError = 'Zone $cleanZone not in account $_accountId '
            '(or not active). Pick a zone from this account, or re-verify '
            'with a token covering the intended account.';
        return false;
      }
      _customDomain = CdnCustomDomain(
        zoneId: matched.id,
        zoneName: matched.name,
        subdomain: cleanSub,
      );
      await _persistCustomDomain();
      // Promote out of verifiedButIncomplete now that a destination
      // exists. Without this, the UI stayed locked in the yellow
      // "setup incomplete" state even after the user successfully
      // bound a domain — the very thing the warning was asking them
      // to do — because nothing recomputed _status. Codex review #4
      // caught this as a half-fix of the dropdown bug: dropdown
      // works, save succeeds, but the user still can't deploy
      // Workers because [deployWorkerForNode] gates strictly on
      // verified.
      if (_status == CdnStatus.verifiedButIncomplete) {
        _status = CdnStatus.verified;
      }
      _lastError = null;
      return true;
    } finally {
      _isSavingCustomDomain = false;
      notifyListeners();
    }
  }

  /// GET /accounts/{aid}/workers/domains?per_page=1 with the current token.
  /// Empty result is fine — we just need 200; 401/403 mean the token's
  /// permission set is missing 'Account.Workers Scripts:Edit' against this
  /// account. Returns null when the call succeeds, or a user-actionable
  /// error string when it doesn't.
  Future<String?> _probeCustomDomainScope() async {
    final token = await StorageService.getSecureString(_kTokenKey);
    if (token == null || token.isEmpty) {
      return 'Token missing from storage.';
    }
    final aid = (_accountId ?? '').trim();
    if (aid.isEmpty) {
      return 'Token not verified — verify it first.';
    }
    try {
      final dio = Dio(BaseOptions(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
      ));
      final r =
          await dio.get('$_accountsEndpoint/$aid/workers/domains?per_page=1');
      final code = r.statusCode ?? 0;
      if (code == 200) return null;
      if (code == 401 || code == 403) {
        return "Token cannot read Workers Custom Domains on this account — "
            "add 'Account.Workers Scripts:Edit' scope to the token "
            "(or pick a token already verified against the right account).";
      }
      return _extractCloudflareError(r.data) ??
          'Custom Domains scope probe failed (HTTP $code).';
    } on DioException catch (e) {
      return 'Network error probing scope: ${e.message ?? e.type.name}';
    }
  }

  /// Wipe the M1 binding config. Existing deployments retain their bindings
  /// on disk so [deleteWorkerForNode] can still detach them; only future
  /// deploys revert to workers.dev only.
  Future<void> clearCustomDomain() async {
    _customDomain = null;
    await _persistCustomDomain();
    // Mirror of the promote logic in setCustomDomain: if removing the
    // custom domain leaves no destination at all (no workers.dev
    // subdomain claimed either), demote back to verifiedButIncomplete.
    // Codex review round 2 caught the asymmetry — without this, the
    // UI shows green "verified" but deployWorkerForNode would reject
    // because there's no destination.
    final hasSubdomain = (_workersSubdomain ?? '').isNotEmpty;
    if (!hasSubdomain && _status == CdnStatus.verified) {
      _status = CdnStatus.verifiedButIncomplete;
      // Distinct copy from the generic "Token verified, but no
      // subdomain" — the user just intentionally removed the binding,
      // so the message should explain the consequence + what would
      // re-enable deploy.
      _lastError = 'Custom domain unbound. To deploy Workers, claim a '
          'workers.dev subdomain in the Cloudflare dashboard, or bind '
          'a custom domain below.';
    } else {
      _lastError = null;
    }
    notifyListeners();
  }

  /// Compose the per-script host. Each Worker gets a distinct host so multi-
  /// node deploys don't collide on a single Custom Domain (CF binds one
  /// hostname → one script).
  String? _customHostFor(String scriptName) {
    final cd = _customDomain;
    if (cd == null) return null;
    final suffix = _scriptShortSuffix(scriptName);
    if (suffix == null) return null;
    return '${cd.subdomain}-$suffix.${cd.zoneName}';
  }

  /// Extract the trailing 6-hex-digit hash that [_safeWorkerName] always
  /// appends, mirroring the Go side. Same script → same host.
  String? _scriptShortSuffix(String scriptName) {
    if (scriptName.length < 6) return null;
    final cand = scriptName.substring(scriptName.length - 6);
    final hex = RegExp(r'^[0-9a-f]{6}$');
    return hex.hasMatch(cand) ? cand : null;
  }

  /// Workers Custom Domains attach. Single PUT replaces the older two-step
  /// (DNS CNAME + Worker route) flow; CF auto-creates DNS + managed cert.
  /// Returned id lets [_detachWorkerCustomDomain] address the binding later
  /// without re-resolving by hostname.
  /// Build the multipart body for a module-Worker upload.
  ///
  /// ROOT-CAUSE FIX (1101): the `metadata` part MUST carry
  /// `Content-Type: application/json`. Dio plain form *fields*
  /// (`form.fields`) send no per-part Content-Type, so Cloudflare read the
  /// metadata as text, ignored `main_module`, and treated the upload as a
  /// legacy *service-worker* script. Under that mode the worker.js ES-module
  /// syntax (`import { connect } …` / `export default`) is a parse error, so
  /// the deployed Worker threw CF error 1101 on EVERY request — every phone
  /// (Dart) deploy was silently broken this way, while the Go bridge worked
  /// because it set the header explicitly. Sending metadata as a
  /// MultipartFile forces the Content-Type and matches the Go path.
  FormData _buildWorkerUploadForm(String scriptBody) {
    final form = FormData();
    form.files.add(MapEntry(
      'metadata',
      MultipartFile.fromString(
        jsonEncode({
          'main_module': 'worker.mjs',
          'compatibility_date': _kCompatDate,
        }),
        contentType: DioMediaType('application', 'json'),
      ),
    ));
    form.files.add(MapEntry(
      'worker.mjs',
      MultipartFile.fromString(
        scriptBody,
        filename: 'worker.mjs',
        contentType: DioMediaType('application', 'javascript+module'),
      ),
    ));
    return form;
  }

  Future<_WorkerCustomDomainBinding?> _attachWorkerCustomDomain(
    Dio dio,
    String hostname,
    String scriptName,
    String zoneId,
  ) async {
    final r = await dio.put(
      '$_accountsEndpoint/$_accountId/workers/domains',
      data: jsonEncode({
        'hostname': hostname,
        'service': scriptName,
        'environment': 'production',
        'zone_id': zoneId,
      }),
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    if (r.statusCode == null || r.statusCode! >= 400) {
      _lastError = _extractCloudflareError(r.data) ??
          'Custom domain attach failed (HTTP ${r.statusCode}).';
      return null;
    }
    final body = r.data;
    if (body is! Map || body['result'] is! Map) {
      _lastError = 'Unexpected /workers/domains response shape.';
      return null;
    }
    final res = body['result'] as Map;
    final id = res['id']?.toString();
    if (id == null || id.isEmpty) {
      _lastError = 'Custom domain attach returned no id.';
      return null;
    }
    return _WorkerCustomDomainBinding(
      id: id,
      hostname: res['hostname']?.toString() ?? hostname,
    );
  }

  /// Workers Custom Domains detach. 404 is treated as success (the binding
  /// is already gone — CF dashboard or another tool may have removed it).
  /// CF cascades the auto-created DNS record as part of the detach.
  Future<bool> _detachWorkerCustomDomain(
    Dio dio,
    String accountId,
    String domainId,
  ) async {
    if (domainId.isEmpty) return true;
    final r = await dio.delete(
      '$_accountsEndpoint/$accountId/workers/domains/$domainId',
    );
    final ok =
        r.statusCode != null && (r.statusCode! < 400 || r.statusCode == 404);
    if (!ok) {
      _lastError = _extractCloudflareError(r.data) ??
          'Custom domain detach failed (HTTP ${r.statusCode}).';
    }
    return ok;
  }

  String _safeWorkerName(String nodeId, String label) {
    // Worker script names: alphanumeric + hyphen, max 63 chars, must start
    // with letter. Compose from a sanitized label + a short stable hash of
    // the node id (so re-deploying same node reuses the same script name).
    final cleanLabel = label
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final shortId = _shortHash(nodeId, length: 6);
    final name = cleanLabel.isEmpty
        ? 'pd-relay-$shortId'
        : 'pd-relay-${cleanLabel.substring(0, min(20, cleanLabel.length))}-$shortId';
    if (RegExp(r'^[0-9]').hasMatch(name)) {
      return 'r-$name';
    }
    return name;
  }

  /// Resume readiness probes for every deployment that has a custom host
  /// but hasn't reached 'active' yet. Crucially this includes 'failed',
  /// not only 'pending'.
  ///
  /// Root-cause fix: the one-shot probe in [_probeCustomHostReadiness]
  /// regularly hit its budget before Cloudflare finished issuing the
  /// managed cert for a new custom hostname, or before a just-deployed
  /// VPS opened its relay port. Marking that transient 'failed' — and
  /// then never re-probing 'failed' — permanently stranded otherwise
  /// correct deployments behind a custom host that 404/522s. Re-probing
  /// 'failed' on every cold start and after a cloud-backup import lets
  /// such a node self-heal once CF and the VPS settle, instead of
  /// requiring a manual re-deploy.
  void _resumeIncompleteProbes() {
    for (final entry in _deployments.entries) {
      final dep = entry.value;
      final host = dep.customHost;
      if (host == null || host.isEmpty) continue;
      final status = dep.customHostStatus;
      if (status != 'pending' && status != 'failed') continue;
      // Reset a stale 'failed' to 'pending' so the UI honestly shows
      // "probing" during the retry instead of a red Failed chip.
      if (status == 'failed') {
        unawaited(_markCustomHostStatus(entry.key, host, 'pending'));
      }
      unawaited(_probeCustomHostReadiness(entry.key, host));
    }
  }

  /// Polls the customHost until the WS upgrade succeeds end-to-end (CF
  /// cert + Worker dispatch + Worker→VPS TCP) or the budget is
  /// exhausted. Mirrors bridge/cdn/cdn_probe.go so desktop and mobile
  /// have the same readiness semantics. Total budget ~24 min.
  ///
  /// The long tail is deliberate and was the fix for a real stranding
  /// bug: a brand-new Workers Custom Domain's managed edge certificate
  /// plus DNS/edge propagation, and a freshly-booted VPS opening its
  /// relay port + UFW rule, both routinely take much longer than the
  /// first few minutes. The old ~3.7-min budget expired mid-provisioning,
  /// the deployment was marked terminally 'failed', and — because nothing
  /// re-probed 'failed' — the node was left advertising a custom host that
  /// 404/522s forever even though the deploy itself was correct. This
  /// budget now covers worst-case CF cert issuance, and
  /// [_resumeIncompleteProbes] re-runs it on every launch/import so even
  /// this ceiling is per-session, not one-and-done.
  ///
  /// Two-stage: cheap TLS handshake first, then a WS upgrade with the
  /// deployment's path-secret. The WS upgrade is the only real proof
  /// that Worker→VPS connectivity is live (UFW open, port correct,
  /// VPS up). Earlier code only checked TLS, which would happily report
  /// "active" against a Worker pointing at a closed port.
  Future<void> _probeCustomHostReadiness(String nodeId, String host,
      {bool autoRepair = true}) async {
    var repaired = false;
    var badStreak = 0;
    var backendStreak = 0;
    const delays = [
      Duration(seconds: 3),
      Duration(seconds: 6),
      Duration(seconds: 12),
      Duration(seconds: 20),
      Duration(seconds: 30),
      Duration(seconds: 40),
      Duration(seconds: 50),
      Duration(seconds: 60),
      Duration(seconds: 90),
      Duration(seconds: 120),
      Duration(seconds: 180),
      Duration(seconds: 240),
      Duration(seconds: 300),
      Duration(seconds: 300),
    ];
    for (final d in delays) {
      await Future.delayed(d);
      final dep = _deployments[nodeId];
      if (dep == null || dep.customHost != host) {
        // Deployment was deleted or re-bound; abandon this probe.
        return;
      }
      if (!await _customHostTLSReachable(host)) {
        debugPrint('[CDNProbe] $host tls=DOWN (retry, delay was $d)');
        continue;
      }
      final secret = (dep.pathSecret ?? '').trim();
      if (secret.isEmpty) {
        // Legacy deployment with no path-secret on record. TLS-only
        // is the best we can do — mark active so it doesn't sit in
        // pending forever.
        await _markCustomHostStatus(nodeId, host, 'active');
        return;
      }
      final status = await _customHostUpgradeStatus(host, secret);
      debugPrint('[CDNProbe] $host status=$status secretLen=${secret.length}');
      // Record the last definite status so the UI can distinguish a backend
      // failure (Worker up, VPS relay 502/504) from a CDN-layer failure and
      // point the user at the right fix. 502/504 is intentionally NOT treated
      // as brokenWorkerOrBinding below: recreating the Worker can't revive a
      // dead VPS relay (confirmed on node-260602234422 — stayed 502 across a
      // full worker+binding recreate; only a node redeploy fixed it).
      if (status != null) _lastProbeStatus[nodeId] = status;
      if (status == 101) {
        await _markCustomHostStatus(nodeId, host, 'active');
        return;
      }
      // 502/504 = the Worker is up but can't reach the VPS relay backend.
      // Tolerate a boot window (a freshly-deployed node's relay needs a few
      // minutes), but past ~7 min of unbroken bad-gateway the backend is
      // genuinely down — and no Worker/binding action can revive it (proven
      // on node-260602234422). Fail now, with the 502 already recorded above,
      // so the UI says "redeploy the node" promptly instead of sitting on
      // "verifying" for the full ~24-min budget.
      if (status == 502 || status == 504) {
        backendStreak++;
        if (backendStreak >= 10) {
          await _markCustomHostStatus(nodeId, host, 'failed');
          return;
        }
      } else {
        backendStreak = 0;
      }
      // TLS is up but the host isn't serving the relay. 500 = the Worker
      // threw (first-upload CF 1101); 52x = the custom-domain binding is
      // stuck — both are cleared by a delete+recreate. A brand-new custom
      // domain can briefly 52x while its managed cert provisions, so only
      // repair after the bad state persists a few iterations. 502/504 = the
      // VPS relay is still booting and 404 = secret/legacy — those
      // self-resolve, so keep probing. repairCustomHostForNode re-uploads +
      // re-attaches and re-probes with autoRepair off, so it can't loop.
      // Rides the DoH + custom-domain path, so it works where a
      // *.workers.dev GET can't (that host is DNS-altered on these nets).
      final brokenWorkerOrBinding =
          status != null && (status == 500 || (status >= 520 && status <= 526));
      if (brokenWorkerOrBinding) {
        badStreak++;
        if (autoRepair && !repaired && badStreak >= 3) {
          repaired = true;
          await repairCustomHostForNode(nodeId);
          return;
        }
      } else {
        badStreak = 0;
      }
    }
    await _markCustomHostStatus(nodeId, host, 'failed');
  }

  /// Re-run the customHost readiness probe for an existing deployment
  /// without redeploying the Worker. Useful when the deploy itself was
  /// correct (script uploaded, route bound) but CF was still mid-
  /// propagation when the original probe budget expired, leaving the
  /// node parked at status='failed' even though a single later retry
  /// would clear it. Resets to 'pending' on entry so the UI feedback
  /// matches what's actually happening.
  ///
  /// Returns true if the probe ultimately confirmed reachability;
  /// false if it timed out again (status stays 'failed') or the
  /// deployment / customHost vanished mid-probe.
  Future<bool> retryCustomHostProbe(String nodeId) async {
    final dep = _deployments[nodeId];
    if (dep == null) return false;
    final host = dep.customHost;
    if (host == null || host.isEmpty) return false;
    await _markCustomHostStatus(nodeId, host, 'pending');
    await _probeCustomHostReadiness(nodeId, host);
    final after = _deployments[nodeId];
    return after?.customHostStatus == 'active';
  }

  /// Authoritative existence check of a Workers Custom Domain binding,
  /// straight from Cloudflare rather than the blackbox TLS/WS probe.
  ///
  /// The blackbox probe can't tell "binding orphaned (worker/DNS gone)"
  /// apart from "binding present but cert still provisioning" — both look
  /// like an unreachable host. This GET does: a 404 means the binding is
  /// gone (only a re-attach restores service), anything 2xx means it still
  /// exists (waiting / re-probing can clear it). Returns null when the call
  /// itself failed (network/token) so callers fall back to the probe
  /// instead of acting on bad data.
  Future<bool?> _customDomainBindingExists(
    Dio dio,
    String accountId,
    String customDomainId,
  ) async {
    try {
      final r = await dio.get(
        '$_accountsEndpoint/$accountId/workers/domains/$customDomainId',
      );
      final code = r.statusCode ?? 0;
      if (code == 404) return false;
      if (code >= 400) return null;
      return true;
    } catch (_) {
      return null;
    }
  }

  /// Repair a stuck/failed custom-domain deployment WITHOUT a full node
  /// redeploy. Unlike [retryCustomHostProbe] (which only re-runs the
  /// blackbox probe and so can never recover an orphaned or never-activated
  /// binding), this re-asserts the whole CF side from the deployment's own
  /// stored parameters:
  ///   1. Re-render + re-upload the Worker script from the deployment's
  ///      backend + path-secret (reusing the SAME secret so every client
  ///      already pointed here stays valid). Fixes a script deleted out
  ///      from under the binding — a classic 522 cause.
  ///   2. Enable the workers.dev fallback when a subdomain is now claimed,
  ///      closing the single-point-of-failure where a custom-domain-only
  ///      deploy had no sibling in the client's urltest pool.
  ///   3. Re-attach the Workers Custom Domain (idempotent PUT) — the actual
  ///      fix for "DNS record resolves but the host 404/522s".
  ///   4. Re-probe and persist.
  ///
  /// Returns true when the node ends up with at least one usable CDN path
  /// (custom host active, or a workers.dev fallback now in place).
  Future<bool> repairCustomHostForNode(String nodeId) async {
    if (_isDeploying) return false;
    final dep = _deployments[nodeId];
    if (dep == null) return false;
    // Repair re-renders from dep.backend (the stored value — we can't reach
    // the live CloudInstance here, and must keep the SAME path-secret so
    // existing clients keep working). If that stored backend is host-less
    // (e.g. ":24444", left by the pre-fix empty-IPv4 auto-deploy race), an
    // overwrite just re-creates a Worker that 502s on every relay — only a
    // delete + fresh deploy re-derives the backend from the node's IPv4.
    // Refuse loudly instead of silently re-uploading a broken Worker.
    if (dep.backend.split(':').first.trim().isEmpty) {
      _lastError =
          'Stored backend "${dep.backend}" has no host (legacy empty-IP '
          'deploy). Repair would just re-upload a 502 Worker — delete this '
          "node's Worker and deploy it again to re-bind the node IP.";
      notifyListeners();
      return false;
    }
    if (_status != CdnStatus.verified || (_accountId ?? '').isEmpty) {
      _lastError = 'Token not verified — verify it first.';
      notifyListeners();
      return false;
    }
    _isDeploying = true;
    _lastError = null;
    notifyListeners();
    try {
      final token = await StorageService.getSecureString(_kTokenKey);
      if (token == null || token.isEmpty) {
        _lastError = 'Token missing from storage.';
        return false;
      }
      // Pin to the deployment's recorded account so a re-verified token
      // pointing at a different account doesn't repair the wrong worker.
      final accountId =
          (dep.accountId?.isNotEmpty ?? false) ? dep.accountId! : _accountId!;
      final scriptName = dep.scriptName;

      // Re-render from the deployment's OWN backend + path-secret. Never
      // mint a fresh secret here: that would silently break every client
      // already routed through this host.
      final template = await rootBundle.loadString('assets/cdn/worker.js');
      var scriptBody = template.replaceAll(
        "'__BACKEND_PLACEHOLDER__'",
        "'${_escapeJsString(dep.backend)}'",
      );
      scriptBody = scriptBody.replaceAll(
        "'__PATH_SECRET_PLACEHOLDER__'",
        "'${_escapeJsString(dep.pathSecret ?? '')}'",
      );
      if (scriptBody.contains("'__BACKEND_PLACEHOLDER__'") ||
          scriptBody.contains("'__PATH_SECRET_PLACEHOLDER__'")) {
        _lastError = 'Worker template placeholder render failed.';
        return false;
      }

      final dio = Dio(BaseOptions(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
      ));

      // 1. Delete the script, then re-create it. A Worker that came up
      //    throwing 1101 on its very first upload stays broken under an
      //    overwrite-PUT — only a delete + fresh create clears the bad
      //    module state. force=true so an attached custom domain doesn't
      //    block the delete (it's re-attached in step 3 below).
      try {
        await dio.delete(
          '$_accountsEndpoint/$accountId/workers/scripts/$scriptName?force=true',
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
      } catch (_) {}
      final form = _buildWorkerUploadForm(scriptBody);
      final put = await dio.put(
        '$_accountsEndpoint/$accountId/workers/scripts/$scriptName',
        data: form,
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/form-data; boundary=${form.boundary}',
        }),
      );
      if ((put.statusCode ?? 500) >= 400) {
        _lastError = _extractCloudflareError(put.data) ??
            'Worker re-upload failed (HTTP ${put.statusCode}).';
        return false;
      }

      // 2. Ensure a workers.dev fallback exists when a subdomain is claimed.
      var workerHost = dep.workerHost;
      if ((_workersSubdomain ?? '').isNotEmpty) {
        final sub = await dio.post(
          '$_accountsEndpoint/$accountId/workers/scripts/$scriptName/subdomain',
          data: jsonEncode({'enabled': true}),
          options: Options(headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          }),
        );
        if ((sub.statusCode ?? 500) < 400) {
          workerHost = '$scriptName.$_workersSubdomain.workers.dev';
        }
      }

      // 3. Re-attach the custom domain (idempotent). Only when the bound
      //    domain still matches the deployment's host — otherwise we don't
      //    know the zone id and must not guess.
      var customHost = dep.customHost;
      var customDomainId = dep.customDomainId;
      final cd = _customDomain;
      // Authoritative pre-flight (Hardening #2): ask Cloudflare whether the
      // binding still exists, so we can tell the user whether this was an
      // orphan (had to be re-created) or a slow cert (just re-attached).
      bool? bindingWasPresent;
      if (cd != null &&
          (customHost?.isNotEmpty ?? false) &&
          customHost!.endsWith('.${cd.zoneName}')) {
        if (customDomainId != null && customDomainId.isNotEmpty) {
          bindingWasPresent =
              await _customDomainBindingExists(dio, accountId, customDomainId);
          // A binding that exists but never goes live — the host 52x's while
          // the Worker itself is healthy on workers.dev — is stuck: its
          // managed certificate failed to provision, or the route points at a
          // stale service. An idempotent re-attach (PUT) just returns that
          // same stuck binding without re-issuing anything, which is why
          // delete+recreate of the *script* alone never healed these nodes.
          // Mirror the Worker fix at the binding layer: DELETE the binding,
          // then create it fresh so CF re-provisions the cert and re-wires the
          // route. CF cascades the auto-created DNS record on detach; the
          // attach below re-creates it. (Confirmed on node-260602234422:
          // worker = 404 on workers.dev, custom host = 522.)
          if (bindingWasPresent == true) {
            await _detachWorkerCustomDomain(dio, accountId, customDomainId);
            customDomainId = null;
          }
        }
        final binding = await _attachWorkerCustomDomain(
            dio, customHost, scriptName, cd.zoneId);
        if (binding != null) {
          customHost = binding.hostname;
          customDomainId = binding.id;
        }
      }

      _deployments[nodeId] = CdnDeployment(
        nodeId: dep.nodeId,
        scriptName: scriptName,
        workerHost: workerHost,
        backend: dep.backend,
        deployedAt: DateTime.now().toUtc(),
        customHost: customHost,
        customDomainId: customDomainId,
        customHostStatus: (customHost?.isNotEmpty ?? false) ? 'pending' : null,
        accountId: accountId,
        pathSecret: dep.pathSecret,
        deployedBy: dep.deployedBy,
      );
      await _persistDeployments();
      notifyListeners();

      // Release the deploy lock BEFORE verifying. _probeCustomHostReadiness
      // can run for its full retry budget (~24 min when a managed cert is
      // slow); awaiting it here pinned _isDeploying for that entire window.
      // Because the auto-heal path calls repairCustomHostForNode from INSIDE
      // the deploy probe (on persistent 500/52x), that hold blocked every
      // concurrent deploy and made the manual "repair & retry" button
      // instant-fail with a misleading "unreachable" for up to 24 min.
      // Mirror deployWorkerForNode, which kicks its probe unawaited: free the
      // lock now and let the status row reflect the real verdict via
      // _markCustomHostStatus → notifyListeners as CF settles.
      _isDeploying = false;
      if (customHost?.isNotEmpty ?? false) {
        // autoRepair off: this probe runs right after a recreate, so it must
        // not trigger another recreate (would loop).
        unawaited(
            _probeCustomHostReadiness(nodeId, customHost!, autoRepair: false));
      }
      // "Applied" = the CF side was re-asserted (script recreated, domain
      // re-attached) and a path now exists to verify; readiness itself is
      // reported asynchronously by the probe kicked above.
      final applied =
          (customHost?.isNotEmpty ?? false) || workerHost.isNotEmpty;
      if (applied) {
        _lastError = bindingWasPresent == false
            ? 'Custom-domain binding was missing on Cloudflare and has been '
                're-created — the managed certificate can take a few minutes '
                'to go active.'
            : null;
      }
      return applied;
    } on DioException catch (e) {
      _lastError =
          'Network error repairing Worker: ${e.message ?? e.type.name}';
      return false;
    } catch (e) {
      _lastError = 'Unexpected error: $e';
      return false;
    } finally {
      _isDeploying = false;
      notifyListeners();
    }
  }

  /// True when this node's deployment relies on a custom hostname with no
  /// workers.dev fallback — a single point of failure in the client's
  /// urltest pool. Drives a UI hint nudging the user to claim a
  /// workers.dev subdomain (which [repairCustomHostForNode] then wires in).
  bool deploymentLacksFallback(String nodeId) {
    final dep = _deployments[nodeId];
    if (dep == null) return false;
    return (dep.customHost?.isNotEmpty ?? false) && dep.workerHost.isEmpty;
  }

  /// Single TLS handshake to host:443. Success = CF edge served a valid
  /// cert for the SNI — necessary but not sufficient for the relay to
  /// work end-to-end.
  ///
  /// Resolution goes through DoH (see [_resolveViaDoH]) instead of the
  /// OS resolver. Without that, the first probe iteration fires within
  /// seconds of the Workers Custom Domain binding, before CF's auto-DNS
  /// has propagated. The OS resolver returns NXDOMAIN, then per RFC 2308
  /// caches it negatively for the zone's SOA-MIN — typically far longer
  /// than the entire 3.7-min probe budget. Once cached, every iteration
  /// continues to fail even after CF has fully provisioned the record.
  /// AOSP's `netd/res_cache.cpp` and iOS's `mDNSResponder` both honor
  /// SOA-MIN, so this is not Android-specific. DoH bypass dodges both
  /// caches by going straight to authoritative-by-proxy resolvers each
  /// iteration.
  Future<bool> _customHostTLSReachable(String host) async {
    Socket? raw;
    SecureSocket? secure;
    try {
      final ips = await _resolveViaDoH(host);
      if (ips.isEmpty) return false;
      // Open TCP to the DoH-resolved IP, then upgrade to TLS with the
      // customHost as the SNI/Host so CF presents the correct cert. We
      // avoid `SecureSocket.connect(host, ...)` because passing a hostname
      // there would re-introduce the OS-resolver lookup we just bypassed.
      raw = await Socket.connect(
        ips.first,
        443,
        timeout: const Duration(seconds: 8),
      );
      secure = await SecureSocket.secure(raw, host: host)
          .timeout(const Duration(seconds: 8));
      await secure.close();
      return true;
    } catch (_) {
      try {
        await secure?.close();
      } catch (_) {}
      try {
        raw?.destroy();
      } catch (_) {}
      return false;
    }
  }

  /// Attempts the full WS upgrade through the Worker, exercising the
  /// entire CF-edge → Worker → VPS relay path. Success means the Worker
  /// accepted the path-secret AND established a TCP connection to the
  /// VPS upstream. We close immediately — no payload exchange needed,
  /// only that the upgrade returned 101.
  ///
  /// A 502/504 means Worker→VPS TCP failed (UFW, wrong port, VPS down).
  /// 404 means the path-secret didn't match.
  /// Performs the WS upgrade against the custom host (DoH-resolved, so it
  /// works even where *.workers.dev is DNS-altered) and returns the HTTP
  /// status of the response: 101 = relay path live, 404 = secret mismatch,
  /// 500 = the Worker itself threw (CF 1101), 502/504 = Worker→VPS down.
  /// null = couldn't get a status (TLS/DNS/timeout).
  Future<int?> _customHostUpgradeStatus(String host, String pathSecret) async {
    if (host.isEmpty || pathSecret.isEmpty) return null;
    Socket? raw;
    SecureSocket? secure;
    StreamSubscription<List<int>>? sub;
    try {
      // DoH-resolve the custom host (see _resolveViaDoH for why), then
      // open the TLS connection ourselves and write the WebSocket upgrade
      // by hand. The earlier attempt used HttpClient.connectionFactory
      // for this, which works for plain HTTP but not HTTPS: the factory
      // must return a SecureSocket that's already TLS-handshaken, and
      // ConnectionTask has no public constructor that lets us hand back
      // a TLS-wrapped socket. Rather than fight the framework, we just
      // do the upgrade dance directly — eight extra lines of HTTP/1.1.
      final ips = await _resolveViaDoH(host);
      debugPrint(
          '[CDNProbe] $host DoH-> ${ips.isEmpty ? "EMPTY" : ips.join(",")}');
      if (ips.isEmpty) return null;
      raw = await Socket.connect(
        ips.first,
        443,
        timeout: const Duration(seconds: 8),
      );
      // ALPN must be HTTP/1.1 only. CF Worker WebSocket upgrades use the
      // HTTP/1.1 Upgrade mechanism; over HTTP/2 the runtime strips the
      // Upgrade + Connection headers (they're hop-by-hop in HTTP/2) and
      // the Worker returns 404 even though every other handshake field
      // is correct. Without an explicit supportedProtocols list Dart's
      // TLS client may send no ALPN extension, leaving CF free to pick
      // h2 — and we'd silently misread a healthy Worker as broken.
      secure = await SecureSocket.secure(
        raw,
        host: host,
        supportedProtocols: const ['http/1.1'],
      ).timeout(const Duration(seconds: 8));
      // RFC 6455 Sec-WebSocket-Key: 16 random bytes, base64.
      final keyBytes = Uint8List(16);
      final rng = Random.secure();
      for (var i = 0; i < 16; i++) {
        keyBytes[i] = rng.nextInt(256);
      }
      final wsKey = base64Encode(keyBytes);
      final query = 'ed=2560&k=${Uri.encodeQueryComponent(pathSecret)}';
      final req = 'GET /?$query HTTP/1.1\r\n'
          'Host: $host\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: $wsKey\r\n'
          'Sec-WebSocket-Version: 13\r\n'
          'User-Agent: PrivateDeploy-CDN-Probe/1\r\n'
          '\r\n';
      secure.add(utf8.encode(req));
      // Wait for the response status line. We don't care about anything
      // past it — 101 Switching Protocols is the only success case; any
      // other status code (404 secret-mismatch, 502/504 Worker→VPS down,
      // 400 malformed request) means the relay path isn't ready.
      final firstLine = Completer<String>();
      final buf = BytesBuilder();
      sub = secure.listen(
        (chunk) {
          buf.add(chunk);
          final s = utf8.decode(buf.toBytes(), allowMalformed: true);
          final eol = s.indexOf('\r\n');
          if (eol >= 0 && !firstLine.isCompleted) {
            firstLine.complete(s.substring(0, eol));
          }
        },
        onError: (e) {
          if (!firstLine.isCompleted) firstLine.completeError(e);
        },
        onDone: () {
          if (!firstLine.isCompleted) {
            firstLine.completeError(
                const SocketException('connection closed before response'));
          }
        },
        cancelOnError: true,
      );
      final line = await firstLine.future.timeout(const Duration(seconds: 12));
      debugPrint('[CDNProbe] $host upgrade line: $line');
      // Parse the numeric status from "HTTP/1.1 <code> <text>".
      final m = RegExp(r'^HTTP/1\.[01]\s+(\d{3})').firstMatch(line);
      return m != null ? int.parse(m.group(1)!) : null;
    } catch (e) {
      debugPrint('[CDNProbe] $host upgrade EXC: $e');
      return null;
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await secure?.close();
      } catch (_) {}
      try {
        raw?.destroy();
      } catch (_) {}
    }
  }

  /// DoH endpoints, tried in order until one returns A records. Hardcoded
  /// to IP literals so we never consult the OS resolver for the DoH
  /// provider itself (which would re-introduce the negative-cache hazard
  /// the whole DoH path exists to dodge). AliDNS is listed first because
  /// the app's primary audience is regional mobile network, where CF/Google are
  /// reachable but markedly slower (200ms+ RTT) and sometimes middleboxed.
  /// CF/Google follow as fallbacks for non-regional networks where AliDNS is
  /// the slow path.
  static const List<String> _kDoHEndpoints = [
    'https://223.5.5.5/resolve', // AliDNS (CN-friendly)
    'https://223.6.6.6/resolve', // AliDNS secondary
    'https://1.1.1.1/dns-query', // Cloudflare
    'https://1.0.0.1/dns-query', // Cloudflare secondary
    'https://8.8.8.8/resolve', // Google
  ];

  Future<List<InternetAddress>> _resolveViaDoH(String host) async {
    if (host.isEmpty) return const [];
    for (final ep in _kDoHEndpoints) {
      final ips = await _doHQuery(ep, host);
      if (ips.isNotEmpty) return ips;
    }
    return const [];
  }

  Future<List<InternetAddress>> _doHQuery(String endpoint, String host) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      validateStatus: (_) => true,
    ));
    try {
      final r = await dio.getUri<dynamic>(
        Uri.parse('$endpoint?name=$host&type=A'),
        options: Options(headers: {'accept': 'application/dns-json'}),
      );
      if (r.statusCode != 200 || r.data == null) return const [];
      final body = r.data;
      Map<String, dynamic>? parsed;
      if (body is Map) {
        parsed = Map<String, dynamic>.from(body);
      } else if (body is String) {
        try {
          parsed = jsonDecode(body) as Map<String, dynamic>;
        } catch (_) {
          return const [];
        }
      }
      if (parsed == null) return const [];
      final answers = parsed['Answer'];
      if (answers is! List) return const [];
      final out = <InternetAddress>[];
      for (final a in answers) {
        if (a is! Map) continue;
        // type 1 = A, type 28 = AAAA. Ask for A above so type-1 is the
        // common path; defensively handle 28 in case of mixed answer.
        final type = a['type'];
        final data = a['data']?.toString();
        if (data == null || data.isEmpty) continue;
        if (type == 1 || type == 28) {
          final ip = InternetAddress.tryParse(data);
          if (ip != null) out.add(ip);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Persists a status transition for the deployment that still owns
  /// this host. Notifies listeners so the UI can react. No-op if the
  /// deployment was deleted/re-bound while the probe slept.
  Future<void> _markCustomHostStatus(
    String nodeId,
    String host,
    String status,
  ) async {
    final dep = _deployments[nodeId];
    if (dep == null || dep.customHost != host) return;
    if (dep.customHostStatus == status) return;
    _deployments[nodeId] = CdnDeployment(
      nodeId: dep.nodeId,
      scriptName: dep.scriptName,
      workerHost: dep.workerHost,
      backend: dep.backend,
      deployedAt: dep.deployedAt,
      customHost: dep.customHost,
      customDomainId: dep.customDomainId,
      customHostStatus: status,
      accountId: dep.accountId,
      deployedBy: dep.deployedBy,
      pathSecret: dep.pathSecret,
    );
    await _persistDeployments();
    notifyListeners();
  }

  /// SHA-256 → first [length] hex chars. Must match Go bridge/cdn/cdn.go
  /// `shortHash` byte-for-byte: cross-platform parity (same nodeID → same
  /// scriptName → same customHost) is the contract that makes Workers
  /// Custom Domains work across desktop and mobile.
  String _shortHash(String s, {int length = 6}) {
    final digest = crypto.sha256.convert(utf8.encode(s));
    final hex = digest.toString();
    return hex.substring(0, min(length, hex.length));
  }

  /// Cryptographically random hex string of length 2*[nBytes]. Used for the
  /// per-deployment PATH_SECRET that the Worker enforces on every request.
  /// `Random.secure()` is documented to draw from the platform's
  /// cryptographically-secure source (Android: SecureRandom). Mirrors
  /// `randomHex` in Go bridge/cdn/cdn.go for entropy budget parity.
  String _randomHex(int nBytes) {
    final r = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < nBytes; i++) {
      sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// DNS label rules tightened to lowercase [a-z0-9-], 1-56 chars
  /// (leaves room for the per-node "-<6hex>" suffix inside the 63-char
  /// total label budget), no leading/trailing hyphen. Mirrors the Go
  /// validateDNSLabel in bridge/cdn/cdn.go so both platforms reject
  /// the same inputs at save time.
  String? _validateDnsLabel(String label) {
    if (label.isEmpty) return 'Subdomain required.';
    if (label.length > 56) {
      return 'Subdomain too long (max 56 chars; needs room for the per-node hash suffix).';
    }
    if (label.startsWith('-') || label.endsWith('-')) {
      return "Subdomain cannot start or end with '-'.";
    }
    final ok = RegExp(r'^[a-z0-9-]+$');
    if (!ok.hasMatch(label)) {
      return "Subdomain must be lowercase a-z, 0-9, or '-'.";
    }
    return null;
  }

  String _escapeJsString(String s) =>
      s.replaceAll('\\', r'\\').replaceAll("'", r"\'");

  String? _extractCloudflareError(dynamic body) {
    if (body is Map) {
      final errors = body['errors'];
      if (errors is List && errors.isNotEmpty && errors.first is Map) {
        final e = errors.first as Map;
        final msg = e['message'];
        final code = e['code'];
        if (msg is String && msg.isNotEmpty) {
          return code != null ? '$msg (code $code)' : msg;
        }
      }
    }
    return null;
  }
}

/// Lifecycle of the CDN provider's view of the user's Cloudflare account.
///
///  - [disabled]              — no token configured (default for new installs)
///  - [unverified]            — token saved but never successfully verified
///                              (e.g. saved offline, network down, or token
///                              was revoked since last verify)
///  - [verifiedButIncomplete] — token validates and the account is reachable,
///                              but the prerequisite for actually deploying
///                              a Worker is missing: no workers.dev subdomain
///                              claimed AND no custom domain bound. Surfacing
///                              this distinctly stops the UI from showing a
///                              cheerful green "Verified" while every deploy
///                              attempt would silently fail.
///  - [verified]              — fully ready: token works, account known, and
///                              there is at least one destination (subdomain
///                              or custom domain) to publish Workers under.
enum CdnStatus { disabled, unverified, verifiedButIncomplete, verified }

/// One Cloudflare Worker deployment, scoped to a single cloud node.
class CdnDeployment {
  CdnDeployment({
    required this.nodeId,
    required this.scriptName,
    required this.workerHost,
    required this.backend,
    required this.deployedAt,
    this.customHost,
    this.customDomainId,
    this.customHostStatus,
    this.accountId,
    this.pathSecret,
    this.deployedBy,
  });

  /// The PrivateDeploy cloud node id this Worker fronts (e.g. Vultr instance
  /// id). One Worker per node — re-deploying same node updates in place.
  final String nodeId;

  /// CF Worker script name, e.g. "pd-relay-vultr-9f2c8a".
  final String scriptName;

  /// Full hostname under workers.dev, e.g.
  /// "pd-relay-vultr-9f2c8a.acme.workers.dev". Always set even if M1's
  /// custom-domain binding is also active — used as a fallback path.
  final String workerHost;

  /// "host:port" string we wrote into the Worker's BACKEND constant.
  final String backend;

  /// UTC timestamp of the most recent successful deploy.
  final DateTime deployedAt;

  /// M1: per-script Workers Custom Domain hostname (e.g.
  /// "relay-9f2c8a.example.com"). Empty when only the workers.dev path
  /// is bound.
  final String? customHost;

  /// M1: id returned by PUT /accounts/{aid}/workers/domains. Lets the
  /// detach call address the binding without re-resolving by hostname.
  final String? customDomainId;

  /// CF-side readiness of the bound hostname.
  ///   null / ""  → no custom host bound.
  ///   "pending"  → attached, awaiting cert + edge propagation.
  ///   "active"   → TLS handshake confirmed; safe to route traffic.
  ///   "failed"   → readiness probe gave up; client falls back to workers.dev.
  /// Subscription emission and share-link generation only treat customHost
  /// as routable when this is "active".
  final String? customHostStatus;

  /// CF account id this deployment was created against. Pinned here so
  /// detach/delete-script use the right account even after the user
  /// re-verifies with a different token. Old persisted records may have
  /// this empty — DeleteWorker falls back to the manager's current
  /// verified account in that case.
  final String? accountId;

  /// Per-deployment 32-hex random injected into the Worker as PATH_SECRET.
  /// The client appends ?k=<secret> to the VLESS-WS path; the Worker
  /// rejects every request that lacks the matching value with a bare 404.
  /// Without this, anyone who learns the Worker hostname could use it as
  /// a free TCP-out relay against the VPS relay port. Empty/null means
  /// "deployed before the path-secret gate landed" — the client emits the
  /// path without ?k= and the Worker template falls through to its old
  /// behaviour. Newly deployed Workers always have one.
  final String? pathSecret;

  /// Provenance of this deployment. "manual" when the user tapped Deploy
  /// from CDN settings; "auto" when Gate ① fired during a cellular
  /// connectivity failure recovery. Null on records that predate this field so the
  /// UI can render "已部署" without a provenance subtitle. Surfaced in
  /// the node row so users can tell apart deployments they explicitly
  /// created from ones the app provisioned in the background.
  final String? deployedBy;

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'scriptName': scriptName,
        'workerHost': workerHost,
        'backend': backend,
        'deployedAt': deployedAt.toIso8601String(),
        if (customHost != null && customHost!.isNotEmpty)
          'customHost': customHost,
        if (customDomainId != null && customDomainId!.isNotEmpty)
          'customDomainId': customDomainId,
        if (customHostStatus != null && customHostStatus!.isNotEmpty)
          'customHostStatus': customHostStatus,
        if (accountId != null && accountId!.isNotEmpty) 'accountId': accountId,
        if (pathSecret != null && pathSecret!.isNotEmpty)
          'pathSecret': pathSecret,
        if (deployedBy != null && deployedBy!.isNotEmpty)
          'deployedBy': deployedBy,
      };

  factory CdnDeployment.fromJson(Map json) => CdnDeployment(
        nodeId: json['nodeId']?.toString() ?? '',
        scriptName: json['scriptName']?.toString() ?? '',
        workerHost: json['workerHost']?.toString() ?? '',
        backend: json['backend']?.toString() ?? '',
        deployedAt: DateTime.tryParse(json['deployedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0).toUtc(),
        customHost: (json['customHost']?.toString().isEmpty ?? true)
            ? null
            : json['customHost'].toString(),
        customDomainId: (json['customDomainId']?.toString().isEmpty ?? true)
            ? null
            : json['customDomainId'].toString(),
        customHostStatus: (json['customHostStatus']?.toString().isEmpty ?? true)
            ? null
            : json['customHostStatus'].toString(),
        accountId: (json['accountId']?.toString().isEmpty ?? true)
            ? null
            : json['accountId'].toString(),
        pathSecret: (json['pathSecret']?.toString().isEmpty ?? true)
            ? null
            : json['pathSecret'].toString(),
        deployedBy: (json['deployedBy']?.toString().isEmpty ?? true)
            ? null
            : json['deployedBy'].toString(),
      );

  /// True only when CF has confirmed the customHost is reachable. Use
  /// this everywhere routing decisions are made — never raw `customHost`.
  bool get customHostReady =>
      (customHost?.isNotEmpty ?? false) && customHostStatus == 'active';
}

/// M1 binding config — global, applied to every future deploy. Per-node
/// uniqueness comes from a script-hash suffix in [_customHostFor].
class CdnCustomDomain {
  CdnCustomDomain({
    required this.zoneId,
    required this.zoneName,
    required this.subdomain,
  });

  final String zoneId;
  final String zoneName;
  final String subdomain;

  /// The host pattern shown in the UI: '<subdomain>-<node>.<zoneName>'.
  /// Per-deployment hostnames substitute the 6-hex script-name hash for
  /// '<node>'. Used only for preview text — deployment records carry the
  /// real customHost.
  String get hostPattern => '$subdomain-<node>.$zoneName';

  Map<String, dynamic> toJson() => {
        'zoneId': zoneId,
        'zoneName': zoneName,
        'subdomain': subdomain,
      };

  factory CdnCustomDomain.fromJson(Map json) => CdnCustomDomain(
        zoneId: json['zoneId']?.toString() ?? '',
        zoneName: json['zoneName']?.toString() ?? '',
        subdomain: json['subdomain']?.toString() ?? '',
      );
}

/// One CF zone visible to the verified token, surfaced to the picker.
class CdnZone {
  CdnZone({required this.id, required this.name});
  final String id;
  final String name;
}

class _WorkerCustomDomainBinding {
  _WorkerCustomDomainBinding({required this.id, required this.hostname});
  final String id;
  final String hostname;
}
