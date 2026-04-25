import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../shared/utils/logger.dart';
import 'cloud_node_record.dart';
import 'cloud_provider_id.dart';
import 'vultr_client.dart';
import 'vultr_deploy.dart';

const String sshAuthMethodPassword = 'password';

bool hasValidSshAccessConfig(Map<String, String> extra) {
  final host = extra['host']?.trim() ?? '';
  final username = extra['username']?.trim() ?? '';
  final password = extra['password']?.trim() ?? '';
  return host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
}

Map<String, String> normalizeSshAccessConfig({
  required String host,
  required String port,
  required String username,
  required String password,
}) {
  final normalizedPort = int.tryParse(port.trim());
  return <String, String>{
    'host': host.trim(),
    'port': normalizedPort == null || normalizedPort <= 0
        ? '22'
        : normalizedPort.toString(),
    'username': username.trim(),
    'authMethod': sshAuthMethodPassword,
    'password': password.trim(),
  };
}

String sshAccessSummary(Map<String, String> extra) {
  final username = extra['username']?.trim();
  final host = extra['host']?.trim();
  final port = extra['port']?.trim();
  if (host == null || host.isEmpty) {
    return '';
  }
  final effectiveUser = (username == null || username.isEmpty) ? 'root' : username;
  final effectivePort = (port == null || port.isEmpty) ? '22' : port;
  return '$effectiveUser@$host:$effectivePort';
}

class SshDeployResult {
  const SshDeployResult({
    required this.record,
    required this.lightweight,
  });

  final VultrNodeRecord record;
  final bool lightweight;
}

class _SshServerInfo {
  const _SshServerInfo({
    required this.os,
    required this.arch,
    required this.memoryMb,
  });

  final String os;
  final String arch;
  final int memoryMb;
}

Future<void> testSshConnection(Map<String, String> extra) async {
  final client = await _connect(extra);
  try {
    await client.authenticated;
    final result = await client.runWithResult(
      r'''sh -lc 'echo connected' ''',
    );
    final stdout = utf8.decode(result.stdout).trim();
    final stderr = utf8.decode(result.stderr).trim();
    if (stdout != 'connected') {
      throw StateError(
        'SSH connection test failed'
        ' (exit=${result.exitCode}, stdout="$stdout", stderr="$stderr")',
      );
    }
  } finally {
    client.close();
  }
}

Future<SshDeployResult> deployNodeViaSsh({
  required Map<String, String> extra,
  required String label,
}) async {
  final normalized = _validatedAccess(extra);
  final client = await _connect(normalized);
  try {
    await client.authenticated;
    final server = await _detectServer(client);
    final bundle = await VultrDeploymentBuilder.build(
      planRam: server.memoryMb,
      portProfile:
          normalized['portProfile']?.trim().isNotEmpty == true
              ? normalized['portProfile']!.trim()
              : PortProfileAllocator.randomProfile,
    );

    await _runScript(client, bundle.userData);

    final tcpPorts = <int>[
      bundle.nodeRecord['ssPort'] as int? ?? 0,
      if (!bundle.lightweight) ...[
        bundle.nodeRecord['vlessPort'] as int? ?? 0,
        bundle.nodeRecord['trojanPort'] as int? ?? 0,
      ],
    ].where((port) => port > 0).toList(growable: false);
    final udpPorts = <int>[
      if (!bundle.lightweight) bundle.nodeRecord['hyPort'] as int? ?? 0,
    ].where((port) => port > 0).toList(growable: false);

    await _waitForRemoteListeners(
      client,
      tcpPorts: tcpPorts,
      udpPorts: udpPorts,
    );
    await _waitForTcpPorts(normalized['host']!, tcpPorts);

    final host = normalized['host']!;
    final instanceId = 'cloud-ssh-${host.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-')}-${DateTime.now().millisecondsSinceEpoch}';
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final record = VultrNodeRecord(
      instanceId: instanceId,
      provider: CloudProviderId.ssh,
      label: label.isEmpty ? 'ssh-$host' : label,
      region: host,
      plan: 'ssh-deploy',
      ssPort: bundle.nodeRecord['ssPort'] as int? ?? 0,
      ssPassword: bundle.nodeRecord['ssPassword']?.toString() ?? '',
      hyPort: bundle.nodeRecord['hyPort'] as int? ?? 0,
      hyPassword: bundle.nodeRecord['hyPassword']?.toString() ?? '',
      hyServerName: bundle.nodeRecord['hysteriaServerName']?.toString() ?? '',
      vlessPort: bundle.nodeRecord['vlessPort'] as int? ?? 0,
      vlessUuid: bundle.nodeRecord['vlessUUID']?.toString() ?? '',
      vlessPublicKey: bundle.nodeRecord['vlessPublicKey']?.toString() ?? '',
      vlessShortId: bundle.nodeRecord['vlessShortId']?.toString() ?? '',
      vlessServerName: bundle.nodeRecord['vlessServerName']?.toString() ?? '',
      trojanPort: bundle.nodeRecord['trojanPort'] as int? ?? 0,
      trojanPassword: bundle.nodeRecord['trojanPassword']?.toString() ?? '',
      trojanServerName: bundle.nodeRecord['trojanServerName']?.toString() ?? '',
      ipv4: host,
      createdAt: createdAt,
      portProfile:
          bundle.nodeRecord['portProfile']?.toString() ??
          PortProfileAllocator.randomProfile,
      planRam: bundle.nodeRecord['planRam'] as int? ?? server.memoryMb,
    );
    return SshDeployResult(record: record, lightweight: bundle.lightweight);
  } finally {
    client.close();
  }
}

