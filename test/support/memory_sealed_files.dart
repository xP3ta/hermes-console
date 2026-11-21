// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hermes_android/core/services/cold_start_store.dart'
    show SecureColdStartStorage;
import 'package:hermes_android/core/services/cold_start_tail_cipher.dart';
import 'package:hermes_android/core/services/sealed_local_files.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

/// The files of one [SealedLocalFiles] family, in memory. Every test isolate
/// starts with these ([install], from `flutter_test_config.dart`): widget
/// tests run in a fake-async zone where real file I/O never completes. A
/// test about the files themselves gives its own directory.
class MemorySealedFileIo implements SealedFileIo {
  static final Map<String, MemorySealedFileIo> families = {};

  /// Every family of [SealedLocalFiles] in memory again, with no hook.
  static void install() {
    for (final io in families.values) {
      io.resetHooks();
    }
    SealedLocalFiles.ioForTesting = (family, _) => of(family);
  }

  static MemorySealedFileIo of(String family) =>
      families.putIfAbsent(family, MemorySealedFileIo.new);

  final Map<String, Uint8List> files = {};

  /// Files read and written since [resetHooks].
  int reads = 0;
  int writes = 0;
  final List<String> readNames = [];

  /// Runs before each read or write of a file: it may wait (a gate) or
  /// throw (a storage failure, a process death).
  Future<void> Function(String name)? beforeRead;
  Future<void> Function(String name)? beforeWrite;
  Future<void> Function(String name)? beforeDelete;

  void resetHooks() {
    reads = 0;
    writes = 0;
    readNames.clear();
    beforeRead = null;
    beforeWrite = null;
    beforeDelete = null;
  }

  @override
  Future<Uint8List?> readFile(String name) async {
    reads++;
    readNames.add(name);
    await beforeRead?.call(name);
    return files[name];
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    writes++;
    await beforeWrite?.call(name);
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> deleteFile(String name) async {
    await beforeDelete?.call(name);
    files.remove(name);
  }

  @override
  Future<List<String>> fileNames() async => files.keys.toList();
}

/// The in-memory files of [family], starting empty, with each write and
/// deletion observed around it (what a test used to see on the
/// secure-storage channel).
class ObservedSealedFileIo implements SealedFileIo {
  ObservedSealedFileIo(
    this.family, {
    this.onWrite,
    this.afterWrite,
    this.onDelete,
    this.afterDelete,
  }) {
    _files.files.clear();
  }

  final String family;
  final Future<void>? Function(String name, Uint8List bytes)? onWrite;
  final void Function(String name)? afterWrite;
  final Future<void>? Function(String name)? onDelete;
  final void Function(String name)? afterDelete;

  MemorySealedFileIo get _files => MemorySealedFileIo.of(family);

  @override
  Future<Uint8List?> readFile(String name) => _files.readFile(name);

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    await onWrite?.call(name, bytes);
    await _files.writeFile(name, bytes);
    afterWrite?.call(name);
  }

  /// A temporary file of an unfinished write is not the value: its
  /// deletion is not observed.
  @override
  Future<void> deleteFile(String name) async {
    final unfinished = name.endsWith(SecureColdStartStorage.partialSuffix);
    if (!unfinished) await onDelete?.call(name);
    await _files.deleteFile(name);
    if (!unfinished) afterDelete?.call(name);
  }

  @override
  Future<List<String>> fileNames() => _files.fileNames();

  /// [SealedLocalFiles.ioForTesting]: this for [family], memory for the
  /// others. Undone by [MemorySealedFileIo.install].
  void install() => SealedLocalFiles.ioForTesting = (name, _) =>
      name == family ? this : MemorySealedFileIo.of(name);
}

/// A family's files in memory, each read, write and deletion handed to
/// [before] first, by the method a secure-storage call would have had.
class HookedSealedFileIo implements SealedFileIo {
  HookedSealedFileIo(this.files, this.before);

  final MemorySealedFileIo files;
  final Future<void> Function(String method, String name) before;

  /// Every family hooked through [before], each starting with no file.
  static void install(Future<void> Function(String method, String name) b) {
    for (final family in SealedLocalFiles.families) {
      MemorySealedFileIo.of(family).files.clear();
    }
    SealedLocalFiles.ioForTesting = (family, _) =>
        HookedSealedFileIo(MemorySealedFileIo.of(family), b);
  }

  @override
  Future<Uint8List?> readFile(String name) async {
    await before('read', name);
    return files.readFile(name);
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    await before('write', name);
    await files.writeFile(name, bytes);
  }

  @override
  Future<void> deleteFile(String name) async {
    await before('delete', name);
    await files.deleteFile(name);
  }

  @override
  Future<List<String>> fileNames() => files.fileNames();
}

/// The values of the in-memory sealed files ([MemorySealedFileIo]) by the
/// secure-storage key each one had (`chat_turn_outbox_v1`, a draft key…),
/// read and written synchronously so widget tests can look at them.
/// [secure] is the mocked secure storage holding the file key.
final class SealedValues {
  SealedValues(this.secure, {this.readFile});

  final Map<String, String> secure;

  /// Reads the file of a family by name ([] only); memory by default.
  final Uint8List? Function(String family, String name)? readFile;

  static final _random = Random.secure();

  static final _listKey = RegExp(
    r'^cold_start_(?:recents|list)_v1\.([0-9a-f]*)\.([0-9a-f]*)$',
  );

