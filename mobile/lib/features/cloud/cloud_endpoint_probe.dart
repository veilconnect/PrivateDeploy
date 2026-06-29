part of 'cloud_provider.dart';

// Endpoint latency probing: plain TCP Socket.connect reachability/latency
// measurement across a node's protocol ports (quick + benchmark modes). Pure
// top-level helpers, split out of cloud_provider.dart.

Future<CloudLatencyCheck> _defaultLatencyProbe(CloudInstance instance) async {
  return _probeCloudInstanceLatency(
    instance,
    mode: CloudProbeMode.quick,
  );
}

Future<CloudLatencyCheck> _defaultBenchmarkLatencyProbe(
  CloudInstance instance,
) async {
  return _probeCloudInstanceLatency(
    instance,
    mode: CloudProbeMode.benchmark,
  );
}

Future<CloudLatencyCheck> _probeCloudInstanceLatency(
  CloudInstance instance, {
  required CloudProbeMode mode,
}) async {
  final host = (() {
    final ipv4 = instance.ipv4?.trim();
    if (ipv4 != null && ipv4.isNotEmpty && ipv4 != '0.0.0.0') {
      return ipv4;
    }
    final ipv6 = instance.ipv6?.trim();
    if (ipv6 != null && ipv6.isNotEmpty) {
      return ipv6;
    }
    return null;
  })();
  final nodeInfo = instance.nodeInfo;
  if (!instance.isActive || host == null || host.isEmpty || nodeInfo == null) {
    return CloudLatencyCheck.failure(
      error: 'Node is not ready for latency testing yet',
      updatedAt: DateTime.now(),
      mode: mode,
    );
  }

  final targets = <({String label, int port})>[];
  void addTarget(String label, int port) {
    if (port <= 0) {
      return;
    }
    targets.add((label: label, port: port));
  }

  final supportedLabels = supportedCloudProbeEndpointsForCurrentPlatform(
    nodeInfo: nodeInfo,
  );
  if (supportedLabels.contains('Trojan')) {
    addTarget('Trojan', nodeInfo.trojanPort);
  }
  if (supportedLabels.contains('VLESS')) {
    addTarget('VLESS', nodeInfo.vlessPort);
  }
  if (supportedLabels.contains('Shadowsocks')) {
    addTarget('Shadowsocks', nodeInfo.ssPort);
  }

  if (targets.isEmpty) {
    final hasAnyPort = nodeInfo.ssPort > 0 ||
        nodeInfo.trojanPort > 0 ||
        nodeInfo.vlessPort > 0 ||
        nodeInfo.hyPort > 0;
    return CloudLatencyCheck.failure(
      error: hasAnyPort
          ? 'No TCP endpoint is available for testing'
          : '节点凭证已丢失(可能因重装应用)。请销毁后重建,或从备份恢复。',
      updatedAt: DateTime.now(),
      mode: mode,
    );
  }

  final targetResults = await Future.wait(
    targets.map(
      (target) => mode == CloudProbeMode.benchmark
          ? _runBenchmarkEndpointProbe(
              host: host,
              label: target.label,
              port: target.port,
            )
          : _runQuickEndpointProbe(
              host: host,
              label: target.label,
              port: target.port,
            ),
    ),
  );

  final successfulResults = targetResults
      .where((result) => result.latencyMs != null && result.scoreMs != null)
      .toList(growable: false)
    ..sort((a, b) => a.scoreMs!.compareTo(b.scoreMs!));
  final lastError = targetResults
      .map((result) => result.error)
      .whereType<String>()
      .where((error) => error.trim().isNotEmpty)
      .firstOrNull;

  if (successfulResults.isNotEmpty) {
    final fastest = successfulResults.first;
    return CloudLatencyCheck.success(
      latencyMs: fastest.latencyMs!,
      endpointLabel: fastest.label,
      updatedAt: DateTime.now(),
      mode: mode,
      sampleCount: fastest.sampleCount,
      successfulSamples: fastest.successfulSamples,
    );
  }

  return CloudLatencyCheck.failure(
    error: lastError ??
        (mode == CloudProbeMode.benchmark
            ? 'Benchmark test failed'
            : 'Latency test failed'),
    updatedAt: DateTime.now(),
    mode: mode,
  );
}

