enum CloudProviderId {
  vultr('vultr', 'Vultr'),
  digitalocean('digitalocean', 'DigitalOcean'),
  ssh('ssh', 'SSH');

  final String id;
  final String displayName;

  const CloudProviderId(this.id, this.displayName);

  String get apiKeyStorageKey => 'mobile_cloud_${id}_api_key';

  String get configStorageKey => 'mobile_cloud_${id}_config';

  String get nodeRecordsStorageKey => 'mobile_cloud_${id}_nodes';

  static CloudProviderId? tryParse(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    for (final candidate in CloudProviderId.values) {
      if (candidate.id == value) {
        return candidate;
      }
    }
    return null;
  }

  static CloudProviderId parseOrVultr(String? value) =>
      tryParse(value) ?? CloudProviderId.vultr;
}
