import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';
import '../widgets/chat_event_cards.dart';

/// Plan estructural de una unidad del timeline. Guarda índices, no mapas de
/// mensajes: [ActiveChat] sustituye `messages[0]` durante el streaming y una
/// caché de mapas enseñaría snapshots antiguos.
sealed class ChatRenderUnitPlan {
  const ChatRenderUnitPlan();
}

final class ChatMessageUnitPlan extends ChatRenderUnitPlan {
  final int messageIndex;

  const ChatMessageUnitPlan(this.messageIndex);
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

  final List<ChatRenderUnitPlan> units;
  final List<int> assistantMessageIndexesNewestFirst;
  final int visibleUserCount;

  ChatRenderProjection._({
    required List<Map<String, dynamic>> source,
    required this.units,
    required this.assistantMessageIndexesNewestFirst,
    required this.visibleUserCount,
    required this._messageIndexes,
    required this._userOrdinals,
  }) : _source = source,
       _messageCount = source.length,
       _headRole = source.isEmpty ? null : source.first['role'] as String?,
       _headPipeline = source.isNotEmpty && source.first['_pipeline'] == true,
       _headSteer = source.isNotEmpty && source.first['_steer'] == true,
       _headDisplayKind = source.isEmpty
           ? null
           : source.first['display_kind']?.toString().trim(),
       _headHasVisibleText =
           source.isNotEmpty && _hasVisibleText(source.first['content']),
       _headHasStructuredReasoning =
           source.isNotEmpty &&
           structuredReasoningText(source.first).isNotEmpty;

  factory ChatRenderProjection.build(List<Map<String, dynamic>> messages) {
    final chronologicalUnits = <ChatRenderUnitPlan>[];
    final assistantIndexes = <int>[];
    final messageIndexes = Map<Map<String, dynamic>, int>.identity();
    final userOrdinals = <int, int>{};
    List<ChatEventInfo>? pendingTools;
    List<int>? pendingToolIndexes;
    var visibleUserCount = 0;

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
        chronologicalUnits.add(ChatMessageUnitPlan(index));
        continue;
      }

      final event = ChatEventInfo.classify(message);
      if (event.kind == ChatEventKind.toolEvent ||
          event.kind == ChatEventKind.approval) {
        (pendingTools ??= <ChatEventInfo>[]).add(event);
        (pendingToolIndexes ??= <int>[]).add(index);
        continue;
      }

      // Los placeholders vacíos del asistente no generan huecos visuales. Un
      // assistant con razonamiento estructurado (reasoning_content/metadata)
      // pero sin content visible SÍ se conserva: su bloque de razonamiento
      // plegado es contenido real del turno y no debe evaporarse.
      if (event.text.trim().isEmpty &&
          structuredReasoningText(message).isEmpty) {
        continue;
      }
      flushTools();
      chronologicalUnits.add(ChatMessageUnitPlan(index));
      if (role == 'assistant') assistantIndexes.add(index);
    }
    flushTools();

    return ChatRenderProjection._(
      source: messages,
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
  bool canReuseFor(List<Map<String, dynamic>> messages) {
    if (!identical(messages, _source) || messages.length != _messageCount) {
      return false;
    }
    if (messages.isEmpty) return true;
    final head = messages.first;
    return head['role'] == _headRole &&
        (head['_pipeline'] == true) == _headPipeline &&
        (head['_steer'] == true) == _headSteer &&
        head['display_kind']?.toString().trim() == _headDisplayKind &&
        _hasVisibleText(head['content']) == _headHasVisibleText &&
        structuredReasoningText(head).isNotEmpty == _headHasStructuredReasoning;
  }

  Map<String, dynamic>? get latestUserMessage {
    for (var index = 0; index < _source.length; index++) {
      if (_userOrdinals.containsKey(index)) return _source[index];
    }
    return null;
  }

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
        ChatMessageUnitPlan(:final messageIndex) => [messageIndex],
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
