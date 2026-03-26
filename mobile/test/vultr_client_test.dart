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
  });
}
