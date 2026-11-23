import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app_error_log.dart';
import 'app_lock_sensitive_read_fence.dart';
import 'cold_start_store.dart' show SecureColdStartStorage;
import 'cold_start_tail_cipher.dart';
import 'secure_storage.dart';

/// The files of a [SealedLocalFiles] family. Production uses
/// [SecureColdStartStorage] (temporary file renamed over the old one).
abstract interface class SealedFileIo {
  /// The file [name], or null when there is none.
  Future<Uint8List?> readFile(String name);

  /// Replaces the file [name] whole: a reader finds the old bytes or the
  /// new ones, never part of them.
  Future<void> writeFile(String name, Uint8List bytes);

  Future<void> deleteFile(String name);

  /// The names of the files, unfinished writes included. Nothing is read.
  Future<List<String>> fileNames();
}

/// Where one value lives: the secure-storage key an older version kept it
/// under (read once, to move it) and the scope its file name is hashed
/// from (a connection first, then a profile and a chat; empty for a value
/// of the whole app).
@immutable
final class SealedName {
  const SealedName(this.key, [this.scope = const []]);

  final String key;
  final List<String> scope;
}

/// A file that does not open (altered, truncated, sealed with another key)
/// and no older entry to fall back on. Its store treats it as it treats an
/// entry it cannot read.
final class SealedFileUnreadable implements Exception {
  const SealedFileUnreadable();
}

/// The values of one scope ([SealedLocalFiles.readScope]) by the key of
/// each one, the files of the scope that do not open, the writes a process
/// death interrupted, and what those held by key (the ones that open).
typedef SealedScope = ({
  Map<String, String> values,
  List<String> unreadable,
  List<String> partial,
  List<String> unreadablePartial,
  Map<String, String> unfinished,
});

