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
  // Compatibility date the Worker is deployed with. Bumping this can change
  // runtime behavior, so it lives next to the worker template.
  static const _kCompatDate = '2024-09-23';

  static const _verifyEndpoint =
      'https://api.cloudflare.com/client/v4/user/tokens/verify';
  static const _accountsEndpoint =
      'https://api.cloudflare.com/client/v4/accounts';
  static const _zonesEndpoint =
      'https://api.cloudflare.com/client/v4/zones';

  CdnStatus _status = CdnStatus.disabled;
  String? _accountId;
  String? _accountEmail;
  String? _workersSubdomain;
  String? _lastError;
  bool _isVerifying = false;
  bool _isDeploying = false;
  Map<String, CdnDeployment> _deployments = {};
  CdnCustomDomain? _customDomain;
  List<CdnZone> _zones = const [];
  bool _zonesLoading = false;
  bool _isSavingCustomDomain = false;

  CdnStatus get status => _status;
  String? get accountId => _accountId;
  String? get accountEmail => _accountEmail;
  String? get workersSubdomain => _workersSubdomain;
  String? get lastError => _lastError;
  bool get isVerifying => _isVerifying;
  bool get isDeploying => _isDeploying;
  bool get isConfigured => _status != CdnStatus.disabled;
  Map<String, CdnDeployment> get deployments =>
      Map.unmodifiable(_deployments);
  CdnDeployment? deploymentFor(String nodeId) => _deployments[nodeId];
  CdnCustomDomain? get customDomain => _customDomain;
  List<CdnZone> get zones => List.unmodifiable(_zones);
  bool get isZonesLoading => _zonesLoading;
  bool get isSavingCustomDomain => _isSavingCustomDomain;

  /// Build the workers.dev URL fragment we display in the UI as
  /// "<your-name>.<subdomain>.workers.dev". Returns null if not yet known.
  String? get workersDevExample {
    final s = _workersSubdomain;
    if (s == null || s.isEmpty) return null;
    return 'pd-relay-<your-name>.$s.workers.dev';
  }

  Future<void> load() async {
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
    _status = (_accountId != null && _accountId!.isNotEmpty)
        ? CdnStatus.verified
        : CdnStatus.unverified;
    _loadDeployments();
    _loadCustomDomain();
    notifyListeners();
    // Resume readiness probes for any deployment still Pending from a
    // previous app launch. If propagation finished while we were closed,
    // the very first probe attempt will flip it Active. "failed" stays
    // failed until the user re-deploys.
    for (final entry in _deployments.entries) {
      final dep = entry.value;
      if ((dep.customHost?.isNotEmpty ?? false) &&
          dep.customHostStatus == 'pending') {
        unawaited(_probeCustomHostReadiness(entry.key, dep.customHost!));
      }
    }
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
      _deployments = decoded.map((k, v) =>
          MapEntry(k.toString(), CdnDeployment.fromJson(v as Map)));
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
        _status = priorStatus == CdnStatus.verified
            ? CdnStatus.unverified
            : CdnStatus.disabled;
        return false;
      }

      // 2. List accounts. Token-scoped tokens typically return one entry.
      final acc = await dio.get(_accountsEndpoint);
      final accounts =
          (acc.data is Map) ? (acc.data['result'] as List? ?? const []) : const [];
      if (accounts.isEmpty) {
        _lastError = 'Token has no accessible Cloudflare accounts.';
        _status = priorStatus == CdnStatus.verified
            ? CdnStatus.unverified
            : CdnStatus.disabled;
        return false;
      }
      final account = accounts.first as Map;
      final accountId = (account['id'] as String?) ?? '';
      if (accountId.isEmpty) {
        _lastError = 'Could not parse account id from Cloudflare response.';
        _status = priorStatus == CdnStatus.verified
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
      _status = CdnStatus.verified;
      _lastError = workersSub.isEmpty
          ? 'Token verified, but no workers.dev subdomain claimed yet — '
              'visit the Workers dashboard once to claim one.'
          : null;
      return true;
    } on DioException catch (e) {
      _lastError = 'Network error verifying token: ${e.message ?? e.type.name}';
      _status = priorStatus == CdnStatus.verified
          ? CdnStatus.unverified
          : CdnStatus.disabled;
      return false;
    } catch (e) {
      _lastError = 'Unexpected error: $e';
      _status = priorStatus == CdnStatus.verified
          ? CdnStatus.unverified
          : CdnStatus.disabled;
      return false;
    } finally {
      _isVerifying = false;
      notifyListeners();
    }
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
      final form = FormData();
      form.fields.add(MapEntry(
        'metadata',
        jsonEncode({
          'main_module': 'worker.mjs',
          'compatibility_date': _kCompatDate,
        }),
      ));
      form.files.add(MapEntry(
        'worker.mjs',
        MultipartFile.fromString(
          scriptBody,
          filename: 'worker.mjs',
          contentType: DioMediaType('application', 'javascript+module'),
        ),
      ));

      final put = await dio.put(
        '$_accountsEndpoint/$_accountId/workers/scripts/$scriptName',
        data: form,
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type':
              'multipart/form-data; boundary=${form.boundary}',
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
      );
      await _persistDeployments();
      if (customHost != null) {
        // Kick off readiness probe in the background. Status flips happen
        // via _markCustomHostStatus → notifyListeners so the UI reacts
        // when CF settles.
        unawaited(_probeCustomHostReadiness(nodeId, customHost));
      }
      // Preserve _lastError if the M1 step failed (so the UI can show it)
      // but clear it when everything succeeded.
      if (_customDomain != null && customHost == null && _lastError == null) {
        _lastError = 'workers.dev path live, but custom-domain binding produced no host.';
      } else if (customHost != null) {
        _lastError = null;
      }
      return true;
    } on DioException catch (e) {
      _lastError = 'Network error deploying Worker: ${e.message ?? e.type.name}';
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
    if (_status != CdnStatus.verified) {
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
    if (_status != CdnStatus.verified) {
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
      final r = await dio
          .get('$_accountsEndpoint/$aid/workers/domains?per_page=1');
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
    _lastError = null;
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
    final ok = r.statusCode != null &&
        (r.statusCode! < 400 || r.statusCode == 404);
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

  /// Polls the customHost until the WS upgrade succeeds end-to-end (CF
  /// cert + Worker dispatch + Worker→VPS TCP) or the budget is
  /// exhausted. Mirrors bridge/cdn/cdn_probe.go so desktop and mobile
  /// have the same readiness semantics. Total budget ~3.7 min.
  ///
  /// Two-stage: cheap TLS handshake first, then a WS upgrade with the
  /// deployment's path-secret. The WS upgrade is the only real proof
  /// that Worker→VPS connectivity is live (UFW open, port correct,
  /// VPS up). Earlier code only checked TLS, which would happily report
  /// "active" against a Worker pointing at a closed port.
  Future<void> _probeCustomHostReadiness(String nodeId, String host) async {
    const delays = [
      Duration(seconds: 3),
      Duration(seconds: 6),
      Duration(seconds: 12),
      Duration(seconds: 20),
      Duration(seconds: 30),
      Duration(seconds: 40),
      Duration(seconds: 50),
      Duration(seconds: 60),
    ];
    for (final d in delays) {
      await Future.delayed(d);
      final dep = _deployments[nodeId];
      if (dep == null || dep.customHost != host) {
        // Deployment was deleted or re-bound; abandon this probe.
        return;
      }
      if (!await _customHostTLSReachable(host)) {
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
      if (await _customHostRelayReachable(host, secret)) {
        await _markCustomHostStatus(nodeId, host, 'active');
        return;
      }
    }
    await _markCustomHostStatus(nodeId, host, 'failed');
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
  Future<bool> _customHostRelayReachable(String host, String pathSecret) async {
    if (host.isEmpty || pathSecret.isEmpty) return false;
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
      if (ips.isEmpty) return false;
      raw = await Socket.connect(
        ips.first,
        443,
        timeout: const Duration(seconds: 8),
      );
      secure = await SecureSocket.secure(raw, host: host)
          .timeout(const Duration(seconds: 8));
      // RFC 6455 Sec-WebSocket-Key: 16 random bytes, base64.
      final keyBytes = Uint8List(16);
      final rng = Random.secure();
      for (var i = 0; i < 16; i++) {
        keyBytes[i] = rng.nextInt(256);
      }
      final wsKey = base64Encode(keyBytes);
      final query =
          'ed=2560&k=${Uri.encodeQueryComponent(pathSecret)}';
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
      final line =
          await firstLine.future.timeout(const Duration(seconds: 12));
      // "HTTP/1.1 101 Switching Protocols" — match status code, ignore
      // case + minor status-text variation across reverse proxies.
      return RegExp(r'^HTTP/1\.[01]\s+101\b').hasMatch(line);
    } catch (_) {
      return false;
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
    'https://223.5.5.5/resolve',           // AliDNS (CN-friendly)
    'https://223.6.6.6/resolve',           // AliDNS secondary
    'https://1.1.1.1/dns-query',           // Cloudflare
    'https://1.0.0.1/dns-query',           // Cloudflare secondary
    'https://8.8.8.8/resolve',             // Google
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

enum CdnStatus { disabled, unverified, verified }

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

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'scriptName': scriptName,
        'workerHost': workerHost,
        'backend': backend,
        'deployedAt': deployedAt.toIso8601String(),
        if (customHost != null && customHost!.isNotEmpty) 'customHost': customHost,
        if (customDomainId != null && customDomainId!.isNotEmpty)
          'customDomainId': customDomainId,
        if (customHostStatus != null && customHostStatus!.isNotEmpty)
          'customHostStatus': customHostStatus,
        if (accountId != null && accountId!.isNotEmpty) 'accountId': accountId,
        if (pathSecret != null && pathSecret!.isNotEmpty)
          'pathSecret': pathSecret,
      };

  factory CdnDeployment.fromJson(Map json) => CdnDeployment(
        nodeId: json['nodeId']?.toString() ?? '',
        scriptName: json['scriptName']?.toString() ?? '',
        workerHost: json['workerHost']?.toString() ?? '',
        backend: json['backend']?.toString() ?? '',
        deployedAt:
            DateTime.tryParse(json['deployedAt']?.toString() ?? '') ??
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
