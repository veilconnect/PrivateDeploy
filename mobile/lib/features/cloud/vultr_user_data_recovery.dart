class RecoveredVultrNodeRecord {
  final int ssPort;
  final String ssPassword;
  final int hyPort;
  final String hyPassword;
  final String hyServerName;
  final int vlessPort;
  final String vlessUuid;
  final String vlessPublicKey;
  final String vlessShortId;
  final String vlessServerName;
  final int trojanPort;
  final String trojanPassword;
  final String trojanServerName;
  final int vlessRelayPort;

  const RecoveredVultrNodeRecord({
    required this.ssPort,
    required this.ssPassword,
    required this.hyPort,
    required this.hyPassword,
    required this.hyServerName,
    required this.vlessPort,
    required this.vlessUuid,
    required this.vlessPublicKey,
    required this.vlessShortId,
    required this.vlessServerName,
    required this.trojanPort,
    required this.trojanPassword,
    required this.trojanServerName,
    this.vlessRelayPort = 0,
  });

  bool get isUsable => ssPort > 0 && ssPassword.isNotEmpty;

  Map<String, dynamic> toNodeRecordJson() => {
        'ssPort': ssPort,
        'ssPassword': ssPassword,
        'hyPort': hyPort,
        'hyPassword': hyPassword,
        'hysteriaServerName': hyServerName,
        'vlessPort': vlessPort,
        'vlessUUID': vlessUuid,
        'vlessPublicKey': vlessPublicKey,
        'vlessShortId': vlessShortId,
        'vlessServerName': vlessServerName,
        'trojanPort': trojanPort,
        'trojanPassword': trojanPassword,
        'trojanServerName': trojanServerName,
        if (vlessRelayPort > 0) 'vlessRelayPort': vlessRelayPort,
      };
}

RecoveredVultrNodeRecord? recoverVultrNodeRecordFromUserData(String userData) {
  final script = userData.trim();
  if (script.isEmpty) {
    return null;
  }

  final ssMatch = _ssConfig.firstMatch(script);
  if (ssMatch == null) {
    return null;
  }

  final ssPort = int.tryParse(ssMatch.group(1) ?? '') ?? 0;
  final ssPassword = _firstNonEmptyGroups(ssMatch, const [3, 4, 5]);
  if (ssPort <= 0 || ssPassword.isEmpty) {
    return null;
  }

  final hyPort = _parseInt(
    _firstMatchGroup(
      _hysteriaPort,
      script,
      1,
    ),
  );
  final hyPassword = _firstNonEmpty(
    _firstMatchGroup(_hysteriaPasswordEnv, script, 2),
    _firstMatchGroup(_hysteriaPasswordEnv, script, 3),
    _firstMatchGroup(_hysteriaPasswordEnv, script, 4),
    _firstMatchGroup(_hysteriaPasswordJson, script, 1),
  );
  final hyServerName = _firstNonEmpty(
    _firstMatchGroup(_hysteriaServerEnv, script, 2),
    _firstMatchGroup(_hysteriaServerEnv, script, 3),
    _firstMatchGroup(_hysteriaServerEnv, script, 4),
    _firstMatchGroup(_hysteriaServerJson, script, 1),
  );

  final vlessPort = _parseInt(_firstMatchGroup(_vlessPort, script, 1));
  final vlessUuid = _firstMatchGroup(_vlessUuid, script, 1) ?? '';
  final vlessPublicKey = _firstMatchGroup(_vlessPublicKey, script, 1) ?? '';
  final vlessShortId = _firstNonEmpty(
    _firstMatchGroup(_vlessShortIdReality, script, 1),
    _firstMatchGroup(_vlessShortIdConfig, script, 1),
  );
  final vlessServerName = _firstMatchGroup(_vlessServerName, script, 1) ?? '';

  final trojanPort = _parseInt(_firstMatchGroup(_trojanPort, script, 1));
  final trojanPassword =
      _firstMatchGroup(_trojanPassword, script, 1) ?? '';
  final trojanServerName =
      _firstMatchGroup(_trojanServerName, script, 1) ?? '';

  // The plain-VLESS relay block (M1 / Workers Custom Domain front) is
  // emitted only when a relay port is allocated. Match either the UFW
  // line or the relay.json listen_port — UFW is cheaper to scan.
  final vlessRelayPort =
      _parseInt(_firstMatchGroup(_vlessRelayPort, script, 1));

  return RecoveredVultrNodeRecord(
    ssPort: ssPort,
    ssPassword: ssPassword,
    hyPort: hyPort,
    hyPassword: hyPassword,
    hyServerName: hyServerName,
    vlessPort: vlessPort,
    vlessUuid: vlessUuid,
    vlessPublicKey: vlessPublicKey,
    vlessShortId: vlessShortId,
    vlessServerName: vlessServerName,
    trojanPort: trojanPort,
    trojanPassword: trojanPassword,
    trojanServerName: trojanServerName,
    vlessRelayPort: vlessRelayPort,
  );
}

