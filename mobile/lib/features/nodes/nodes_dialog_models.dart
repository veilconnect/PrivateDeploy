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
  // Whether to chain a CDN Worker deployment after the VPS comes up.
  // Default true when CDN is verified — saves the user a second
  // trip into Settings → CDN to tap "部署 Worker". Can be unchecked
  // in the create dialog if the user wants to skip; they can always
  // deploy later from the CDN screen.
  final bool autoDeployCdnWorker;

  const NodesCreateCloudRequest({
    required this.label,
    required this.region,
    required this.plan,
    this.usesSavedSshAccess = false,
    this.autoDeployCdnWorker = false,
  });
}
