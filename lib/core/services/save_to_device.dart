// «Guardar en el móvil» (1.4.0, orden DESCARGAS-DIRECTAS): UN ayudante para
// toda la app. El diálogo «Guardar como» de Android (SAF, sin permisos de
// almacenamiento) y una escritura POR BLOQUES directa al documento elegido:
// nunca se carga un archivo entero en memoria ni se pasa entero por un canal.
//
// El lado Android es `HermesSaveToDeviceHandler` (canal
// `hermes/save_to_device`). Cada fallo dice por qué (sin espacio, permiso,
// el destino no admite escritura, el origen ya no está, red, el diálogo no
// se abrió, Android no respondió a tiempo) y cada paso deja una línea
// `[save] …` en logcat, sin nombres, rutas ni Uris.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;

import '../../l10n/app_localizations.dart';
import 'sftp_downloads.dart' show isNoSpaceError, sftpSafeFileName;

/// One diagnostic line, read with `adb logcat | grep '\[save\]'`. Never a
/// name, a path or a Uri.
void saveLog(String line) => debugPrint('[save] $line');

/// Where a save failed: choosing the place, writing, or closing the
/// document.
enum SaveStage { picker, copy, finalize }

/// Why a save failed.
enum SaveProblem {
  /// The phone, or the place chosen, has no room left.
  noSpace('no_space'),

  /// The place chosen no longer lets the app write (permission revoked).
  permission('permission'),

  /// The place chosen does not take files (a read-only provider), or no
  /// app can do it.
  unsupported('unsupported'),

  /// The user stopped it.
  cancelled('cancelled'),

  /// The file to save is gone.
  sourceMissing('source_missing'),

  /// The server or the connection failed while reading.
  network('network'),

  /// Android's «Guardar como» did not show (or its answer was lost).
  pickerNotShown('picker_not_shown'),

  /// Android did not answer in time.
  timeout('timeout'),

  /// This build has no Android side for it (MissingPluginException).
  unavailable('unavailable'),

  /// Anything else.
  failed('failed');

  const SaveProblem(this.code);

  /// The wire code (from Android) and the code in the diagnostic line.
  final String code;

  static SaveProblem fromCode(String code) => SaveProblem.values.firstWhere(
    (problem) => problem.code == code,
    orElse: () => SaveProblem.failed,
  );
}

/// A save that did not happen, and why.
class SaveFailure implements Exception {
  SaveFailure(this.stage, this.problem, {this.bytes = 0}) {
    // No name, path or Uri: only what can be read safely in logcat.
    saveLog('stage=${stage.name} code=${problem.code} bytes=$bytes');
  }

  final SaveStage stage;
  final SaveProblem problem;

  /// Bytes already written when it failed.
  final int bytes;

  @override
  String toString() => 'SaveFailure(${stage.name}, ${problem.code}, $bytes)';
}

/// A document saved on the phone: where (its `content://` Uri), under
/// which name, and how big.
@immutable
class SavedDocument {
  const SavedDocument({
    required this.uri,
    required this.name,
    required this.bytes,
  });

  final String uri;
  final String name;
  final int bytes;
}

/// Writes one document, block by block, in the order given.
abstract interface class SaveSink {
  /// Bytes written so far.
  int get bytes;

  Future<void> add(Uint8List data);

  /// Closes it; returns the bytes written.
  Future<int> close();

  /// Stops it and deletes what was written.
  Future<void> abort();
}

/// The reason of [problem], in words.
String saveProblemMessage(Strings strings, SaveProblem problem) =>
    switch (problem) {
      SaveProblem.noSpace => strings.saveNoSpace,
      SaveProblem.permission => strings.savePermission,
      SaveProblem.unsupported => strings.saveUnsupported,
      SaveProblem.cancelled => strings.saveCancelled,
      SaveProblem.sourceMissing => strings.saveSourceMissing,
      SaveProblem.network => strings.saveNetwork,
      SaveProblem.pickerNotShown => strings.savePickerNotShown,
      SaveProblem.timeout => strings.saveTimeout,
      SaveProblem.unavailable => strings.saveUnavailable,
      SaveProblem.failed => strings.saveFailed,
    };

class SaveToDevice {
  const SaveToDevice([
    this._channel = const MethodChannel('hermes/save_to_device'),
  ]);

  final MethodChannel _channel;

  /// Size of each block sent to the document.
  static const int blockBytes = 256 * 1024;

  /// How long «Guardar como» has to cover the app once asked for. Opening
  /// it pauses the app; if that never happens, it did not show.
  static const Duration pickerShowTimeout = Duration(seconds: 8);

  /// How long its answer may take once the app is back in front.
  static const Duration pickerAnswerTimeout = Duration(seconds: 5);

  /// Limit of one call that answers at once (open, write a block, close).
  static const Duration stepTimeout = Duration(seconds: 30);

  /// Limit of a copy done whole on Android's side: two minutes, plus one
  /// second per MiB.
  static Duration copyTimeout(int bytes) =>
      Duration(seconds: 120 + bytes ~/ (1024 * 1024));

