import 'package:flutter/foundation.dart';

import 'cloud_provider_id.dart';

/// Shared base for concrete cloud provider implementations.
///
/// Phase 2 of the multi-provider refactor: keeps the existing single-class
/// architecture intact while carving out the surface that all providers must
/// expose. Subclasses declare their [providerId] and inherit namespaced
/// storage keys derived from it.
///
/// Phase 3 adds [DigitalOceanCloudProvider] as a sibling subclass. Common
/// behaviour will migrate down into this base as concrete duplication
/// emerges — we don't extract speculatively.
abstract class CloudProviderBase with ChangeNotifier {
  CloudProviderId get providerId;

  String get providerName => providerId.id;

  String get providerDisplayName => providerId.displayName;

  String get apiKeyStorageKey => providerId.apiKeyStorageKey;

  String get nodeRecordsStorageKey => providerId.nodeRecordsStorageKey;
}
