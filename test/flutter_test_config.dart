import 'dart:async';
import 'dart:io';

import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Living bot faces animate continuously while visible; whole-screen tests
  // need a settled frame. Motion tests opt back in.
  debugLivingBotFacesStill = true;
  sqfliteFfiInit();
  final databaseDirectory = await Directory.systemTemp.createTemp(
    'hermes-sqflite-worker-',
  );
  await databaseFactoryFfi.setDatabasesPath(databaseDirectory.path);
  sqflite.databaseFactory = databaseFactoryFfi;
  try {
    await testMain();
  } finally {
    try {
      await databaseDirectory.delete(recursive: true);
    } on FileSystemException {
      // A failed test may leave a native handle alive until its process exits.
    }
  }
}
