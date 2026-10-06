import 'dart:async';
import 'dart:io';

import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Living bot faces animate continuously while visible; whole-screen tests
  // need a settled frame. Motion tests opt back in.
  debugLivingBotFacesStill = true;
  // Same for the header mascot: still poses, no frame timers.
  debugMascotSpritesStill = true;
  // The shared pool lingers 5 min after the last release in the app; widget
  // suites keep the immediate close so no timer outlives the tree. Pool and
  // listener tests opt in with SharedGatewayPool.forTesting(linger: …).
  SharedGatewayPool.debugDefaultLinger = Duration.zero;
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
