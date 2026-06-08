import '../../services/vpn_native_service.dart';
import 'vpn_models.dart';

bool isVpnConflictMessage(String? message) {
  final normalizedMessage = message?.trim().toLowerCase();
  if (normalizedMessage == null || normalizedMessage.isEmpty) {
    return false;
  }

  return normalizedMessage.contains('permission revoked') ||
      normalizedMessage.contains('another vpn') ||
      normalizedMessage.contains('system vpn') ||
      normalizedMessage.contains('interrupted this connection') ||
      normalizedMessage.contains('took over this connection');
}

TrafficStats trafficStatsFromNative(
  VpnNativeStats nativeStats, {
  Duration connectionTime = Duration.zero,
}) {
  return TrafficStats(
    uploadBytes: nativeStats.uploadBytes,
    downloadBytes: nativeStats.downloadBytes,
    uploadSpeed: nativeStats.uploadSpeed.toDouble(),
    downloadSpeed: nativeStats.downloadSpeed.toDouble(),
    connectionTime: connectionTime,
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
  if (nativeStatus.status == 'revoked') {
    return true;
  }

  if (previousStatus != VpnStatus.connected) {
    return isVpnConflictMessage(message);
  }

  return isVpnConflictMessage(message);
}
