import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../shared/utils/logger.dart';

class NativeHttpResponse {
  const NativeHttpResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

class NativeHttpService {
  static const MethodChannel _channel =
      MethodChannel('com.privatedeploy.vpn/native');

  static Future<NativeHttpResponse?> request({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    required Duration connectTimeout,
    required Duration readTimeout,
  }) async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      print('[NativeHttpService] invoking $method $url');
      final response = await _channel.invokeMethod<Map>('httpJsonRequest', {
        'method': method,
        'url': url,
        'headers': headers ?? const <String, String>{},
        'body': body,
        'connectTimeoutMs': connectTimeout.inMilliseconds,
        'readTimeoutMs': readTimeout.inMilliseconds,
      });
      if (response == null) {
        print('[NativeHttpService] null response for $method $url');
        return null;
      }

      final data = Map<String, dynamic>.from(response);
      print(
        '[NativeHttpService] success $method $url -> ${(data['statusCode'] as num?)?.toInt() ?? 0}',
      );
      return NativeHttpResponse(
        statusCode: (data['statusCode'] as num?)?.toInt() ?? 0,
        body: data['body']?.toString() ?? '',
      );
    } on PlatformException catch (e) {
      print(
        '[NativeHttpService] platform failure for $method $url: ${e.code} ${e.message}',
      );
      AppLogger.warning(
        '[NativeHttpService] Native HTTP request failed: ${e.code} ${e.message}',
      );
      return null;
    } catch (e) {
      print('[NativeHttpService] failure for $method $url: $e');
      AppLogger.warning('[NativeHttpService] Native HTTP request failed: $e');
      return null;
    }
  }
}
