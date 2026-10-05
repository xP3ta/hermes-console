import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/chat_quick_replies.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _IdeasGateway
    implements HermesDesktopGateway, HermesQuickReplySuggestionGateway {
  bool available = true;
  bool fail = false;
  final calls = <({String lastAssistant, String lastUser, String profile})>[];
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}

  @override
  bool get quickReplySuggestionsAvailable => available;

  @override
  Future<List<String>> suggestQuickReplies({
    required String lastAssistant,
    required String lastUser,
    String profile = '',
  }) async {
    calls.add((
      lastAssistant: lastAssistant,
      lastUser: lastUser,
      profile: profile,
    ));
    if (fail) throw StateError('llm.oneshot failed');
    return const ['Sí', 'Muéstralo'];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ActiveChat _chat(_IdeasGateway gateway, {bool readOnly = false}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'conn-ideas',
    label: 'Ideas',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'test-key',
    readOnly: readOnly,
  ),
  sessionId: 'session-ideas',
  sessionTitle: 'Ideas',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
  initialStoredSessionId: 'session-ideas',
)..state = ChatPipelineState.idle;

void main() {
  final es = StringsEs();
  final en = StringsEn();

  group('heuristic quick replies', () {
    test('a closing question offers yes / no / explain more', () {
      expect(
        heuristicQuickReplies(
          'Lo he revisado.\n\n¿Quieres que lo aplique?',
          es,
        ),
        ['Sí', 'No', 'Explícamelo más'],
      );
      expect(heuristicQuickReplies('Done. Should I apply it?  ', en), [
        'Yes',
        'No',
        'Explain it in more detail',
      ]);
    });

    test('a proposed plan offers go ahead / step by step', () {
      const plan =
          'Plan:\n\n1. Crear la tabla\n2. Migrar datos\n3. Borrar la vieja';
      expect(heuristicQuickReplies(plan, es), [
        'Adelante',
        'Hazlo paso a paso',
      ]);
      expect(heuristicQuickReplies(plan, en), [
        'Go ahead',
        'Do it step by step',
      ]);
    });

    test('code or a diff offers run tests / review changes', () {
      const code = 'Cambiado:\n\n```dart\nvoid main() {}\n```\nListo.';
      expect(heuristicQuickReplies(code, es), [
        'Ejecuta los tests',
        'Revisa los cambios',
      ]);
      const diff = 'Applied:\n--- a/x.dart\n+++ b/x.dart\n@@ -1 +1 @@\n-a\n+b';
      expect(heuristicQuickReplies(diff, en), [
        'Run the tests',
        'Review the changes',
      ]);
    });

    test('anything else offers no chips', () {
      // No generic follow-ups (Desktop has none): only a recognisable
      // context earns chips.
      expect(heuristicQuickReplies('Here is the overview of X.', en), isEmpty);
      expect(heuristicQuickReplies('Este es el resumen.', es), isEmpty);
    });

    test(
      'a question in the middle of the answer is not a closing question',
      () {
        expect(heuristicQuickReplies('Why? Because X. Done.', en), isEmpty);
        expect(
          heuristicQuickReplies('¿Por qué? Porque falta el índice. Listo.', es),
          isEmpty,
        );
        // An earlier paragraph's question does not count either.
        expect(
          heuristicQuickReplies(
            '¿Quieres que lo aplique?\n\nLo he aplicado ya.',
            es,
          ),
          isEmpty,
        );
      },
    );

    test('a closing question wrapped in markdown or quotes still counts', () {
      for (final answer in [
        'Lo he revisado. **¿Quieres que lo aplique?**',
        'Hecho (¿lo aplico?)',
        'He dejado el borrador: "¿Lo envío?"',
        'Done. _Should I apply it?_',
      ]) {
        expect(
          classifyQuickReplyContext(answer),
          QuickReplyContext.question,
          reason: answer,
        );
      }
      expect(heuristicQuickReplies('Ready. **Should I apply it?**', en), [
        'Yes',
        'No',
        'Explain it in more detail',
      ]);
    });

    test('a single numbered item is not a plan', () {
      expect(
        classifyQuickReplyContext('Hecho:\n\n1. Crear la tabla'),
        QuickReplyContext.generic,
      );
      expect(
        heuristicQuickReplies('Done:\n\n1. Create the table', en),
        isEmpty,
      );
      expect(
        classifyQuickReplyContext('Hecho:\n\n1. Crear la tabla\n2. Migrar'),
        QuickReplyContext.plan,
      );
    });

    test('an empty answer offers nothing', () {
      expect(heuristicQuickReplies('   ', es), isEmpty);
    });
  });

  group('smart quick replies parsing', () {
    test('keeps up to three short clean lines', () {
      expect(
        parseSmartQuickReplies(
          '1. "Sí, hazlo"\n- Muéstrame el diff\n\n* ¿Y los tests?\nOtra más',
        ),
        ['Sí, hazlo', 'Muéstrame el diff', '¿Y los tests?'],
      );
    });

    test('drops overlong lines, duplicates and blanks', () {
      expect(parseSmartQuickReplies('ok\nOK\n${'x' * 200}\n  \nvale'), [
        'ok',
        'vale',
      ]);
    });

    test('the prompt input carries only truncated last messages', () {
      final input = smartQuickReplyInput(
        lastAssistant: 'A' * 5000,
        lastUser: 'U' * 5000,
      );
      expect(input.length, lessThan(2600));
      expect(input, contains('A' * 100));
      expect(input, contains('U' * 100));
    });

    test(
      'the prompt input keeps the end of long messages after an ellipsis',
      () {
        final filler = List.filled(800, 'relleno').join(' ');
        final input = smartQuickReplyInput(
          lastAssistant: 'ASSISTANT-START $filler ASSISTANT-END?',
          lastUser: 'USER-START $filler USER-END',
        );
        expect(input, isNot(contains('ASSISTANT-START')));
        expect(input, isNot(contains('USER-START')));
        expect(input, contains('User said:\n…'));
        expect(input, contains('Assistant replied:\n…'));
        expect(input, endsWith('ASSISTANT-END?'));
        expect(input.split('\n\n').first, endsWith('USER-END'));
        // Short messages travel whole, without an ellipsis.
        expect(
          smartQuickReplyInput(lastAssistant: '¿Sigo?', lastUser: 'Hola'),
          'User said:\nHola\n\nAssistant replied:\n¿Sigo?',
        );
      },
    );
  });

  group('ActiveChat quick reply ideas', () {
    test('a writable chat with the capability asks once', () async {
      final gateway = _IdeasGateway();
      final chat = _chat(gateway);
      addTearDown(chat.dispose);
      expect(chat.canSuggestQuickReplies, isTrue);
      expect(
        await chat.suggestQuickReplies(
          lastAssistant: '¿Sigo?',
          lastUser: 'Hola',
        ),
        ['Sí', 'Muéstralo'],
      );
      expect(gateway.calls, hasLength(1));
      expect(gateway.calls.single.lastAssistant, '¿Sigo?');
      expect(gateway.calls.single.lastUser, 'Hola');
    });

    test(
      'a read-only connection never asks, even with the capability',
      () async {
        final gateway = _IdeasGateway();
        final chat = _chat(gateway, readOnly: true);
        addTearDown(chat.dispose);
        expect(gateway.quickReplySuggestionsAvailable, isTrue);
        expect(chat.canSuggestQuickReplies, isFalse);
        expect(
          await chat.suggestQuickReplies(
            lastAssistant: '¿Sigo?',
            lastUser: 'Hola',
          ),
          isEmpty,
        );
        expect(gateway.calls, isEmpty);
      },
    );

    test('an unsupported server never asks', () async {
      final gateway = _IdeasGateway()..available = false;
      final chat = _chat(gateway);
      addTearDown(chat.dispose);
      expect(chat.canSuggestQuickReplies, isFalse);
      expect(
        await chat.suggestQuickReplies(
          lastAssistant: '¿Sigo?',
          lastUser: 'Hola',
        ),
        isEmpty,
      );
      expect(gateway.calls, isEmpty);
    });

    test('a failed request yields no ideas instead of an error', () async {
      final gateway = _IdeasGateway()..fail = true;
      final chat = _chat(gateway);
      addTearDown(chat.dispose);
      expect(
        await chat.suggestQuickReplies(
          lastAssistant: '¿Sigo?',
          lastUser: 'Hola',
        ),
        isEmpty,
      );
      expect(gateway.calls, hasLength(1));
    });
  });
}
