/// Índice de prompts del chat (salto a un prompt). Funciones puras: derivan las
/// entradas desde la transcripción ya cargada, sin I/O ni estado.
///
/// Reglas portadas de `deriveTimelineEntries`/`timelinePreview` de Desktop:
/// una entrada por mensaje de usuario con texto no vacío, vista previa con los
/// espacios colapsados y como mucho 120 caracteres terminados en `…`, y entrada
/// activa = último prompt a la altura del borde superior (8 px de holgura) o,
/// si no hay ninguno, el primero pintado.
library;

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

/// True when [message] is a user row with text: the rows that open a turn and
/// appear in the prompt list.
bool isChatPromptMessage(Map<String, dynamic> message) {
  if (message['role'] != 'user') return false;
  final content = message['content'];
  return content is String && content.trim().isNotEmpty;
}

/// Índice, en [newestFirst], del prompt que abrió el turno al que pertenece la
/// fila [topIndex] (la que cruza el borde superior del viewport). El prompt es
/// la fila de usuario más próxima hacia atrás en el tiempo; recorre solo la
/// longitud de ese turno.
int? stickyPromptIndex(List<Map<String, dynamic>> newestFirst, int topIndex) {
  if (topIndex < 0 || topIndex >= newestFirst.length) return null;
  for (var i = topIndex; i < newestFirst.length; i++) {
    if (isChatPromptMessage(newestFirst[i])) return i;
  }
  return null;
}

/// Entradas de [newestFirst] (el orden de la transcripción del chat), más
/// reciente primero.
List<ChatPromptEntry> deriveChatPromptEntries(
  List<Map<String, dynamic>> newestFirst,
) {
  final entries = <ChatPromptEntry>[];
  for (var i = 0; i < newestFirst.length; i++) {
    final message = newestFirst[i];
    if (!isChatPromptMessage(message)) continue;
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
