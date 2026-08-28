import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ledger durable y acotado para que varios observadores reclamen el mismo
/// evento semántico antes de interrumpir al usuario.
///
/// La identidad contiene únicamente ámbito y objeto autoritativos. Títulos,
/// cuerpos y previews no forman parte del claim ni de su persistencia.
class NotificationEventLedger {
  static const storageKey = 'notification_event_claims_v1';
  static Future<void> _tail = Future<void>.value();

  final SharedPreferences _prefs;
  final int maxEntries;
  final DateTime Function() _now;

  NotificationEventLedger(
    this._prefs, {
    this.maxEntries = 256,
    DateTime Function()? now,
  }) : assert(maxEntries > 0),
       _now = now ?? DateTime.now;

  /// Devuelve true solo al primer productor que reclama esta identidad.
  ///
  /// Si falta algún componente autoritativo no se inventa una identidad: se
  /// permite avisar de forma conservadora para no ocultar errores accionables.
  Future<bool> claim({
    required String connId,
    required String? profile,
    required String objectId,
    required String eventKind,
  }) async {
    final connection = connId.trim();
    final scopedProfile = (profile ?? '').trim();
    final object = objectId.trim();
    final kind = eventKind.trim();
    if (connection.isEmpty || object.isEmpty || kind.isEmpty) return true;

    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await _withProcessLock(() async {
        await _prefs.reload();
        final entries = decodeEntries(_prefs.getString(storageKey));
        final duplicate = entries.any(
          (entry) =>
              entry['c'] == connection &&
              entry['p'] == scopedProfile &&
              entry['o'] == object &&
              entry['k'] == kind,
        );
        if (duplicate) return false;

        entries.add(<String, Object>{
          'c': connection,
          'p': scopedProfile,
          'o': object,
          'k': kind,
          'at': _now().millisecondsSinceEpoch,
        });
        if (entries.length > maxEntries) {
          entries.removeRange(0, entries.length - maxEntries);
        }
        await _prefs.setString(storageKey, jsonEncode(entries));
        return true;
      });
    } catch (error) {
      // Un ledger corrupto o almacenamiento no disponible nunca debe convertir
      // un fallo accionable en silencio. Se avisa y el siguiente claim reintenta.
      if (kDebugMode) {
        debugPrint('[hermes-notif] ledger no disponible: $error');
      }
      return true;
    } finally {
      release.complete();
    }
  }

  /// SharedPreferences no ofrece compare-and-set entre isolates. El lock de
  /// archivo serializa el read-modify-write entre UI y foreground service.
  static Future<T> _withProcessLock<T>(Future<T> Function() action) async {
    Directory directory;
    try {
      directory = await getApplicationSupportDirectory();
    } catch (_) {
      directory = Directory.systemTemp;
    }
    final file = File('${directory.path}/notification_event_ledger.lock');
    final handle = await file.open(mode: FileMode.append);
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (true) {
        try {
          await handle.lock(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (!DateTime.now().isBefore(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      return await action();
    } finally {
      try {
        await handle.unlock();
      } catch (_) {}
      await handle.close();
    }
  }

  @visibleForTesting
  static List<Map<String, dynamic>> decodeEntries(String? raw) {
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .where(
            (entry) =>
                entry['c'] is String &&
                entry['p'] is String &&
                entry['o'] is String &&
                entry['k'] is String &&
                entry['at'] is int,
          )
          .toList(growable: true);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }
}
