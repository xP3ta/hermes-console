// Transferencias SFTP que SOBREVIVEN al cierre de la pantalla y a poner la app
// en segundo plano. Cada transferencia abre su propio SSHClient (independiente
// de la UI), reporta progreso (barra in-app + notificación) y, mientras hay
// alguna activa, mantiene el proceso vivo vía el foreground service compartido.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'notifications/notification_service.dart';
import 'save_to_device.dart';
import 'sftp_downloads.dart';
import 'ssh_manager.dart';
import '../utils/ssh_error.dart';

enum TransferDirection { download, upload }

enum TransferStatus { running, done, error }

/// Una transferencia en curso o terminada. Mutable: el servicio actualiza
/// [doneBytes]/[status] y reemite por [SftpTransferService.transfers].
class SftpTransfer {
  final String id;
  final String connectionId;
  final String name;
  final TransferDirection direction;
  final int totalBytes;

  /// Where it is on the server (a download's source, an upload's target):
  /// what a retry uses.
  final String remotePath;
  int doneBytes;
  TransferStatus status;
  String? error;
  String? localPath;

  /// A download to share: it goes to a temporary copy ([localPath]) in
  /// the app's cache, not to a place the user chose.
  final bool forShare;

  /// A finished download: the document the user chose, written directly.
  SavedDocument? saved;

  /// Why it failed, when it did.
  SaveProblem? problem;

  SftpTransfer({
    required this.id,
    required this.connectionId,
    required this.name,
    required this.direction,
    required this.totalBytes,
    this.remotePath = '',
    this.forShare = false,
    this.doneBytes = 0,
    this.status = TransferStatus.running,
    this.error,
    this.localPath,
  });

  double? get fraction =>
      totalBytes > 0 ? (doneBytes / totalBytes).clamp(0.0, 1.0) : null;
  bool get isRunning => status == TransferStatus.running;
}

class SftpTransferService {
  final SshManager _ssh;
  final NotificationService? _notif;

  /// Android's side of a download: the document the user chose.
  final SaveToDevice device;

  /// The app's cache, where a download to share is copied for a moment.
  final Future<Directory> Function() _cache;

  /// The app's private files: where 9708 kept its copies of downloads.
  final Future<Directory> Function() _support;

  SftpTransferService(
    this._ssh,
    this._notif, {
    this.device = const SaveToDevice(),
    Future<Directory> Function()? cache,
    Future<Directory> Function()? support,
  }) : _cache = cache ?? getTemporaryDirectory,
       _support = support ?? getApplicationSupportDirectory;

  /// [cleanUpAtStart] once [firstFrame] (the first frame on screen) is
  /// done: nothing of it delays a cold start, nor the decryption of the
  /// chats' tails while the first frames paint.
  void cleanUpAfter(Future<void> firstFrame) {
    unawaited(
      firstFrame.then(
        (_) => cleanUpAtStart(),
        onError: (Object error) =>
            saveLog('cleanup skipped=${error.runtimeType}'),
      ),
    );
  }

  /// At start: the copies made to share are gone, and so is the folder
  /// where APK 9708 kept a private copy of each download
  /// (`files/sftp_downloads/`). Only that folder: nothing else is touched.
  ///
  /// It never fails the start: without the app's folders (no path
  /// provider, an unreadable disk) it says why in logcat and skips.
  Future<void> cleanUpAtStart() async {
    try {
      await clearShareCopies();
      final legacy = Directory('${(await _support()).path}/sftp_downloads');
      if (!await legacy.exists()) return;
      await legacy.delete(recursive: true);
      saveLog('removed the 9708 private downloads folder');
    } on FileSystemException catch (error) {
      saveLog(
        'cleanup skipped=FileSystemException os=${error.osError?.errorCode}',
      );
    } on Object catch (error) {
      // MissingPluginException, PlatformException…: nothing to clean.
      saveLog('cleanup skipped=${error.runtimeType}');
    }
  }

  /// Lista observable para la barra de progreso in-app.
  final ValueNotifier<List<SftpTransfer>> transfers =
      ValueNotifier<List<SftpTransfer>>(const []);

  /// Lo cablea HermesAppState: levantar el foreground service al empezar una
  /// transferencia, y reevaluar su parada al terminar (respetando voz/runs).
  VoidCallback? onNeedForeground;
  VoidCallback? onMaybeRelease;

  int _seq = 0;
  int _notifBaseId = 8100;
  final Map<String, SSHClient> _activeClients = <String, SSHClient>{};
  final Set<String> _cancelRequested = <String>{};
  static const int _chunk = 64 * 1024;
  static const Duration _operationTimeout = Duration(seconds: 30);

  bool get hasActive => transfers.value.any((t) => t.isRunning);

