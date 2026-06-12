import '../vpn/vpn_provider.dart';

class NodesPreviousVpnSession {
  const NodesPreviousVpnSession({
    required this.connected,
    required this.profileName,
    required this.configJson,
    required this.proxyless,
  });

  const NodesPreviousVpnSession.disconnected()
      : connected = false,
        profileName = null,
        configJson = null,
        proxyless = false;

  final bool connected;
  final String? profileName;
  final String? configJson;
  final bool proxyless;

  bool get canRestore => connected && (configJson?.trim().isNotEmpty ?? false);
}

NodesPreviousVpnSession capturePreviousVpnSession({
  required VpnProvider vpnProvider,
}) {
  final snapshot = vpnProvider.activeSessionSnapshot;
  if (snapshot == null) {
    return const NodesPreviousVpnSession.disconnected();
  }

  return NodesPreviousVpnSession(
    connected: true,
    profileName: snapshot.profileName,
    configJson: snapshot.configJson,
    proxyless: snapshot.proxyless,
  );
}

Future<bool> restorePreviousVpnSession({
  required NodesPreviousVpnSession session,
  required VpnProvider vpnProvider,
}) {
  if (!session.canRestore) {
    return Future<bool>.value(true);
  }
  return vpnProvider.connect(
    configJson: session.configJson,
    profileName: session.profileName,
    stabilityCheckDuration: const Duration(seconds: 1),
    statusPollInterval: const Duration(milliseconds: 250),
    proxyless: session.proxyless,
  );
}
