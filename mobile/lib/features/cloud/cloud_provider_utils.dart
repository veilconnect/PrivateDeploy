String cloudProviderMessageFromError(Object error) {
  if (error is StateError) {
    return error.message.toString();
  }
  return error.toString();
}

bool shouldKeepCloudApiKeyOnError(Object error) {
  final message = cloudProviderMessageFromError(error).toLowerCase();
  const authIndicators = [
    '401',
    '403',
    'permission denied',
    'forbidden',
    'unauthorized',
    'invalid api key',
  ];
  const transientIndicators = [
    'timeout',
    'connection failed',
    'connection refused',
    'socket exception',
    'failed host lookup',
    'failed to connect',
    'network is unreachable',
    'operation canceled',
    'certificate',
  ];

  if (authIndicators.any((needle) => message.contains(needle))) {
    return false;
  }

  if (transientIndicators.any((needle) => message.contains(needle))) {
    return true;
  }

  return false;
}

int cloudJsonIntValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value != null) {
      final parsed = int.tryParse(value.toString());
      if (parsed != null) {
        return parsed;
      }
    }
  }
  return 0;
}

bool isBlankCloudValue(String? value) {
  return value == null || value.trim().isEmpty;
}

List<int> preferredCloudOsIds(Map<String, dynamic> osData) {
  final list = (osData['os'] as List?) ?? const [];

  final oses = list
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList();

  final matches = <int>[];

  void pushUnique(int osId) {
    if (!matches.contains(osId)) {
      matches.add(osId);
    }
  }

  bool matchesCondition(String text, String expected) {
    return text.toLowerCase().contains(expected.toLowerCase());
  }

  void collect(bool Function(String name, String family) matchesCandidate) {
    for (final os in oses) {
      final name = (os['name'] ?? '').toString();
      final family = (os['family'] ?? '').toString();
      final id = cloudJsonIntValue(os, const ['id']);
      if (isBlankCloudValue(name) || id <= 0) {
        continue;
      }

      if (matchesCandidate(name, family)) {
        pushUnique(id);
      }
    }
  }

  collect((name, _) {
    return matchesCondition(name, 'debian') && matchesCondition(name, '11');
  });
  collect((name, family) {
    return matchesCondition(family, 'ubuntu') &&
        matchesCondition(name, '20.04');
  });
  collect((_, family) => matchesCondition(family, 'debian'));
  collect((_, family) => matchesCondition(family, 'ubuntu'));

  if (matches.isNotEmpty) {
    return matches;
  }

  for (final os in oses) {
    final id = cloudJsonIntValue(os, const ['id']);
    if (id > 0) {
      pushUnique(id);
    }
  }

  return matches;
}