  /// Calls [method] within [limit], saying in logcat what was asked and
  /// what came back; every exception becomes a [SaveFailure] at [stage].
  Future<T?> _call<T>(
    String method,
    Map<String, Object?> arguments, {
    required SaveStage stage,
    Duration limit = stepTimeout,
    int bytes = 0,
  }) async {
    saveLog('invoke method=$method');
    try {
      final value = await _channel
          .invokeMethod<T>(method, arguments)
          .timeout(limit);
      saveLog('result method=$method ok=true');
      return value;
    } on PlatformException catch (error) {
      saveLog('error method=$method type=PlatformException code=${error.code}');
      throw SaveFailure(stage, SaveProblem.fromCode(error.code), bytes: bytes);
    } on MissingPluginException {
      saveLog('error method=$method type=MissingPluginException');
      throw SaveFailure(stage, SaveProblem.unavailable, bytes: bytes);
    } on TimeoutException {
      saveLog('error method=$method type=TimeoutException');
      throw SaveFailure(stage, SaveProblem.timeout, bytes: bytes);
    }
  }

  /// Android's «Guardar como» with [name] made safe ([sftpSafeFileName]):
  /// the Uri of the document chosen, or null when the dialog was closed
  /// (not an error: nothing happens). A dialog that never shows, or whose
  /// answer never comes, fails with [SaveProblem.pickerNotShown] instead of
  /// waiting forever.
  Future<String?> pick(String name) async {
    saveLog('invoke method=pick');
    final answer = Completer<String?>();
    var paused = false;
    Timer? watchdog;
    void giveUp(String why) {
      if (answer.isCompleted) return;
      saveLog('error method=pick type=Watchdog why=$why');
      answer.completeError(
        SaveFailure(SaveStage.picker, SaveProblem.pickerNotShown),
      );
      unawaited(
        _channel.invokeMethod<void>('cancelPick').catchError((Object error) {
          saveLog('error method=cancelPick type=${error.runtimeType}');
        }),
      );
    }

    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          if (!paused) saveLog('picker covers the app state=${state.name}');
          paused = true;
          watchdog?.cancel();
          watchdog = null;
        } else if (paused) {
          watchdog?.cancel();
          watchdog = Timer(pickerAnswerTimeout, () => giveUp('no_answer'));
        }
      },
    );
    watchdog = Timer(pickerShowTimeout, () {
      if (!paused) giveUp('not_shown');
    });
    unawaited(
      _channel
          .invokeMethod<String>('pick', {'name': sftpSafeFileName(name)})
          .then(
            (uri) {
              if (!answer.isCompleted) answer.complete(uri);
            },
            onError: (Object error) {
              if (answer.isCompleted) return;
              answer.completeError(_pickFailure(error));
            },
          ),
    );
    try {
      final uri = await answer.future;
      if (uri == null || uri.isEmpty) {
        saveLog('result method=pick ok=true uri=false');
        saveLog('stage=picker code=cancelled bytes=0');
        return null;
      }
      saveLog('result method=pick ok=true uri=true');
      return uri;
    } finally {
      watchdog?.cancel();
      lifecycle.dispose();
    }
  }

  static SaveFailure _pickFailure(Object error) {
    if (error is PlatformException) {
      saveLog('error method=pick type=PlatformException code=${error.code}');
      return SaveFailure(SaveStage.picker, SaveProblem.fromCode(error.code));
    }
    saveLog('error method=pick type=${error.runtimeType}');
    return SaveFailure(
      SaveStage.picker,
      error is MissingPluginException
          ? SaveProblem.unavailable
          : SaveProblem.failed,
    );
  }

  /// Opens the document at [uri] to write it block by block. When it
  /// cannot be opened, the (empty) document is deleted.
  Future<SaveSink> begin(String uri) async {
    final int writer;
    try {
      writer =
          await _call<int>('begin', {'uri': uri}, stage: SaveStage.copy) ?? -1;
    } on SaveFailure {
      await delete(uri);
      rethrow;
    }
    return _DocumentSink(this, writer);
  }

  /// Copies the app's file [file] to [uri], by blocks, on the phone's
  /// side. Returns the bytes copied. A failure deletes the document.
  Future<int> copyFile(File file, String uri) async {
    final bytes = await _call<int>(
      'copy',
      {'path': file.path, 'uri': uri},
      stage: SaveStage.copy,
      limit: copyTimeout(file.lengthSync()),
    );
    return bytes ?? 0;
  }

  /// Copies the saved document [source] (of [bytes]) to [uri] («Guardar
  /// otra copia…»).
  Future<int> copyDocument(String source, String uri, {int bytes = 0}) async {
    final copied = await _call<int>(
      'copy',
      {'source': source, 'uri': uri},
      stage: SaveStage.copy,
      limit: copyTimeout(bytes),
    );
    return copied ?? 0;
  }

  /// Asks where to save the app's file [file] (as [name]) and copies it
  /// there by blocks. Null when the dialog was closed.
  Future<SavedDocument?> saveFile(File file, {required String name}) async {
    // A stat, not a read: the check stays synchronous and cheap.
    if (!file.existsSync()) {
      throw SaveFailure(SaveStage.picker, SaveProblem.sourceMissing);
    }
    final uri = await pick(name);
    if (uri == null) return null;
    final bytes = await copyFile(file, uri);
    return SavedDocument(uri: uri, name: sftpSafeFileName(name), bytes: bytes);
  }

  /// Asks where to save [data] (already in memory, as [name]) and writes
  /// it straight there, block by block. Null when the dialog was closed.
  Future<SavedDocument?> saveBytes(
    Uint8List data, {
    required String name,
  }) async {
    final uri = await pick(name);
    if (uri == null) return null;
    final sink = await begin(uri);
    try {
      for (var at = 0; at < data.length; at += blockBytes) {
        final end = min(at + blockBytes, data.length);
        await sink.add(Uint8List.sublistView(data, at, end));
      }
      final bytes = await sink.close();
      return SavedDocument(
        uri: uri,
        name: sftpSafeFileName(name),
        bytes: bytes,
      );
    } on Object {
      // Half a document is no copy: it goes.
      await sink.abort();
      rethrow;
    }
  }

  /// «Guardar otra copia…» of [saved]: asks where, then copies it.
  Future<SavedDocument?> saveAnotherCopy(SavedDocument saved) async {
    final uri = await pick(saved.name);
    if (uri == null) return null;
    final bytes = await copyDocument(saved.uri, uri, bytes: saved.bytes);
    return SavedDocument(uri: uri, name: saved.name, bytes: bytes);
  }

  /// «Abrir»: the app the system picks, reading the document chosen.
  Future<void> open(String uri) =>
      _call<void>('view', {'uri': uri}, stage: SaveStage.finalize);

  /// «Compartir»: Android's share sheet over the document itself (no copy).
  Future<void> share(String uri) =>
      _call<void>('share', {'uri': uri}, stage: SaveStage.finalize);

  /// Deletes a document the app created and did not finish. Never throws:
  /// what failed is in logcat (the document may stay, empty).
  Future<void> delete(String uri) async {
    try {
      await _call<void>('delete', {'uri': uri}, stage: SaveStage.copy);
    } on SaveFailure catch (failure) {
      saveLog('delete not done code=${failure.problem.code}');
    }
  }
}

