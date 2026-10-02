import '../services/session_reconciler.dart';
import '../utils/chat_turn.dart';
import '../widgets/chat_event_cards.dart';

Set<String> _delegateTaskCallIds(List<Map<String, dynamic>> messages) {
  final ids = <String>{};
  for (final message in messages) {
    final calls = message['tool_calls'];
    if (calls is! List) continue;
    for (final raw in calls) {
      if (raw is! Map) continue;
      final function = raw['function'];
      final name = function is Map ? function['name'] : null;
      if (name?.toString().trim().toLowerCase() != 'delegate_task') continue;
      final id = raw['id']?.toString().trim();
      if (id != null && id.isNotEmpty) ids.add(id);
    }
  }
  return ids;
}

bool _hasCanonicalReasoning(Map<String, dynamic> message) {
  final reasoning = message['reasoning'];
  return reasoning is String && reasoning.trim().isNotEmpty;
}

bool _isDelegateTaskTranscriptMessage(
  Map<String, dynamic> message,
  Set<String> callIds,
) {
  final role = message['role']?.toString().trim().toLowerCase();
  if (role == 'assistant') {
    final calls = message['tool_calls'];
    if (calls is! List) return false;
    return calls.any((raw) {
      if (raw is! Map) return false;
      final function = raw['function'];
      final name = function is Map ? function['name'] : null;
      return name?.toString().trim().toLowerCase() == 'delegate_task';
    });
  }
  if (role != 'tool') return false;
  final toolName = message['tool_name']?.toString().trim().toLowerCase();
  if (toolName == 'delegate_task') return true;
  final callId = message['tool_call_id']?.toString().trim();
  return callId != null && callId.isNotEmpty && callIds.contains(callId);
}

/// Plan estructural de una unidad del timeline. Guarda índices, no mapas de
/// mensajes: [ActiveChat] sustituye `messages[0]` durante el streaming y una
/// caché de mapas enseñaría snapshots antiguos.
sealed class ChatRenderUnitPlan {
  const ChatRenderUnitPlan();
}

final class ChatMessageUnitPlan extends ChatRenderUnitPlan {
  /// Fila que posee la burbuja: la más nueva del grupo de respuesta.
  final int messageIndex;
  final List<int> _olderMemberIndexes;

  const ChatMessageUnitPlan(
    this.messageIndex, [
    this._olderMemberIndexes = const [],
  ]);

  /// Filas del asistente que esta burbuja agrupa, más nueva primero. Cada una
  /// conserva su identidad (anclas, búsqueda, rewind); solo comparten burbuja.
  List<int> get memberIndexesNewestFirst => _olderMemberIndexes.isEmpty
      ? [messageIndex]
      : [messageIndex, ..._olderMemberIndexes];
}

/// Una fila del asistente puede compartir burbuja con las filas del asistente
/// contiguas del mismo turno (Desktop `ResponseMessages`). Las respuestas
/// paradas/canceladas conservan su marca propia y los eventos editoriales nunca
/// se agrupan.
bool _joinsResponseGroup(Map<String, dynamic> message) =>
    message['role'] == 'assistant' &&
    (message['display_kind']?.toString().trim().isEmpty ?? true) &&
    message['_cancelled'] != true &&
    message['_stopped'] != true;

