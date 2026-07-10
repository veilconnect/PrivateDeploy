import 'package:logger/logger.dart';

class AppLogger {
  static bool _enabled = true;

  // Opt-in release diagnostics. Off by default so release builds keep the
  // logger's DevelopmentFilter (drops logs unless kDebugMode) and a compact
  // stack depth. Turn on with:
  //   flutter build apk --release --dart-define=PRIVATEDEPLOY_VPNCORE_DEBUG_LOGS=true
  // or via `PRIVATEDEPLOY_VPNCORE_DEBUG_LOGS=1 mobile/scripts/build_release.sh`
  // to capture VpnProvider reconnect-trigger decisions from a signed release
  // APK on-device: ProductionFilter emits in release too, and the deeper method
  // count preserves full call chains.
  static const bool _debugLogs =
      bool.fromEnvironment('PRIVATEDEPLOY_VPNCORE_DEBUG_LOGS');

  static final Logger _logger = Logger(
    filter: _debugLogs ? ProductionFilter() : DevelopmentFilter(),
    printer: PrettyPrinter(
      methodCount: _debugLogs ? 8 : 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  static void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  static void debug(dynamic message) {
    if (!_enabled) {
      return;
    }
    _logger.d(message);
  }

  static void info(dynamic message) {
    if (!_enabled) {
      return;
    }
    _logger.i(message);
  }

  static void warning(dynamic message) {
    if (!_enabled) {
      return;
    }
    _logger.w(message);
  }

  static void error(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    if (!_enabled) {
      return;
    }
    _logger.e(message, error: error, stackTrace: stackTrace);
  }
}
