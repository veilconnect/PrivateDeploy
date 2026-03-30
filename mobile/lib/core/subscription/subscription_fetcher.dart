import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class SubscriptionFetchException implements Exception {
  const SubscriptionFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<Uint8List> fetchSubscriptionResponseData(
  String url, {
  HttpClient? client,
}) async {
  final uri = Uri.tryParse(url.trim());
  final isValidHttpUri = uri != null &&
      uri.hasAuthority &&
      (uri.scheme == 'http' || uri.scheme == 'https');
  if (!isValidHttpUri) {
    throw const SubscriptionFetchException('Please enter a valid http(s) URL');
  }

  final httpClient = client ?? HttpClient();
  final ownsClient = client == null;
  httpClient.connectionTimeout = const Duration(seconds: 15);

  try {
    final request = await httpClient.getUrl(uri);
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'PrivateDeploy/1.0');
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers.set(HttpHeaders.connectionHeader, 'close');

    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      await response.drain<void>();
      throw SubscriptionFetchException(
        'Subscription request failed with HTTP ${response.statusCode}',
      );
    }

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    if (result.isEmpty) {
      throw const SubscriptionFetchException('Subscription response was empty');
    }
    return result;
  } on TimeoutException {
    throw const SubscriptionFetchException('Subscription request timed out');
  } on SocketException {
    throw const SubscriptionFetchException(
      'Network error while fetching subscription',
    );
  } on HttpException catch (error) {
    final message = error.message.trim();
    throw SubscriptionFetchException(
      message.isEmpty
          ? 'Subscription response was interrupted'
          : 'Subscription response error: $message',
    );
  } finally {
    if (ownsClient) {
      httpClient.close(force: true);
    }
  }
}