/// Funde las filas de un grupo de respuesta ([oldestFirst]) en los metadatos de
/// UNA burbuja: la traza (razonamiento + herramientas) en orden, el texto
/// visible de cada fila en orden y los medios de todas. La identidad, la hora y
/// el estado vivo son los de la fila más nueva.
Map<String, dynamic> mergeAssistantResponseGroup(
  List<Map<String, dynamic>> oldestFirst,
) {
  if (oldestFirst.length == 1) return oldestFirst.single;
  final newest = oldestFirst.last;
  final steps = <Map<String, dynamic>>[];
  final reasoning = <String>[];
  final texts = <String>[];
  final images = <Object?>[];
  final toolResults = <Object?>[];
  final toolCalls = <Object?>[];
  var seconds = 0.0;
  var hasSeconds = false;
  Object? timestampKey;
  for (final row in oldestFirst) {
    final trace = normalizeAssistantActivityTrace(
      row[assistantActivityTraceKey],
    );
    final rowReasoning = row['reasoning'];
    final hasReasoning =
        rowReasoning is String && rowReasoning.trim().isNotEmpty;
    if (hasReasoning) reasoning.add(rowReasoning.trim());
    // Un razonamiento sin paso propio ocupa su sitio cronológico en la traza.
    if (hasReasoning && !trace.any((step) => step['kind'] == 'reasoning')) {
      steps.add({
        'kind': 'reasoning',
        'text': rowReasoning,
        'status': row['_pipeline'] == true ? 'running' : 'completed',
      });
    }
    steps.addAll(trace);
    final content = row['content'];
    if (content is String && content.trim().isNotEmpty) texts.add(content);
    for (final (key, sink) in [
      ('_generatedImages', images),
      (assistantToolResultEvidenceKey, toolResults),
      ('tool_calls', toolCalls),
    ]) {
      final value = row[key];
      if (value is List) sink.addAll(value);
    }
    final duration = row['_activity_duration_seconds'];
    if (duration is num && duration.isFinite && duration > 0) {
      seconds += duration;
      hasSeconds = true;
    }
    for (final key in const ['created_at', 'timestamp', 'createdAt']) {
      if (row[key] != null) timestampKey = key;
    }
  }
  final merged = <String, dynamic>{...newest, 'content': texts.join('\n\n')};
  if (steps.isEmpty) {
    merged.remove(assistantActivityTraceKey);
  } else {
    merged[assistantActivityTraceKey] = List<Map<String, dynamic>>.unmodifiable(
      steps,
    );
  }
  if (reasoning.isEmpty) {
    merged.remove('reasoning');
  } else {
    merged['reasoning'] = reasoning.join('\n\n');
  }
  if (images.isNotEmpty) merged['_generatedImages'] = images;
  if (toolResults.isNotEmpty) {
    merged[assistantToolResultEvidenceKey] = toolResults;
  }
  if (toolCalls.isNotEmpty) merged['tool_calls'] = toolCalls;
  if (hasSeconds) merged['_activity_duration_seconds'] = seconds;
  // La hora es la de la última fila que la trae.
  if (timestampKey != null && newest[timestampKey] == null) {
    for (final row in oldestFirst.reversed) {
      if (row[timestampKey] != null) {
        merged[timestampKey as String] = row[timestampKey];
        break;
      }
    }
  }
  return Map<String, dynamic>.unmodifiable(merged);
}

final class ChatUserTurnUnitPlan extends ChatRenderUnitPlan {
  final int primaryMessageIndex;
  final List<int> supplementMessageIndexes;

  ChatUserTurnUnitPlan(
    this.primaryMessageIndex, [
    Iterable<int> supplementMessageIndexes = const [],
  ]) : supplementMessageIndexes = List.unmodifiable(supplementMessageIndexes);
}

final class ChatToolActivityUnitPlan extends ChatRenderUnitPlan {
  final List<ChatEventInfo> events;
  final List<int> messageIndexes;

  ChatToolActivityUnitPlan(
    Iterable<ChatEventInfo> events,
    Iterable<int> messageIndexes,
  ) : events = List.unmodifiable(events),
      messageIndexes = List.unmodifiable(messageIndexes);
}

/// Proyección cacheable del timeline del chat.
///
/// La agrupación de herramientas y turnos es O(n), pero solo se rehace cuando
/// cambia la estructura. Los flushes de tokens sustituyen el mapa más nuevo sin
/// cambiar dicha estructura; [canReuseFor] lo detecta en O(1), y los índices de
/// [units] resuelven siempre el mapa vivo de la lista actual.
final class ChatRenderProjection {
  final List<Map<String, dynamic>> _source;
  final int _messageCount;
  final String? _headRole;
  final bool _headPipeline;
  final bool _headSteer;
  final String? _headDisplayKind;
  final bool _headHasVisibleText;
  final bool _headHasStructuredReasoning;
  final Map<Map<String, dynamic>, int> _messageIndexes;
  final Map<int, int> _userOrdinals;
  final Map<int, List<int>> _responseGroups;
  final bool _headCancelled;
  final bool _streamingHead;

