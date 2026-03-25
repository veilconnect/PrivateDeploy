class ApiConstants {
  static const String _overrideBaseUrl = String.fromEnvironment(
    'PRIVATEDEPLOY_API_BASE_URL',
    defaultValue: '',
  );
  static const String _overrideWsUrl = String.fromEnvironment(
    'PRIVATEDEPLOY_WS_URL',
    defaultValue: '',
  );

  // Base URL defaults for a real phone: localhost is the only sane fallback.
  // If you run API on Android emulator host, pass --dart-define=PRIVATEDEPLOY_API_BASE_URL.
  static const String _defaultBaseUrl = 'http://127.0.0.1:8443/api/v1';
  static const String _defaultWsUrl = 'ws://127.0.0.1:8443/api/v1/ws';

  static String get defaultBaseUrl =>
      _normalizeUrl(_isSet(_overrideBaseUrl) ? _overrideBaseUrl : _defaultBaseUrl);
  static String get defaultWsUrl =>
      _normalizeUrl(_isSet(_overrideWsUrl) ? _overrideWsUrl : _defaultWsUrl);

  static bool _isSet(String value) {
    return value.trim().isNotEmpty;
  }

  static String _normalizeUrl(String value) {
    return value.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  // Endpoints
  static const String cloudProviders = '/cloud/providers';
  static const String cloudConfig = '/cloud/config';
  static const String cloudInstances = '/cloud/instances';
  static const String cloudRegions = '/cloud/regions';
  static const String cloudPlans = '/cloud/plans';

  static const String profiles = '/profiles';
  static const String subscriptions = '/subscriptions';

  static const String vpnStart = '/vpn/start';
  static const String vpnStop = '/vpn/stop';
  static const String vpnStatus = '/vpn/status';
  static const String vpnStats = '/vpn/stats';

  // Timeouts
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration cloudCreateTimeout = Duration(seconds: 120);

  // Storage Keys
  static const String userKey = 'user_data';
  static const String settingsKey = 'app_settings';
}