  /// Cancela todas las operaciones vivas por una acción explícita del usuario
  /// (botón Stop de la notificación dataSync). Marca el estado antes de cerrar
  /// sockets para liberar inmediatamente el lease de foreground; cada Future
  /// conserva su cleanup normal de parciales y notificación terminal.
  void cancelAll() {
    var changed = false;
    for (final transfer in transfers.value.where((item) => item.isRunning)) {
      _cancelRequested.add(transfer.id);
      transfer
        ..status = TransferStatus.error
        ..error = _ssh.appStrings.m1215TransferCancelled;
      _activeClients[transfer.id]?.close();
      changed = true;
    }
    if (!changed) return;
    _emit();
    onMaybeRelease?.call();
  }

  void _throwIfCancelled(String transferId) {
    if (_cancelRequested.contains(transferId)) {
      throw const _SftpTransferCancelled();
    }
  }

  void _emit() => transfers.value = List.unmodifiable(transfers.value);

  void _add(SftpTransfer t) {
    transfers.value = List.unmodifiable([...transfers.value, t]);
    if (hasActive) onNeedForeground?.call();
  }

  /// Removes [transfer] from the list once it has finished (its row's ×).
  void dismiss(SftpTransfer transfer) {
    if (transfer.isRunning) return;
    transfers.value = List.unmodifiable(
      transfers.value.where((t) => !identical(t, transfer)),
    );
  }

  /// Quita las transferencias terminadas de la lista (las notificaciones ya
  /// reflejan el resultado).
  void clearFinished() {
    transfers.value = List.unmodifiable(
      transfers.value.where((t) => t.isRunning),
    );
  }

  void _finish(SftpTransfer t) {
    _emit();
    if (!hasActive) onMaybeRelease?.call();
  }

  /// Rechaza host keys nuevas/cambiadas en background (no hay UI para el TOFU):
  /// la transferencia se lanza desde una pantalla ya conectada y con la key
  /// confiada, así que esto solo dispara si algo no cuadra → fallo seguro.
  Future<bool> _refuseUnknownHostKey(SshHostKeyPrompt _) async => false;

  /// Downloads [failed] again: to [document] (a place chosen again: the
  /// failed one was deleted), or to share when it was a download to share.
  Future<SftpTransfer> retry(SftpTransfer failed, {String? document}) {
    transfers.value = List.unmodifiable(
      transfers.value.where((t) => !identical(t, failed)),
    );
    if (failed.forShare || document == null) {
      return downloadToShare(
        connectionId: failed.connectionId,
        remotePath: failed.remotePath,
        fileName: failed.name,
        totalBytes: failed.totalBytes,
      );
    }
    return download(
      connectionId: failed.connectionId,
      remotePath: failed.remotePath,
      fileName: failed.name,
      totalBytes: failed.totalBytes,
      document: document,
    );
  }

  /// Downloads [remotePath] straight into [document], the place the user
  /// chose in Android's «Guardar como» ([SaveToDevice.pick]): block by
  /// block, with no copy in the app. A failure or a cancel deletes the
  /// half-written document.
  Future<SftpTransfer> download({
    required String connectionId,
    required String remotePath,
    required String fileName,
    required int totalBytes,
    required String document,
  }) {
    final t = SftpTransfer(
      id: 'd${_seq++}',
      connectionId: connectionId,
      name: fileName,
      direction: TransferDirection.download,
      totalBytes: totalBytes,
      remotePath: remotePath,
    );
    return _download(
      t,
      openSink: () => device.begin(document),
      // The dialog created it: nothing written yet, it goes too.
      discardUnopened: () => device.delete(document),
      onSaved: (bytes) => t.saved = SavedDocument(
        uri: document,
        name: sftpSafeFileName(fileName),
        bytes: bytes,
      ),
    );
  }

  /// Downloads [remotePath] to a temporary copy in the app's cache
  /// (`cache/sftp_share/`), to share it: [SftpTransfer.localPath] once
  /// done. [clearShareCopies] deletes it.
  Future<SftpTransfer> downloadToShare({
    required String connectionId,
    required String remotePath,
    required String fileName,
    required int totalBytes,
  }) {
    final t = SftpTransfer(
      id: 'd${_seq++}',
      connectionId: connectionId,
      name: fileName,
      direction: TransferDirection.download,
      totalBytes: totalBytes,
      remotePath: remotePath,
      forShare: true,
    );
    return _download(
      t,
      openSink: () async {
        final folder = Directory('${(await _shareRoot()).path}/${t.id}');
        await folder.create(recursive: true);
        final file = File('${folder.path}/${sftpSafeFileName(fileName)}');
        t.localPath = file.path;
        return FileSaveSink(file);
      },
      discardUnopened: () async {},
      onSaved: (_) {},
    );
  }

