// Regression tests for the generated lightweight (Shadowsocks-only) deploy
// script. A lint/format pass once stripped the shell line-continuation
// backslashes from the multi-line `docker run` command inside the Dart string
// literal (a single `\` before a newline in a NON-raw Dart string is silently
// dropped by the compiler), which makes the generated cloud-init script start
// a broken container command on every deploy. These tests pin the exact
// continuation structure so any future "cleanup" of the string literal fails
// fast in CI instead of on a freshly provisioned VPS.
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/vultr_client.dart';

void main() {
  group('PortProfileAllocator.lightweightScript docker run continuations', () {
    const ssPort = 28388;
    const ssPassword = 's3cret-Pass_1';

    String script() => PortProfileAllocator.lightweightScript(
          ssPort: ssPort,
          ssPassword: ssPassword,
        );

    /// Returns the `docker run ...` block: the line starting with `docker run`
    /// plus every following line while the previous line ends with `\`.
    List<String> dockerRunBlock(String source) {
      final lines = source.split('\n');
      final start = lines.indexWhere((l) => l.startsWith('docker run '));
      expect(start, greaterThanOrEqualTo(0),
          reason: 'generated script must contain a docker run command');
      final block = <String>[lines[start]];
      var i = start;
      while (lines[i].endsWith(r'\')) {
        i++;
        expect(i, lessThan(lines.length),
            reason: 'continuation backslash on the last line of the script');
        block.add(lines[i]);
      }
      return block;
    }

    test('every intermediate line ends with " \\" and no trailing spaces', () {
      final block = dockerRunBlock(script());
      expect(block.length, greaterThanOrEqualTo(2),
          reason: 'docker run must span multiple continued lines');
      for (var i = 0; i < block.length - 1; i++) {
        final line = block[i];
        expect(line.endsWith(r' \'), isTrue,
            reason: 'continuation line must end with " \\": "$line"');
        expect(line, equals(line.trimRight()),
            reason: 'no whitespace allowed after the backslash: "$line"');
      }
      // The final line terminates the command: no dangling continuation.
      final last = block.last;
      expect(last.endsWith(r'\'), isFalse,
          reason: 'last docker run line must not continue: "$last"');
      expect(last, equals(last.trimRight()));
    });

    test('joined single-line command keeps image, ports and cipher intact', () {
      final block = dockerRunBlock(script());
      // Merge exactly the way a POSIX shell does: `\` + newline disappears.
      final joined = block
          .map((l) => l.endsWith(r'\') ? l.substring(0, l.length - 1) : l)
          .map((l) => l.trim())
          .join(' ');

      expect(joined, startsWith('docker run -d --name ss-server'));
      expect(joined, contains('--restart=always'));
      expect(joined, contains('-p $ssPort:$ssPort/tcp'));
      expect(joined, contains('-p $ssPort:$ssPort/udp'));
      expect(joined, contains('$pinnedShadowsocksImage ss-server'));
      expect(joined, contains('-s 0.0.0.0'));
      expect(joined, contains('-p $ssPort -k "$ssPassword"'));
      expect(joined, contains('-m aes-256-gcm'));
      // Image must come before its arguments (structure, not just presence).
      expect(
        joined.indexOf(pinnedShadowsocksImage),
        lessThan(joined.indexOf('-m aes-256-gcm')),
      );
    });

    test('no line in the whole script carries trailing whitespace', () {
      // Trailing spaces are how the original regression manifested (the
      // backslash vanished, its leading space stayed behind).
      for (final line in script().split('\n')) {
        expect(line, equals(line.trimRight()),
            reason: 'trailing whitespace in generated script line: "$line"');
      }
    });

    test('script is a well-formed bash cloud-init payload', () {
      final s = script();
      expect(s, startsWith('#!/bin/bash'));
      expect(s, contains('set -euo pipefail'));
      expect(s, contains('ufw allow $ssPort/tcp'));
      expect(s, contains('ufw allow $ssPort/udp'));
      expect(s, contains('echo "shadowsocks-deployed"'));
    });

    // Regression test: the script runs under `set -euo pipefail`. If the
    // explicit `docker pull` for the pinned Shadowsocks image isn't
    // fault-tolerant, a single transient pull failure (registry rate limit,
    // a momentary network blip on a fresh VPS) kills the whole script
    // before the container ever starts — with no self-heal, since the
    // script never runs again. Mirrors the same fix + test on the desktop
    // side (bridge/cloud/deploy/deploy_test.go) and the multi-protocol
    // template (vultr_deploy_test.dart).
    test('docker pull failure does not abort the script', () {
      final s = script();
      final idx = s.indexOf('docker pull --quiet');
      expect(idx, greaterThanOrEqualTo(0),
          reason: 'expected a docker pull for the pinned Shadowsocks image');
      final lineEnd = s.indexOf('\n', idx);
      final line = s.substring(idx, lineEnd < 0 ? s.length : lineEnd);
      expect(line.trim(), endsWith('|| true'),
          reason:
              'docker pull for Shadowsocks must tolerate failure, got line: $line');
    });
  });
}
