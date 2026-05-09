import 'dart:convert';
import 'dart:math';

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
    await StorageService.removeSecure(_kTokenKey);
    await StorageService.remove(_kAccountIdKey);
    await StorageService.remove(_kAccountEmailKey);
    await StorageService.remove(_kWorkersSubdomainKey);
    await StorageService.remove(_kDeploymentsKey);
    _accountId = null;
    _accountEmail = null;
    _workersSubdomain = null;
    _deployments = {};
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
    if ((_workersSubdomain ?? '').isEmpty) {
      _lastError =
          'No workers.dev subdomain claimed yet — visit the Cloudflare '
          'dashboard once to claim one, then retry.';
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

      // Load the worker template + render BACKEND.
      final template = await rootBundle.loadString('assets/cdn/worker.js');
      final backend = '$backendHost:$backendPort';
      final scriptBody = template.replaceAll(
        "'__BACKEND_PLACEHOLDER__'",
        "'${_escapeJsString(backend)}'",
      );
      if (scriptBody.contains('__BACKEND_PLACEHOLDER__')) {
        _lastError = 'Worker template missing BACKEND placeholder.';
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

      // Enable the workers.dev subdomain for the script.
      final sub = await dio.post(
        '$_accountsEndpoint/$_accountId/workers/scripts/$scriptName/subdomain',
        data: jsonEncode({'enabled': true}),
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        }),
      );
      if (sub.statusCode! >= 400) {
        // Upload succeeded but subdomain enable failed — still surface as
        // partial failure; the user can re-deploy later.
        _lastError = _extractCloudflareError(sub.data) ??
            'Worker uploaded but subdomain enable failed '
                '(HTTP ${sub.statusCode}).';
        return false;
      }

      final url = '$scriptName.$_workersSubdomain.workers.dev';
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
      );
      await _persistDeployments();
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
    if ((_accountId ?? '').isEmpty) {
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
      final detached = await _detachWorkerCustomDomain(dio, domainId);
      if (!detached) {
        // Capture the error before script-delete clears _lastError.
        detachWarning = _lastError ?? 'custom-domain detach failed';
      }
    }

    final r = await dio.delete(
      '$_accountsEndpoint/$_accountId/workers/scripts/${dep.scriptName}',
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
      final r = await dio.get('$_zonesEndpoint?per_page=50');
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
      final out = <CdnZone>[];
      for (final raw in body['result'] as List) {
        if (raw is! Map) continue;
        if (raw['status'] != 'active') continue;
        final id = raw['id']?.toString();
        final name = raw['name']?.toString();
        if (id == null || id.isEmpty || name == null || name.isEmpty) continue;
        out.add(CdnZone(id: id, name: name));
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
    if (cleanSub.isEmpty) {
      _lastError = 'Subdomain required (e.g. "relay").';
      notifyListeners();
      return false;
    }
    if (cleanSub.contains('.') || cleanSub.contains('/') || cleanSub.contains(' ')) {
      _lastError = 'Subdomain must be a single label (no ".", "/", or whitespace).';
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
      // Validate the zone is reachable with the current token. Reuses the
      // listZones result to avoid an extra round-trip if we just fetched.
      final available = _zones.isNotEmpty ? _zones : await listZones();
      CdnZone? matched;
      for (final z in available) {
        if (z.id == cleanZone) {
          matched = z;
          break;
        }
      }
      if (matched == null) {
        _lastError = 'Zone $cleanZone not visible to this token. '
            'Add Zone:Read for that zone or pick another.';
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
  Future<bool> _detachWorkerCustomDomain(Dio dio, String domainId) async {
    if (domainId.isEmpty) return true;
    final r = await dio.delete(
      '$_accountsEndpoint/$_accountId/workers/domains/$domainId',
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

  String _shortHash(String s, {int length = 6}) {
    var h = 5381;
    for (final cu in s.codeUnits) {
      h = ((h << 5) + h + cu) & 0x7fffffff;
    }
    final hex = h.toRadixString(16).padLeft(8, '0');
    return hex.substring(0, min(length, hex.length));
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

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'scriptName': scriptName,
        'workerHost': workerHost,
        'backend': backend,
        'deployedAt': deployedAt.toIso8601String(),
        if (customHost != null && customHost!.isNotEmpty) 'customHost': customHost,
        if (customDomainId != null && customDomainId!.isNotEmpty)
          'customDomainId': customDomainId,
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
      );
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
