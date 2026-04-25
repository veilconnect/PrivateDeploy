typedef NodesProfileNameValidator = String? Function(String name);

class NodesImportProfileRequest {
  final String name;
  final String payload;
  final String passphrase;

  const NodesImportProfileRequest({
    required this.name,
    required this.payload,
    required this.passphrase,
  });
}

class NodesCreateProfileRequest {
  final String name;
  final String config;

  const NodesCreateProfileRequest({
    required this.name,
    required this.config,
  });
}

class NodesCreateCloudRequest {
  final String label;
  final String region;
  final String plan;
  final bool usesSavedSshAccess;

  const NodesCreateCloudRequest({
    required this.label,
    required this.region,
    required this.plan,
    this.usesSavedSshAccess = false,
  });
}
