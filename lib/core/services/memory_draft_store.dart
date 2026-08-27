import 'package:shared_preferences/shared_preferences.dart';

/// Borradores locales de archivos de memoria.
///
/// La API /api/memory es solo lectura (metadatos): no existe endpoint para
/// leer ni escribir el contenido remoto. Este store guarda borradores LOCALES
/// por instancia+perfil+archivo y nunca sincroniza nada — la UI debe dejarlo
/// claro. Las claves sin perfil conservan compatibilidad con borradores legacy.
class MemoryDraftStore {
  final SharedPreferences prefs;

  MemoryDraftStore(this.prefs);

  static String _scope(String connId, String? profile) {
    final value = profile?.trim() ?? '';
    if (value.isEmpty || value == 'default') return connId;
    return '$connId::profile=${Uri.encodeComponent(value)}';
  }

  static String _key(String connId, String name, String? profile) =>
      'memory_draft::${_scope(connId, profile)}::$name';
  static String _tsKey(String connId, String name, String? profile) =>
      'memory_draft_ts::${_scope(connId, profile)}::$name';

  bool exists(String connId, String name, {String? profile}) =>
      prefs.containsKey(_key(connId, name, profile));

  String? read(String connId, String name, {String? profile}) =>
      prefs.getString(_key(connId, name, profile));

  DateTime? updatedAt(String connId, String name, {String? profile}) {
    final ms = prefs.getInt(_tsKey(connId, name, profile));
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> write(
    String connId,
    String name,
    String text, {
    String? profile,
  }) async {
    await prefs.setString(_key(connId, name, profile), text);
    await prefs.setInt(
      _tsKey(connId, name, profile),
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> delete(String connId, String name, {String? profile}) async {
    await prefs.remove(_key(connId, name, profile));
    await prefs.remove(_tsKey(connId, name, profile));
  }
}
