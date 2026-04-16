import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../services/native_http_service.dart';
import 'cloud_api_client.dart';

class VultrCloudClient implements CloudApiClient {
  static const String baseUrl = 'https://api.vultr.com/v2';
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 90);
  static const Duration _validationTimeout = Duration(seconds: 12);
  static const Duration _dnsTimeout = Duration(seconds: 5);
  static const String _userAgent = 'PrivateDeploy-Mobile/1.0 (dart)';

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

  Future<String?> getInstanceUserData(String instanceId) async {
    final response =
        await _requestJson('GET', '/instances/$instanceId/user-data');
    final rawUserData = response['user_data'];
    if (rawUserData is String && rawUserData.isNotEmpty) {
      return utf8.decode(base64Decode(rawUserData));
    }
    if (rawUserData is Map) {
      final encoded = rawUserData['data']?.toString();
      if (encoded == null || encoded.isEmpty) {
        return null;
      }
      return utf8.decode(base64Decode(encoded));
    }
    return null;
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
    return _requestJson('GET', '/account', timeout: _validationTimeout);
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
    Duration? timeout,
  }) async {
    final previousConnectTimeout = _dio.options.connectTimeout;
    if (timeout != null) {
      _dio.options.connectTimeout = timeout;
    }

    try {
      final response = await _dio.request<dynamic>(
        path,
        data: data,
        options: Options(
          method: method,
          receiveTimeout: timeout ?? _receiveTimeout,
          sendTimeout: timeout ?? _receiveTimeout,
        ),
      );
      return _normalizeResponseBody(response.statusCode, response.data);
    } on DioException catch (error) {
      if (_shouldRetryViaIpv4(error)) {
        print(
          '[VultrCloudClient] retrying $method $path after Dio ${error.type}: ${error.message}',
        );
        try {
          final nativeResponse = await _requestJsonViaNativeStack(
            method,
            path,
            data: data,
            timeout: timeout,
          );
          if (nativeResponse != null) {
            print(
                '[VultrCloudClient] native fallback succeeded for $method $path');
            return nativeResponse;
          }
          print(
              '[VultrCloudClient] native fallback returned null for $method $path');
        } on StateError {
          rethrow;
        } catch (nativeError) {
          print(
            '[VultrCloudClient] native fallback failed for $method $path: $nativeError',
          );
          // Continue to the lower-level socket fallback when the native stack
          // path is unavailable or fails unexpectedly.
        }

        try {
          print(
              '[VultrCloudClient] trying raw IPv4 fallback for $method $path');
          return await _requestJsonViaIpv4(
            method,
            path,
            data: data,
            timeout: timeout,
          );
        } on StateError {
          rethrow;
        } catch (_) {
          // Fall through to the original Dio-derived message below when the
          // fallback path also fails for a non-StateError reason.
        }
      }
      final message = _extractDioErrorMessage(error);
      throw StateError(message);
    } finally {
      if (timeout != null) {
        _dio.options.connectTimeout = previousConnectTimeout;
      }
    }
  }

  Future<Map<String, dynamic>?> _requestJsonViaNativeStack(
    String method,
    String path, {
    dynamic data,
    Duration? timeout,
  }) async {
    final resolvedUri = _resolveRequestUri(path);
    final requestTimeout = timeout ?? _receiveTimeout;
    final connectTimeout = timeout ?? _connectTimeout;
    final authorization =
        _dio.options.headers['Authorization']?.toString() ?? '';
    final response = await NativeHttpService.request(
      method: method,
      url: resolvedUri.toString(),
      headers: <String, String>{
        'Authorization': authorization,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      },
      body: data == null ? null : jsonEncode(data),
      connectTimeout: connectTimeout,
      readTimeout: requestTimeout,
    );
    if (response == null) {
      return null;
    }

    dynamic decoded;
    if (response.body.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = response.body;
      }
    }
    return _normalizeResponseBody(response.statusCode, decoded);
  }

  bool _shouldRetryViaIpv4(DioException error) {
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError;
  }

  Future<Map<String, dynamic>> _requestJsonViaIpv4(
    String method,
    String path, {
    dynamic data,
    Duration? timeout,
  }) async {
    final resolvedUri = _resolveRequestUri(path);
    final baseUri = resolvedUri;

    if (baseUri.host == '127.0.0.1' ||
        baseUri.host == 'localhost' ||
        InternetAddress.tryParse(baseUri.host) != null) {
      throw StateError('Vultr API request failed');
    }

    final requestTimeout = timeout ?? _receiveTimeout;
    final connectTimeout = timeout ?? _connectTimeout;
    final body = data == null ? '' : jsonEncode(data);

    try {
      final ipv4s = await InternetAddress.lookup(
        baseUri.host,
        type: InternetAddressType.IPv4,
      ).timeout(_dnsTimeout);
      if (ipv4s.isEmpty) {
        throw StateError('Vultr API unreachable: no IPv4 for ${baseUri.host}');
      }

      final rawSocket = await Socket.connect(
        ipv4s.first.address,
        baseUri.hasPort ? baseUri.port : 443,
        timeout: connectTimeout,
      );
      final socket = await SecureSocket.secure(
        rawSocket,
        host: baseUri.host,
        supportedProtocols: const ['http/1.1'],
      ).timeout(connectTimeout);

      try {
        final requestPath = resolvedUri.path.isEmpty ? '/' : resolvedUri.path;
        final fullPath = resolvedUri.hasQuery
            ? '$requestPath?${resolvedUri.query}'
            : requestPath;
        final contentLength = utf8.encode(body).length;
        final authorization =
            _dio.options.headers['Authorization']?.toString() ?? '';
        socket.write(
          '$method $fullPath HTTP/1.1\r\n'
          'Host: ${baseUri.host}\r\n'
          'Authorization: $authorization\r\n'
          'User-Agent: $_userAgent\r\n'
          'Accept: application/json\r\n'
          'Accept-Encoding: identity\r\n'
          'Content-Type: application/json\r\n'
          'Connection: close\r\n'
          'Content-Length: $contentLength\r\n\r\n'
          '$body',
        );
        await socket.flush();
        final raw = await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join()
            .timeout(requestTimeout);
        return _parseHttp11Response(raw);
      } finally {
        await socket.close();
      }
    } on TimeoutException {
      throw StateError(
        'Vultr API request timed out after ${connectTimeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      throw StateError('Vultr API unreachable: ${e.message}');
    } on HandshakeException catch (e) {
      throw StateError('Vultr TLS handshake failed: ${e.message}');
    }
  }

  Uri _resolveRequestUri(String path) {
    final effectiveBase =
        _dio.options.baseUrl.isNotEmpty ? _dio.options.baseUrl : baseUrl;
    final baseUri = Uri.parse(effectiveBase);
    final trimmedBasePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final trimmedRequestPath = path.startsWith('/') ? path.substring(1) : path;
    final joinedPath = [trimmedBasePath, trimmedRequestPath]
        .where((segment) => segment.isNotEmpty)
        .join('/');
    final normalizedPath =
        joinedPath.startsWith('/') ? joinedPath : '/$joinedPath';
    return baseUri.replace(path: normalizedPath);
  }

  Map<String, dynamic> _parseHttp11Response(String raw) {
    final headerEnd = raw.indexOf('\r\n\r\n');
    if (headerEnd < 0) {
      throw StateError('Vultr API returned malformed response');
    }

    final headerBlock = raw.substring(0, headerEnd);
    var body = raw.substring(headerEnd + 4);
    final statusLine = headerBlock.split('\r\n').first;
    final parts = statusLine.split(' ');
    final statusCode = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    if (headerBlock.toLowerCase().contains('transfer-encoding: chunked')) {
      final buffer = StringBuffer();
      var cursor = 0;
      while (cursor < body.length) {
        final lineEnd = body.indexOf('\r\n', cursor);
        if (lineEnd < 0) break;
        final size =
            int.tryParse(body.substring(cursor, lineEnd).trim(), radix: 16) ??
                0;
        if (size == 0) break;
        final chunkStart = lineEnd + 2;
        final chunkEnd = chunkStart + size;
        if (chunkEnd > body.length) break;
        buffer.write(body.substring(chunkStart, chunkEnd));
        cursor = chunkEnd + 2;
      }
      body = buffer.toString();
    }

    dynamic decoded;
    if (body.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        decoded = body;
      }
    }

    return _normalizeResponseBody(statusCode, decoded);
  }

  Map<String, dynamic> _normalizeResponseBody(int? statusCode, dynamic body) {
    if (statusCode != null && statusCode >= 400 && statusCode <= 599) {
      throw StateError(
        _extractVultrError(body) ?? 'Vultr API error ($statusCode)',
      );
    }
    if (body == null) {
      return const {};
    }
    if (body is Map<String, dynamic>) {
      return body;
    }
    if (body is Map) {
      return Map<String, dynamic>.from(body);
    }
    return {'data': body};
  }

  String _extractDioErrorMessage(DioException error) {
    final response = error.response?.data;
    if (response is Map<String, dynamic>) {
      final rawError = response['error'];
      if (rawError is String && rawError.isNotEmpty) {
        return rawError;
      }
      final message =
          (rawError is Map ? rawError['message'] : null) ?? response['message'];
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
