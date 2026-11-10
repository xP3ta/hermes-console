// Android side of «Guardar en el móvil» (orden DESCARGAS-DIRECTAS and its
// addendum from the Fold), read as a contract like the 1.2.15 provider test
// (attachment_document_preview_android_test, untouched):
// - the same channel name on both sides;
// - Android's own «Guardar como» (ACTION_CREATE_DOCUMENT, openable, the name
//   suggested), registered with the activity before it starts;
// - writes with ContentResolver.openOutputStream, by blocks, and a document
//   half written is deleted;
// - only the app's private files can be copied out;
// - opening and sharing grant only reading, to that one Uri;
// - no storage permission asked, the storage permissions of the manifest
//   exactly those of 1.3.1, and no FileProvider of SFTP downloads any more;
// - each step leaves a `[save]` line in logcat; a pick still pending never
//   blocks the next one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _kotlin = 'android/app/src/main/kotlin/com/hermesagent/hermes_android';

String _read(String path) => File(path).readAsStringSync();

/// A permission about shared storage or media.
final _storagePermission = RegExp(r'STORAGE|READ_MEDIA_|ACCESS_MEDIA_LOCATION');

void main() {
  final handler = _read('$_kotlin/HermesSaveToDeviceHandler.kt');
  final activity = _read('$_kotlin/MainActivity.kt');
  final manifest = _read('android/app/src/main/AndroidManifest.xml');
  final dart = _read('lib/core/services/save_to_device.dart');

  test('one channel, the same name on both sides', () {
    expect(
      handler,
      contains('const val CHANNEL_NAME = "hermes/save_to_device"'),
    );
    expect(dart, contains("MethodChannel('hermes/save_to_device')"));
    expect(activity, contains('HermesSaveToDeviceHandler.CHANNEL_NAME'));
    for (final method in const [
      '"pick"',
      '"cancelPick"',
      '"begin"',
      '"write"',
      '"finish"',
      '"abort"',
      '"copy"',
      '"view"',
      '"share"',
      '"delete"',
    ]) {
      expect(handler, contains('$method ->'), reason: method);
    }
  });

  test('Android\'s own «Guardar como», registered before the activity '
      'starts', () {
    expect(handler, contains('Intent(Intent.ACTION_CREATE_DOCUMENT)'));
    expect(handler, contains('addCategory(Intent.CATEGORY_OPENABLE)'));
    expect(handler, contains('putExtra(Intent.EXTRA_TITLE, input.first)'));
    expect(handler, contains('Activity.RESULT_OK'));
    // A property initializer: registerForActivityResult must run before
    // the activity is STARTED.
    expect(
      RegExp(
        r'private val saveCreateDocument =\s*'
        r'registerForActivityResult\(SaveCreateDocument\(\)\)',
      ).hasMatch(activity),
      isTrue,
    );
    expect(
      activity,
      contains('saveToDeviceHandler?.onDocumentCreated(uri)'),
    );
    expect(activity, contains('saveCreateDocument.launch(name to mimeType)'));
    expect(activity, contains('saveToDeviceHandler?.close()'));
  });

  test('written by blocks to the document; half a document is deleted', () {
    expect(handler, contains('resolver.openOutputStream(uri, "wt")'));
    expect(handler, contains('resolver.openOutputStream(target, "wt")'));
    expect(handler, contains('COPY_BUFFER_BYTES = 256 * 1024'));
    expect(handler, contains('ByteArray(COPY_BUFFER_BYTES)'));
    expect(
      handler,
      contains('DocumentsContract.deleteDocument(resolver, uri)'),
    );
    // Copy and abort delete what they leave half written.
    expect(
      RegExp(r'catch \(error: Throwable\) \{[^}]*deleteDocument\(target\)')
          .hasMatch(handler),
      isTrue,
    );
    expect(
      RegExp(r'"abort" ->').hasMatch(handler) &&
          RegExp(r'deleteDocument\(writer\.uri\)').hasMatch(handler),
      isTrue,
    );
    // Never whole in memory.
    expect(handler, isNot(contains('readBytes()')));
    expect(handler, isNot(contains('readAllBytes')));
  });

  test('only the app\'s private files are copied out', () {
    expect(handler, contains('applicationContext.dataDir.canonicalFile'));
    expect(handler, contains('File(path).canonicalFile'));
    expect(handler, contains('startsWith(root.path + File.separator)'));
    expect(handler, contains('throw SecurityException('));
  });

  test('opening and sharing grant reading only, to that Uri', () {
    expect(handler, contains('Intent(Intent.ACTION_VIEW)'));
    expect(handler, contains('Intent(Intent.ACTION_SEND)'));
    expect(handler, contains('putExtra(Intent.EXTRA_STREAM, uri)'));
    expect(
      RegExp('FLAG_GRANT_READ_URI_PERMISSION').allMatches(handler).length,
      greaterThanOrEqualTo(3),
    );
    expect(handler, isNot(contains('FLAG_GRANT_WRITE_URI_PERMISSION')));
    expect(handler, isNot(contains('FLAG_GRANT_PERSISTABLE_URI_PERMISSION')));
  });

  test('storage permissions stay as in 1.3.1; no SFTP file provider left', () {
    // «Guardar como» needs no storage permission: nothing is asked for.
    expect(handler, isNot(contains('requestPermissions')));
    expect(handler, isNot(contains('_EXTERNAL_STORAGE')));
    expect(activity, isNot(contains('_EXTERNAL_STORAGE')));
    // Every <uses-permission> about storage or media in the manifest,
    // spaces collapsed, is exactly what 1.3.1 (f80fae72) had: WRITE only
    // up to Android 9 (maxSdkVersion 28, for «Guardar en galería»), READ
    // removed from the merged manifest. Nothing added (no MANAGE_*, no
    // READ_MEDIA_*, no WRITE for newer Android).
    final storage = [
      for (final m in RegExp(r'<uses-permission\b[^>]*>').allMatches(manifest))
        if (_storagePermission.hasMatch(m.group(0)!))
          m.group(0)!.replaceAll(RegExp(r'\s+'), ' '),
    ];
    expect(storage, [
      '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" />',
      '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" tools:node="remove" />',
    ]);
    // DESCARGAS-DIRECTAS removed the private copies, so their provider,
    // its class and its paths went with them.
    expect(manifest, isNot(contains('SftpDownloadsFileProvider')));
    expect(manifest, isNot(contains('sftp_downloads')));
    expect(File('$_kotlin/SftpDownloadsFileProvider.kt').existsSync(), isFalse);
    expect(
      File('$_kotlin/HermesSftpDownloadsHandler.kt').existsSync(),
      isFalse,
    );
    expect(
      File('android/app/src/main/res/xml/sftp_downloads_paths.xml')
          .existsSync(),
      isFalse,
    );
    // The generated media provider is the only FileProvider, as in 1.2.15.
    expect(RegExp(r'<provider\b').allMatches(manifest), hasLength(1));
    expect(manifest, contains('generated_file_provider'));
  });

  test('each step leaves a [save] line in logcat', () {
    for (final line in const [
      '"[save] pick received"',
      '"[save] pick launching mime=',
      '"[save] pick launched"',
      '"[save] pick failed type=',
      '"[save] picker result uri=',
      '"[save] begin writer=',
      '"[save] finish writer=',
      '"[save] copy start from=',
      '"[save] copy end bytes=',
      '"[save] \$method failed type=',
    ]) {
      expect(handler, contains(line), reason: line);
    }
    expect(handler, contains('private const val TAG = "HermesSave"'));
    expect(activity, contains('"[save] launcher state='));
    // Never a Uri or a path in a log line.
    for (final log in RegExp(r'Log\.[iw]\(TAG, ([^\n]*)').allMatches(handler)) {
      expect(log.group(1), isNot(contains(r'$uri')), reason: log.group(0));
      expect(log.group(1), isNot(contains(r'$path')), reason: log.group(0));
      expect(log.group(1), isNot(contains(r'$name')), reason: log.group(0));
    }
  });

  test('a pick still pending never blocks the next one', () {
    // The old «Guardar en…» answered BUSY forever after a lost result.
    expect(handler, isNot(contains('"busy"')));
    expect(handler, contains('pendingPick?.let { stale ->'));
    expect(handler, contains('stale.error(PICKER_NOT_SHOWN, "superseded"'));
    // Anything that stops the dialog from showing is an answer, not silence.
    expect(handler, contains('catch (error: RuntimeException)'));
    expect(
      handler,
      contains('result.error(PICKER_NOT_SHOWN, error.javaClass.simpleName'),
    );
  });
}
