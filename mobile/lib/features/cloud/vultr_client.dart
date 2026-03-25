import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

class VultrCloudClient {
  static const String baseUrl = 'https://api.vultr.com/v2';
  static const Duration _connectTimeout = Duration(seconds: 30);
  static const Duration _receiveTimeout = Duration(seconds: 90);

  final Dio _dio;

  VultrCloudClient(String apiKey, {Dio? dio})
      : _dio = (dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: _connectTimeout,
                receiveTimeout: _receiveTimeout,
                headers: {'Content-Type': 'application/json'},
              ),
            )) {
    _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    _dio.interceptors.clear();
  }

  Future<Map<String, dynamic>> listRegions() async {
    return _requestJson('GET', '/regions');
  }

  Future<Map<String, dynamic>> listPlans() async {
    return _requestJson('GET', '/plans');
  }

  Future<Map<String, dynamic>> listInstances() async {
    return _requestJson('GET', '/instances');
  }

  Future<Map<String, dynamic>> deleteInstance(String instanceId) async {
    return _requestJson('DELETE', '/instances/$instanceId');
  }

  Future<Map<String, dynamic>> getOperatingSystems() async {
    return _requestJson('GET', '/os');
  }

  Future<Map<String, dynamic>> createInstance({
    required String region,
    required String plan,
    required String label,
    required int osId,
    required int ssPort,
    required String ssPassword,
    required String userData,
  }) async {
    final body = {
      'region': region,
      'plan': plan,
      'label': label,
      'enable_ipv6': true,
      'os_id': osId,
      'user_data': base64Encode(utf8.encode(userData)),
    };

    return _requestJson('POST', '/instances', data: body);
  }

  Future<Map<String, dynamic>> validateApiKey() {
    return listRegions();
  }

  Future<Map<String, dynamic>> getPlanById(String planId) async {
    final plans = await listPlans();
    final items = (plans['plans'] as List?) ?? const [];
    for (final item in items) {
      if (item is Map<String, dynamic> && item['id']?.toString() == planId) {
        return Map<String, dynamic>.from(item);
      }
    }
    throw StateError('Plan not found');
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    dynamic data,
  }) async {
    try {
      final response = await _dio.request<dynamic>(
        path,
        data: data,
        options: Options(method: method),
      );
      final normalized = response.data;
      if (response.statusCode != null &&
          response.statusCode! >= 400 &&
          response.statusCode! <= 599) {
        throw StateError(_extractVultrError(normalized) ??
            'Vultr API error (${response.statusCode})');
      }
      if (normalized == null) {
        return const {};
      }
      if (normalized is Map<String, dynamic>) {
        return normalized;
      }
      if (normalized is Map) {
        return Map<String, dynamic>.from(normalized);
      }
      return {'data': normalized};
    } on DioException catch (error) {
      final message = _extractDioErrorMessage(error);
      throw StateError(message);
    }
  }

  String _extractDioErrorMessage(DioException error) {
    final response = error.response?.data;
    if (response is Map<String, dynamic>) {
      final message = response['error']?['message'] ?? response['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }
    return error.message ?? 'Vultr API request failed';
  }

  String? _extractVultrError(dynamic response) {
    if (response is Map<String, dynamic>) {
      final error = response['error'];
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      final errors = response['errors'];
      if (errors is List && errors.isNotEmpty) {
        final first = errors.first;
        if (first is Map && first['message'] is String) {
          return first['message'] as String;
        }
      }
      final message = response['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }
    return null;
  }
}

class PortProfileAllocator {
  static const String randomProfile = 'random';

  static int randomPort() => 20000 + Random.secure().nextInt(30000);

  static int portProfileEdge443() => 24443;

  static int portProfileEdge8443() => 28443;

  static List<int> allocatePorts({String profile = randomProfile}) {
    switch (profile) {
      case 'edge443':
        return const [24443, 443, 8443, 443];
      case 'edge8443':
        return const [28443, 8443, 9443, 8443];
      default:
        final base = randomPort();
        return [base, base + 1, base + 2, base + 3];
    }
  }

  static String generatePassword(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(chars[random.nextInt(chars.length)]);
    }
    return buffer.toString();
  }

  static String lightweightScript({
    required int ssPort,
    required String ssPassword,
  }) {
    return '''
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077

apt-get update -qq
apt-get install -y docker.io ufw

systemctl enable docker
systemctl start docker

ufw --force disable || true
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow $ssPort/tcp comment 'Shadowsocks-TCP'
ufw allow $ssPort/udp comment 'Shadowsocks-UDP'
echo "y" | ufw enable

docker rm -f ss-server >/dev/null 2>&1 || true
docker pull --quiet teddysun/shadowsocks-libev || true
docker run -d --name ss-server --restart=always \
  -p $ssPort:$ssPort/tcp -p $ssPort:$ssPort/udp \
  teddysun/shadowsocks-libev ss-server \
  -s 0.0.0.0 -p $ssPort -k "$ssPassword" -m aes-256-gcm

echo "shadowsocks-deployed"
''';
  }
}
