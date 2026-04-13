import 'dart:convert';

import '../../core/subscription/parser.dart';

String? validateSingboxConfig(String configJson) {
  try {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map<String, dynamic>) {
      return 'Invalid config: not a JSON object';
    }
    final outbounds = decoded['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      return 'Invalid config: missing or empty "outbounds" section';
    }
    return null;
  } on FormatException {
    return 'Invalid config: not valid JSON';
  } catch (e) {
    return 'Invalid config: $e';
  }
}

/// Validates input that can be sing-box JSON, proxy URIs, or base64-encoded
/// URI list. Returns null if valid, or an error message.
String? validateNodeConfig(String input) {
  // Try as sing-box JSON first
  final jsonError = validateSingboxConfig(input);
  if (jsonError == null) return null;

  // Try as proxy URI list or base64
  final parsed = SubscriptionParser.parseToSingboxConfig(input);
  if (parsed != null && parsed != '{}') return null;

  return 'Unrecognized format. Paste proxy links (ss://, vless://, etc.) or sing-box JSON.';
}

/// Converts input to sing-box JSON config. Input can be sing-box JSON,
/// proxy URIs, or base64-encoded URI list.
String? normalizeToSingboxConfig(String input) {
  return SubscriptionParser.parseToSingboxConfig(input);
}
