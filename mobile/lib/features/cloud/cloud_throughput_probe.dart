import 'dart:async';
import 'dart:io';

const String defaultCloudBenchmarkUrl =
    'https://speed.cloudflare.com/__down?bytes=2000000';
const Duration defaultCloudBenchmarkTimeout = Duration(seconds: 10);

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

Future<CloudThroughputSample> runCloudThroughputProbe({
  String testUrl = defaultCloudBenchmarkUrl,
  Duration timeout = defaultCloudBenchmarkTimeout,
  HttpClient? client,
}) async {
  final ownsClient = client == null;
  final httpClient = client ?? HttpClient();
  httpClient.connectionTimeout = timeout;

  final stopwatch = Stopwatch()..start();
  var downloadedBytes = 0;

  try {
    final request =
        await httpClient.getUrl(Uri.parse(testUrl)).timeout(timeout);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    request.headers.set(HttpHeaders.userAgentHeader, 'PrivateDeploy-Mobile');

    final response = await request.close().timeout(timeout);
    await for (final chunk in response.timeout(timeout)) {
      downloadedBytes += chunk.length;
    }

    stopwatch.stop();
    return _buildThroughputSample(
      bytes: downloadedBytes,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  } on TimeoutException {
    stopwatch.stop();
    return _buildThroughputSample(
      bytes: downloadedBytes,
      elapsedMs: stopwatch.elapsedMilliseconds,
      error: 'Download sample timed out',
    );
  } catch (e) {
    stopwatch.stop();
    return _buildThroughputSample(
      bytes: downloadedBytes,
      elapsedMs: stopwatch.elapsedMilliseconds,
      error: 'Download sample failed: $e',
    );
  } finally {
    if (ownsClient) {
      httpClient.close(force: true);
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