  Future<Directory> _shareRoot() async =>
      Directory('${(await _cache()).path}/sftp_share');

  /// Deletes the temporary copies made to share (leaving the browser, at
  /// start, before another share), except those still being downloaded.
  Future<void> clearShareCopies() async {
    final root = await _shareRoot();
    if (!await root.exists()) return;
    final running = {
      for (final t in transfers.value)
        if (t.forShare && t.isRunning) '${root.path}/${t.id}',
    };
    await for (final entry in root.list()) {
      if (running.contains(entry.path)) continue;
      try {
        await entry.delete(recursive: true);
      } on FileSystemException catch (error) {
        saveLog('share copy not deleted os=${error.osError?.errorCode}');
      }
    }
  }

  /// Stops [transfer] (a download to share whose screen is gone).
  void cancel(SftpTransfer transfer) {
    if (!transfer.isRunning) return;
    _cancelRequested.add(transfer.id);
    transfer
      ..status = TransferStatus.error
      ..problem = SaveProblem.cancelled
      ..error = _ssh.appStrings.m1215TransferCancelled;
    _activeClients[transfer.id]?.close();
    _emit();
    if (!hasActive) onMaybeRelease?.call();
  }

  Future<SftpTransfer> _download(
    SftpTransfer t, {
    required Future<SaveSink> Function() openSink,
    required Future<void> Function() discardUnopened,
    required void Function(int bytes) onSaved,
  }) async {
    final notifId = _notifBaseId++;
    _add(t);
    SSHClient? client;
    var opened = false;
    try {
      client = await _ssh
          .connect(t.connectionId, onHostKey: _refuseUnknownHostKey)
          .timeout(_operationTimeout);
      _activeClients[t.id] = client;
      _throwIfCancelled(t.id);
      await client.authenticated.timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      final sftp = await client.sftp().timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      final file = await sftp
          .open(t.remotePath, mode: SftpFileOpenMode.read)
          .timeout(_operationTimeout);
      opened = true;
      final bytes = await writeRemoteFile(
        read: (offset, length) => file
            .readBytes(length: length, offset: offset)
            .timeout(_operationTimeout),
        openSink: openSink,
        totalBytes: t.totalBytes,
        checkCancelled: () => _throwIfCancelled(t.id),
        onProgress: (done) async {
          t.doneBytes = done;
          _emit();
          await _progressNotif(notifId, t);
        },
        beforeClose: () => file.close().timeout(_operationTimeout),
      );
      onSaved(bytes);
      t.status = TransferStatus.done;
      await _doneNotif(notifId, t);
    } catch (e) {
      if (!opened) await discardUnopened();
      t.status = TransferStatus.error;
      final cancelled = _cancelRequested.contains(t.id);
      // The file is gone from the server: said as such, not as the network.
      final gone = e is SftpStatusError && e.code == SftpStatusCode.noSuchFile;
      final problem = t.problem = cancelled
          ? SaveProblem.cancelled
          : e is SaveFailure
          ? e.problem
          : gone
          ? SaveProblem.sourceMissing
          : SaveProblem.network;
      if (e is! SaveFailure) {
        // What the server side did (or the user's cancel), for logcat.
        saveLog(
          'stage=copy code=${problem.code} bytes=${t.doneBytes} '
          'type=${e.runtimeType}',
        );
      }
      t.error = cancelled
          ? _ssh.appStrings.m1215TransferCancelled
          : e is SaveFailure || gone
          ? saveProblemMessage(_ssh.appStrings, problem)
          : localizedSshError(_ssh.appStrings, e);
      await _doneNotif(notifId, t);
    } finally {
      client?.close();
      _activeClients.remove(t.id);
      _cancelRequested.remove(t.id);
      _finish(t);
    }
    return t;
  }

