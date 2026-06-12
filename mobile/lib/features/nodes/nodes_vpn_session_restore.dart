import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../profiles/profile_config_normalizer.dart';
import '../profiles/profile_provider.dart';
import '../settings/app_settings_provider.dart';
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
  required BuildContext context,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
}) {
  if (vpnProvider.status != VpnStatus.connected) {
    return const NodesPreviousVpnSession.disconnected();
  }

  final routingSettings =
      context.read<AppSettingsProvider>().vpnRoutingSettings;
  final proxyless = vpnProvider.isProxylessTunnel;
  final wg = routingSettings.wireGuardIntranet;
  final configJson = proxyless
      ? buildWireguardIntranetOnlyConfig(wg.copyWith(enabled: true))
      : profileProvider.getActiveConfigJson(routingSettings: routingSettings);

  return NodesPreviousVpnSession(
    connected: true,
    profileName: vpnProvider.activeProfile,
    configJson: configJson,
    proxyless: proxyless,
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
