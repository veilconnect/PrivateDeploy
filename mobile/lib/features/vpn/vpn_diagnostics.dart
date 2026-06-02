import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/network/managed_dns_defaults.dart';
import '../../services/vpn_native_service.dart';
import '../../shared/utils/logger.dart';

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
    this.dnsServerTag,
  });

  final DateTime timestamp;
  final VpnRouteDecisionType type;
  final String outboundType;
  final String outboundTag;
  final String target;
  final String? domain;
  final String? dnsServerTag;

  bool get isDirect => type == VpnRouteDecisionType.direct;

  bool get isDnsDecision => dnsServerTag != null;

  String get typeLabel =>
      isDnsDecision ? 'DNS' : (isDirect ? 'DIRECT' : 'PROXY');

  String get routeLabel {
    if (isDnsDecision) {
      return dnsDisplayLabel;
    }
    return isDirect ? '直连规则' : '代理规则 (${outboundTag.trim()})';
  }

  String get dnsDisplayLabel {
    return switch (dnsServerTag) {
      'dns-cn' => 'dns-cn',
      'dns-remote' => 'dns-remote',
      'dns-remote-google' => 'dns-remote-alt',
      'dns-direct' => 'dns-bootstrap',
      'dns-local' => 'dns-system',
      String tag => tag,
      null => '',
    };
  }

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
    final targetPort = _extractTargetPort(target);
    final domain = InternetAddress.tryParse(targetHost) == null
        ? targetHost
        : _domainByIp[targetHost];
    final dnsServerTag = _classifyDnsServerTag(
      targetHost: targetHost,
      targetPort: targetPort,
    );
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
      dnsServerTag: dnsServerTag,
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
    if (_isLoopbackPrivateDnsProbe(next.target)) {
      return true;
    }
    if (_isUrlTestProbe(next)) {
      return true;
    }
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

  static bool _isLoopbackPrivateDnsProbe(String target) {
    return _extractTargetPort(target) == 853 &&
        _isLoopbackHost(_extractTargetHost(target));
  }

  static int? _extractTargetPort(String target) {
    final targetValue = target.trim();
    if (targetValue.startsWith('[')) {
      final closingIndex = targetValue.indexOf(']');
      if (closingIndex <= 0 || closingIndex + 2 > targetValue.length) {
        return null;
      }
      return int.tryParse(targetValue.substring(closingIndex + 2));
    }

    final separatorIndex = targetValue.lastIndexOf(':');
    if (separatorIndex <= 0 || separatorIndex >= targetValue.length - 1) {
      return null;
    }
    return int.tryParse(targetValue.substring(separatorIndex + 1));
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized == '::1') {
      return true;
    }

    final address = InternetAddress.tryParse(host);
    return address?.isLoopback ?? false;
  }

  static bool _isUrlTestProbe(VpnRouteDecision decision) {
    final domain = decision.domain?.trim().toLowerCase();
    final host = decision.targetHost.trim().toLowerCase();
    final port = _extractTargetPort(decision.target);
    return (domain == 'www.gstatic.com' || host == 'www.gstatic.com') &&
        port == 80;
  }

  static String? _classifyDnsServerTag({
    required String targetHost,
    required int? targetPort,
  }) {
    final normalizedHost = targetHost.trim().toLowerCase();
    if (managedDnsRemoteHosts.contains(normalizedHost) && targetPort == 443) {
      return managedDnsRemoteTag;
    }
    if (managedDnsRemoteFallbackHosts.contains(normalizedHost) &&
        targetPort == 443) {
      return managedDnsRemoteFallbackTag;
    }
    if (managedDnsBootstrapHosts.contains(normalizedHost) &&
        (targetPort == 53 || targetPort == 853 || targetPort == 443)) {
      return managedDnsBootstrapTag;
    }
    if (managedDnsCnHosts.contains(normalizedHost) &&
        (targetPort == 53 || targetPort == 853 || targetPort == 443)) {
      return managedDnsCnTag;
    }
    if (targetPort == 53 || targetPort == 853) {
      return managedDnsLocalTag;
    }
    return null;
  }
}

