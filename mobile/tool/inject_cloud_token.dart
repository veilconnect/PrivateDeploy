import 'dart:io';

import 'package:hive/hive.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: inject_cloud_token.dart <box-dir> <token-file>');
    exit(1);
  }

  final boxDir = Directory(args[0]);
  final tokenFile = File(args[1]);

  if (!boxDir.existsSync()) {
    stderr.writeln('box dir not found: ${boxDir.path}');
    exit(1);
  }
  if (!tokenFile.existsSync()) {
    stderr.writeln('token file not found: ${tokenFile.path}');
    exit(1);
  }

  final token = tokenFile.readAsStringSync().trim();
  if (token.isEmpty) {
    stderr.writeln('token file is empty');
    exit(1);
  }

  Hive.init(boxDir.path);
  final box = await Hive.openBox('cloud');
  await box.put('vultr_api_key', token);
  await box.close();

  stdout.writeln('cloud.hive updated');
}
