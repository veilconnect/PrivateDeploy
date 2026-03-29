import 'package:logger/logger.dart';

class AppLogger {
  static bool _enabled = true;
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
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
