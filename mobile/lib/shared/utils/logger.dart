import 'package:logger/logger.dart';

class AppLogger {
  static bool _enabled = true;
  static final Logger _logger = Logger(
    // TEMP(diagnostics): ProductionFilter emits logs in release builds too (the
    // default DevelopmentFilter drops everything unless kDebugMode). Needed to
    // capture VpnProvider reconnect-trigger decisions from a signed release APK
    // on-device. Revert to the default filter before merge.
    filter: ProductionFilter(),
    printer: PrettyPrinter(
      methodCount: 8,
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
