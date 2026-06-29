part of 'cloud_provider.dart';

// Node-record replacement matching: pairs a freshly observed instance with a
// previously stored record (by address, or label+region) when an instance ID
// changed under it. Pure top-level helpers, split out of cloud_provider.dart.

String? _findReplacementNodeRecordId({
  required String instanceId,
  required String label,
  required String region,
  required String ipv4,
  required String ipv6,
  required Map<String, VultrNodeRecord> knownRecords,
  required Set<String> liveInstanceIds,
  required Set<String> claimedRecordIds,
}) {
  final addressMatches = <String>[];
  final labelRegionMatches = <String>[];

  final normalizedLabel = label.trim().toLowerCase();
  final normalizedRegion = region.trim().toLowerCase();
  final normalizedIpv4 = ipv4.trim();
  final normalizedIpv6 = ipv6.trim().toLowerCase();

  for (final entry in knownRecords.entries) {
    if (entry.key == instanceId ||
        liveInstanceIds.contains(entry.key) ||
        claimedRecordIds.contains(entry.key)) {
      continue;
    }

    final record = entry.value;
    final recordIpv4 = record.ipv4.trim();
    final recordIpv6 = record.ipv6.trim().toLowerCase();
    if ((normalizedIpv4.isNotEmpty && recordIpv4 == normalizedIpv4) ||
        (normalizedIpv6.isNotEmpty &&
            recordIpv6.isNotEmpty &&
            recordIpv6 == normalizedIpv6)) {
      addressMatches.add(entry.key);
      continue;
    }

    final recordLabel = record.label.trim().toLowerCase();
    final recordRegion = record.region.trim().toLowerCase();
    if (normalizedLabel.isNotEmpty &&
        normalizedRegion.isNotEmpty &&
        recordLabel == normalizedLabel &&
        recordRegion == normalizedRegion) {
      labelRegionMatches.add(entry.key);
    }
  }

  if (addressMatches.length == 1) {
    return addressMatches.first;
  }
  if (labelRegionMatches.length == 1) {
    return labelRegionMatches.first;
  }
  return null;
}

VultrNodeRecord _prepareReplacementNodeRecord({
  required VultrNodeRecord record,
  required String instanceId,
  required String label,
  required String region,
  required String plan,
  required String ipv4,
  required String ipv6,
  required String createdAt,
}) {
  final next = record.toJson()
    ..['label'] = label
    ..['region'] = region
    ..['plan'] = plan
    ..['ipv4'] = ipv4
    ..['ipv6'] = ipv6
    ..['createdAt'] = createdAt
    ..['ssPort'] = 0
    ..['ssPassword'] = ''
    ..['hyPort'] = 0
    ..['hyPassword'] = ''
    ..['hysteriaServerName'] = ''
    ..['vlessPort'] = 0
    ..['vlessUUID'] = ''
    ..['vlessPublicKey'] = ''
    ..['vlessShortId'] = ''
    ..['vlessServerName'] = ''
    ..['trojanPort'] = 0
    ..['trojanPassword'] = ''
    ..['trojanServerName'] = '';

  return VultrNodeRecord.fromJson(instanceId, next);
}