/// User data that used to be secure-storage entries, kept in app-private
/// files sealed like the cold-start tails ([ColdStartTailCipher]): random
/// nonce, the file name as associated data, file names made of keyed hashes
/// only. The 32-byte key is one small secure-storage entry ([keyKey]) of
/// its own, so clearing the chat cache never touches drafts or the outbox.
///
/// `flutter_secure_storage` keeps every value of the app in one preferences
/// file that Android loads and decrypts whole on the first access; each
/// value kept there weighed on every secret read (OutOfMemoryError reported
/// from inside the plugin). Credentials, tokens, the keys and small flags
/// stay there.
///
/// An entry an older version wrote is moved the first time it is read:
/// sealed into a temporary file, renamed over the file, read back and
/// opened, compared, and only then deleted. Whatever the step a process
/// dies in, the next read finds one value: a file that opens wins, and the
/// entry it came from is deleted then; without one, the entry is still
/// there and is moved again. A delete removes the entry before the file,
/// so a kill between the two never brings back an older value.
final class SealedLocalFiles {
  SealedLocalFiles(
    this.family, {
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secure = secureStorage;

  /// One directory per family.
  final String family;
  final FlutterSecureStorage _secure;

  static const drafts = 'drafts';
  static const outbox = 'outbox';
  static const transcripts = 'transcripts';
  static const lists = 'lists';
  static const tombstones = 'tombstones';
  static const shareInbox = 'share_inbox';
  static const families = [
    drafts,
    outbox,
    transcripts,
    lists,
    tombstones,
    shareInbox,
  ];

  /// Secure-storage entry holding the key of every family.
  static const keyKey = 'local_files_key_v1';

  /// Under the app-private support directory (Android `getFilesDir()`),
  /// which neither the cloud backup nor a device transfer copies
  /// (`allowBackup="false"`, the `file` domain excluded in
  /// `data_extraction_rules.xml`).
  static const rootName = 'local_files';

  /// Replaces the files of a family (tests: memory, a temporary directory,
  /// a simulated process death), for the secure storage a store was given.
  @visibleForTesting
  static SealedFileIo Function(String family, FlutterSecureStorage secure)?
  ioForTesting;

  /// Entries known to be gone in this process, per file key.
  static final Map<String, Set<String>> _settled = {};
  static Future<_FileKey>? _creating;

  /// Where [_creating] runs: a creation is joined only from there (a test
  /// that ended with one pending leaves a future no later test can await).
  static Zone? _creatingZone;
  static final Map<(String, String), (Future<void>, Zone)> _moveTails = {};
  static final Map<(String, String, Zone), int> _activeMutators = {};
  static final Map<(String, Zone), int> _activeFamilyMutators = {};
  static final Map<(String, String), int> _entryEpochs = {};
  static final Map<String, int> _familyEpochs = {};

  /// A new process: what this one learned is forgotten (tests; also from
  /// `TurnOutboxStore.resetSerializationForTesting`).
  static void resetForTesting() {
    _settled.clear();
    _creating = null;
    _creatingZone = null;
    _moveTails.clear();
    _activeMutators.clear();
    _activeFamilyMutators.clear();
    _entryEpochs.clear();
    _familyEpochs.clear();
  }

  int _epochOf(String entry) =>
      (_entryEpochs[(family, entry)] ?? 0) + (_familyEpochs[family] ?? 0);

  bool _hasActiveMutator(String entry) {
    final zone = Zone.current.errorZone;
    return (_activeMutators[(family, entry, zone)] ?? 0) > 0 ||
        (_activeFamilyMutators[(family, zone)] ?? 0) > 0;
  }

  void _bumpEntry(String entry) {
    final id = (family, entry);
    _entryEpochs[id] = (_entryEpochs[id] ?? 0) + 1;
  }

  void _bumpFamily() {
    _familyEpochs[family] = (_familyEpochs[family] ?? 0) + 1;
  }

  Future<void> _drainMove(String entry) async {
    final current = _moveTails[(family, entry)];
    if (current != null && identical(current.$2, Zone.current.errorZone)) {
      await current.$1.catchError((_) {});
    }
  }

  Future<T> _mutateEntry<T>(
    String entry,
    Future<T> Function() operation,
  ) async {
    final id = (family, entry, Zone.current.errorZone);
    _bumpEntry(entry);
    _activeMutators[id] = (_activeMutators[id] ?? 0) + 1;
    try {
      await _drainMove(entry);
      return await operation();
    } finally {
      final remaining = (_activeMutators[id] ?? 1) - 1;
      if (remaining <= 0) {
        _activeMutators.remove(id);
      } else {
        _activeMutators[id] = remaining;
      }
      _bumpEntry(entry);
    }
  }

  Future<T> _serializeMove<T>(
    String entry,
    Future<T> Function() operation,
  ) {
    final id = (family, entry);
    final zone = Zone.current.errorZone;
    final prev = _moveTails[id];
    final previous = prev != null && identical(prev.$2, zone)
        ? prev.$1
        : Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> next;
    next = previous
        .catchError((_) {})
        .then((_) async {
          try {
            completer.complete(await operation());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          final current = _moveTails[id];
          if (current != null && identical(current.$1, next)) {
            _moveTails.remove(id);
          }
        });
    _moveTails[id] = (next, zone);
    return completer.future;
  }

  SealedFileIo get _io =>
      ioForTesting?.call(family, _secure) ?? _directoryIo(family, _secure);

  static SealedFileIo _directoryIo(String family, FlutterSecureStorage s) =>
      SecureColdStartStorage(
        secureStorage: s,
        directory: () async {
          final support = await getApplicationSupportDirectory();
          return Directory('${support.path}/$rootName/$family');
        },
      );

  // ── Key ─────────────────────────────────────────────────────────────────

  Future<_FileKey?> _key() async {
    final raw = await _secure.read(key: keyKey);
    final bytes = raw == null ? null : _decodeKey(raw);
    return bytes == null ? null : _FileKey(raw!, ColdStartTailCipher(bytes));
  }

  static Uint8List? _decodeKey(String raw) {
    try {
      final key = base64Decode(raw);
      return key.length == ColdStartTailCipher.keyBytes ? key : null;
    } on FormatException {
      return null;
    }
  }

  /// The key, created when there is none. One creation at a time in this
  /// isolate: two families moving their first entry together get the same
  /// key. A key that cannot be read (the read throws) is never replaced.
  Future<_FileKey> _keyForWrite() async {
    final existing = await _key();
    if (existing != null) return existing;
    final zone = Zone.current.errorZone;
    final running = _creating;
    if (running != null && identical(_creatingZone, zone)) return running;
    late final Future<_FileKey> pending;
    pending = _createKey().whenComplete(() {
      if (identical(_creating, pending)) _creating = null;
    });
    _creating = pending;
    _creatingZone = zone;
    return pending;
  }

  Future<_FileKey> _createKey() async {
    final raw = await _secure.read(key: keyKey);
    final bytes = raw == null ? null : _decodeKey(raw);
    if (bytes != null) return _FileKey(raw!, ColdStartTailCipher(bytes));
    // No usable key: every file there is was sealed with one that is gone
    // (secure storage wiped) and never opens again.
    var lost = 0;
    for (final name in families) {
      final io =
          ioForTesting?.call(name, _secure) ?? _directoryIo(name, _secure);
      for (final file in await io.fileNames()) {
        await io.deleteFile(file);
        lost++;
      }
    }
    if (lost > 0 || raw != null) {
      debugPrint('[local-files] key unavailable, $lost files dropped');
      SecureStorageDiagnostics.record(
        SecureStorageOperation.localFilesKey,
        const SealedFileUnreadable(),
      );
    }
    final key = ColdStartTailCipher.newKey();
    final encoded = base64Encode(key);
    await _secure.write(key: keyKey, value: encoded);
    // On disk before any file depends on it. The flush channel is Android's
    // (`DurableSecretWriter`, attached to every engine of the app).
    if (Platform.isAndroid) await SecureStorage.flushWrites();
    return _FileKey(encoded, ColdStartTailCipher(key));
  }

  // ── Values ──────────────────────────────────────────────────────────────

  /// The file name of [name], or null without a key.
  Future<String?> fileNameOf(SealedName name) async =>
      (await _key())?.cipher.scopedFileName(name.scope, name.key);

  static Uint8List _frame(String key, String value) =>
      utf8.encode('$key\n$value');

  /// The key and the value of an opened file.
  static (String, String)? _unframe(Uint8List content) {
    final newline = content.indexOf(0x0a);
    if (newline < 0) return null;
    try {
      return (
        utf8.decode(Uint8List.sublistView(content, 0, newline)),
        utf8.decode(Uint8List.sublistView(content, newline + 1)),
      );
    } on FormatException {
      return null;
    }
  }

  /// The value of [name]: its file when there is one that opens; otherwise
  /// the secure-storage entry an older version wrote, moved into a file
  /// first when [movable] accepts it (a value the store cannot use is left
  /// where it is, for the store's own unreadable path). Null when there is
  /// neither.
  ///
  /// [fence] (App Lock, `SensitiveReadTicket.ensureCurrent`) runs before
  /// every read and after it, so a revoked read starts no further one.
  ///
  /// Throws [SealedFileUnreadable] when the file does not open and there is
  /// no entry to fall back on.
  Future<String?> read(
    SealedName name, {
    void Function()? fence,
    bool Function(String value)? movable,
    void Function()? onSettled,
  }) async {
    fence?.call();
    final key = await _key();
    fence?.call();
    var unreadable = false;
    if (key != null) {
      final file = key.cipher.scopedFileName(name.scope, name.key);
      final sealed = await _io.readFile(file);
      fence?.call();
      if (sealed != null) {
        final content = await key.cipher.open(file, sealed);
        fence?.call();
        final framed = content == null ? null : _unframe(content);
        if (framed != null && framed.$1 == name.key) {
          await _settle(key, name.key);
          fence?.call();
          onSettled?.call();
          return framed.$2;
        }
        unreadable = true;
      } else if (key.settled(name.key)) {
        onSettled?.call();
        return null;
      }
    }
    final readEpoch = _epochOf(name.key);
    final legacy = await _secure.read(key: name.key);
    fence?.call();
    if (legacy == null) {
      if (unreadable) throw const SealedFileUnreadable();
      key?.settle(name.key);
      onSettled?.call();
      return null;
    }
    if (movable == null || movable(legacy)) {
      try {
        await _move(
          name,
          legacy,
          readEpoch: readEpoch,
          fence: fence,
          onSettled: onSettled,
        );
      } on SensitiveReadUnavailable {
        rethrow;
      } catch (error) {
        // The entry is still the copy; the next read tries again.
        debugPrint('[local-files] move failed (${error.runtimeType})');
        SecureStorageDiagnostics.record(
          SecureStorageOperation.localFilesMove,
          error,
        );
      }
    }
    return legacy;
  }

  Future<void> _move(
    SealedName name,
    String value, {
    required int readEpoch,
    void Function()? fence,
    void Function()? onSettled,
  }) => _serializeMove(name.key, () async {
    bool stale() =>
        _epochOf(name.key) != readEpoch || _hasActiveMutator(name.key);
    fence?.call();
    if (stale()) return;
    final key = await _keyForWrite();
    fence?.call();
    if (stale() || key.settled(name.key)) return;
    final file = key.cipher.scopedFileName(name.scope, name.key);
    final content = _frame(name.key, value);
    final sealed = await key.cipher.seal(file, content);
    fence?.call();
    if (stale()) return;
    await _io.writeFile(file, sealed);
    fence?.call();
    if (stale()) return;
    final back = await _io.readFile(file);
    fence?.call();
    if (stale()) return;
    final opened = back == null ? null : await key.cipher.open(file, back);
    fence?.call();
    if (stale()) return;
    if (opened == null || !listEquals(opened, content)) {
      // Not proven: the entry stays the only copy.
      await _io.deleteFile(file);
      throw const SealedFileUnreadable();
    }
    await _secure.delete(key: name.key);
    key.settle(name.key);
    onSettled?.call();
  });

  /// Deletes an older secure-storage entry whose sealed file is already
  /// known to open, once per process.
  Future<void> settleLegacy(String entry) async {
    final key = await _key();
    if (key == null) return;
    await _settle(key, entry);
  }

  /// The entry an older version kept is deleted once per process (a file
  /// that opens is newer than it, or the same).
  Future<void> _settle(_FileKey key, String entry) async {
    if (key.settled(entry)) return;
    await _secure.delete(key: entry);
    key.settle(entry);
  }

  /// An entry is moved only when it parses as JSON: one that does not is
  /// left where it is, as the store left it before ([read]'s `movable`).
  static bool isJson(String raw) {
    try {
      jsonDecode(raw);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Replaces the value of [name].
  Future<void> write(SealedName name, String value) =>
      _mutateEntry(name.key, () async {
        final key = await _keyForWrite();
        final file = key.cipher.scopedFileName(name.scope, name.key);
        await _io.writeFile(
          file,
          await key.cipher.seal(file, _frame(name.key, value)),
        );
        await _settle(key, name.key);
      });

  /// Deletes the value of [name]: the older entry first, then the file,
  /// then (with [unfinished]) a write of it a process death interrupted.
  /// [unfinished] only where no write of [name] can be in flight (the
  /// store's own queue for it, or a cleanup that holds its scope): it would
  /// delete that write's temporary file.
  Future<void> delete(SealedName name, {bool unfinished = false}) =>
      _mutateEntry(name.key, () async {
        final key = await _key();
        if (key == null || !key.settled(name.key)) {
          await _secure.delete(key: name.key);
          key?.settle(name.key);
        }
        if (key == null) return;
        final file = key.cipher.scopedFileName(name.scope, name.key);
        await _io.deleteFile(file);
        if (unfinished) {
          for (final other in await _io.fileNames()) {
            if (SecureColdStartStorage.partialTarget(other) == file) {
              await _io.deleteFile(other);
            }
          }
        }
      });

  /// Every file of [scope]: a null part matches any (`[connection, null,
  /// chat]`: that chat in every profile); an empty scope is the family.
  /// Each file is opened, unfinished writes too (sealed for the name they
  /// were to get); secure storage is not read (an older entry is found by
  /// its key, [read]).
  Future<SealedScope> readScope(
    List<String?> scope, {
    void Function()? fence,
  }) async {
    final values = <String, String>{};
    final unreadable = <String>[];
    final partial = <String>[];
    final unreadablePartial = <String>[];
    final unfinished = <String, String>{};
    fence?.call();
    final key = await _key();
    fence?.call();
    if (key != null) {
      final names = await _namesIn(key, scope);
      fence?.call();
      for (final file in names) {
        final target = SecureColdStartStorage.partialTarget(file);
        final isPartial = target != null;
        final sealed = await _io.readFile(file);
        fence?.call();
        if (sealed == null) continue;
        final content = await key.cipher.open(target ?? file, sealed);
        fence?.call();
        final framed = content == null ? null : _unframe(content);
        if (isPartial) {
          partial.add(file);
          if (framed != null) {
            unfinished[framed.$1] = framed.$2;
          } else {
            unreadablePartial.add(file);
          }
        } else if (framed == null) {
          unreadable.add(file);
        } else {
          values[framed.$1] = framed.$2;
        }
      }
    }
    return (
      values: values,
      unreadable: unreadable,
      partial: partial,
      unreadablePartial: unreadablePartial,
      unfinished: unfinished,
    );
  }

  /// The writes of [scope] a process death interrupted, by name; nothing is
  /// read. Delete them only where no write of the scope can be in flight
  /// ([delete]).
  Future<List<String>> unfinishedIn(List<String?> scope) async {
    final key = await _key();
    if (key == null) return const [];
    return [
      for (final file in await _namesIn(key, scope))
        if (file.endsWith(SecureColdStartStorage.partialSuffix)) file,
    ];
  }

  Future<List<String>> _namesIn(_FileKey key, List<String?> scope) async {
    final parts = <int, String>{
      for (var i = 0; i < scope.length; i++)
        if (scope[i] != null) i: key.cipher.scopeHash(scope, i),
    };
    return [
      for (final file in await _io.fileNames())
        if (_inScope(file.split('.'), parts)) file,
    ];
  }

  static bool _inScope(List<String> segments, Map<int, String> parts) {
    for (final MapEntry(key: index, value: hash) in parts.entries) {
      // The last two segments are the entry's hash and the suffix.
      if (index >= segments.length - 2 || segments[index] != hash) {
        return false;
      }
    }
    return true;
  }

  /// Deletes files by name ([readScope]).
  Future<void> deleteFiles(Iterable<String> files) async {
    for (final file in files) {
      await _io.deleteFile(file);
    }
  }

  /// Deletes every file of [scope] (see [readScope]) without opening any.
  Future<int> deleteScope(List<String?> scope) async {
    final zone = Zone.current.errorZone;
    final familyId = (family, zone);
    _bumpFamily();
    _activeFamilyMutators[familyId] =
        (_activeFamilyMutators[familyId] ?? 0) + 1;
    try {
      final pending = [
        for (final entry in _moveTails.entries)
          if (entry.key.$1 == family && identical(entry.value.$2, zone))
            entry.value.$1.catchError((_) {}),
      ];
      if (pending.isNotEmpty) await Future.wait(pending);
      final key = await _key();
      if (key == null) return 0;
      final files = await _namesIn(key, scope);
      await deleteFiles(files);
      return files.length;
    } finally {
      final remaining = (_activeFamilyMutators[familyId] ?? 1) - 1;
      if (remaining <= 0) {
        _activeFamilyMutators.remove(familyId);
      } else {
        _activeFamilyMutators[familyId] = remaining;
      }
      _bumpFamily();
    }
  }
}

final class _FileKey {
  _FileKey(this.raw, this.cipher);

  final String raw;
  final ColdStartTailCipher cipher;

  bool settled(String entry) =>
      SealedLocalFiles._settled[raw]?.contains(entry) ?? false;

  void settle(String entry) =>
      (SealedLocalFiles._settled[raw] ??= {}).add(entry);
}
