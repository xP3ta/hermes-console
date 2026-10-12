import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/main.dart';

ScrollPosition _primaryVerticalScrollPosition(
  WidgetTester tester,
  Finder candidates,
) {
  final states = tester
      .stateList<ScrollableState>(candidates)
      .where((state) => state.position.axis == Axis.vertical)
      .toList(growable: false);
  expect(states, isNotEmpty);
  final primary = states.reduce(
    (current, candidate) =>
        candidate.position.maxScrollExtent > current.position.maxScrollExtent
        ? candidate
        : current,
  );
  return primary.position;
}

class _StreamingGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: 'sess-scroll-stress',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-scroll-stress',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'conn-scroll-stress',
  label: 'Scroll stress',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-scroll-stress',
  title: 'Prueba de scroll',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'http://192.168.255.254:8642',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

List<Map<String, dynamic>> _longHistory() {
  final messages = <Map<String, dynamic>>[];
  for (var turn = 29; turn >= 0; turn--) {
    messages.add({
      'role': 'assistant',
      'content':
          'Respuesta histórica $turn. '
          'Este texto ocupa varias líneas para que el historial tenga suficiente '
          'recorrido y el gesto pueda invertir la dirección sin tocar un borde.',
    });
    messages.add({
      'role': 'user',
      'content':
          'Pregunta histórica $turn con contexto adicional para la prueba.',
    });
  }
  return messages;
}

List<Map<String, dynamic>> _heavyHistory() {
  final messages = <Map<String, dynamic>>[];
  for (var turn = 7; turn >= 0; turn--) {
    final sections = List.generate(
      72,
      (index) =>
          'Sección ${index + 1}:\n\n'
          'Este párrafo de la respuesta histórica $turn conserva bastante '
          'texto, **formato**, una ruta `/tmp/qa_${turn}_$index.log` y datos '
          'suficientes para atravesar varias pantallas sin crear un único árbol '
          'Markdown gigante.\n\n',
    ).join();
    messages.add({'role': 'assistant', 'content': sections});
    messages.add({
      'role': 'user',
      'content': 'Pregunta pesada $turn para validar la virtualización.',
    });
  }
  return messages;
}

