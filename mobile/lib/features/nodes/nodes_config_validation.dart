import 'dart:convert';

import '../../core/subscription/parser.dart';
import '../../l10n/app_localizations.dart';

String? validateSingboxConfig(String configJson, AppLocalizations l10n) {
  try {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map<String, dynamic>) {
      return l10n.invalidConfigNotJsonObject;
    }
    final outbounds = decoded['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      return l10n.invalidConfigMissingOutbounds;
    }
    return null;
  } on FormatException {
    return l10n.invalidConfigNotJson;
  } catch (e) {
    return l10n.invalidConfigGeneric(e);
  }
}

/// Validates input that can be sing-box JSON, proxy URIs, or base64-encoded
/// URI list. Returns null if valid, or an error message.
String? validateNodeConfig(String input, AppLocalizations l10n) {
  // Try as sing-box JSON first
  final jsonError = validateSingboxConfig(input, l10n);
  if (jsonError == null) return null;

  // Try as proxy URI list or base64
  final parsed = SubscriptionParser.parseToSingboxConfig(input);
  if (parsed != null && parsed != '{}') return null;

  return l10n.unrecognizedFormat;
}

/// Converts input to sing-box JSON config. Input can be sing-box JSON,
/// proxy URIs, or base64-encoded URI list.
String? normalizeToSingboxConfig(String input) {
  return SubscriptionParser.parseToSingboxConfig(input);
}
