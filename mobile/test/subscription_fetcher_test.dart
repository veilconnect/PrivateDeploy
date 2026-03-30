import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/subscription/subscription_fetcher.dart';

void main() {
  group('fetchSubscriptionResponseData', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('returns raw bytes for plain text subscriptions', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          'ss://YWVzLTI1Ni1nY206cGFzczEyMw==@example.com:443#SmokeSub',
        );
        await request.response.close();
      });

      final data = await fetchSubscriptionResponseData(
        'http://${server.address.host}:${server.port}/sub.txt',
      );

      expect(
        utf8.decode(data),
        'ss://YWVzLTI1Ni1nY206cGFzczEyMw==@example.com:443#SmokeSub',
      );
    });

    test('follows redirects before reading the response body', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.movedTemporarily;
          request.response.headers.set(HttpHeaders.locationHeader, '/sub.txt');
          await request.response.close();
          return;
        }

        request.response.headers.contentType = ContentType.binary;
        request.response.add(utf8.encode('vmess://example-node'));
        await request.response.close();
      });

      final data = await fetchSubscriptionResponseData(
        'http://${server.address.host}:${server.port}/redirect',
      );

      expect(utf8.decode(data), 'vmess://example-node');
    });

    test('throws sanitized errors for non-success responses', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write('forbidden');
        await request.response.close();
      });

      expect(
        () => fetchSubscriptionResponseData(
          'http://${server.address.host}:${server.port}/blocked',
        ),
        throwsA(
          isA<SubscriptionFetchException>().having(
            (error) => error.message,
            'message',
            'Subscription request failed with HTTP 403',
          ),
        ),
      );
    });
  });
}
