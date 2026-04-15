import 'package:dio/dio.dart';

import 'cloud_api_client.dart';

/// Thin REST wrapper around the DigitalOcean v2 API, matching the shape
/// of [VultrCloudClient] so callers don't need to branch on provider.
///
/// DO returns its payloads in slightly different envelopes than Vultr
/// (e.g. `sizes` not `plans`, `droplets` not `instances`). Normalization
/// into Vultr-shaped keys happens at this layer so the rest of the app
/// (region pickers, plan pickers, node list) stays provider-agnostic.
class DigitalOceanCloudClient implements CloudApiClient {
  static const String baseUrl = 'https://api.digitalocean.com/v2';
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 90);
  static const Duration _validationTimeout = Duration(seconds: 12);

  final Dio _dio;

  DigitalOceanCloudClient(String apiKey, {Dio? dio})
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

  /// Returns regions in a payload shaped like Vultr's response so callers
  /// can treat the result uniformly. DO returns `{regions: [{slug, name, ...}]}`;
  /// Vultr returns `{regions: [{id, city, country, ...}]}`. We map slug→id
  /// and derive city/country from the display name.
  Future<Map<String, dynamic>> listRegions() async {
    final raw = await _requestJson('GET', '/regions');
    final items = (raw['regions'] as List?) ?? const [];
    final regions = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item is! Map) continue;
      final available = item['available'];
      if (available == false) continue;
      final slug = item['slug']?.toString() ?? '';
      if (slug.isEmpty) continue;
      final name = item['name']?.toString() ?? slug;
      final parts = _parseRegionName(name);
      regions.add({
        'id': slug,
        'city': parts.$1,
        'country': parts.$2,
      });
    }
    return {'regions': regions};
  }

  /// DO's /sizes endpoint. Shaped to match Vultr's /plans output so the
  /// existing plan-picker UI keeps working. The slug becomes id;
  /// vcpus/memory/disk/transfer/monthly/hourly are forwarded directly,
  /// and `locations` holds the list of region slugs where the size runs.
  Future<Map<String, dynamic>> listPlans() async {
    final raw = await _requestJson('GET', '/sizes');
    final items = (raw['sizes'] as List?) ?? const [];
    final plans = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item is! Map) continue;
      if (item['available'] == false) continue;
      final slug = item['slug']?.toString() ?? '';
      if (slug.isEmpty) continue;
      plans.add({
        'id': slug,
        'vcpu_count': item['vcpus'] ?? 0,
        'ram': item['memory'] ?? 0,
        'disk': item['disk'] ?? 0,
        'bandwidth': item['transfer'] ?? 0,
        'monthly_cost': item['price_monthly'] ?? 0,
        'hourly_cost': item['price_hourly'] ?? 0,
        'type': 'standard',
        'locations': (item['regions'] as List?)
                ?.map((r) => r.toString())
                .toList() ??
            const [],
        'description': item['description']?.toString() ?? '',
      });
    }
    return {'plans': plans};
  }

  /// DO's /droplets returns `{droplets: [...]}`. We translate each droplet
  /// into the Vultr-instance shape (id/main_ip/v6_main_ip/region/plan/status).
  Future<Map<String, dynamic>> listInstances() async {
    final raw = await _requestJson('GET', '/droplets');
    final items = (raw['droplets'] as List?) ?? const [];
    final instances = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item is! Map) continue;
      instances.add(_normalizeDroplet(Map<String, dynamic>.from(item)));
    }
    return {'instances': instances};
  }

  /// Single-droplet fetch used during post-create polling. DO creates the
  /// droplet asynchronously; IPs appear on subsequent GETs once the
  /// hypervisor has assigned networking.
  Future<Map<String, dynamic>> getInstance(String instanceId) async {
    final id = _stripIdPrefix(instanceId);
    final raw = await _requestJson('GET', '/droplets/$id');
    final droplet = raw['droplet'];
    if (droplet is Map) {
      return {
        'instance': _normalizeDroplet(Map<String, dynamic>.from(droplet)),
      };
    }
    return const {};
  }

  /// DO does not expose the user-data back via API after creation, so
  /// there is no equivalent of Vultr's GET /instances/{id}/user-data.
  /// We always return null; recovery from user-data is Vultr-only.
  Future<String?> getInstanceUserData(String instanceId) async => null;

  Future<Map<String, dynamic>> deleteInstance(String instanceId) async {
    final id = _stripIdPrefix(instanceId);
    return _requestJson('DELETE', '/droplets/$id');
  }

  /// Creates a droplet and returns a Vultr-instance-shaped record.
  /// `osId` is ignored (DO uses image slugs, not ids); we default to
  /// debian-12-x64 to match the Go backend's behaviour.
  Future<Map<String, dynamic>> createInstance({
    required String region,
    required String plan,
    required String label,
    required int osId,
    required String userData,
  }) async {
    final body = {
      'name': label,
      'region': region,
      'size': plan,
      'image': 'debian-12-x64',
      'user_data': userData,
      'monitoring': true,
      'ipv6': true,
      'tags': const ['privatedeploy'],
    };
    final response = await _requestJson('POST', '/droplets', data: body);
    final droplet = response['droplet'];
    if (droplet is Map) {
      return {
        'instance': _normalizeDroplet(Map<String, dynamic>.from(droplet)),
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> validateApiKey() {
    return _requestJson('GET', '/account', timeout: _validationTimeout);
  }

  /// DO doesn't expose a `getPlanById` equivalent. We look the slug up in
  /// the full /sizes listing. The response is already Vultr-shaped by
  /// [listPlans], so callers can read plan.ram / plan.vcpu_count / ... the
  /// same way.
  @override
  Future<Map<String, dynamic>> getPlanById(String planId) async {
    final response = await listPlans();
    final plans = (response['plans'] as List?) ?? const [];
    for (final item in plans) {
      if (item is Map && item['id']?.toString() == planId) {
        return Map<String, dynamic>.from(item);
      }
    }
    throw StateError('Plan not found');
  }

  /// DO uses image slugs (`debian-12-x64`) not numeric ids, and the
  /// mobile client hardcodes the slug in [createInstance]. Returning a
  /// synthetic single-entry OS list makes preferredCloudOsIds route the
  /// deploy loop to one iteration with osId=1 (which the body ignores).
  @override
  Future<Map<String, dynamic>> getOperatingSystems() async {
    return const {
      'os': [
        {
          'id': 1,
          'name': 'Debian 12 x64',
          'family': 'debian',
        },
      ],
    };
  }

  /// Strips the `cloud-do-` prefix that mobile storage uses to keep DO
  /// instance ids distinct from Vultr's. DO's API wants the raw numeric id.
  String _stripIdPrefix(String id) {
    const prefix = 'cloud-do-';
    return id.startsWith(prefix) ? id.substring(prefix.length) : id;
  }

  Map<String, dynamic> _normalizeDroplet(Map<String, dynamic> droplet) {
    final networks = droplet['networks'];
    String mainIp = '';
    String v6MainIp = '';
    if (networks is Map) {
      final v4 = (networks['v4'] as List?) ?? const [];
      for (final entry in v4) {
        if (entry is Map && entry['type'] == 'public') {
          mainIp = entry['ip_address']?.toString() ?? '';
          if (mainIp.isNotEmpty) break;
        }
      }
      final v6 = (networks['v6'] as List?) ?? const [];
      for (final entry in v6) {
        if (entry is Map && entry['type'] == 'public') {
          v6MainIp = entry['ip_address']?.toString() ?? '';
          if (v6MainIp.isNotEmpty) break;
        }
      }
    }
    final region = droplet['region'];
    final size = droplet['size'];
    return {
      'id': 'cloud-do-${droplet['id']}',
      'label': droplet['name']?.toString() ?? '',
      'status': droplet['status']?.toString() ?? 'unknown',
      'region': region is Map ? region['slug']?.toString() ?? '' : '',
      'plan': size is Map ? size['slug']?.toString() ?? '' : '',
      'main_ip': mainIp,
      'v6_main_ip': v6MainIp,
      'date_created': droplet['created_at']?.toString() ?? '',
    };
  }

  /// DO's region names look like "New York 3" or "Amsterdam 3". We map
  /// that onto (city, country) so the mobile UI renders consistently
  /// with Vultr. Heuristic — DO doesn't ship an ISO country code.
  (String, String) _parseRegionName(String name) {
    final cleaned = name.replaceAll(RegExp(r'\s+\d+$'), '').trim();
    const cityToCountry = <String, String>{
      'New York': 'US',
      'San Francisco': 'US',
      'Atlanta': 'US',
      'Toronto': 'CA',
      'Amsterdam': 'NL',
      'Frankfurt': 'DE',
      'London': 'GB',
      'Singapore': 'SG',
      'Bangalore': 'IN',
      'Sydney': 'AU',
    };
    final country = cityToCountry[cleaned] ?? '';
    return (cleaned, country);
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
      final normalized = response.data;
      if (response.statusCode != null &&
          response.statusCode! >= 400 &&
          response.statusCode! <= 599) {
        throw StateError(_extractDoError(normalized) ??
            'DigitalOcean API error (${response.statusCode})');
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
    } finally {
      if (timeout != null) {
        _dio.options.connectTimeout = previousConnectTimeout;
      }
    }
  }

  String _extractDioErrorMessage(DioException error) {
    final response = error.response?.data;
    if (response is Map<String, dynamic>) {
      final message = response['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
      final id = response['id'];
      if (id is String && id.isNotEmpty) {
        return id;
      }
    }
    return error.message ?? 'DigitalOcean API request failed';
  }

  String? _extractDoError(dynamic response) {
    if (response is Map<String, dynamic>) {
      final message = response['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
      final id = response['id'];
      if (id is String && id.isNotEmpty) {
        return id;
      }
    }
    return null;
  }
}
