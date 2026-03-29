typedef NodesProfileNameValidator = String? Function(String name);

class NodesImportProfileRequest {
  final String name;
  final String url;

  const NodesImportProfileRequest({
    required this.name,
    required this.url,
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

  const NodesCreateCloudRequest({
    required this.label,
    required this.region,
    required this.plan,
  });
}
