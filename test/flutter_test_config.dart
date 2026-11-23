import 'dart:async';
import 'dart:io';

import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/services/cold_start_tail_cipher.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/remove_test_dir.dart';

import 'support/memory_sealed_files.dart';

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
  // The app has one dock and nothing stored chooses another
  // (dock_single_test.dart). The classic bar it replaced is unreachable in
  // the app; the suites written for it still mount it through this seam
  // until they are ported, and the dock's own suites opt in with
  // resetForTesting(gestureDock: true).
  FeatureFlags.instance.resetForTesting();
  // The Agents section is switched off in the app; its suites still test it.
  FeatureFlags.instance.agentsSection = true;
  // Drafts, the outbox and the other sealed local files live in memory: a
  // widget test's fake-async zone never completes real file I/O. Their key
  // is in the mocked secure storage, so a test that resets it starts with
  // no readable file.
  MemorySealedFileIo.install();
  // Large files too are sealed and opened on the test's own isolate: the
  // fake-async zone of a widget test never sees another isolate answer.
  ColdStartTailCipher.debugOnCallingIsolate = true;
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
      await removeTestDir(databaseDirectory);
    } on FileSystemException {
      // A failed test may leave a native handle alive until its process exits.
    }
  }
}
