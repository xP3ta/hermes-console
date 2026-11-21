import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/macs/poly1305.dart';
import 'package:pointycastle/stream/chacha20poly1305.dart';
import 'package:pointycastle/stream/chacha7539.dart';

/// Seals the cold-start tail files: ChaCha20-Poly1305 (the IETF AEAD of RFC
/// 8439, 96-bit nonce), a random 12-byte nonce on every write, the file
/// name as associated data (a file moved to another name does not open).
/// The 32-byte key lives in secure storage; the files themselves never hold
/// an id, a title or a row in clear.
final class ColdStartTailCipher {
  ColdStartTailCipher(Uint8List key) : _key = Uint8List.fromList(key) {
    if (key.length != keyBytes) throw ArgumentError('key length');
  }

  /// A new random key.
  static Uint8List newKey() => _random(keyBytes);

  static const int keyBytes = 32;
  static const int nonceBytes = 12;
  static const int tagBytes = 16;
  static const int _version = 1;

  /// Bytes a sealed file adds to its content: version, nonce and tag.
  static const int overhead = 1 + nonceBytes + tagBytes;

  /// Content above this is sealed and opened off the UI isolate, like the
  /// JSON of a large tail (`decodeJsonOffMain`).
  static const int offMainBytes = 64 * 1024;

  /// Tests: everything on the calling isolate. A widget test runs in a
  /// fake-async zone that never sees another isolate answer.
  @visibleForTesting
  static bool debugOnCallingIsolate = false;

  static const fileSuffix = '.ct';

  final Uint8List _key;

  static final Random _secureRandom = Random.secure();

  static Uint8List _random(int length) => Uint8List.fromList([
    for (var i = 0; i < length; i++) _secureRandom.nextInt(256),
  ]);

  String _hash(String label, String value) => Hmac(
    sha256,
    _key,
  ).convert(utf8.encode('$label\u0000$value')).toString().substring(0, 16);

  /// The first part of every file name of [connectionId].
  String connectionPrefix(String connectionId) =>
      '${_hash('c', connectionId)}.';

  /// The first part of every file name of [connectionId] and [owner].
  String profilePrefix(String connectionId, String owner) =>
      '${connectionPrefix(connectionId)}'
      '${_hash('p', '$connectionId\u0000$owner')}.';

  /// The file of the tail stored under [tailKey]: keyed hashes only, so the
  /// name tells nothing without the key, yet a cleanup of a connection or a
  /// profile still finds its files by prefix.
  String fileName(String connectionId, String owner, String tailKey) =>
      '${profilePrefix(connectionId, owner)}'
      '${_hash('t', tailKey)}$fileSuffix';

  /// The file of [entryKey] under [scope] (a connection first, then what a
  /// cleanup selects by: a profile, a chat): one keyed hash per part and
  /// one of the entry. The files of a connection, of a profile or of a chat
  /// in any profile are found by name ([scopeHash]), and the name tells
  /// nothing without the key.
  String scopedFileName(List<String> scope, String entryKey) => [
    for (var i = 0; i < scope.length; i++) scopeHash(scope, i),
    '${_hash('t', entryKey)}$fileSuffix',
  ].join('.');

  /// Part [index] of every file name under [scope]: it depends on the
  /// connection (`scope[0]`) and on `scope[index]` only.
  String scopeHash(List<String?> scope, int index) => _hash(
    's$index',
    index == 0 ? scope[0]! : '${scope[0]}\u0000${scope[index]}',
  );

  /// [content] sealed for the file [name].
  Future<Uint8List> seal(String name, Uint8List content) {
    final key = _key;
    final nonce = _random(nonceBytes);
    if (content.length <= offMainBytes || debugOnCallingIsolate) {
      return Future.value(_sealed(key, nonce, name, content));
    }
    return Isolate.run(() => _sealed(key, nonce, name, content));
  }

  /// The content of the file [name], or null when it does not open (another
  /// key, a truncated or altered file, another file's bytes).
  Future<Uint8List?> open(String name, Uint8List sealed) {
    final key = _key;
    if (sealed.length <= offMainBytes || debugOnCallingIsolate) {
      return Future.value(_opened(key, name, sealed));
    }
    return Isolate.run(() => _opened(key, name, sealed));
  }

  static Uint8List _sealed(
    Uint8List key,
    Uint8List nonce,
    String name,
    Uint8List content,
  ) {
    final body = aead(
      encrypt: true,
      key: key,
      nonce: nonce,
      associatedData: Uint8List.fromList(utf8.encode(name)),
      input: content,
    );
    return Uint8List(1 + nonceBytes + body.length)
      ..[0] = _version
      ..setRange(1, 1 + nonceBytes, nonce)
      ..setRange(1 + nonceBytes, 1 + nonceBytes + body.length, body);
  }

  static Uint8List? _opened(Uint8List key, String name, Uint8List sealed) {
    if (sealed.length < overhead || sealed[0] != _version) return null;
    try {
      return aead(
        encrypt: false,
        key: key,
        nonce: Uint8List.sublistView(sealed, 1, 1 + nonceBytes),
        associatedData: Uint8List.fromList(utf8.encode(name)),
        input: Uint8List.sublistView(sealed, 1 + nonceBytes),
      );
    } catch (_) {
      // Authentication failed or the bytes are not a sealed file.
      return null;
    }
  }

  /// ChaCha20-Poly1305 with its 128-bit tag: ciphertext followed by the tag
  /// when encrypting; the content when decrypting (throws when the tag
  /// fails). `process()` of this cipher never finishes the message (no
  /// tag is written nor checked), so the final step is called here.
  static Uint8List aead({
    required bool encrypt,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List associatedData,
    required Uint8List input,
  }) {
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(
        encrypt,
        AEADParameters(KeyParameter(key), tagBytes * 8, nonce, associatedData),
      );
    final out = Uint8List(cipher.getOutputSize(input.length));
    var length = cipher.processBytes(input, 0, input.length, out, 0);
    length += cipher.doFinal(out, length);
    return Uint8List.sublistView(out, 0, length);
  }
}