  Future<SftpTransfer> upload({
    required String connectionId,
    required String remotePath,
    required String fileName,
    required String localPath,
    required int totalBytes,
  }) async {
    final t = SftpTransfer(
      id: 'u${_seq++}',
      connectionId: connectionId,
      name: fileName,
      direction: TransferDirection.upload,
      totalBytes: totalBytes,
    );
    final notifId = _notifBaseId++;
    _add(t);
    SSHClient? client;
    SftpClient? sftp;
    final partialRemote = '$remotePath.part-${t.id}';
    try {
      client = await _ssh
          .connect(connectionId, onHostKey: _refuseUnknownHostKey)
          .timeout(_operationTimeout);
      _activeClients[t.id] = client;
      _throwIfCancelled(t.id);
      await client.authenticated.timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      sftp = await client.sftp().timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      final file = await sftp
          .open(
            partialRemote,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
          )
          .timeout(_operationTimeout);
      final input = File(localPath).openRead();
      var offset = 0;
      await for (final chunk in input) {
        _throwIfCancelled(t.id);
        var chunkOffset = 0;
        while (chunkOffset < chunk.length) {
          final end = min(chunkOffset + _chunk, chunk.length);
          await file
              .writeBytes(
                Uint8List.sublistView(
                  Uint8List.fromList(chunk),
                  chunkOffset,
                  end,
                ),
                offset: offset,
              )
              .timeout(_operationTimeout);
          _throwIfCancelled(t.id);
          offset += end - chunkOffset;
          chunkOffset = end;
        }
        t.doneBytes = offset;
        _emit();
        await _progressNotif(notifId, t);
      }
      await file.close().timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      await sftp.rename(partialRemote, remotePath).timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      t.status = TransferStatus.done;
      await _doneNotif(notifId, t);
    } catch (e) {
      try {
        await sftp?.remove(partialRemote).timeout(_operationTimeout);
      } on Object catch (error) {
        // The partial upload stays on the server; the reason is said below.
        debugPrint('[sftp] partial upload not removed ${error.runtimeType}');
      }
      t.status = TransferStatus.error;
      t.error = _cancelRequested.contains(t.id)
          ? _ssh.appStrings.m1215TransferCancelled
          : localizedSshError(_ssh.appStrings, e);
      await _doneNotif(notifId, t);
    } finally {
      client?.close();
      _activeClients.remove(t.id);
      _cancelRequested.remove(t.id);
      _finish(t);
    }
    return t;
  }

  Future<void> _progressNotif(int id, SftpTransfer t) async {
    final pct = t.fraction == null ? null : (t.fraction! * 100).round();
    final s = _ssh.appStrings;
    await _notif?.transferProgress(
      id: id,
      title: t.direction == TransferDirection.download
          ? s.m1215TransferDownloading(t.name)
          : s.m1215TransferUploading(t.name),
      body: pct == null ? s.m1215TransferInProgress : '$pct%',
      progress: pct ?? 0,
      max: 100,
      indeterminate: t.fraction == null,
    );
  }

  Future<void> _doneNotif(int id, SftpTransfer t) async {
    final ok = t.status == TransferStatus.done;
    final s = _ssh.appStrings;
    final download = t.direction == TransferDirection.download;
    final saved = t.saved;
    if (ok && download && saved != null) {
      // Tapped, it offers Abrir, Compartir and Guardar otra copia… of the
      // document written (never a path).
      await _notif?.downloadReady(
        id: id,
        title: s.m1215TransferDownloaded(t.name),
        body: s.saveReadyBody,
        open: NotificationOpen(
          connId: t.connectionId,
          downloadUri: saved.uri,
          downloadName: saved.name,
        ),
      );
      return;
    }
    await _notif?.transferDone(
      id: id,
      title: switch ((download, ok)) {
        (true, true) => s.m1215TransferDownloaded(t.name),
        (true, false) => s.m1215TransferDownloadFailed(t.name),
        (false, true) => s.m1215TransferUploaded(t.name),
        (false, false) => s.m1215TransferUploadFailed(t.name),
      },
      // A copy to share is no place to show: it lives in the cache.
      body: ok
          ? (t.forShare
                ? s.m1215TransferCompleted
                : (t.localPath ?? s.m1215TransferCompleted))
          : (t.error ?? s.m1215TransferFailedBody),
      ok: ok,
    );
  }
}

/// Copies a remote file into [openSink]'s destination, block by block:
/// [read] gives up to `length` bytes at `offset` (empty at the end), each
/// block is written before the next is read, [onProgress] hears the total
/// so far. [beforeClose] runs once the last block is read (closing the
/// remote file). Returns the bytes written.
///
/// Any failure, a cancel ([checkCancelled] throwing) included, aborts the
/// destination: a half-written document, or temporary copy, is deleted.
Future<int> writeRemoteFile({
  required Future<Uint8List> Function(int offset, int length) read,
  required Future<SaveSink> Function() openSink,
  required int totalBytes,
  void Function()? checkCancelled,
  Future<void> Function(int done)? onProgress,
  Future<void> Function()? beforeClose,
  int chunk = 64 * 1024,
}) async {
  final sink = await openSink();
  try {
    var offset = 0;
    while (totalBytes <= 0 || offset < totalBytes) {
      checkCancelled?.call();
      final data = await read(offset, chunk);
      checkCancelled?.call();
      if (data.isEmpty) break;
      await sink.add(data);
      offset += data.length;
      await onProgress?.call(offset);
    }
    await beforeClose?.call();
    checkCancelled?.call();
    return await sink.close();
  } on Object {
    await sink.abort();
    rethrow;
  }
}

class _SftpTransferCancelled implements Exception {
  const _SftpTransferCancelled();
}
