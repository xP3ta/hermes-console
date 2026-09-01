// Transferencias SFTP que SOBREVIVEN al cierre de la pantalla y a poner la app
// en segundo plano. Cada transferencia abre su propio SSHClient (independiente
// de la UI), reporta progreso (barra in-app + notificación) y, mientras hay
// alguna activa, mantiene el proceso vivo vía el foreground service compartido.
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'notifications/notification_service.dart';
import 'ssh_manager.dart';

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
  int doneBytes;
  TransferStatus status;
  String? error;
  String? localPath;

  SftpTransfer({
    required this.id,
    required this.connectionId,
    required this.name,
    required this.direction,
    required this.totalBytes,
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

  SftpTransferService(this._ssh, this._notif);

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
        ..error = 'Cancelado por el usuario';
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

  Future<SftpTransfer> download({
    required String connectionId,
    required String remotePath,
    required String fileName,
    required int totalBytes,
  }) async {
    final t = SftpTransfer(
      id: 'd${_seq++}',
      connectionId: connectionId,
      name: fileName,
      direction: TransferDirection.download,
      totalBytes: totalBytes,
    );
    final notifId = _notifBaseId++;
    _add(t);
    SSHClient? client;
    File? partial;
    IOSink? sink;
    try {
      client = await _ssh
          .connect(connectionId, onHostKey: _refuseUnknownHostKey)
          .timeout(_operationTimeout);
      _activeClients[t.id] = client;
      _throwIfCancelled(t.id);
      await client.authenticated.timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      final sftp = await client.sftp().timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      final file = await sftp
          .open(remotePath, mode: SftpFileOpenMode.read)
          .timeout(_operationTimeout);
      final dir = await getApplicationDocumentsDirectory();
      final out = File('${dir.path}/$fileName');
      partial = File('${out.path}.part-${t.id}');
      sink = partial.openWrite();
      var offset = 0;
      while (totalBytes <= 0 || offset < totalBytes) {
        _throwIfCancelled(t.id);
        final data = await file
            .readBytes(length: _chunk, offset: offset)
            .timeout(_operationTimeout);
        _throwIfCancelled(t.id);
        if (data.isEmpty) break;
        sink.add(data);
        offset += data.length;
        t.doneBytes = offset;
        _emit();
        await _progressNotif(notifId, t);
      }
      await sink.close();
      sink = null;
      await file.close().timeout(_operationTimeout);
      _throwIfCancelled(t.id);
      if (await out.exists()) await out.delete();
      await partial.rename(out.path);
      partial = null;
      t.localPath = out.path;
      t.status = TransferStatus.done;
      await _doneNotif(notifId, t);
    } catch (e) {
      t.status = TransferStatus.error;
      t.error = _cancelRequested.contains(t.id)
          ? 'Cancelado por el usuario'
          : SshManager.describeError(e);
      await _doneNotif(notifId, t);
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      if (partial != null && await partial.exists()) {
        await partial.delete();
      }
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
      } catch (_) {}
      t.status = TransferStatus.error;
      t.error = _cancelRequested.contains(t.id)
          ? 'Cancelado por el usuario'
          : SshManager.describeError(e);
      await _doneNotif(notifId, t);
    } finally {
      client?.close();
      _activeClients.remove(t.id);
      _cancelRequested.remove(t.id);
      _finish(t);
    }
    return t;
  }

  String _verb(TransferDirection d) =>
      d == TransferDirection.download ? 'Descargando' : 'Subiendo';

  Future<void> _progressNotif(int id, SftpTransfer t) async {
    final pct = t.fraction == null ? null : (t.fraction! * 100).round();
    await _notif?.transferProgress(
      id: id,
      title: '${_verb(t.direction)} ${t.name}',
      body: pct == null ? 'En curso…' : '$pct%',
      progress: pct ?? 0,
      max: 100,
      indeterminate: t.fraction == null,
    );
  }

  Future<void> _doneNotif(int id, SftpTransfer t) async {
    final ok = t.status == TransferStatus.done;
    final verb = t.direction == TransferDirection.download
        ? (ok ? 'Descargado' : 'Falló la descarga')
        : (ok ? 'Subido' : 'Falló la subida');
    await _notif?.transferDone(
      id: id,
      title: '$verb · ${t.name}',
      body: ok ? (t.localPath ?? 'Completado') : (t.error ?? 'Error'),
      ok: ok,
    );
  }
}

class _SftpTransferCancelled implements Exception {
  const _SftpTransferCancelled();
}
