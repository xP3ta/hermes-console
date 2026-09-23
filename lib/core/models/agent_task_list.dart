import 'dart:convert';

/// Estado de un elemento de la lista de tareas del agente (herramienta
/// `todo_list`). Es el mismo vocabulario que Desktop y la TUI
/// (`tools/todo_tool.py VALID_STATUSES`).
enum AgentTaskStatus { pending, inProgress, completed, cancelled }

/// Un elemento de la lista. Todo el texto ya viene saneado por
/// [AgentTaskList.tryParse]: se pinta siempre como texto plano.
final class AgentTaskItem {
  const AgentTaskItem({
    required this.id,
    required this.content,
    required this.status,
    this.parentId,
  });

  final String id;
  final String content;
  final AgentTaskStatus status;

  /// Id de otro elemento cuando este es una subtarea. Puede apuntar a un id
  /// inexistente o formar un ciclo si el gateway fuese defectuoso; [AgentTaskList.rows]
  /// lo degrada a raíz en vez de fallar.
  final String? parentId;

  bool get isOpen =>
      status == AgentTaskStatus.pending || status == AgentTaskStatus.inProgress;

  @override
  bool operator ==(Object other) =>
      other is AgentTaskItem &&
      other.id == id &&
      other.content == content &&
      other.status == status &&
      other.parentId == parentId;

  @override
  int get hashCode => Object.hash(id, content, status, parentId);
}

/// Fila ya ordenada para pintar: elemento + profundidad de anidamiento.
typedef AgentTaskRow = ({AgentTaskItem item, int depth});

/// Instantánea COMPLETA de la lista de tareas de una sesión.
///
/// Fuente única de verdad: `todo.updated` en vivo y `todo_state` de
/// `session.resume`/`session.activate` traen la lista entera con una
/// `revision` monótona (`tui_gateway/tool_progress.py`). Nunca se aplica un
/// diff; una revisión más antigua no pisa a una más nueva.
final class AgentTaskList {
  const AgentTaskList({
    required this.revision,
    required this.items,
    this.omitted = 0,
  });

  static const AgentTaskList empty = AgentTaskList(revision: null, items: []);

  /// Topes defensivos: el backend admite 256 elementos de 4000 caracteres,
  /// pero la UI móvil no necesita más y una lista hostil no debe crecer sin
  /// límite en memoria ni en el árbol de widgets.
  static const int maxItems = 200;
  static const int maxContentChars = 240;
  static const int maxIdChars = 128;
  static const int maxRawJsonChars = 512000;

  /// `null` cuando el payload no trae revisión (gateways antiguos): se aplica
  /// sin mover la marca de agua.
  final int? revision;
  final List<AgentTaskItem> items;

  /// Elementos válidos que no caben en [maxItems].
  final int omitted;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  /// Las tareas canceladas no cuentan a ningún lado de la fracción (regla de
  /// la tarjeta lateral de Desktop): no son trabajo pendiente ni hecho.
  int get total =>
      items.where((item) => item.status != AgentTaskStatus.cancelled).length;
  int get done =>
      items.where((item) => item.status == AgentTaskStatus.completed).length;
  int get cancelledCount =>
      items.where((item) => item.status == AgentTaskStatus.cancelled).length;
  int get openCount => items.where((item) => item.isOpen).length;
  bool get hasOpen => items.any((item) => item.isOpen);

  /// Todo completado o cancelado (y hay algo). Una lista vacía no está
  /// «terminada»: es una lista borrada.
  bool get isFinished => items.isNotEmpty && !hasOpen;

  double get progress {
    final counted = total;
    return counted == 0 ? 0 : done / counted;
  }

  /// Primer elemento en curso (la lista es prioridad-por-posición).
  AgentTaskItem? get current {
    for (final row in rows) {
      if (row.item.status == AgentTaskStatus.inProgress) return row.item;
    }
    return null;
  }

  /// Orden de pintado: recorrido en profundidad, padres antes que hijos.
  /// Padres inexistentes o ciclos degradan a raíz para no perder elementos
  /// (mismo criterio que `todoTree` en Desktop y la TUI).
  List<AgentTaskRow> get rows {
    final ids = {for (final item in items) item.id};
    final children = <String, List<AgentTaskItem>>{};
    final roots = <AgentTaskItem>[];
    for (final item in items) {
      final parent = item.parentId;
      if (parent != null && parent != item.id && ids.contains(parent)) {
        (children[parent] ??= <AgentTaskItem>[]).add(item);
      } else {
        roots.add(item);
      }
    }
    final out = <AgentTaskRow>[];
    final seen = <String>{};
    void walk(AgentTaskItem item, int depth) {
      if (!seen.add(item.id)) return;
      out.add((item: item, depth: depth));
      for (final child in children[item.id] ?? const <AgentTaskItem>[]) {
        walk(child, depth + 1);
      }
    }

    for (final root in roots) {
      walk(root, 0);
    }
    // Los miembros de un ciclo nunca cuelgan de una raíz: se añaden planos.
    for (final item in items) {
      if (seen.add(item.id)) out.add((item: item, depth: 0));
    }
    return List<AgentTaskRow>.unmodifiable(out);
  }

  bool sameContentAs(AgentTaskList other) {
    if (identical(this, other)) return true;
    if (other.omitted != omitted || other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (items[i] != other.items[i]) return false;
    }
    return true;
  }

