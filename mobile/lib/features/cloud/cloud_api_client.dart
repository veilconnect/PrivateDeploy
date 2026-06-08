import 'cloud_models.dart';

/// Common REST surface shared by every provider-specific client
/// ([VultrCloudClient], [DigitalOceanCloudClient], …). CloudProvider talks
/// to providers only through this interface, so adding a new provider is a
/// matter of implementing this contract without touching provider-agnostic
/// orchestration.
///
/// Every method returns a Vultr-shaped envelope (`{regions: [...]}`,
/// `{plans: [...]}`, `{instance: {...}}`, …) — concrete clients normalize
/// their provider-specific JSON into that shape at their boundary so the
/// rest of the app stays unaware of the underlying API.
abstract class CloudApiClient {
  Future<Map<String, dynamic>> validateApiKey();

  Future<Map<String, dynamic>> listRegions();

  Future<Map<String, dynamic>> listPlans();

  Future<Map<String, dynamic>> listInstances();

  Future<String?> getInstanceUserData(String instanceId);

  Future<Map<String, dynamic>> deleteInstance(String instanceId);

  Future<Map<String, dynamic>> getPlanById(String planId);

  /// Returns the operating-system payload the deploy flow iterates over
  /// when picking an image for [createInstance]. Vultr returns its live
  /// `/os` response; DigitalOcean returns a stub that drives
  /// preferredCloudOsIds toward `[0]` (DO uses image slugs, not numeric
  /// ids, and ignores osId in its createInstance body).
  Future<Map<String, dynamic>> getOperatingSystems();

  Future<Map<String, dynamic>> createInstance({
    required String region,
    required String plan,
    required String label,
    required int osId,
    required String userData,
  });

  /// Probes the upstream account state so the UI can degrade — block the
  /// deploy button when state == locked && canDeploy == false, render a
  /// banner for warning / soft-locked, etc. Default implementation returns
  /// [CloudAccountStatus.active] so providers that don't expose a quota or
  /// account-lock endpoint are treated as always-deployable (fail-open).
  Future<CloudAccountStatus> getAccountStatus() async =>
      CloudAccountStatus.active();
}
