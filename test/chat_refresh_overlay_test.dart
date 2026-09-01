import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';

void main() {
  test('refresh canonicaliza todos los aliases de ID de mensaje', () {
    const selected = {
      '_desktopMessageId': 'message-42',
      'role': 'assistant',
      'content': 'contenido estable',
    };

    for (final candidate in const [
      {'_desktopMessageId': 'message-42'},
      {'message_id': 'message-42'},
      {'id': 'message-42'},
    ]) {
      expect(
        chatRefreshMessagesShareAnchorIdentity(selected, candidate),
        isTrue,
      );
    }
  });

  test('refresh conserva el ancla entre REST id y Desktop row_id', () {
    const selected = {
      'id': 74,
      'role': 'assistant',
      'content': 'contenido durable por fila',
    };

    for (final candidate in const [
      {'_desktopRowId': 74},
      {'row_id': 74},
      {'_row_id': 74},
      {'id': 74},
    ]) {
      expect(
        chatRefreshMessagesShareAnchorIdentity(selected, candidate),
        isTrue,
      );
    }
  });

  test('refresh no equipara row id numérico con message id string', () {
    expect(
      chatRefreshMessagesShareAnchorIdentity(
        const {'id': 74},
        const {'_desktopMessageId': '74'},
      ),
      isFalse,
    );
  });

  test('refresh enlaza una identidad enriquecida con su row id REST', () {
    expect(
      chatRefreshMessagesShareAnchorIdentity(
        const {'_desktopMessageId': 'message-74', '_desktopRowId': 74},
        const {'id': 74},
      ),
      isTrue,
    );
  });

  test('refresh falla cerrado ante aliases contradictorios', () {
    expect(
      chatRefreshMessagesShareAnchorIdentity(
        const {'_desktopMessageId': 'message-a', 'message_id': 'message-b'},
        const {'message_id': 'message-a'},
      ),
      isFalse,
    );
    expect(
      chatRefreshMessagesShareAnchorIdentity(
        const {'row_id': 73, 'id': 74},
        const {'id': 73},
      ),
      isFalse,
    );
  });

  test('refresh no elige un ancla durable duplicada', () {
    const selected = {'message_id': 'message-dup'};
    const first = {'message_id': 'message-dup', 'content': 'primera'};
    const second = {'message_id': 'message-dup', 'content': 'segunda'};

    expect(
      chatRefreshFindAnchorMessage(selected, const [first, second]),
      isNull,
    );
  });

  test('refresh no ignora un alias conflictivo que reclama el ancla', () {
    const selected = {'message_id': 'message-dup'};
    const conflicting = {
      '_desktopMessageId': 'message-other',
      'message_id': 'message-dup',
      'content': 'alias contradictorio',
    };
    const apparentlyUnique = {
      'message_id': 'message-dup',
      'content': 'coincidencia aparente',
    };

    expect(
      chatRefreshFindAnchorMessage(selected, const [
        conflicting,
        apparentlyUnique,
      ]),
      isNull,
    );
  });

  test('Read Aloud conserva row aliases y separa int de string', () {
    final desktop = chatReadAloudMessageKey('session', const {
      '_desktopMessageId': 'message-42',
      '_desktopRowId': 42,
    }, 'respuesta');
    final rest = chatReadAloudMessageKey('session', const {
      'id': 42,
    }, 'respuesta');
    final stringId = chatReadAloudMessageKey('session', const {
      'id': '42',
    }, 'respuesta');

    expect(desktop, rest);
    expect(rest, isNot(stringId));
  });

  test('refresh no degrada a role/content si el ID desaparece', () {
    expect(
      chatRefreshMessagesShareAnchorIdentity(
        const {
          'id': 'message-42',
          'role': 'assistant',
          'content': 'contenido duplicado',
        },
        const {'role': 'assistant', 'content': 'contenido duplicado'},
      ),
      isFalse,
    );
  });

  test('refresh trata los IDs como opacos y no recorta espacios', () {
    expect(
      chatRefreshMessagesShareAnchorIdentity(
        const {
          'id': ' message-42 ',
          'role': 'assistant',
          'content': 'contenido duplicado',
        },
        const {
          '_desktopMessageId': 'message-42',
          'role': 'assistant',
          'content': 'contenido duplicado',
        },
      ),
      isFalse,
    );
  });

  test('refresh con contenido duplicado conserva solo la identidad exacta', () {
    const selected = {
      'message_id': 'message-a',
      'role': 'assistant',
      'content': 'contenido duplicado',
    };

    expect(
      chatRefreshMessagesShareAnchorIdentity(selected, const {
        'id': 'message-b',
        'role': 'assistant',
        'content': 'contenido duplicado',
      }),
      isFalse,
    );
    expect(
      chatRefreshMessagesShareAnchorIdentity(selected, const {
        'id': 'message-a',
        'role': 'assistant',
        'content': 'contenido duplicado',
      }),
      isTrue,
    );
  });

  test('refresh id-less solo conserva el mismo objeto de la proyección', () {
    final selected = <String, dynamic>{
      'role': 'assistant',
      'content': 'contenido sin identidad',
    };
    final equalButDistinct = Map<String, dynamic>.of(selected);

    expect(chatRefreshMessagesShareAnchorIdentity(selected, selected), isTrue);
    expect(
      chatRefreshMessagesShareAnchorIdentity(selected, equalButDistinct),
      isFalse,
    );
  });

  test('dos filas id-less iguales conservan exactamente el segundo objeto', () {
    final first = <String, dynamic>{
      'role': 'assistant',
      'content': 'contenido id-less repetido',
    };
    final second = <String, dynamic>{
      'role': 'assistant',
      'content': 'contenido id-less repetido',
    };

    expect(chatRefreshFindAnchorMessage(second, [first, second]), same(second));
  });

  testWidgets('refresh lento conserva el transcript visible', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatRefreshStatusOverlay(
            loading: true,
            errorMessage: null,
            child: Text('mensaje histórico'),
          ),
        ),
      ),
    );

    expect(find.text('mensaje histórico'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-refresh-progress')), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('chat-refresh-progress')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
  });

  testWidgets('refresh fallido conserva transcript y superpone error', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatRefreshStatusOverlay(
            loading: false,
            errorMessage: 'No se pudo actualizar',
            child: Text('mensaje histórico'),
          ),
        ),
      ),
    );

    expect(find.text('mensaje histórico'), findsOneWidget);
    expect(find.text('No se pudo actualizar'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-refresh-error')), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('chat-refresh-error')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
  });
}