class _DocumentSink implements SaveSink {
  _DocumentSink(this._device, this._writer);

  final SaveToDevice _device;
  final int _writer;
  bool _ended = false;

  @override
  int bytes = 0;

  @override
  Future<void> add(Uint8List data) async {
    await _device._call<int>(
      'write',
      {'writer': _writer, 'bytes': data},
      stage: SaveStage.copy,
      bytes: bytes,
    );
    bytes += data.length;
  }

  @override
  Future<int> close() async {
    final written = await _device._call<int>(
      'finish',
      {'writer': _writer},
      stage: SaveStage.finalize,
      bytes: bytes,
    );
    _ended = true;
    saveLog('stage=finalize code=ok bytes=${written ?? bytes}');
    return written ?? bytes;
  }

  @override
  Future<void> abort() async {
    if (_ended) return;
    _ended = true;
    try {
      await _device._call<void>(
        'abort',
        {'writer': _writer},
        stage: SaveStage.copy,
        bytes: bytes,
      );
    } on SaveFailure catch (failure) {
      saveLog('abort not done code=${failure.problem.code} bytes=$bytes');
    }
  }
}

/// Writes to a file of the app (a temporary copy to share), block by
/// block.
class FileSaveSink implements SaveSink {
  FileSaveSink(this.file) : _sink = file.openWrite();

  final File file;
  final IOSink _sink;
  bool _ended = false;

  @override
  int bytes = 0;

  SaveProblem _problemOf(FileSystemException error) =>
      isNoSpaceError(error) ? SaveProblem.noSpace : SaveProblem.failed;

  @override
  Future<void> add(Uint8List data) async {
    try {
      _sink.add(data);
      await _sink.flush();
    } on FileSystemException catch (error) {
      throw SaveFailure(SaveStage.copy, _problemOf(error), bytes: bytes);
    }
    bytes += data.length;
  }

  @override
  Future<int> close() async {
    try {
      await _sink.close();
      _ended = true;
      return bytes;
    } on FileSystemException catch (error) {
      throw SaveFailure(SaveStage.finalize, _problemOf(error), bytes: bytes);
    }
  }

  @override
  Future<void> abort() async {
    if (_ended) return;
    _ended = true;
    try {
      await _sink.close();
    } on FileSystemException catch (error) {
      saveLog(
        'abort temp close type=FileSystemException '
        'os=${error.osError?.errorCode} bytes=$bytes',
      );
    }
    if (await file.exists()) await file.delete();
  }
}
