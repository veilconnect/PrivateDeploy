import 'dart:io';

/// Vultr's public per-region speed-test anchor IPs, keyed by the region code
/// Vultr's API returns as [CloudRegion.id] (e.g. `sjc`, `icn`, `sgp`).
///
/// These are Vultr's own published latency-probe endpoints — identical for
/// every Vultr account and NOT a user's deployed node — so they are safe to
/// ship. Mirrors `bridge/cloud/providers/vultr/latency.go`'s `testIPMap` so the
/// mobile deploy dialog can estimate reachability/latency to each region BEFORE
/// a node exists there.
///
/// Reaching the anchor is a proxy for the region being usable from the current
/// network: a probe that times out is a strong signal the whole range is
/// blocked (carrier/regional reachability), so that region should be avoided. A probe that
/// succeeds means the region is very likely usable — but the freshly-deployed
/// node gets a different IP in the same range, so it is not a hard guarantee.
const Map<String, String> kVultrRegionTestIp = {
  'bom': '207.148.77.101', // 孟买 Mumbai
  'sgp': '45.32.100.168', // 新加坡 Singapore
  'nrt': '139.180.132.194', // 东京 Tokyo
  'icn': '45.76.178.200', // 首尔 Seoul
  'fra': '108.61.210.117', // 法兰克福 Frankfurt
  'lax': '108.61.219.200', // 洛杉矶 Los Angeles
  'yto': '149.248.2.101', // 多伦多 Toronto
  'lhr': '45.76.113.28', // 伦敦 London
  'cdg': '95.179.139.229', // 巴黎 Paris
  'ams': '108.61.198.102', // 阿姆斯特丹 Amsterdam
  'syd': '108.61.212.117', // 悉尼 Sydney
  'sjc': '45.32.48.10', // 硅谷 Silicon Valley
  'sea': '108.61.194.105', // 西雅图 Seattle
  'ord': '45.32.203.95', // 芝加哥 Chicago
  'ewr': '45.76.1.68', // 纽约 New Jersey
  'atl': '45.63.115.219', // 亚特兰大 Atlanta
  'dfw': '108.61.224.175', // 达拉斯 Dallas
};

/// Whether [regionId] has a known anchor IP we can probe.
bool vultrRegionHasLatencyAnchor(String regionId) =>
    kVultrRegionTestIp.containsKey(regionId);

/// Probes a single region by code. Returns round-trip milliseconds, or null
/// when the region has no anchor or is unreachable within [timeout].
typedef RegionLatencyProbe = Future<int?> Function(String regionId);

/// TCP-connects to the region's anchor IP on port 80 and returns the round-trip
/// in milliseconds, or null when the region is unreachable within [timeout]
/// (timeout / refused / reset). Port 80 mirrors latency.go; TCP avoids the ICMP
/// permission problems on mobile. The probe runs from the device's current
/// network, so the result reflects what the user can actually reach right now.
Future<int?> probeVultrRegionLatency(
  String regionId, {
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  final ip = kVultrRegionTestIp[regionId];
  if (ip == null) {
    return null;
  }
  final stopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(ip, 80, timeout: timeout);
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds.clamp(1, 9999).toInt();
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}
