import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../storage/storage_service.dart';

class ApiClient {
  final Dio _dio;

  ApiClient(this._dio, {String? baseUrl}) {
    _dio.options.baseUrl = baseUrl ??
        (_dio.options.baseUrl.isNotEmpty
            ? _dio.options.baseUrl
            : StorageService.getApiBaseUrl());
    _dio.options.connectTimeout ??= ApiConstants.connectTimeout;
    _dio.options.receiveTimeout ??= ApiConstants.receiveTimeout;
    _dio.options.headers['Content-Type'] = 'application/json';
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    Duration? receiveTimeout,
  }) async {
    try {
      final response = await _dio.request<dynamic>(
        path,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          receiveTimeout: receiveTimeout,
        ),
      );
      return _normalizeResponse(response.data);
    } on DioException catch (e) {
      return _errorResponse(_messageFromDio(e), e.response?.data);
    } catch (e) {
      return _errorResponse(e.toString(), null);
    }
  }

  Map<String, dynamic> _normalizeResponse(dynamic raw) {
    if (raw == null) {
      return {'success': true, 'data': null};
    }

    if (raw is Map<String, dynamic>) {
      final out = Map<String, dynamic>.from(raw);
      if (out['success'] is bool) {
        if (out['success'] != true) {
          final msg = _extractErrorMessage(out) ?? 'Request failed';
          out['message'] = msg;
        }
        return out;
      }
      return {'success': true, 'data': out};
    }

    return {'success': true, 'data': raw};
  }

  Map<String, dynamic> _errorResponse(String message, dynamic details) {
    return {
      'success': false,
      'message': message,
      'error': {
        'message': message,
        if (details != null) 'details': details,
      },
    };
  }

  String? _extractErrorMessage(Map<String, dynamic> response) {
    final msg = response['message'];
    if (msg is String && msg.isNotEmpty) {
      return msg;
    }
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      final errMsg = error['message'];
      if (errMsg is String && errMsg.isNotEmpty) {
        return errMsg;
      }
    }
    return null;
  }

  String _messageFromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        final msg = error['message'];
        if (msg is String && msg.isNotEmpty) {
          return msg;
        }
      }
      final msg = data['message'];
      if (msg is String && msg.isNotEmpty) {
        return msg;
      }
    }
    return e.message ?? 'Network error';
  }

  Future<Map<String, dynamic>> _get(String path,
      {Map<String, dynamic>? query}) {
    return _request('GET', path, query: query);
  }

  Future<Map<String, dynamic>> _post(String path, {dynamic data}) {
    return _request('POST', path, data: data);
  }

  Future<Map<String, dynamic>> _put(String path, {dynamic data}) {
    return _request('PUT', path, data: data);
  }

  Future<Map<String, dynamic>> _delete(String path) {
    return _request('DELETE', path);
  }

  // Cloud
  Future<Map<String, dynamic>> getProviders() => _get('/cloud/providers');
  Future<Map<String, dynamic>> getActiveProvider() =>
      _get('/cloud/provider/active');
  Future<Map<String, dynamic>> setActiveProvider(String provider) =>
      _post('/cloud/provider/active', data: {'provider': provider});
  Future<Map<String, dynamic>> getCloudConfig() => _get('/cloud/config');
  Future<Map<String, dynamic>> saveCloudConfig(Map<String, dynamic> config) =>
      _post('/cloud/config', data: config);
  Future<Map<String, dynamic>> getInstances() => _get('/cloud/instances');
  Future<Map<String, dynamic>> createInstance(Map<String, dynamic> options) =>
      _request(
        'POST',
        '/cloud/instances',
        data: options,
        receiveTimeout: ApiConstants.cloudCreateTimeout,
      );
  Future<Map<String, dynamic>> deleteInstance(String id) =>
      _delete('/cloud/instances/$id');
  Future<Map<String, dynamic>> getRegions() => _get('/cloud/regions');
  Future<Map<String, dynamic>> getPlans({String? region}) =>
      _get('/cloud/plans', query: region == null ? null : {'region': region});

  // Profiles
  Future<Map<String, dynamic>> getProfiles() => _get('/profiles');
  Future<Map<String, dynamic>> getActiveProfile() => _get('/profiles/active');
  Future<Map<String, dynamic>> createProfile(Map<String, dynamic> profile) =>
      _post('/profiles', data: profile);
  Future<Map<String, dynamic>> updateProfile(
          dynamic id, Map<String, dynamic> profile) =>
      _put('/profiles/$id', data: profile);
  Future<Map<String, dynamic>> deleteProfile(dynamic id) =>
      _delete('/profiles/$id');
  Future<Map<String, dynamic>> setActiveProfile(dynamic id) =>
      _put('/profiles/$id/active', data: {});
  Future<Map<String, dynamic>> updateSubscription(dynamic id) =>
      _put('/profiles/$id/subscription', data: {});
  Future<Map<String, dynamic>> getProfileContent(dynamic id) =>
      _get('/profiles/$id/content');
  Future<Map<String, dynamic>> saveProfileContent(
          dynamic id, Map<String, dynamic> body) =>
      _put('/profiles/$id/content', data: body);

  // Subscriptions
  Future<Map<String, dynamic>> getSubscriptions() => _get('/subscriptions');
  Future<Map<String, dynamic>> createSubscription(
          Map<String, dynamic> subscription) =>
      _post('/subscriptions', data: subscription);
  Future<Map<String, dynamic>> refreshSubscription(dynamic id) =>
      _put('/subscriptions/$id/refresh', data: {});

  // System / VPN
  Future<Map<String, dynamic>> getSystemInfo() => _get('/system/info');
  Future<Map<String, dynamic>> getVpnStatus() => _get('/vpn/status');
  Future<Map<String, dynamic>> startVpn({String profileId = 'default'}) =>
      _post('/vpn/start', data: {'profileId': profileId});
  Future<Map<String, dynamic>> stopVpn() => _post('/vpn/stop', data: {});
  Future<Map<String, dynamic>> restartVpn() => _post('/vpn/restart', data: {});
  Future<Map<String, dynamic>> getTrafficStats() => _get('/vpn/stats');
  Future<Map<String, dynamic>> resetTrafficStats() =>
      _post('/vpn/stats/reset', data: {});
}

class DioClient {
  static Dio createDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: StorageService.getApiBaseUrl(),
        connectTimeout: ApiConstants.connectTimeout,
        receiveTimeout: ApiConstants.receiveTimeout,
        headers: {
          'Content-Type': 'application/json',
        },
      ),
    );

    return dio;
  }
}
