import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
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

class _StreamingGateway implements HermesDesktopGateway {
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
      ..messages = history ?? _longHistory()
      ..messagesLoaded = true;

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        bridgeManager: BridgeManager(secureStorage, connectionManager),
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
    expect(find.textContaining('>_ '), findsNothing);
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
      frame < 120 && find.textContaining('>_ ').evaluate().isEmpty;
      frame++
    ) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.textContaining('>_ '),
      findsOneWidget,
      reason: 'el scroll nativo no alcanzó la cabecera virtualizada',
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(
      tester.getCenter(find.byIcon(Icons.keyboard_arrow_down)).dx,
      closeTo(tester.getRect(guardedList).center.dx, 1),
      reason: 'el único salto debe quedar centrado como en Desktop',
    );
    final jumpRect = tester.getRect(find.byIcon(Icons.keyboard_arrow_down));
    final viewportRect = tester.getRect(guardedList);
    expect(
      jumpRect.bottom,
      lessThanOrEqualTo(viewportRect.bottom),
      reason: 'el salto debe fundirse dentro del borde inferior del chat',
    );
    expect(
      jumpRect.top,
      greaterThan(viewportRect.bottom - 56),
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

    gateway.emit('message.delta', {
      'text': 'El primer delta después del contacto no debe reenganchar. ',
    });
    await tester.pump(const Duration(milliseconds: 20));
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
    expect(
      position.pixels,
      closeTo(offsetAfterReversals, 1),
      reason: 'los deltas posteriores movieron el historial al fondo',
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
}
