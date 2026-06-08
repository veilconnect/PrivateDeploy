import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/digitalocean_client.dart';

void main() {
  group('DigitalOceanCloudClient', () {
    test('surfaces DO error message on 4xx responses', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(
            {'id': 'unauthorized', 'message': 'Unable to authenticate you.'}));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = DigitalOceanCloudClient('test-key', dio: dio);

      expect(
        () => client.validateApiKey(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Unable to authenticate you.',
          ),
        ),
      );
    });

    test('listRegions filters unavailable and maps slug→id with city/country',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'regions': [
            {'slug': 'nyc3', 'name': 'New York 3', 'available': true},
            {'slug': 'ams3', 'name': 'Amsterdam 3', 'available': false},
            {'slug': 'blr1', 'name': 'Bangalore 1', 'available': true},
          ],
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = DigitalOceanCloudClient('test-key', dio: dio);

      final response = await client.listRegions();
      final regions = (response['regions'] as List).cast<Map>();

      // ams3 was unavailable and must be filtered out.
      expect(regions.map((r) => r['id']), ['nyc3', 'blr1']);
      expect(regions.first['city'], 'New York');
      expect(regions.first['country'], 'US');
      expect(regions.last['city'], 'Bangalore');
      expect(regions.last['country'], 'IN');
    });

    test('listPlans re-shapes DO sizes into Vultr-compatible plan keys',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'sizes': [
            {
              'slug': 's-1vcpu-512mb-10gb',
              'memory': 512,
              'vcpus': 1,
              'disk': 10,
              'transfer': 0.5,
              'price_monthly': 4,
              'price_hourly': 0.00595,
              'available': true,
              'regions': ['nyc3', 'sfo3'],
              'description': 'Basic',
            },
            {
              'slug': 's-1vcpu-1gb',
              'memory': 1024,
              'vcpus': 1,
              'disk': 25,
              'transfer': 1,
              'price_monthly': 6,
              'price_hourly': 0.00893,
              'available': false,
              'regions': ['nyc3'],
              'description': 'Basic',
            },
          ],
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = DigitalOceanCloudClient('test-key', dio: dio);

      final response = await client.listPlans();
      final plans = (response['plans'] as List).cast<Map>();

      // The unavailable size is filtered out.
      expect(plans, hasLength(1));
      final plan = plans.first;
      expect(plan['id'], 's-1vcpu-512mb-10gb');
      expect(plan['ram'], 512);
      expect(plan['vcpu_count'], 1);
      expect(plan['disk'], 10);
      expect(plan['monthly_cost'], 4);
      expect(plan['locations'], ['nyc3', 'sfo3']);
    });

    test('listInstances normalizes droplets to Vultr-instance shape', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'droplets': [
            {
              'id': 12345,
              'name': 'pd-node-1',
              'status': 'active',
              'created_at': '2026-04-14T09:00:00Z',
              'region': {'slug': 'sfo3'},
              'size': {'slug': 's-1vcpu-512mb-10gb'},
              'networks': {
                'v4': [
                  {'type': 'private', 'ip_address': '10.0.0.1'},
                  {'type': 'public', 'ip_address': '203.0.113.10'},
                ],
                'v6': [
                  {'type': 'public', 'ip_address': '2001:db8::1'},
                ],
              },
            },
          ],
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = DigitalOceanCloudClient('test-key', dio: dio);

      final response = await client.listInstances();
      final instances = (response['instances'] as List).cast<Map>();
      expect(instances, hasLength(1));
      final inst = instances.first;
      expect(inst['id'], 'cloud-do-12345');
      expect(inst['label'], 'pd-node-1');
      expect(inst['main_ip'], '203.0.113.10');
      expect(inst['v6_main_ip'], '2001:db8::1');
      expect(inst['region'], 'sfo3');
      expect(inst['plan'], 's-1vcpu-512mb-10gb');
    });

    test('deleteInstance strips cloud-do- prefix from id before URL', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      String? receivedPath;
      server.listen((request) async {
        receivedPath = request.uri.path;
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = DigitalOceanCloudClient('test-key', dio: dio);

      await client.deleteInstance('cloud-do-99999');

      expect(receivedPath, '/droplets/99999');
    });

    test('createInstance sends DO-shaped body and returns normalized instance',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      Map<String, dynamic>? receivedBody;
      server.listen((request) async {
        final raw = await utf8.decoder.bind(request).join();
        receivedBody = jsonDecode(raw) as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'droplet': {
            'id': 777,
            'name': receivedBody!['name'],
            'status': 'new',
            'created_at': '2026-04-14T10:00:00Z',
            'region': {'slug': receivedBody!['region']},
            'size': {'slug': receivedBody!['size']},
          },
        }));
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      final client = DigitalOceanCloudClient('test-key', dio: dio);

      final result = await client.createInstance(
        region: 'sfo3',
        plan: 's-1vcpu-512mb-10gb',
        label: 'pd-auto',
        osId: 0,
        userData: '#!/bin/bash\necho hi',
      );

      expect(receivedBody!['name'], 'pd-auto');
      expect(receivedBody!['region'], 'sfo3');
      expect(receivedBody!['size'], 's-1vcpu-512mb-10gb');
      expect(receivedBody!['image'], 'debian-12-x64');
      expect(receivedBody!['user_data'], '#!/bin/bash\necho hi');
      expect(receivedBody!['ipv6'], true);
      expect(receivedBody!['tags'], contains('privatedeploy'));

      final inst = result['instance'] as Map;
      expect(inst['id'], 'cloud-do-777');
      expect(inst['label'], 'pd-auto');
    });

    test('getInstanceUserData returns null (DO does not expose user-data)',
        () async {
      final client = DigitalOceanCloudClient('test-key',
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')));
      final data = await client.getInstanceUserData('cloud-do-1');
      expect(data, isNull);
    });
  });
}
