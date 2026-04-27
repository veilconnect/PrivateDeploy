import '../../l10n/app_localizations.dart';
import 'vpn_provider.dart';

/// Maps the canonical English error/diagnostic messages emitted by
/// [VpnProvider] (kept English so they are stable across native log lines and
/// existing tests) onto their localized UI strings. Unknown messages pass
/// through unchanged so sing-box runtime errors and other free-form text are
/// still surfaced to the user.
String localizeVpnStatusMessage(String? raw, AppLocalizations l10n) {
  if (raw == null) {
    return '';
  }
  switch (raw) {
    case VpnProvider.vpnConflictMessage:
      return l10n.vpnConflictMessageLocalized;
    case VpnProvider.vpnPermissionDeniedMessage:
      return l10n.vpnPermissionDeniedMessageLocalized;
    case VpnProvider.egressProbeFailureMessage:
      return l10n.egressProbeFailureMessageLocalized;
    case VpnProvider.startupConnectivityFailureMessage:
      return l10n.startupConnectivityFailureMessageLocalized;
    case VpnProvider.startupProbeInconclusiveMessage:
      return l10n.startupProbeInconclusiveMessageLocalized;
  }
  return raw;
}
