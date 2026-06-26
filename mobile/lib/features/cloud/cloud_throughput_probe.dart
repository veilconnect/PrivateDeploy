import 'dart:async';
import 'dart:io';

// Cloudflare speed endpoint accepts ?bytes=N. We request a large file per
// connection so slow-start isn't the bottleneck; combined with parallel
// connections this more closely matches real-world multi-stream loads
// (browsers, Netflix, etc.) than a single 2 MB download.
const String defaultCloudBenchmarkUrl =
    'https://speed.cloudflare.com/__down?bytes=25000000';
const Duration defaultCloudBenchmarkTimeout = Duration(seconds: 10);

/// How long the aggregate parallel download is allowed to run before we
/// compute throughput from whatever has arrived so far. Tuned to let
/// TCP windows grow past slow-start on a typical intercontinental path.
const Duration defaultCloudBenchmarkSampleWindow = Duration(seconds: 6);

/// Number of parallel HTTP connections used when sampling throughput. A
/// single connection is dominated by per-RTT window growth on long paths
/// (for example, a distant client and VPS region); 4 parallel streams reliably saturate
/// the link like a real browser/CDN workload.
const int defaultCloudBenchmarkConcurrency = 4;

class CloudThroughputSample {
  const CloudThroughputSample({
    required this.bytes,
    required this.elapsedMs,
    this.speedMbps,
    this.error,
  });

  final int bytes;
  final int elapsedMs;
  final double? speedMbps;
  final String? error;

  bool get hasSample => speedMbps != null && speedMbps! > 0;
}

/// Measure effective aggregate download throughput with [concurrency]
/// parallel HTTP streams. Aggregates bytes across all streams and divides
/// by wall-clock elapsed time, matching how browsers load pages and how
/// fast.com reports Netflix CDN throughput.
///
/// Stops once [sampleWindow] has elapsed (even if the individual downloads
/// haven't finished their requested byte count) so the total probe time
/// stays bounded and predictable.
Future<CloudThroughputSample> runCloudThroughputProbe({
  String testUrl = defaultCloudBenchmarkUrl,
  Duration timeout = defaultCloudBenchmarkTimeout,
  Duration sampleWindow = defaultCloudBenchmarkSampleWindow,
  int concurrency = defaultCloudBenchmarkConcurrency,
  HttpClient? client,
}) async {
  // If the caller passes a custom client we reuse it (and we do NOT close
  // it); otherwise each parallel stream gets its own client so they don't
  // serialize on a single HttpClient's connection pool.
  final sharedClient = client;
  final ownedClients = <HttpClient>[];

  HttpClient clientForStream() {
    if (sharedClient != null) {
      return sharedClient;
    }
    final c = HttpClient();
    c.connectionTimeout = timeout;
    ownedClients.add(c);
    return c;
  }

  final stopwatch = Stopwatch()..start();
  final byteCounts = List<int>.filled(concurrency, 0, growable: false);
  final errors = <String>[];

  Future<void> runStream(int index) async {
    try {
      final streamClient = clientForStream();
      final request =
          await streamClient.getUrl(Uri.parse(testUrl)).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.userAgentHeader, 'PrivateDeploy-Mobile');

      final response = await request.close().timeout(timeout);
      await for (final chunk in response) {
        byteCounts[index] += chunk.length;
        if (stopwatch.elapsed >= sampleWindow) {
          // Abandon remaining bytes on this stream; the sample window
          // bounds how long the user waits.
          break;
        }
      }
    } on TimeoutException {
      errors.add('stream $index timed out');
    } catch (e) {
      errors.add('stream $index failed: $e');
    }
  }

  try {
    final futures = List.generate(concurrency, runStream);
    // Wait for all streams OR the sample window to elapse, whichever first.
    await Future.any([
      Future.wait(futures),
      Future.delayed(sampleWindow),
    ]);
    stopwatch.stop();

    final totalBytes = byteCounts.fold<int>(0, (sum, v) => sum + v);
    if (totalBytes == 0 && errors.isNotEmpty) {
      return _buildThroughputSample(
        bytes: 0,
        elapsedMs: stopwatch.elapsedMilliseconds,
        error: errors.first,
      );
    }

    return _buildThroughputSample(
      bytes: totalBytes,
      elapsedMs: stopwatch.elapsedMilliseconds,
      // Surface stream errors as a warning only if every stream got bytes.
      error: errors.isEmpty ? null : errors.first,
    );
  } finally {
    for (final c in ownedClients) {
      c.close(force: true);
    }
  }
}

CloudThroughputSample _buildThroughputSample({
  required int bytes,
  required int elapsedMs,
  String? error,
}) {
  if (bytes <= 0 || elapsedMs <= 0) {
    return CloudThroughputSample(
      bytes: bytes,
      elapsedMs: elapsedMs,
      error: error ?? 'Download sample returned no data',
    );
  }

  final elapsedSeconds = elapsedMs / 1000.0;
  final speedMbps = (bytes * 8) / elapsedSeconds / 1000000.0;
  return CloudThroughputSample(
    bytes: bytes,
    elapsedMs: elapsedMs,
    speedMbps: speedMbps,
    error: error,
  );
}
