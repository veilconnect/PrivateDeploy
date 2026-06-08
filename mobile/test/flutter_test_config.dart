import 'dart:async';

import 'package:privatedeploy_mobile/shared/utils/logger.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppLogger.setEnabled(false);
  await testMain();
}