  /// The family and scope of [key], as the stores name its file.
  static (String, SealedName)? nameOf(String key) {
    if (key.startsWith('chat_draft_v3.')) {
      return (
        SealedLocalFiles.drafts,
        AttachmentOwnershipCoordinator.draftName(key),
      );
    }
    const transcript = 'hermes.transcript.v3.';
    if (key.startsWith(transcript)) {
      final parts = key.substring(transcript.length).split('.');
      if (parts.length != 3) return null;
      final scope = parts.map(_unhex).toList();
      return (SealedLocalFiles.transcripts, SealedName(key, scope));
    }
    final list = _listKey.firstMatch(key);
    if (list != null) {
      final scope = [_unhex(list[1]!), _unhex(list[2]!)];
      return (SealedLocalFiles.lists, SealedName(key, scope));
    }
    return switch (key) {
      'chat_turn_outbox_v1' => (SealedLocalFiles.outbox, SealedName(key)),
      'cancelled_turn_tombstones_v2' => (
        SealedLocalFiles.tombstones,
        SealedName(key),
      ),
      'android_share_inbox_v1' => (
        SealedLocalFiles.shareInbox,
        SealedName(key),
      ),
      _ => null,
    };
  }

  static String _unhex(String value) => String.fromCharCodes([
    for (var i = 0; i + 4 <= value.length; i += 4)
      int.parse(value.substring(i, i + 4), radix: 16),
  ]);

  Uint8List? get _fileKey {
    final raw = secure[SealedLocalFiles.keyKey];
    if (raw == null) return null;
    final key = base64Decode(raw);
    return key.length == ColdStartTailCipher.keyBytes ? key : null;
  }

  static (String, String) _file(String key, Uint8List fileKey) {
    final name = nameOf(key);
    if (name == null) throw ArgumentError.value(key, 'key', 'not sealed');
    final (family, sealed) = name;
    return (
      family,
      ColdStartTailCipher(fileKey).scopedFileName(sealed.scope, sealed.key),
    );
  }

  /// The value of [key] in its file, or null when there is none that opens.
  String? operator [](String key) {
    final fileKey = _fileKey;
    if (fileKey == null) return null;
    final (family, name) = _file(key, fileKey);
    final sealed =
        readFile?.call(family, name) ??
        MemorySealedFileIo.of(family).files[name];
    if (sealed == null) return null;
    final framed = _open(fileKey, name, sealed);
    return framed != null && framed.$1 == key ? framed.$2 : null;
  }

  bool containsKey(String key) => this[key] != null;

  /// The value sealed in [bytes], the file [name] (a write in flight).
  String? valueOfFile(String name, Uint8List bytes) {
    final fileKey = _fileKey;
    return fileKey == null ? null : _open(fileKey, name, bytes)?.$2;
  }

  /// The key of the value sealed in [bytes], the file [name].
  String? keyOfFile(String name, Uint8List bytes) {
    final fileKey = _fileKey;
    return fileKey == null ? null : _open(fileKey, name, bytes)?.$1;
  }

  /// The name of the file of [key], or null without a file key.
  String? fileNameOf(String key) {
    final fileKey = _fileKey;
    return fileKey == null ? null : _file(key, fileKey).$2;
  }

  /// Writes [value] into the file of [key] (null deletes it), creating the
  /// file key when the secure storage has none.
  void operator []=(String key, String? value) {
    var fileKey = _fileKey;
    if (fileKey == null) {
      fileKey = ColdStartTailCipher.newKey();
      secure[SealedLocalFiles.keyKey] = base64Encode(fileKey);
    }
    final (family, name) = _file(key, fileKey);
    final io = MemorySealedFileIo.of(family);
    if (value == null) {
      io.files.remove(name);
      return;
    }
    io.files[name] = _seal(fileKey, name, utf8.encode('$key\n$value'));
  }

  void remove(String key) => this[key] = null;

  /// The keys of every value whose file opens with the current key.
  Set<String> get keys {
    final fileKey = _fileKey;
    if (fileKey == null) return {};
    return {
      for (final io in MemorySealedFileIo.families.values)
        for (final MapEntry(key: name, value: sealed) in io.files.entries)
          ?_open(fileKey, name, sealed)?.$1,
    };
  }

  static (String, String)? _open(Uint8List key, String name, Uint8List data) {
    const nonce = ColdStartTailCipher.nonceBytes;
    if (data.length < ColdStartTailCipher.overhead || data[0] != 1) {
      return null;
    }
    final Uint8List content;
    try {
      content = ColdStartTailCipher.aead(
        encrypt: false,
        key: key,
        nonce: Uint8List.sublistView(data, 1, 1 + nonce),
        associatedData: Uint8List.fromList(utf8.encode(name)),
        input: Uint8List.sublistView(data, 1 + nonce),
      );
    } catch (_) {
      return null;
    }
    final text = utf8.decode(content);
    final newline = text.indexOf('\n');
    if (newline < 0) return null;
    return (text.substring(0, newline), text.substring(newline + 1));
  }

  static Uint8List _seal(Uint8List key, String name, Uint8List content) {
    final nonce = Uint8List.fromList([
      for (var i = 0; i < ColdStartTailCipher.nonceBytes; i++)
        _random.nextInt(256),
    ]);
    final body = ColdStartTailCipher.aead(
      encrypt: true,
      key: key,
      nonce: nonce,
      associatedData: Uint8List.fromList(utf8.encode(name)),
      input: content,
    );
    return Uint8List.fromList([1, ...nonce, ...body]);
  }
}
