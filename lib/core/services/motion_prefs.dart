import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cursor que acompaña a la respuesta mientras llega en streaming.
enum StreamingCursorStyle {
  off,
  line,
  block,
  underscore;

  static StreamingCursorStyle fromName(String? name) {
    for (final style in values) {
      if (style.name == name) return style;
    }
    return StreamingCursorStyle.off;
  }
}

/// Ajustes de movimiento opcionales del dispositivo: el cursor de la
/// respuesta en streaming (nace apagado). «Reducir movimiento» del sistema lo
/// anula siempre.
///
/// El cambio de tema con círculo que se expande ya no es un ajuste: está
/// SIEMPRE activo (ver `HermesThemeRevealHost`) para todos, también para quien lo hubiera
/// apagado en una versión anterior (la clave `motion_theme_reveal` guardada
/// ya no se lee). Solo «reducir movimiento» del sistema lo omite.
class MotionPrefs extends ChangeNotifier {
  MotionPrefs._(this._prefs)
    : _cursor = StreamingCursorStyle.fromName(_prefs?.getString(cursorKey));

  static const String cursorKey = 'motion_streaming_cursor';

  final SharedPreferences? _prefs;
  StreamingCursorStyle _cursor;

  static MotionPrefs? _shared;

  static MotionPrefs get shared => _shared ??= MotionPrefs._(null);

  static Future<MotionPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = MotionPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(MotionPrefs? store) => _shared = store;

  StreamingCursorStyle get cursor => _cursor;

  Future<void> setCursor(StreamingCursorStyle value) async {
    if (_cursor == value) return;
    _cursor = value;
    notifyListeners();
    await _prefs?.setString(cursorKey, value.name);
  }
}
