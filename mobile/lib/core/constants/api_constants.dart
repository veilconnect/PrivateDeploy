class ApiConstants {
  // Base URLs
  static const String defaultBaseUrl = String.fromEnvironment(
    'PRIVATEDEPLOY_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8443/api/v1',
  );
  static const String defaultWsUrl = String.fromEnvironment(
    'PRIVATEDEPLOY_WS_URL',
    defaultValue: 'ws://10.0.2.2:8443/api/v1/ws',
  );

  // Endpoints
  static const String authLogin = '/auth/login';
  static const String authRefresh = '/auth/refresh';

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

  // Storage Keys
  static const String tokenKey = 'auth_token';
  static const String userKey = 'user_data';
  static const String settingsKey = 'app_settings';
}
