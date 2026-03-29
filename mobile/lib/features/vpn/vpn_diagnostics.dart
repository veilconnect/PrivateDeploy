import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../services/vpn_native_service.dart';

enum VpnRouteDecisionType {
  direct,
  proxy,
}

class VpnRouteDecision {
  const VpnRouteDecision({
    required this.timestamp,
    required this.type,
    required this.outboundType,
    required this.outboundTag,
    required this.target,
    this.domain,
  });

  final DateTime timestamp;
  final VpnRouteDecisionType type;
  final String outboundType;
  final String outboundTag;
  final String target;
  final String? domain;

  bool get isDirect => type == VpnRouteDecisionType.direct;

  String get typeLabel => isDirect ? 'DIRECT' : 'PROXY';

  String get routeLabel =>
      isDirect ? '直连规则' : '代理规则 (${outboundTag.trim()})';

  String get displayTarget {
    if (domain == null || domain == targetHost) {
      return target;
    }
    return '$domain -> $target';
  }

  String get targetHost {
    final targetValue = target.trim();
    if (targetValue.startsWith('[')) {
      final closing = targetValue.indexOf(']');
      if (closing > 0) {
        return targetValue.substring(1, closing);
      }
    }

    final segments = targetValue.split(':');
    if (segments.length <= 2) {
      return segments.first;
    }
    return targetValue;
  }
}

class VpnRuntimeLogParser {
  static final RegExp _dnsRule = RegExp(
    r'dns: exchanged (?:A|AAAA) ([^\s]+)\. .* IN (?:A|AAAA) ([0-9a-fA-F:.]+)',
  );
  static final RegExp _outboundRule = RegExp(
    r'outbound/([^\[]+)\[([^\]]+)\]: outbound (?:packet )?connection to ([^ ]+)',
  );

  final LinkedHashMap<String, String> _domainByIp = LinkedHashMap();
  final List<VpnRouteDecision> _recentDecisions = [];

  List<VpnRouteDecision> get recentDecisions =>
      List<VpnRouteDecision>.unmodifiable(_recentDecisions);

  void reset() {
    _domainByIp.clear();
    _recentDecisions.clear();
  }

  void replaceWith(Iterable<VpnNativeLogEntry> entries) {
    reset();
    final sortedEntries = entries.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final entry in sortedEntries) {
      ingest(entry);
    }
  }

  VpnRouteDecision? ingest(VpnNativeLogEntry entry) {
    final message = entry.message.trim();
    if (message.isEmpty) {
      return null;
    }

    final dnsMatch = _dnsRule.firstMatch(message);
    if (dnsMatch != null) {
      _rememberDomain(dnsMatch.group(1)!, dnsMatch.group(2)!);
      return null;
    }

    final outboundMatch = _outboundRule.firstMatch(message);
    if (outboundMatch == null) {
      return null;
    }

    final outboundType = outboundMatch.group(1)!.trim();
    final outboundTag = outboundMatch.group(2)!.trim();
    final target = outboundMatch.group(3)!.trim();
    final targetHost = _extractTargetHost(target);
    final domain = InternetAddress.tryParse(targetHost) == null
        ? targetHost
        : _domainByIp[targetHost];
    final type = outboundType == 'direct' || outboundTag == 'direct'
        ? VpnRouteDecisionType.direct
        : VpnRouteDecisionType.proxy;

    final decision = VpnRouteDecision(
      timestamp: entry.timestamp,
      type: type,
      outboundType: outboundType,
      outboundTag: outboundTag,
      target: target,
      domain: domain,
    );

    if (_shouldSkipDecision(decision)) {
      return null;
    }

    _recentDecisions.insert(0, decision);
    if (_recentDecisions.length > 15) {
      _recentDecisions.removeRange(15, _recentDecisions.length);
    }
    return decision;
  }

  bool _shouldSkipDecision(VpnRouteDecision next) {
    if (_recentDecisions.isEmpty) {
      return false;
    }

    final previous = _recentDecisions.first;
    final sameRoute = previous.type == next.type &&
        previous.outboundTag == next.outboundTag &&
        previous.target == next.target &&
        previous.domain == next.domain;
    if (!sameRoute) {
      return false;
    }

    return next.timestamp.difference(previous.timestamp).inSeconds.abs() < 2;
  }

  void _rememberDomain(String rawDomain, String address) {
    final domain = rawDomain.trim().replaceAll(RegExp(r'\.+$'), '');
    if (domain.isEmpty || address.trim().isEmpty) {
      return;
    }

    _domainByIp.remove(address);
    _domainByIp[address] = domain;
    while (_domainByIp.length > 256) {
      _domainByIp.remove(_domainByIp.keys.first);
    }
  }

  static String _extractTargetHost(String target) {
    if (target.startsWith('[')) {
      final closingIndex = target.indexOf(']');
      if (closingIndex > 0) {
        return target.substring(1, closingIndex);
      }
    }

    final parts = target.split(':');
    if (parts.length <= 2) {
      return parts.first;
    }
    return target;
  }
}

Future<String?> fetchVpnEgressIp() async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      responseType: ResponseType.plain,
      validateStatus: (status) => status != null && status >= 200 && status < 400,
    ),
  );
  const endpoints = [
    'https://api64.ipify.org?format=json',
    'https://api.ipify.org?format=json',
    'https://ifconfig.me/ip',
    'https://icanhazip.com',
  ];

  Object? lastError;
  for (final endpoint in endpoints) {
    try {
      final response = await dio.get<String>(endpoint);
      final value = _extractIp(response.data);
      if (value != null) {
        return value;
      }
    } catch (error) {
      lastError = error;
    }
  }

  if (lastError != null) {
    throw StateError('Unable to determine egress IP: $lastError');
  }
  throw const FormatException('Unable to determine egress IP');
}

String? _extractIp(String? payload) {
  if (payload == null) {
    return null;
  }

  final normalized = payload.trim();
  if (normalized.isEmpty) {
    return null;
  }

  final jsonCandidate = normalized.startsWith('{') ? normalized : null;
  if (jsonCandidate != null) {
    try {
      final decoded = jsonDecode(jsonCandidate);
      if (decoded is Map<String, dynamic>) {
        for (final key in ['ip', 'ip_addr', 'address']) {
          final candidate = decoded[key]?.toString().trim();
          if (candidate != null && InternetAddress.tryParse(candidate) != null) {
            return candidate;
          }
        }
      }
    } catch (_) {}
  }

  final firstLine = normalized.split('\n').first.trim();
  if (InternetAddress.tryParse(firstLine) != null) {
    return firstLine;
  }
  return null;
}
