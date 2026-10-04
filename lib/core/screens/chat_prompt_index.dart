/// Índice de prompts del chat (salto a un prompt). Funciones puras: derivan las
/// entradas desde la transcripción ya cargada, sin I/O ni estado.
///
/// Reglas portadas de `deriveTimelineEntries`/`timelinePreview` de Desktop:
/// una entrada por mensaje de usuario con texto no vacío, vista previa con los
/// espacios colapsados y como mucho 120 caracteres terminados en `…`, y entrada
/// activa = último prompt a la altura del borde superior (8 px de holgura) o,
/// si no hay ninguno, el primero pintado.
library;

import '../utils/chat_turn.dart';

const int chatPromptPreviewMax = 120;
const double chatPromptActiveSlack = 8;

class ChatPromptEntry {
  const ChatPromptEntry({
    required this.message,
    required this.messageIndex,
    required this.preview,
  });

  /// Mensaje de la transcripción (identidad, para localizar su ancla).
  final Map<String, dynamic> message;

  /// Posición en la lista recibida (más reciente primero).
  final int messageIndex;
  final String preview;
}

String chatPromptPreview(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = flat.runes.toList(growable: false);
  if (runes.length <= chatPromptPreviewMax) return flat;
  final head = String.fromCharCodes(runes.take(chatPromptPreviewMax - 1))
      .trimRight();
  return '$head…';
}

// A complete process notification: the whole row is one bracketed
// `[IMPORTANT: Background process …]`. A prompt that merely starts with those
// words (no closing bracket at the end of the row) is not matched.
final RegExp _completeProcessNotification = RegExp(
  r'^\[IMPORTANT: Background process [\s\S]*\]$',
);

/// True when [message] is a user row with text: the rows that open a turn and
/// appear in the prompt list.
///
/// Process-notification carriers (Hermes writes them as user rows) are not
/// prompts: Desktop's timeline skips them too. Only a row that is entirely the
/// notification is dropped (the structured carrier through the visible-content
/// projection, any other complete bracketed row through the anchored pattern),
/// so a real prompt that merely starts with the same words stays a prompt.
/// [isSystemRow] drops other rows the transcript paints as system chips instead of prompts.
bool isChatPromptMessage(
  Map<String, dynamic> message, {
  bool Function(Map<String, dynamic> message)? isSystemRow,
}) {
  if (message['role'] != 'user') return false;
  final content = message['content'];
  if (content is! String || content.trim().isEmpty) return false;
  if (_completeProcessNotification.hasMatch(content.trim())) return false;
  if (projectedUserVisibleContent(message).trim().isEmpty) return false;
  return isSystemRow == null || !isSystemRow(message);
}

/// Índice, en [newestFirst], del prompt que abrió el turno al que pertenece la
/// fila [topIndex] (la que cruza el borde superior del viewport). El prompt es
/// la fila de usuario más próxima hacia atrás en el tiempo; recorre solo la
/// longitud de ese turno.
int? stickyPromptIndex(
  List<Map<String, dynamic>> newestFirst,
  int topIndex, {
  bool Function(Map<String, dynamic> message)? isSystemRow,
}) {
  if (topIndex < 0 || topIndex >= newestFirst.length) return null;
  for (var i = topIndex; i < newestFirst.length; i++) {
    if (isChatPromptMessage(newestFirst[i], isSystemRow: isSystemRow)) return i;
  }
  return null;
}

/// Entradas de [newestFirst] (el orden de la transcripción del chat), más
/// reciente primero.
List<ChatPromptEntry> deriveChatPromptEntries(
  List<Map<String, dynamic>> newestFirst, {
  bool Function(Map<String, dynamic> message)? isSystemRow,
}) {
  final entries = <ChatPromptEntry>[];
  for (var i = 0; i < newestFirst.length; i++) {
    final message = newestFirst[i];
    if (!isChatPromptMessage(message, isSystemRow: isSystemRow)) continue;
    entries.add(
      ChatPromptEntry(
        message: message,
        messageIndex: i,
        preview: chatPromptPreview(message['content'] as String),
      ),
    );
  }
  return entries;
}

/// Índice de la entrada activa dado el borde superior de cada prompt respecto
/// al viewport (`null` si no está pintado). Orden de [tops] libre.
int? activeChatPromptIndex(
  List<double?> tops, {
  double slack = chatPromptActiveSlack,
}) {
  int? atOrAbove;
  double? atOrAboveTop;
  int? first;
  double? firstTop;
  for (var i = 0; i < tops.length; i++) {
    final top = tops[i];
    if (top == null) continue;
    if (top <= slack && (atOrAboveTop == null || top > atOrAboveTop)) {
      atOrAbove = i;
      atOrAboveTop = top;
    }
    if (firstTop == null || top < firstTop) {
      first = i;
      firstTop = top;
    }
  }
  return atOrAbove ?? first;
}

/// Id de fila durable del mensaje (nunca el texto). Mismas claves que el
/// servicio de transcripción usa para identificar filas.
int? chatPromptRowId(Map<String, dynamic> message) {
  for (final key in const ['_desktopRowId', 'row_id', '_row_id', 'id']) {
    final value = message[key];
    if (value is int) return value;
  }
  return null;
}

/// Un renglón de la lista de prompts: cargado en la transcripción
/// ([message] no nulo) o solo conocido por el índice del servidor.
class ChatPromptItem {
  const ChatPromptItem({required this.preview, this.message, this.rowId});

  final String preview;

  /// Mensaje ya cargado; null si hay que traer páginas anteriores para llegar.
  final Map<String, dynamic>? message;

  /// Id de fila durable (`null` si el mensaje cargado no lo lleva).
  final int? rowId;
}

/// Une los prompts cargados (más reciente primero) con los del índice del
/// servidor. Del índice solo entran las filas más antiguas que el prompt
/// cargado más antiguo —o que [oldestLoadedRowId] si se conoce—: las demás ya
/// están cargadas. Sin ancla durable no se puede deduplicar y el índice se
/// ignora. El resultado va de más reciente a más antiguo.
List<ChatPromptItem> mergeChatPromptItems(
  List<ChatPromptEntry> loaded,
  Iterable<({int rowId, String preview})> remote, {
  int? oldestLoadedRowId,
}) {
  final items = <ChatPromptItem>[
    for (final entry in loaded)
      ChatPromptItem(
        preview: entry.preview,
        message: entry.message,
        rowId: chatPromptRowId(entry.message),
      ),
  ];
  var anchor = oldestLoadedRowId;
  for (final item in items) {
    final id = item.rowId;
    if (id != null && (anchor == null || id < anchor)) anchor = id;
  }
  if (anchor == null) return items;
  final older = [
    for (final entry in remote)
      if (entry.rowId < anchor) entry,
  ]..sort((a, b) => b.rowId.compareTo(a.rowId));
  final seen = <int>{};
  for (final entry in older) {
    if (!seen.add(entry.rowId)) continue;
    items.add(
      ChatPromptItem(
        preview: chatPromptPreview(entry.preview),
        rowId: entry.rowId,
      ),
    );
  }
  return items;
}
