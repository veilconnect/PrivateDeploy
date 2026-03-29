import 'dart:convert';

import 'package:flutter/foundation.dart';

String normalizeProfileConfigForCurrentPlatform(
  String content, {
  TargetPlatform? targetPlatform,
}) {
  if ((targetPlatform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return content;
  }

  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      return content;
    }
    var changed = false;
    final inbounds = decoded['inbounds'];
    if (inbounds is List) {
      for (final inbound in inbounds) {
        if (inbound is! Map<String, dynamic>) {
          continue;
        }
        if (inbound['type']?.toString() != 'tun') {
          continue;
        }

        final stack = inbound['stack']?.toString().trim();
        if (stack == null || stack.isEmpty || stack == 'system') {
          inbound['stack'] = 'gvisor';
          changed = true;
        }
      }
    }

    final unsupportedTags = <String>{};
    final outbounds = decoded['outbounds'];
    if (outbounds is List) {
      outbounds.removeWhere((outbound) {
        if (outbound is! Map<String, dynamic>) {
          return false;
        }
        if (!isUnsupportedAndroidOutbound(outbound)) {
          return false;
        }
        final tag = outbound['tag']?.toString();
        if (tag != null && tag.isNotEmpty) {
          unsupportedTags.add(tag);
        }
        changed = true;
        return true;
      });

      while (unsupportedTags.isNotEmpty) {
        var passChanged = false;
        outbounds.removeWhere((outbound) {
          if (outbound is! Map<String, dynamic>) {
            return false;
          }
          final refs = outbound['outbounds'];
          if (refs is! List) {
            return false;
          }

          final before = refs.length;
          refs.removeWhere(
              (value) => unsupportedTags.contains(value?.toString()));
          if (refs.length != before) {
            changed = true;
            passChanged = true;
          }

          final defaultTag = outbound['default']?.toString();
          if (refs.isNotEmpty &&
              defaultTag != null &&
              defaultTag.isNotEmpty &&
              !refs.any((value) => value?.toString() == defaultTag)) {
            outbound['default'] = refs.first.toString();
            changed = true;
            passChanged = true;
          }

          if (refs.isNotEmpty) {
            return false;
          }

          final tag = outbound['tag']?.toString();
          if (tag != null && tag.isNotEmpty) {
            unsupportedTags.add(tag);
          }
          changed = true;
          passChanged = true;
          return true;
        });

        if (!passChanged) {
          break;
        }
      }
    }

    if (!changed) {
      return content;
    }
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {
    return content;
  }
}

bool isUnsupportedAndroidOutbound(Map<String, dynamic> outbound) {
  final type = outbound['type']?.toString();
  if (type == 'hysteria2') {
    return true;
  }
  if (type != 'vless') {
    return false;
  }

  final tls = outbound['tls'];
  if (tls is! Map) {
    return false;
  }

  return isFeatureEnabled(tls['utls']) || isFeatureEnabled(tls['reality']);
}

bool isFeatureEnabled(dynamic value) {
  if (value is Map) {
    final enabled = value['enabled'];
    if (enabled is bool) {
      return enabled;
    }
    return enabled?.toString().toLowerCase() == 'true';
  }
  return false;
}
