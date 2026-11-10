// Seals the destination a notification tap opens.
//
// `MainActivity` has to be exported (it is the launcher), and the tap of a
// notification reaches it as a plain `SELECT_NOTIFICATION` intent carrying a
// `payload` string. Any app on the phone can send that intent, so the payload
// alone cannot be trusted to name a chat, a request or a task. Every payload
// the app issues carries a MAC over its own fields, keyed by a random secret
// that lives in the app's private preferences; a tap whose payload does not
// carry a valid MAC is ignored.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationPayloadSeal {
  const NotificationPayloadSeal._();

  static const String prefsKey = 'notif_open_seal_v1';
  static const String field = 'mac';

  static Uint8List? _key;

  /// Whether a key is installed. Without one (unit tests, a process that has
  /// not initialised notifications) payloads are neither sealed nor checked.
  static bool get installed => _key != null;

  /// Installs the key from [prefs], creating it the first time.
  static void ensure(SharedPreferences prefs) {
    final stored = prefs.getString(prefsKey);
    if (stored != null && stored.isNotEmpty) {
      try {
        final bytes = base64Url.decode(base64Url.normalize(stored));
        if (bytes.length >= 32) {
          _key = Uint8List.fromList(bytes);
          return;
        }
      } on FormatException {
        // A damaged value is replaced below.
      }
    }
    final random = Random.secure();
    final fresh = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    _key = fresh;
    prefs.setString(prefsKey, base64Url.encode(fresh));
  }

  @pragma('vm:visible-for-testing')
  static void installForTesting(List<int>? key) {
    _key = key == null ? null : Uint8List.fromList(key);
  }

  static String _mac(Map<String, dynamic> body) {
    final hmac = Hmac(sha256, _key!);
    return base64Url
        .encode(hmac.convert(utf8.encode(jsonEncode(body))).bytes)
        .replaceAll('=', '');
  }

  /// [body] with its `mac` field added, or [body] itself when no key is
  /// installed.
  static Map<String, dynamic> seal(Map<String, dynamic> body) {
    if (_key == null) return body;
    return {...body, field: _mac(body)};
  }

  /// True when [payload] is a JSON object whose `mac` matches its other
  /// fields. Always true while no key is installed.
  static bool verify(String? payload) {
    if (_key == null) return true;
    if (payload == null || payload.isEmpty) return false;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return false;
      final given = decoded[field];
      if (given is! String || given.isEmpty) return false;
      final body = Map<String, dynamic>.of(decoded)..remove(field);
      final expected = _mac(body);
      if (given.length != expected.length) return false;
      var diff = 0;
      for (var i = 0; i < expected.length; i++) {
        diff |= given.codeUnitAt(i) ^ expected.codeUnitAt(i);
      }
      return diff == 0;
    } on FormatException {
      return false;
    }
  }
}