@visibleForTesting
List<String> supportedCloudProbeEndpointsForCurrentPlatform({
  required NodeInfo nodeInfo,
  TargetPlatform? targetPlatform,
}) {
  final _ = targetPlatform ?? defaultTargetPlatform;
  final labels = <String>[];
  // Intentionally do NOT require passwords/UUIDs here: the latency probe
  // below is a plain TCP Socket.connect measurement, not a protocol
  // handshake, so reachability is meaningful even when creds are empty in
  // the local record. This matters for DigitalOcean droplets — DO doesn't
  // expose user-data, so the app can't always recover every protocol's
  // secrets, leaving populated ports with empty passwords. Without this,
  // DO nodes show "No TCP endpoint is available for testing" even though
  // the ports are open and listening.
  if (nodeInfo.trojanPort > 0) {
    labels.add('Trojan');
  }
  // Keep the quick/benchmark selector on TCP-capable protocols only. Hy2 is
  // now allowed on Android, but this helper still measures reachability via
  // TCP Socket.connect, so it cannot rank a UDP-only protocol correctly.
  if (nodeInfo.vlessPort > 0) {
    labels.add('VLESS');
  }
  if (nodeInfo.ssPort > 0) {
    labels.add('Shadowsocks');
  }
  return labels;
}

Future<_CloudEndpointProbeResult> _runQuickEndpointProbe({
  required String host,
  required String label,
  required int port,
}) async {
  final latencyMs = await _probeTcpLatency(
    host: host,
    port: port,
    timeout: CloudProvider.quickProbeTimeout,
  );
  if (latencyMs == null) {
    return _CloudEndpointProbeResult(
      label: label,
      sampleCount: 1,
      successfulSamples: 0,
      error: '$label port $port unavailable',
    );
  }

  return _CloudEndpointProbeResult(
    label: label,
    latencyMs: latencyMs,
    sampleCount: 1,
    successfulSamples: 1,
    scoreMs: latencyMs,
  );
}

Future<_CloudEndpointProbeResult> _runBenchmarkEndpointProbe({
  required String host,
  required String label,
  required int port,
}) async {
  final samples = <int>[];
  for (var index = 0;
      index < CloudProvider.benchmarkProbeSamplesPerEndpoint;
      index += 1) {
    final latencyMs = await _probeTcpLatency(
      host: host,
      port: port,
      timeout: CloudProvider.benchmarkProbeTimeout,
    );
    if (latencyMs != null) {
      samples.add(latencyMs);
    }
  }

  if (samples.isEmpty) {
    return _CloudEndpointProbeResult(
      label: label,
      sampleCount: CloudProvider.benchmarkProbeSamplesPerEndpoint,
      successfulSamples: 0,
      error: '$label port $port did not answer benchmark probes',
    );
  }

  samples.sort();
  final medianLatencyMs = samples[samples.length ~/ 2];
  final failedSamples =
      CloudProvider.benchmarkProbeSamplesPerEndpoint - samples.length;
  return _CloudEndpointProbeResult(
    label: label,
    latencyMs: medianLatencyMs,
    sampleCount: CloudProvider.benchmarkProbeSamplesPerEndpoint,
    successfulSamples: samples.length,
    scoreMs: medianLatencyMs + (failedSamples * 250),
  );
}

Future<int?> _probeTcpLatency({
  required String host,
  required int port,
  required Duration timeout,
}) async {
  final stopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: timeout,
    );
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds.clamp(1, 9999).toInt();
  } catch (_) {
    stopwatch.stop();
    return null;
  } finally {
    socket?.destroy();
  }
}

class _CloudEndpointProbeResult {
  const _CloudEndpointProbeResult({
    required this.label,
    required this.sampleCount,
    required this.successfulSamples,
    this.latencyMs,
    this.scoreMs,
    this.error,
  });

  final String label;
  final int sampleCount;
  final int successfulSamples;
  final int? latencyMs;
  final int? scoreMs;
  final String? error;
}