Future<String?> fetchVpnEgressIp() async {
  const endpoints = [
    'https://api64.ipify.org?format=json',
    'https://api.ipify.org?format=json',
    'https://ifconfig.me/ip',
    'https://icanhazip.com',
  ];

  Object? lastError;
  for (final host in const ['1.1.1.1', '1.0.0.1']) {
    try {
      final value = await _probeCloudflareTraceViaLiteralIp(host);
      if (value == null) {
        AppLogger.debug(
          '[VpnDiagnostics] Literal IP probe returned no parseable payload for $host',
        );
      }
      if (value != null) {
        AppLogger.info(
          '[VpnDiagnostics] Egress probe succeeded via literal IP $host -> $value',
        );
        return value;
      }
    } catch (error) {
      AppLogger.warning(
        '[VpnDiagnostics] Literal IP probe failed for $host: $error',
      );
      lastError = error;
    }
  }

  final dio = _buildVpnEgressIpDio();
  for (final endpoint in endpoints) {
    try {
      final response = await dio.get<String>(endpoint);
      final value = extractVpnEgressIp(response.data);
      if (value == null) {
        AppLogger.debug(
          '[VpnDiagnostics] Egress probe returned unparseable payload from $endpoint: '
          '${response.data?.toString().replaceAll('\n', '\\n')}',
        );
      }
      if (value != null) {
        AppLogger.info(
          '[VpnDiagnostics] Egress probe succeeded via $endpoint -> $value',
        );
        return value;
      }
    } catch (error) {
      AppLogger.warning(
        '[VpnDiagnostics] Egress probe failed for $endpoint: $error',
      );
      lastError = error;
    }
  }

  if (lastError != null) {
    throw StateError('Unable to determine egress IP: $lastError');
  }
  throw const FormatException('Unable to determine egress IP');
}

Dio _buildVpnEgressIpDio() {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      responseType: ResponseType.plain,
      followRedirects: true,
      maxRedirects: 3,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 400,
    ),
  );
  return dio;
}

Future<String?> _probeCloudflareTraceViaLiteralIp(String host) async {
  Socket? rawSocket;
  SecureSocket? secureSocket;

  try {
    rawSocket = await Socket.connect(
      host,
      443,
      timeout: const Duration(seconds: 5),
    );
    secureSocket = await SecureSocket.secure(
      rawSocket,
      onBadCertificate: (_) => true,
      supportedProtocols: const ['http/1.1'],
    ).timeout(const Duration(seconds: 5));
    rawSocket = null;

    secureSocket.write(
      'GET /cdn-cgi/trace HTTP/1.1\r\n'
      'Host: $host\r\n'
      'User-Agent: PrivateDeploy/1.0\r\n'
      'Accept: */*\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    await secureSocket.flush();

    final bytes = BytesBuilder(copy: false);
    await for (final chunk
        in secureSocket.timeout(const Duration(seconds: 5))) {
      bytes.add(chunk);
    }

    final responseText = utf8.decode(
      bytes.takeBytes(),
      allowMalformed: true,
    );
    final separatorIndex = responseText.indexOf('\r\n\r\n');
    final body = separatorIndex >= 0
        ? responseText.substring(separatorIndex + 4)
        : responseText;
    return extractVpnEgressIp(body);
  } finally {
    await secureSocket?.close();
    await rawSocket?.close();
  }
}

String? extractVpnEgressIp(String? payload) {
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
          if (candidate != null &&
              InternetAddress.tryParse(candidate) != null) {
            return candidate;
          }
        }
      }
    } catch (_) {}
  }

  for (final line in normalized.split('\n')) {
    final trimmedLine = line.trim();
    if (!trimmedLine.startsWith('ip=')) {
      continue;
    }
    final candidate = trimmedLine.substring(3).trim();
    if (InternetAddress.tryParse(candidate) != null) {
      return candidate;
    }
  }

  final firstLine = normalized.split('\n').first.trim();
  if (InternetAddress.tryParse(firstLine) != null) {
    return firstLine;
  }
  return null;
}
