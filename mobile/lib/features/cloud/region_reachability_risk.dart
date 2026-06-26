/// Coarse reachability risk rating per region code. This curated hint is shown
/// alongside the live latency probe; the probe is empirical and current, while
/// this rating is stable prior knowledge that still helps when a probe has not
/// landed yet or a region is borderline.
enum RegionRisk { low, medium, high, critical }

const Map<String, RegionRisk> _reachabilityRiskRating = {
  'sgp': RegionRisk.low,
  'nrt': RegionRisk.low,
  'icn': RegionRisk.low,
  'hkg': RegionRisk.medium,
  'tpe': RegionRisk.low,
  'bom': RegionRisk.low,
  'syd': RegionRisk.low,
  'lax': RegionRisk.medium,
  'sjc': RegionRisk.medium,
  'sea': RegionRisk.medium,
  'ams': RegionRisk.medium,
  'fra': RegionRisk.medium,
  'lhr': RegionRisk.medium,
  'ewr': RegionRisk.high,
  'ord': RegionRisk.high,
  'dfw': RegionRisk.high,
  'mia': RegionRisk.high,
  'atl': RegionRisk.high,
  'yto': RegionRisk.high,
  'cdg': RegionRisk.high,
};

/// Curated reachability risk for [regionId]; unknown regions default to [RegionRisk.medium].
RegionRisk regionReachabilityRisk(String regionId) =>
    _reachabilityRiskRating[regionId] ?? RegionRisk.medium;

/// Traffic-light emoji for [regionId]'s risk, matching the desktop getRiskIcon.
String regionRiskIcon(String regionId) {
  switch (regionReachabilityRisk(regionId)) {
    case RegionRisk.low:
      return '🟢';
    case RegionRisk.medium:
      return '🟡';
    case RegionRisk.high:
      return '🟠';
    case RegionRisk.critical:
      return '🔴';
  }
}