  /// Interpreta `{todos:[...], revision:n}` (mapa o su JSON serializado).
  ///
  /// Devuelve `null` cuando NO es una instantánea utilizable (forma ajena,
  /// JSON roto o el almacén sin uso `{[], 0}`); una lista vacía con revisión
  /// >= 1 sí lo es: significa «el agente la borró».
  static AgentTaskList? tryParse(Object? raw) {
    Object? value = raw;
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty || text.length > maxRawJsonChars) return null;
      try {
        value = jsonDecode(text);
      } on FormatException {
        return null;
      }
    }
    if (value is! Map) return null;
    final rawTodos = value['todos'];
    if (rawTodos is! List) return null;

    final revision = _parseRevision(value['revision']);
    // Duplicados por id: gana la última aparición, en su posición (el
    // gateway hace lo mismo en `_dedupe_by_id`).
    final byId = <String, AgentTaskItem>{};
    final order = <String>[];
    var valid = 0;
    for (final entry in rawTodos.take(maxItems * 4)) {
      final item = _parseItem(entry);
      if (item == null) continue;
      if (byId.containsKey(item.id)) order.remove(item.id);
      byId[item.id] = item;
      order.add(item.id);
      valid = order.length;
    }
    if (order.isEmpty && (revision ?? 0) == 0) return null;
    final kept = order.take(maxItems).map((id) => byId[id]!).toList();
    return AgentTaskList(
      revision: revision,
      items: List<AgentTaskItem>.unmodifiable(kept),
      omitted: valid > maxItems ? valid - maxItems : 0,
    );
  }

  static int? _parseRevision(Object? raw) {
    final value = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (value == null || value < 0) return null;
    return value;
  }

  static AgentTaskItem? _parseItem(Object? raw) {
    if (raw is! Map) return null;
    final id = sanitizeAgentTaskText(
      '${raw['id'] ?? ''}',
      maxChars: maxIdChars,
      mask: false,
      collapse: false,
    );
    final content = sanitizeAgentTaskText(
      '${raw['content'] ?? ''}',
      maxChars: maxContentChars,
    );
    if (id.isEmpty || content.isEmpty) return null;
    final status = switch ('${raw['status'] ?? ''}'.trim().toLowerCase()) {
      'in_progress' => AgentTaskStatus.inProgress,
      'completed' => AgentTaskStatus.completed,
      'cancelled' => AgentTaskStatus.cancelled,
      // `pending`, ausente o desconocido: el backend también lo normaliza a
      // pendiente (`TodoStore._validate`).
      _ => AgentTaskStatus.pending,
    };
    final rawParent = raw['parent'];
    final parent = rawParent == null
        ? ''
        : sanitizeAgentTaskText(
            '$rawParent',
            maxChars: maxIdChars,
            mask: false,
            collapse: false,
          );
    return AgentTaskItem(
      id: id,
      content: content,
      status: status,
      parentId: parent.isEmpty || parent == id ? null : parent,
    );
  }
}

final RegExp _controlChars = RegExp('[\\x00-\\x08\\x0b-\\x1f\\x7f]');
final RegExp _lineBreaks = RegExp('[\\t\\n\\r\\u2028\\u2029]+');
// Controles bidireccionales: pueden invertir el texto que los rodea.
final RegExp _bidiControls = RegExp(
  '[\\u202a-\\u202e\\u2066-\\u2069\\u200e\\u200f]',
);
final RegExp _spaceRuns = RegExp(r' {2,}');

const String _masked = '••••';

// Forma de credenciales, no un detector exhaustivo: el texto de una tarea lo
// escribe el modelo y puede haber copiado un valor del entorno.
final List<RegExp> _secretShapes = [
  RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
  RegExp(r'\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
  RegExp(r'\bxox[abposr]-[A-Za-z0-9-]{10,}'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{12,}', caseSensitive: false),
  RegExp(r'\b[A-Fa-f0-9]{32,}\b'),
  // Racha larga de base64/hex con letras Y dígitos: una credencial, no un
  // identificador snake_case largo.
  RegExp(
    r'(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])'
    r'[A-Za-z0-9+/_-]{40,}={0,2}',
  ),
];
final RegExp _keyedSecret = RegExp(
  r'\b(api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|authorization)(\s*[:=]\s*)("[^"]{8,}"|'
  "'[^']{8,}'"
  r'|\S{8,})',
  caseSensitive: false,
);

/// Sanea el texto de una tarea: quita controles y saltos de línea, elimina los
/// controles bidi, colapsa espacios, enmascara formas de credencial y recorta.
/// Se pinta siempre como texto plano (nunca markdown/HTML).
String sanitizeAgentTaskText(
  String value, {
  required int maxChars,
  bool mask = true,
  bool collapse = true,
}) {
  var text = value
      .replaceAll(_lineBreaks, ' ')
      .replaceAll(_bidiControls, '')
      .replaceAll(_controlChars, '');
  if (mask) {
    text = text.replaceAllMapped(
      _keyedSecret,
      (match) => '${match.group(1)}${match.group(2)}$_masked',
    );
    for (final shape in _secretShapes) {
      text = text.replaceAll(shape, _masked);
    }
  }
  if (collapse) text = text.replaceAll(_spaceRuns, ' ');
  text = text.trim();
  if (text.length > maxChars) {
    final cut = text.substring(0, maxChars - 1).trimRight();
    text = '$cut…';
  }
  return text;
}
