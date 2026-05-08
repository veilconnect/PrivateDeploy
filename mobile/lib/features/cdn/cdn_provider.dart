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
  // Compatibility date the Worker is deployed with. Bumping this can change
  // runtime behavior, so it lives next to the worker template.
  static const _kCompatDate = '2024-09-23';

  static const _verifyEndpoint =
      'https://api.cloudflare.com/client/v4/user/tokens/verify';
  static const _accountsEndpoint =
      'https://api.cloudflare.com/client/v4/accounts';

  CdnStatus _status = CdnStatus.disabled;
  String? _accountId;
  String? _accountEmail;
  String? _workersSubdomain;
  String? _lastError;
  bool _isVerifying = false;
  bool _isDeploying = false;
  Map<String, CdnDeployment> _deployments = {};

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
    notifyListeners();
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
      _deployments[nodeId] = CdnDeployment(
        nodeId: nodeId,
        scriptName: scriptName,
        workerHost: url,
        backend: backend,
        deployedAt: DateTime.now().toUtc(),
      );
      await _persistDeployments();
      _lastError = null;
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
    _lastError = null;
    notifyListeners();
    return true;
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
  });

  /// The PrivateDeploy cloud node id this Worker fronts (e.g. Vultr instance
  /// id). One Worker per node — re-deploying same node updates in place.
  final String nodeId;

  /// CF Worker script name, e.g. "pd-relay-vultr-9f2c8a".
  final String scriptName;

  /// Full hostname under workers.dev, e.g.
  /// "pd-relay-vultr-9f2c8a.acme.workers.dev".
  final String workerHost;

  /// "host:port" string we wrote into the Worker's BACKEND constant.
  final String backend;

  /// UTC timestamp of the most recent successful deploy.
  final DateTime deployedAt;

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'scriptName': scriptName,
        'workerHost': workerHost,
        'backend': backend,
        'deployedAt': deployedAt.toIso8601String(),
      };

  factory CdnDeployment.fromJson(Map json) => CdnDeployment(
        nodeId: json['nodeId']?.toString() ?? '',
        scriptName: json['scriptName']?.toString() ?? '',
        workerHost: json['workerHost']?.toString() ?? '',
        backend: json['backend']?.toString() ?? '',
        deployedAt:
            DateTime.tryParse(json['deployedAt']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0).toUtc(),
      );
}