  final List<ChatRenderUnitPlan> units;

  /// Filas con representación propia en la lista (miembros de grupos de
  /// respuesta incluidos). A diferencia de `units.length`, crece cuando una
  /// página anterior añade una fila a un grupo ya pintado.
  final int renderedMessageCount;
  final List<int> assistantMessageIndexesNewestFirst;
  final int visibleUserCount;

  ChatRenderProjection._({
    required List<Map<String, dynamic>> source,
    required this.units,
    required this.renderedMessageCount,
    required this.assistantMessageIndexesNewestFirst,
    required this.visibleUserCount,
    required this._messageIndexes,
    required this._userOrdinals,
    required this._responseGroups,
    required this._streamingHead,
  }) : _source = source,
       _headCancelled =
           source.isNotEmpty &&
           (source.first['_cancelled'] == true ||
               source.first['_stopped'] == true),
       _messageCount = source.length,
       _headRole = source.isEmpty ? null : source.first['role'] as String?,
       _headPipeline = source.isNotEmpty && source.first['_pipeline'] == true,
       _headSteer = source.isNotEmpty && source.first['_steer'] == true,
       _headDisplayKind = source.isEmpty
           ? null
           : effectiveUserDisplayKind(source.first),
       _headHasVisibleText =
           source.isNotEmpty && _hasVisibleText(source.first['content']),
       _headHasStructuredReasoning =
           source.isNotEmpty && _hasCanonicalReasoning(source.first);

