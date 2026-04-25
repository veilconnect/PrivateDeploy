import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tool/rewrite_profile_content.dart <hive_dir> <profile_name> <content_file>',
    );
    exitCode = 64;
    return;
  }

  final hiveDir = Directory(args[0]);
  final profileName = args[1];
  final contentFile = File(args[2]);

  if (!hiveDir.existsSync()) {
    stderr.writeln('Hive directory not found: ${hiveDir.path}');
    exitCode = 66;
    return;
  }
  if (!contentFile.existsSync()) {
    stderr.writeln('Content file not found: ${contentFile.path}');
    exitCode = 66;
    return;
  }

  final newContent = contentFile.readAsStringSync();

  Hive.init(hiveDir.path);
  final box = await Hive.openBox('profiles');
  try {
    var updated = false;
    for (final key in box.keys) {
      if (key == 'active_profile_id') {
        continue;
      }
      final raw = box.get(key);
      if (raw is! String) {
        continue;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        continue;
      }
      if (decoded['name']?.toString() != profileName) {
        continue;
      }

      decoded['content'] = newContent;
      decoded['updated_at'] = DateTime.now().toIso8601String();
      await box.put(key, jsonEncode(decoded));
      updated = true;
      stdout.writeln('Updated profile $profileName ($key)');
      break;
    }

    if (!updated) {
      stderr.writeln('Profile not found: $profileName');
      exitCode = 65;
      return;
    }

    await box.flush();
  } finally {
    await box.close();
  }
}
