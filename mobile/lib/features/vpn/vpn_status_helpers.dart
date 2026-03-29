import '../../services/vpn_native_service.dart';
import 'vpn_models.dart';

TrafficStats trafficStatsFromNative(VpnNativeStats nativeStats) {
  return TrafficStats(
    uploadBytes: nativeStats.uploadBytes,
    downloadBytes: nativeStats.downloadBytes,
    uploadSpeed: nativeStats.uploadSpeed.toDouble(),
    downloadSpeed: nativeStats.downloadSpeed.toDouble(),
    connectionTime: Duration.zero,
  );
}

VpnStatus vpnStatusFromNative(VpnNativeStatus nativeStatus) {
  final normalizedStatus = nativeStatus.status.toLowerCase();
  final hasRunningSignal =
      nativeStatus.running || normalizedStatus == 'connected';

  switch (normalizedStatus) {
    case 'connecting':
      return VpnStatus.connecting;
    case 'disconnecting':
      return VpnStatus.disconnecting;
    case 'connected':
      return VpnStatus.connected;
    case 'error':
    case 'revoked':
    case 'disconnected':
      return VpnStatus.disconnected;
    default:
      return hasRunningSignal ? VpnStatus.connected : VpnStatus.disconnected;
  }
}

bool isVpnConflictTransition({
  required VpnStatus previousStatus,
  required VpnNativeStatus nativeStatus,
  String? message,
}) {
  if (nativeStatus.status == 'revoked' &&
      previousStatus == VpnStatus.connected) {
    return true;
  }

  if (previousStatus != VpnStatus.connected) {
    return false;
  }

  final normalizedMessage = message?.toLowerCase();
  return normalizedMessage?.contains('permission revoked') == true;
}