Future<SSHClient> _connect(Map<String, String> extra) async {
  final normalized = _validatedAccess(extra);
  final host = normalized['host']!;
  final port = int.parse(normalized['port']!);
  final username = normalized['username']!;
  final password = normalized['password']!;
  final socket = await SSHSocket.connect(host, port);
  return SSHClient(
    socket,
    username: username,
    onPasswordRequest: () => password,
  );
}

Map<String, String> _validatedAccess(Map<String, String> extra) {
  final normalized = normalizeSshAccessConfig(
    host: extra['host'] ?? '',
    port: extra['port'] ?? '22',
    username: extra['username'] ?? 'root',
    password: extra['password'] ?? '',
  );
  if (!hasValidSshAccessConfig(normalized)) {
    throw StateError('SSH host, username, and password are required');
  }
  return normalized;
}

Future<_SshServerInfo> _detectServer(SSHClient client) async {
  const command = r'''sh -lc 'os=""; if [ -f /etc/os-release ]; then . /etc/os-release; os="${ID:-}"; fi; arch="$(uname -m 2>/dev/null || true)"; mem="$(awk '"'"'/MemTotal/ {printf "%d", $2/1024}'"'"' /proc/meminfo 2>/dev/null || true)"; printf "{\"os\":\"%s\",\"arch\":\"%s\",\"memoryMb\":%s}\n" "$os" "$arch" "${mem:-0}"' ''';
  final result = await client.runWithResult(command);
  final raw = utf8.decode(result.stdout).trim();
  final stderr = utf8.decode(result.stderr).trim();
  if (raw.isEmpty) {
    throw StateError(
      'SSH server detection failed'
      ' (exit=${result.exitCode}, stderr="$stderr")',
    );
  }
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return _SshServerInfo(
      os: decoded['os']?.toString() ?? '',
      arch: decoded['arch']?.toString() ?? '',
      memoryMb: int.tryParse(decoded['memoryMb']?.toString() ?? '') ?? 0,
    );
  } catch (error) {
    AppLogger.warning(
      '[SshDeployer] Failed to parse server info "$raw": $error',
    );
    return const _SshServerInfo(os: '', arch: '', memoryMb: 0);
  }
}

Future<void> _runScript(SSHClient client, String script) async {
  final session = await client.execute('bash -se');
  final stdoutFuture =
      utf8.decoder.bind(session.stdout.cast<List<int>>()).join();
  final stderrFuture =
      utf8.decoder.bind(session.stderr.cast<List<int>>()).join();
  const successMarker = '__PD_SSH_OK__';
  final wrappedScript = '$script\nprintf "$successMarker\\n"\n';
  final scriptBytes = Uint8List.fromList(utf8.encode(wrappedScript));
  await session.stdin.addStream(Stream<Uint8List>.value(scriptBytes));
  await session.stdin.close();
  await session.done;
  final stdout = await stdoutFuture;
  final stderr = await stderrFuture;
  if (!stdout.contains(successMarker)) {
    final message = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    throw StateError(
      'SSH deployment script failed'
      ' (exit=${session.exitCode})'
      '${message.isEmpty ? '' : ': $message'}',
    );
  }
}

Future<void> _waitForRemoteListeners(
  SSHClient client, {
  required List<int> tcpPorts,
  required List<int> udpPorts,
}) async {
  if (tcpPorts.isEmpty && udpPorts.isEmpty) {
    return;
  }

  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    if (await _remoteListenersReady(
      client,
      tcpPorts: tcpPorts,
      udpPorts: udpPorts,
    )) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  throw StateError('Deployment finished, but the server listeners are still not ready');
}

Future<bool> _remoteListenersReady(
  SSHClient client, {
  required List<int> tcpPorts,
  required List<int> udpPorts,
}) async {
  final checks = <String>[
    for (final port in tcpPorts) 'ss -ltnH "( sport = :$port )" | grep -q .',
    for (final port in udpPorts) 'ss -lunH "( sport = :$port )" | grep -q .',
  ];
  if (checks.isEmpty) {
    return true;
  }

  const readyMarker = '__PD_READY__';
  const waitMarker = '__PD_WAIT__';
  final result = await client.runWithResult(
    "sh -lc '${checks.join(' && ')} && echo $readyMarker || echo $waitMarker'",
  );
  final stdout = utf8.decode(result.stdout).trim();
  return stdout.contains(readyMarker);
}

Future<void> _waitForTcpPorts(String host, List<int> ports) async {
  if (ports.isEmpty) {
    return;
  }

  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    final allOpen = await Future.wait(
      ports.map((port) => _isPortOpen(host, port)),
    );
    if (allOpen.every((open) => open)) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  throw StateError('Deployment finished, but the server TCP ports are still closed');
}

Future<bool> _isPortOpen(String host, int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    await socket?.close();
  }
}
