import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../shared/utils/logger.dart';

@immutable
class BundledRuleSetPaths {
  const BundledRuleSetPaths({
    this.geositeCnPath,
    this.geoipCnPath,
  });

  final String? geositeCnPath;
  final String? geoipCnPath;

  bool get hasCnRuleSets =>
      geositeCnPath != null &&
      geositeCnPath!.isNotEmpty &&
      geoipCnPath != null &&
      geoipCnPath!.isNotEmpty;
}

class BundledRuleSetRegistry {
  static const _geositeCnAssetPath = 'assets/rules/geosite-cn.srs';
  static const _geoipCnAssetPath = 'assets/rules/geoip-cn.srs';

  static BundledRuleSetPaths _paths = const BundledRuleSetPaths();

  static BundledRuleSetPaths get paths => _paths;

  static Future<void> ensureInstalled({
    AssetBundle? assetBundle,
  }) async {
    final bundle = assetBundle ?? rootBundle;

    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final ruleSetDirectory =
          Directory('${supportDirectory.path}/bundled_rule_sets');
      await ruleSetDirectory.create(recursive: true);

      final geositeCnPath = await _writeAsset(
        bundle: bundle,
        assetPath: _geositeCnAssetPath,
        targetFile: File('${ruleSetDirectory.path}/geosite-cn.srs'),
      );
      final geoipCnPath = await _writeAsset(
        bundle: bundle,
        assetPath: _geoipCnAssetPath,
        targetFile: File('${ruleSetDirectory.path}/geoip-cn.srs'),
      );

      _paths = BundledRuleSetPaths(
        geositeCnPath: geositeCnPath,
        geoipCnPath: geoipCnPath,
      );
    } catch (error, stackTrace) {
      _paths = const BundledRuleSetPaths();
      AppLogger.error(
        '[BundledRuleSetRegistry] Failed to install bundled rule sets',
        error,
        stackTrace,
      );
    }
  }

  static Future<String?> _writeAsset({
    required AssetBundle bundle,
    required String assetPath,
    required File targetFile,
  }) async {
    try {
      final assetData = await bundle.load(assetPath);
      final bytes = assetData.buffer.asUint8List();
      await targetFile.writeAsBytes(bytes, flush: true);
      return targetFile.path;
    } catch (error, stackTrace) {
      AppLogger.error(
        '[BundledRuleSetRegistry] Failed to copy $assetPath',
        error,
        stackTrace,
      );
      return null;
    }
  }

  @visibleForTesting
  static void setPathsForTesting(BundledRuleSetPaths paths) {
    _paths = paths;
  }
}