  factory ChatRenderProjection.build(
    List<Map<String, dynamic>> messages, {
    bool streamingHead = false,
  }) {
    final chronologicalUnits = <ChatRenderUnitPlan>[];
    final delegateTaskCallIds = _delegateTaskCallIds(messages);
    final assistantIndexes = <int>[];
    final messageIndexes = Map<Map<String, dynamic>, int>.identity();
    final userOrdinals = <int, int>{};
    List<ChatEventInfo>? pendingTools;
    List<int>? pendingToolIndexes;
    var visibleUserCount = 0;

    // Añade la burbuja de [index]. Si la unidad anterior es otra burbuja del
    // asistente del mismo turno (sin usuario, aviso ni herramientas sueltas
    // entre ambas), la amplía en su sitio en vez de apilar otra cabecera.
    void addAssistantUnit(int index) {
      final previous = chronologicalUnits.isEmpty
          ? null
          : chronologicalUnits.last;
      if (previous is ChatMessageUnitPlan &&
          _joinsResponseGroup(messages[index]) &&
          _joinsResponseGroup(messages[previous.messageIndex]) &&
          // A live turn without a visible prompt (started from another
          // client) opens after an answer that already closed its turn: the
          // live row keeps its own bubble instead of growing the finished one.
          !(streamingHead &&
              index == 0 &&
              _hasVisibleText(messages[previous.messageIndex]['content']))) {
        chronologicalUnits.removeLast();
        chronologicalUnits.add(
          ChatMessageUnitPlan(index, previous.memberIndexesNewestFirst),
        );
        return;
      }
      chronologicalUnits.add(ChatMessageUnitPlan(index));
    }

    void flushTools() {
      final tools = pendingTools;
      if (tools != null && tools.isNotEmpty) {
        chronologicalUnits.add(
          ChatToolActivityUnitPlan(tools, pendingToolIndexes ?? const []),
        );
      }
      pendingTools = null;
      pendingToolIndexes = null;
    }

    // La fuente usa orden reverse (0 = más nuevo); agrupamos cronológicamente
    // igual que el renderer original y damos la vuelta al terminar.
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      messageIndexes[message] = index;
      if (_isDelegateTaskTranscriptMessage(message, delegateTaskCallIds)) {
        continue;
      }
      final role = (message['role'] as String?) ?? 'assistant';
      final isPipeline = message['_pipeline'] == true;

      // El placeholder vivo siempre ocupa messages[0]. Si uno quedó en una
      // posición histórica por un terminal/interim tardío, no representa una
      // actividad real y no debe reaparecer reutilizando la traza del turno
      // actual. Flush mantiene la frontera entre grupos técnicos contiguos.
      if (isPipeline && index != 0) {
        flushTools();
        continue;
      }

      if (role == 'user') {
        flushTools();
        final displayKind = effectiveUserDisplayKind(message);
        // Hermes persiste algunos eventos editoriales con role=user para que
        // formen parte del transcript. Desktop los proyecta como sistema; no
        // deben agruparse, numerarse ni editarse como prompts reales.
        if (displayKind.isNotEmpty && message['_steer'] != true) {
          // Son envelopes durables del runtime, no texto escrito por el
          // usuario. `hidden` se omite; async_delegation_complete conserva su
          // tarjeta editorial dedicada, que nunca imprime el payload raw.
          if (displayKind != 'hidden') {
            chronologicalUnits.add(ChatMessageUnitPlan(index));
          }
          continue;
        }
        final isRealUser = isRealUserTurn(message);
        if (message['_steer'] == true &&
            chronologicalUnits.isNotEmpty &&
            chronologicalUnits.last is ChatUserTurnUnitPlan) {
          final previous =
              chronologicalUnits.removeLast() as ChatUserTurnUnitPlan;
          chronologicalUnits.add(
            ChatUserTurnUnitPlan(previous.primaryMessageIndex, [
              ...previous.supplementMessageIndexes,
              index,
            ]),
          );
        } else {
          chronologicalUnits.add(ChatUserTurnUnitPlan(index));
        }
        if (isRealUser) {
          userOrdinals[index] = visibleUserCount;
          visibleUserCount++;
        }
        continue;
      }

      if (role == 'assistant_error' || isPipeline) {
        flushTools();
        if (role == 'assistant') {
          addAssistantUnit(index);
        } else {
          chronologicalUnits.add(ChatMessageUnitPlan(index));
        }
        continue;
      }

      final event = ChatEventInfo.classify(message);
      final hasStructuredReasoning =
          role == 'assistant' && _hasCanonicalReasoning(message);
      final hasUnifiedActivity =
          role == 'assistant' &&
          normalizeAssistantActivityTrace(
            message[assistantActivityTraceKey],
          ).isNotEmpty;
      if (!hasUnifiedActivity &&
          (event.kind == ChatEventKind.toolEvent ||
              event.kind == ChatEventKind.approval)) {
        if (hasStructuredReasoning) {
          flushTools();
          addAssistantUnit(index);
          assistantIndexes.add(index);
        }
        (pendingTools ??= <ChatEventInfo>[]).add(event);
        (pendingToolIndexes ??= <int>[]).add(index);
        continue;
      }

      if (event.text.trim().isEmpty &&
          !hasStructuredReasoning &&
          !hasUnifiedActivity) {
        continue;
      }
      flushTools();
      if (role == 'assistant') {
        addAssistantUnit(index);
        assistantIndexes.add(index);
      } else {
        chronologicalUnits.add(ChatMessageUnitPlan(index));
      }
    }
    flushTools();

    final responseGroups = <int, List<int>>{};
    for (final unit in chronologicalUnits) {
      if (unit is ChatMessageUnitPlan && unit._olderMemberIndexes.isNotEmpty) {
        responseGroups[unit.messageIndex] = unit.memberIndexesNewestFirst;
      }
    }

    var renderedMessageCount = 0;
    for (final unit in chronologicalUnits) {
      renderedMessageCount += switch (unit) {
        ChatMessageUnitPlan(:final memberIndexesNewestFirst) =>
          memberIndexesNewestFirst.length,
        ChatUserTurnUnitPlan(:final supplementMessageIndexes) =>
          1 + supplementMessageIndexes.length,
        ChatToolActivityUnitPlan() => 0,
      };
    }