final RegExp _ssConfig = RegExp(
  "-s 0\\.0\\.0\\.0 -p (\\d+) -k (\\\"([^\\\"]+)\\\"|'([^']+)'|([^\\s]+)) -m aes-256-gcm",
  dotAll: true,
);
final RegExp _hysteriaPort = RegExp(
  "\"type\":\\s*\"hysteria2\".*?\"listen_port\":\\s*(\\d+)",
  dotAll: true,
);
final RegExp _hysteriaPasswordJson = RegExp(
  "\"type\":\\s*\"hysteria2\".*?\"password\":\\s*\"([^\"]+)\"",
  dotAll: true,
);
final RegExp _hysteriaPasswordEnv = RegExp(
  "^HYSTERIA_PASSWORD=(\\\"([^\\\"]+)\\\"|'([^']+)'|([^\\s]+))\$",
  multiLine: true,
);
final RegExp _hysteriaServerJson = RegExp(
  "\"type\":\\s*\"hysteria2\".*?\"server_name\":\\s*\"([^\"]+)\"",
  dotAll: true,
);
final RegExp _hysteriaServerEnv = RegExp(
  "^HYSTERIA_SERVER_NAME=(\\\"([^\\\"]+)\\\"|'([^']+)'|([^\\s]+))\$",
  multiLine: true,
);
final RegExp _vlessPort = RegExp(
  "\"type\":\\s*\"vless\".*?\"listen_port\":\\s*(\\d+)",
  dotAll: true,
);
final RegExp _vlessUuid = RegExp(
  "\"type\":\\s*\"vless\".*?\"uuid\":\\s*\"([^\"]+)\"",
  dotAll: true,
);
final RegExp _vlessServerName = RegExp(
  "\"type\":\\s*\"vless\".*?\"server_name\":\\s*\"([^\"]+)\"",
  dotAll: true,
);
final RegExp _vlessPublicKey = RegExp(
  "^PublicKey:\\s*([A-Za-z0-9_-]+)\$",
  multiLine: true,
);
final RegExp _vlessShortIdReality = RegExp(
  "^ShortID:\\s*([A-Za-z0-9]+)\$",
  multiLine: true,
);
final RegExp _vlessShortIdConfig = RegExp(
  "\"short_id\":\\s*\\[\\s*\"([^\"]+)\"\\s*\\]",
  dotAll: true,
);
final RegExp _trojanPort = RegExp(
  "\"type\":\\s*\"trojan\".*?\"listen_port\":\\s*(\\d+)",
  dotAll: true,
);
final RegExp _trojanPassword = RegExp(
  "\"type\":\\s*\"trojan\".*?\"password\":\\s*\"([^\"]+)\"",
  dotAll: true,
);
final RegExp _trojanServerName = RegExp(
  "\"type\":\\s*\"trojan\".*?\"server_name\":\\s*\"([^\"]+)\"",
  dotAll: true,
);
// The relay block UFW comment is unique and one-line, so this matches it
// fast and unambiguously. Falls back to nothing when M1 isn't wired
// (legacy nodes or future deploys with the relay block disabled).
//
// Matches both `ufw allow` and `ufw limit`: the install script emits
// `ufw limit` (rate-limited via iptables' recent module — see
// deploy.go:130), but older revisions and any future change back to
// `allow` should still recover. Bug found 2026-05-12: app saw
// vlessRelayPort=0 for CLI-created nodes because this regex was
// `allow`-only, the install script emitted `limit`, and the M1 deploy
// path therefore looked unsupported in the UI.
final RegExp _vlessRelayPort = RegExp(
  r"ufw\s+(?:allow|limit)\s+(\d+)/tcp\s+comment\s+'VLESS-Relay",
);

String _firstNonEmptyGroups(RegExpMatch match, List<int> indexes) {
  for (final index in indexes) {
    final value = match.group(index);
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String _firstNonEmpty(
  String? first, [
  String? second,
  String? third,
  String? fourth,
]) {
  for (final value in [first, second, third, fourth]) {
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String? _firstMatchGroup(RegExp pattern, String input, int groupIndex) {
  final match = pattern.firstMatch(input);
  return match?.group(groupIndex);
}

int _parseInt(String? value) => int.tryParse(value ?? '') ?? 0;
