import 'dart:convert';

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
