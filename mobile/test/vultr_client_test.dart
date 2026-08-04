import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_client.dart';

void main() {
  group('VultrCloudClient', () {
    test('surfaces string error responses without crashing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'invalid api key'}));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = VultrCloudClient('test-key', dio: dio);

      expect(
        () => client.validateApiKey(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'invalid api key',
          ),
        ),
      );
    });

    // Regression test: a Vultr instance that was already deleted out-of-band
    // (console, expired trial, etc.) makes the real DELETE call 404. That
    // still satisfies "this instance should no longer exist", so
    // deleteInstance must succeed instead of leaving the local record
    // permanently stuck (un-deletable through the normal UI flow). Mirrors
    // the same fix + test on the desktop side
    // (bridge/cloud/providers/vultr/destroy_instance_test.go).
    test('deleteInstance treats 404 as already gone', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Instance not found'}));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = VultrCloudClient('test-key', dio: dio);

      await expectLater(client.deleteInstance('inst-gone'), completes);
    });

    test('deleteInstance still surfaces a real API failure', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'boom'}));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = VultrCloudClient('test-key', dio: dio);

      expect(
        () => client.deleteInstance('inst-gone'),
        throwsA(isA<StateError>()),
      );
    });

    test('loads plans from Vultr json payload', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'plans': [
            {
              'id': 'vc2-1c-1gb',
              'ram': 1024,
              'vcpu_count': 1,
              'disk': 25,
              'monthly_cost': 5,
              'locations': ['fra', 'nrt'],
            },
          ],
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = VultrCloudClient('test-key', dio: dio);
      final response = await client.listPlans();

      expect(response['plans'], isA<List>());
      final plans = response['plans'] as List;
      expect(plans, hasLength(1));
      expect((plans.first as Map)['id'], 'vc2-1c-1gb');
    });

    test('decodes nested instance user-data payload', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'user_data': {
            'data': base64Encode(utf8.encode('#!/bin/bash\necho nested')),
          },
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = VultrCloudClient('test-key', dio: dio);

      final userData = await client.getInstanceUserData('instance-1');

      expect(userData, '#!/bin/bash\necho nested');
    });

    test('decodes string instance user-data payload', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'user_data': base64Encode(utf8.encode('#!/bin/bash\necho string')),
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = VultrCloudClient('test-key', dio: dio);

      final userData = await client.getInstanceUserData('instance-2');

      expect(userData, '#!/bin/bash\necho string');
    });
  });
}
