import 'cloud_models.dart';

String normalizeCloudInstanceLabel(String? raw, {DateTime? now}) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isNotEmpty) {
    return trimmed;
  }

  final ts = now ?? DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  final compact =
      '${ts.year.toString().substring(2)}${two(ts.month)}${two(ts.day)}'
      '${two(ts.hour)}${two(ts.minute)}${two(ts.second)}';
  return 'node-$compact';
}

String? validateCloudDeploymentSelection({
  required String region,
  required String plan,
  required List<CloudRegion> regions,
  required List<CloudPlan> plans,
}) {
  final regionExists = regions.any((candidate) => candidate.id == region);
  if (!regionExists) {
    return 'Selected region is unavailable';
  }

  final selectedPlan =
      plans.where((candidate) => candidate.id == plan).firstOrNull;
  if (selectedPlan == null) {
    return 'Selected plan is unavailable';
  }
  if (!selectedPlan.locations.contains(region)) {
    return 'Selected plan is not available in the chosen region';
  }
  return null;
}