/// One answer shaped like the QA chat where the scroll stopped following the
/// finger: numbered blocks of prose, a code block, a table, lists and a quote
/// (synthetic text).
List<Map<String, dynamic>> _mixedAnswerHistory() {
  final blocks = <String>[];
  for (var i = 1; i <= 10; i++) {
    blocks.add(
      '**Bloque $i.** Un párrafo de prueba con texto suficiente para ocupar '
      'varias líneas en un teléfono y comprobar que el desplazamiento sigue al '
      'dedo en todo momento, también al cruzar contenido de altura variable.',
    );
    if (i == 3) {
      blocks.add(
        '- Anclar al final\n- Subir manualmente\n- Botón para bajar\n'
        '- Sin saltos al terminar\n- Posición conservada',
      );
    }
    if (i == 4) {
      blocks.add(
        '```python\ndef fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n'
        '        yield a\n        a, b = b, a + b\n\nprint(list(fib(20)))\n```',
      );
    }
    if (i == 5) {
      blocks.add(
        '| Caso | Esperado |\n|---|---|\n'
        '| Al final | Sigue el final |\n| Tras subir | No se mueve |\n'
        '| Mensaje nuevo | Baja al final |\n| Redimensionar | Mantiene |',
      );
    }
    if (i == 8) blocks.add('> Medir primero, optimizar después.');
    if (i == 9) {
      blocks.add('1. Abre un chat\n2. Envía\n3. Sube\n4. Comprueba\n5. Baja');
    }
  }
  return [
    {'role': 'assistant', 'content': blocks.join('\n\n')},
    {'role': 'user', 'content': 'Vamos a probar el scroll, di algo largo.'},
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureStore.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    mockChannel('flutter_foreground_task/methods');
    mockChannel('flutter_foreground_task/background');
  });

  Future<ActiveChat> pumpChat(
    WidgetTester tester,
    _StreamingGateway gateway, {
    List<Map<String, dynamic>>? history,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-scroll-stress',
      sessionTitle: 'Prueba de scroll',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = history ?? _longHistory()
      ..messagesLoaded = true;

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),

        sshManager: SshManager(secureStorage, connectionManager),
        sftpTransfers: SftpTransferService(
          SshManager(secureStorage, connectionManager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(
          SshManager(secureStorage, connectionManager),
        ),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    return chat;
  }

  test('el particionado conserva Markdown y no corta vallas de código', () {
    final prose = List.generate(
      80,
      (index) => 'Párrafo $index con texto para una respuesta larga.\n\n',
    ).join();
    final fenced = '```python\n${'print("línea")\n' * 500}```\n';
    final source = '$prose$fenced$prose';

    final chunks = splitAssistantMarkdownForViewport(source);

    expect(chunks.length, greaterThan(2));
    expect(chunks.join(), source);
    for (final chunk in chunks) {
      final fences = RegExp(r'^```', multiLine: true).allMatches(chunk).length;
      expect(fences.isEven, isTrue, reason: 'valla partida en un chunk');
    }
  });

  test('el particionado largo conserva exactamente el árbol Markdown GFM', () {
    final source = [
      '${'A' * 44} **énfasis que',
      'continúa en otra línea** y un [enlace',
      'también partido](https://example.com/ruta).',
      '',
      '- primer elemento con **negrita**',
      '',
      '  continuación del mismo elemento tras una línea vacía',
      '- segundo elemento con [guía](https://example.com)',
      '',
      'Cierre limpio. ' * 12,
      '',
      'Último párrafo. ' * 12,
    ].join('\n');

    final chunks = splitAssistantMarkdownForViewport(
      source,
      targetChars: 70,
      maxChars: 105,
    );
    String render(String input) => md.markdownToHtml(
      input,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );

    expect(chunks.length, greaterThan(1));
    expect(chunks.join(), source);
    expect(chunks.map(render).join(), render(source));
  });

  test('un bloque indivisible nunca se corta por un salto débil', () {
    final source = '**${'texto ' * 20}\n${'continuación ' * 20}**';
    final chunks = splitAssistantMarkdownForViewport(
      source,
      targetChars: 40,
      maxChars: 70,
    );

    expect(chunks, [source]);
  });

  testWidgets('respuestas pesadas se virtualizan durante ráfagas inversas', (
    tester,
  ) async {
    final gateway = _StreamingGateway();
    final history = _heavyHistory();
    await pumpChat(tester, gateway, history: history);

    final guardedList = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(ListView),
    );
    expect(guardedList, findsOneWidget);
    final list = tester.widget<ListView>(guardedList);
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.addAutomaticKeepAlives, isFalse);
    expect(delegate.estimatedChildCount, greaterThan(history.length));
    expect(find.byKey(const ValueKey('assistant-header-name')), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    final scrollableCandidates = find.descendant(
      of: guardedList,
      matching: find.byType(Scrollable),
    );
    final position = _primaryVerticalScrollPosition(
      tester,
      scrollableCandidates,
    );
    for (
      var frame = 0;
      frame < 120 &&
          find
              .byKey(const ValueKey('assistant-header-name'))
              .evaluate()
              .isEmpty;
      frame++
    ) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.byKey(const ValueKey('assistant-header-name')),
      findsOneWidget,
      reason: 'el scroll nativo no alcanzó la cabecera virtualizada',
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    // QA 9493: the single jump sits at the row's end, clear of the centred
    // notch (it used to be centred).
    expect(
      tester.getCenter(find.byIcon(Icons.keyboard_arrow_down)).dx,
      greaterThan(tester.getRect(guardedList).center.dx + 60),
      reason: 'el único salto queda al final de la fila, libre de la muesca',
    );
    final jumpRect = tester.getRect(find.byIcon(Icons.keyboard_arrow_down));
    // The transcript runs under the floating bottom group: the composer's
    // top edge is the group's top.
    final composerEdge = tester
        .getRect(find.byKey(const ValueKey('chat-bottom-bars')))
        .top;
    expect(
      jumpRect.bottom,
      lessThanOrEqualTo(composerEdge),
      reason: 'el salto debe fundirse dentro del borde inferior del chat',
    );
    // The notch tab on the composer's edge sits under the jump.
    expect(
      jumpRect.top,
      greaterThan(composerEdge - 56 - kChatNotchHeight),
      reason: 'el salto no debe abrir una franja separada sobre el compositor',
    );
    for (var burst = 0; burst < 12; burst++) {
      final dy = burst.isEven ? -720.0 : 720.0;
      await tester.fling(guardedList, Offset(0, dy), 7000);
      await tester.pump(const Duration(milliseconds: 48));
      expect(
        find.byType(MarkdownBody).evaluate().length,
        lessThanOrEqualTo(8),
        reason: 'se materializó una respuesta completa fuera del viewport',
      );
      expect(tester.takeException(), isNull);
    }
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);

    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('30 inversiones durante streaming no reactivan el auto-follow', (
    tester,
  ) async {
    final gateway = _StreamingGateway();
    final chat = await pumpChat(tester, gateway);

    expect(find.byType(ChatScrollInteractionGuard), findsOneWidget);
    final scrollableFinder = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(Scrollable),
    );
    final initialPosition = _primaryVerticalScrollPosition(
      tester,
      scrollableFinder,
    );
    expect(initialPosition.maxScrollExtent, greaterThan(400));

    await chat.send(
      fullText: 'Genera una respuesta larga para estresar el scroll.',
      model: 'hermes-agent',
      history: chat.buildHistory(),
    );
    gateway.emit('message.start');
    gateway.emit('message.delta', {'text': 'Comienzo de la respuesta. '});
    await tester.pump(const Duration(milliseconds: 20));
    expect(chat.isStreaming, isTrue);
    final hiddenJump = find.byKey(const ValueKey('scroll-to-bottom-hidden'));
    expect(hiddenJump, findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(hiddenJump).opacity, 0);
    expect(
      tester.getSize(hiddenJump),
      const Size(48, 48),
      reason: 'oculto o visible, el salto conserva tamaño y no abre una franja',
    );
    final positionBeforeFreeze = _primaryVerticalScrollPosition(
      tester,
      scrollableFinder,
    );
    expect(positionBeforeFreeze.maxScrollExtent, greaterThan(400));

    final guardRect = tester.getRect(find.byType(ChatScrollInteractionGuard));
    final viewportHeightBeforeButton = guardRect.height;
    final freezeGesture = await tester.startGesture(guardRect.center);
    await tester.pump();

    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('scroll-to-bottom-hidden')),
          )
          .opacity,
      0,
      reason:
          'tocar el chat en el fondo congela el seguimiento sin enseñar una '
          'flecha que no lleva a ninguna parte',
    );
    expect(
      tester.getSize(find.byType(ChatScrollInteractionGuard)).height,
      viewportHeightBeforeButton,
      reason:
          'el botón para bajar debe flotar sobre el chat, no encoger el viewport',
    );
    expect(
      positionBeforeFreeze.pixels,
      closeTo(positionBeforeFreeze.minScrollExtent, 0.01),
    );

    final extentBeforeHeldDelta = positionBeforeFreeze.maxScrollExtent;
    gateway.emit('message.delta', {
      'text': 'El primer delta después del contacto no debe reenganchar. ',
    });
    await tester.pump(const Duration(milliseconds: 20));
    // The answer must really grow under the resting finger: this is what
    // moves the held viewport off the bottom. Without it the release below
    // would be checked against an unchanged list.
    expect(
      positionBeforeFreeze.maxScrollExtent,
      greaterThan(extentBeforeHeldDelta),
      reason: 'la respuesta debe crecer bajo el dedo antes de soltar',
    );
    expect(
      find.byKey(const ValueKey('scroll-to-bottom-hidden')),
      findsOneWidget,
      reason: 'la flecha debe seguir oculta mientras el viewport está al final',
    );
    await freezeGesture.up();
    await tester.pump();
    var position = _primaryVerticalScrollPosition(tester, scrollableFinder);
    expect(position.maxScrollExtent, greaterThan(400));

    gateway.emit('message.delta', {
      'text': 'Tras soltar en el fondo el seguimiento debe continuar. ',
    });
    await tester.pump(const Duration(milliseconds: 160));
    expect(position.pixels, closeTo(position.minScrollExtent, 1));
    expect(
      find.byKey(const ValueKey('scroll-to-bottom-hidden')),
      findsOneWidget,
    );
    position = _primaryVerticalScrollPosition(tester, scrollableFinder);

    // Dejamos margen en ambos sentidos para que las 30 inversiones no choquen
    // con el rebote del borde y midan únicamente la interacción con streaming.
    position.jumpTo(240);
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, greaterThan(100));
    final contentBeforeReversals = chat.assistantContent;

    // A partir de aquí mantenemos un único puntero y cambiamos su dirección 30
    // veces mientras el mensaje continúa creciendo.
    final gesture = await tester.startGesture(guardRect.center);
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump(const Duration(milliseconds: 16));
    var direction = 1.0;
    for (var reversal = 0; reversal < 30; reversal++) {
      await gesture.moveBy(Offset(0, 24 * direction));
      direction = -direction;
      gateway.emit('message.delta', {
        'text': 'fragmento ${reversal + 1} durante la inversión. ',
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byIcon(Icons.keyboard_arrow_down),
        findsOneWidget,
        reason: 'el delta ${reversal + 1} reactivó el seguimiento',
      );
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 40));

    final offsetAfterReversals = position.pixels;
    final contentAfterReversals = chat.assistantContent;
    expect(offsetAfterReversals, greaterThan(100));
    expect(
      contentAfterReversals.length,
      greaterThan(contentBeforeReversals.length),
    );
    // A history paragraph fully on screen: the reader's place.
    final viewport = tester.getRect(find.byType(ChatScrollInteractionGuard));
    final readerLine = find
        .textContaining('histórica', findRichText: true)
        .evaluate()
        .firstWhere((element) {
          final rect = tester.getRect(
            find.byElementPredicate((e) => e == element),
          );
          return rect.top > viewport.top && rect.bottom < viewport.bottom;
        });
    final readerFinder = find.byElementPredicate((e) => e == readerLine);
    final readerTopAfterReversals = tester.getTopLeft(readerFinder).dy;
    final extentAfterReversals = position.maxScrollExtent;

    for (var delta = 0; delta < 5; delta++) {
      gateway.emit('message.delta', {
        'text': 'cola adicional ${delta + 1} tras soltar el gesto. ',
      });
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      chat.assistantContent.length,
      greaterThan(contentAfterReversals.length),
    );
    // The answer really grew below the reader; in this reversed list the
    // offset grows with it to keep the history still, so the reader's place
    // is checked on screen, not by the raw offset.
    expect(position.maxScrollExtent, greaterThan(extentAfterReversals));
    expect(
      position.pixels,
      greaterThanOrEqualTo(offsetAfterReversals - 1),
      reason: 'los deltas posteriores movieron el historial al fondo',
    );
    expect(
      tester.getTopLeft(readerFinder).dy,
      closeTo(readerTopAfterReversals, 1),
      reason: 'los deltas posteriores movieron el texto bajo el lector',
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(tester.takeException(), isNull);

    gateway.emit('message.complete', {'text': chat.assistantContent});
    // Vacía de forma determinista el typewriter antes de desmontar: los 35
    // deltas se drenan mediante timers de 16 ms incluso tras message.complete.
    for (var frame = 0; frame < 200 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(chat.isStreaming, isFalse);
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('soltar en el fondo sin moverse reengancha aunque la respuesta '
      'haya crecido bajo el dedo; tocar leyendo el historial no baja', (
    tester,
  ) async {
    final gateway = _StreamingGateway();
    final chat = await pumpChat(tester, gateway);
    final scrollableFinder = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(Scrollable),
    );
    await chat.send(
      fullText: 'Genera una respuesta larga.',
      model: 'hermes-agent',
      history: chat.buildHistory(),
    );
    gateway.emit('message.start');
    gateway.emit('message.delta', {'text': 'Comienzo. '});
    await tester.pump(const Duration(milliseconds: 20));
    final position = _primaryVerticalScrollPosition(tester, scrollableFinder);
    final center = tester
        .getRect(find.byType(ChatScrollInteractionGuard))
        .center;

    // At the bottom: the finger rests while a long chunk arrives.
    expect(position.pixels, closeTo(position.minScrollExtent, 0.01));
    final rest = await tester.startGesture(center);
    await tester.pump();
    final extentBefore = position.maxScrollExtent;
    gateway.emit('message.delta', {
      'text': 'Un fragmento largo que llega con el dedo apoyado. ' * 12,
    });
    await tester.pump(const Duration(milliseconds: 20));
    expect(position.maxScrollExtent, greaterThan(extentBefore));
    await rest.up();
    await tester.pump();
    gateway.emit('message.delta', {'text': 'y el seguimiento continúa. '});
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      position.pixels,
      closeTo(position.minScrollExtent, 1),
      reason: 'un toque quieto en el fondo no es leer el historial',
    );
    expect(find.byKey(const ValueKey('scroll-to-bottom-hidden')), findsOne);

    // Reading history: a still tap must leave the reader where they are.
    position.jumpTo(240);
    await tester.pump(const Duration(milliseconds: 16));
    final tap = await tester.startGesture(center);
    await tester.pump();
    gateway.emit('message.delta', {'text': 'más texto mientras se lee. '});
    await tester.pump(const Duration(milliseconds: 20));
    await tap.up();
    await tester.pump(const Duration(milliseconds: 40));
    final readerOffset = position.pixels;
    expect(readerOffset, greaterThan(200));
    gateway.emit('message.delta', {'text': 'y otro fragmento. '});
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      position.pixels,
      greaterThanOrEqualTo(readerOffset - 1),
      reason: 'tocar mientras se lee no devuelve al fondo',
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    gateway.emit('message.complete', {'text': chat.assistantContent});
    for (var frame = 0; frame < 200 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
  // Guard (passes before the fix too): with one long answer mixing prose, a
  // table and a code block, every swipe that does not hit an edge moves the
  // transcript in the swipe's direction by most of its length. The QA report
  // that inspired it (swipes not following the finger) is reproduced by the
  // earlier-page test below, not by this one.
  testWidgets('cada deslizamiento mueve el chat en su sentido', (tester) async {
    tester.view.physicalSize = const Size(960, 2142);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final gateway = _StreamingGateway();
    await pumpChat(tester, gateway, history: _mixedAnswerHistory());
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final guardedList = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(ListView),
    );
    final position = _primaryVerticalScrollPosition(
      tester,
      find.descendant(of: guardedList, matching: find.byType(Scrollable)),
    );
    expect(position.maxScrollExtent, greaterThan(800));
    final report = <String>[];
    Future<void> swipe(double dy) async {
      final before = position.pixels;
      await tester.drag(guardedList, Offset(0, dy));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final moved = position.pixels - before;
      report.add('${dy > 0 ? 'older' : 'newer'} ${moved.round()}');
      final atEdge =
          (dy > 0 && position.pixels >= position.maxScrollExtent - 1) ||
          (dy < 0 && position.pixels <= position.minScrollExtent + 1);
      if (atEdge) return;
      // reverse:true: dragging the finger down shows older rows (pixels up).
      expect(
        moved.sign,
        dy.sign,
        reason: 'el chat se movió al revés del dedo: $report',
      );
      expect(
        moved.abs(),
        greaterThan(dy.abs() * 0.6),
        reason: 'el chat no siguió al dedo: $report',
      );
    }

    for (var i = 0; i < 6; i++) {
      await swipe(170);
    }
    for (var i = 0; i < 8; i++) {
      await swipe(-170);
    }
    // ignore: avoid_print
    print('swipes: $report');
    expect(tester.takeException(), isNull);
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
  // QA (Pixel, real chat, scroll trace): near the oldest loaded row a swipe
  // asks for the earlier page, and when that load ended the screen "restored"
  // the offset with a jump. The jump cancelled the finger's drag (and any
  // fling), so the chat stopped following mid-swipe.
  testWidgets('cargar mensajes anteriores no corta el dedo ni el impulso', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 2142);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final gateway = _StreamingGateway();
    final chat = await pumpChat(
      tester,
      gateway,
      history: _mixedAnswerHistory(),
    );
    chat.earlierMessagesAvailableForTesting = true;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final guardedList = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(ListView),
    );
    final position = _primaryVerticalScrollPosition(
      tester,
      find.descendant(of: guardedList, matching: find.byType(Scrollable)),
    );
    expect(position.maxScrollExtent, greaterThan(1200));
    position.jumpTo(position.maxScrollExtent - 40);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Drag: towards older rows and past the oldest one (this asks for the
    // earlier page), then back towards newer ones while the finger stays
    // down. On the Pixel the page landed while the finger pulled past the
    // edge, and the "restore" jump cancelled the drag.
    final center = tester.getCenter(guardedList);
    final gesture = await tester.startGesture(center);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The finger keeps moving on every frame while that page lands.
    final beforeNewer = position.pixels;
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final dragged = beforeNewer - position.pixels;
    await gesture.up();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      dragged,
      greaterThan(250),
      reason: 'el chat dejó de seguir al dedo tras pedir los anteriores',
    );

    // Fling towards older rows from the same zone: the load it triggers must
    // not stop the momentum.
    chat.earlierMessagesAvailableForTesting = true;
    position.jumpTo(position.maxScrollExtent - 1200);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final beforeFling = position.pixels;
    await tester.fling(guardedList, const Offset(0, 120), 1500);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final early = position.pixels - beforeFling;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final late = position.pixels - beforeFling;
    // ignore: avoid_print
    print('earlier-load drag=$dragged fling early=$early late=$late');
    expect(
      late,
      greaterThan(early + 100),
      reason: 'el impulso se cortó al cargar los mensajes anteriores',
    );
    expect(tester.takeException(), isNull);
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}