    return ChatRenderProjection._(
      source: messages,
      streamingHead: streamingHead,
      renderedMessageCount: renderedMessageCount,
      responseGroups: responseGroups,
      units: List.unmodifiable(chronologicalUnits.reversed),
      assistantMessageIndexesNewestFirst: List.unmodifiable(
        assistantIndexes.reversed,
      ),
      visibleUserCount: visibleUserCount,
      messageIndexes: messageIndexes,
      userOrdinals: userOrdinals,
    );
  }

  /// O(1): permite reutilizar la estructura mientras solo crece el contenido
  /// del mensaje de cabeza. Los cambios de rol/placeholder/texto visible
  /// fuerzan una reconstrucción; los demás eventos invalidan desde ChatScreen.
  bool canReuseFor(
    List<Map<String, dynamic>> messages, {
    bool streamingHead = false,
  }) {
    if (!identical(messages, _source) ||
        messages.length != _messageCount ||
        streamingHead != _streamingHead) {
      return false;
    }
    if (messages.isEmpty) return true;
    final head = messages.first;
    return head['role'] == _headRole &&
        (head['_pipeline'] == true) == _headPipeline &&
        (head['_steer'] == true) == _headSteer &&
        effectiveUserDisplayKind(head) == _headDisplayKind &&
        _hasVisibleText(head['content']) == _headHasVisibleText &&
        _hasCanonicalReasoning(head) == _headHasStructuredReasoning &&
        (head['_cancelled'] == true || head['_stopped'] == true) ==
            _headCancelled;
  }

  Map<String, dynamic>? get latestUserMessage {
    for (var index = 0; index < _source.length; index++) {
      if (_userOrdinals.containsKey(index)) return _source[index];
    }
    return null;
  }

  /// Posición de [message] en la lista de origen (más nuevo primero), o `null`.
  ///
  /// Un flush de tokens sustituye el mapa de cabeza sin reconstruir la
  /// proyección: la cabeza viva de la lista actual también se reconoce.
  int? messageIndexOf(Map<String, dynamic> message) =>
      _messageIndexes[message] ??
      (_source.isNotEmpty && identical(_source.first, message) ? 0 : null);

  /// Filas (más nueva primero) que comparten la burbuja anclada en
  /// [anchorIndex], o `null` si esa burbuja tiene una sola fila.
  List<int>? responseGroupMembers(int anchorIndex) =>
      _responseGroups[anchorIndex];

  int? userOrdinalFor(Map<String, dynamic> message) {
    final index = _messageIndexes[message];
    return index == null ? null : _userOrdinals[index];
  }

  Iterable<Map<String, dynamic>> assistantMessages(
    List<Map<String, dynamic>> messages,
  ) sync* {
    for (final index in assistantMessageIndexesNewestFirst) {
      yield messages[index];
    }
  }

  /// Devuelve el mensaje renderizado más cercano al origen solicitado. Un
  /// evento que solo contiene un artefacto puede no producir burbuja propia;
  /// en ese caso se navega al contexto cronológico adyacente en vez de buscar
  /// durante decenas de frames un ancla que nunca existirá.
  int? nearestRenderableMessageIndex(int sourceIndex) {
    int? best;
    var bestDistance = 1 << 30;
    for (final unit in units) {
      final indexes = switch (unit) {
        ChatMessageUnitPlan(:final memberIndexesNewestFirst) =>
          memberIndexesNewestFirst,
        ChatUserTurnUnitPlan(
          :final primaryMessageIndex,
          :final supplementMessageIndexes,
        ) =>
          [primaryMessageIndex, ...supplementMessageIndexes],
        ChatToolActivityUnitPlan(:final messageIndexes) => messageIndexes,
      };
      for (final candidate in indexes) {
        if (candidate == sourceIndex) return candidate;
        final distance = (candidate - sourceIndex).abs();
        if (distance < bestDistance ||
            (distance == bestDistance &&
                candidate > sourceIndex &&
                (best == null || best < sourceIndex))) {
          best = candidate;
          bestDistance = distance;
        }
      }
    }
    return best;
  }

  static bool _hasVisibleText(Object? value) {
    if (value is! String || value.isEmpty) return false;
    for (final rune in value.runes) {
      if (rune > 0x20 &&
          rune != 0x85 &&
          rune != 0xa0 &&
          rune != 0x1680 &&
          (rune < 0x2000 || rune > 0x200a) &&
          rune != 0x2028 &&
          rune != 0x2029 &&
          rune != 0x202f &&
          rune != 0x205f &&
          rune != 0x3000 &&
          rune != 0xfeff) {
        return true;
      }
    }
    return false;
  }
}
