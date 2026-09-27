import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
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
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
import 'package:hermes_android/main.dart';

class _IdleGateway
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
    runtimeSessionId: 'runtime-md-baseline',
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
    runtimeSessionId: 'runtime-md-baseline',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-md-baseline',
    storedSessionId: 'sess-md-baseline',
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
        sessionId: 'runtime-md-baseline',
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
  id: 'conn-md-baseline',
  label: 'Markdown baseline',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-md-baseline',
  title: 'Baseline markdown',
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

/// T101 (spec 070): línea base del render del chat principal antes y después
/// de extraer las piezas compartidas (ChatMarkdownBody, ChatMessageFrame,
/// ConsoleComposer). Debe pasar idéntica en ambos lados del refactor.
const String _assistantMarkdown = '''
## Resumen del despliegue

El servicio `hermes-gateway` quedó listo. Consulta la [guía oficial](https://example.com/guia).

1. Preparar el entorno
2. Lanzar el agente

- viñeta uno
- viñeta dos

```bash
echo "hola"
```

| Clave | Valor |
| --- | --- |
| modo | local |
''';

const String _userText = 'Pregunta del usuario para la línea base';

List<Map<String, dynamic>> _history() => [
  {
    'role': 'assistant',
    'content': _assistantMarkdown,
    'created_at': 1700000000,
  },
  {'role': 'user', 'content': _userText, 'created_at': 1699999990},
];

TextSpan? _spanContaining(WidgetTester tester, String text) {
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    final span = widget.text;
    if (span is TextSpan && span.toPlainText().contains(text)) return span;
  }
  return null;
}

bool _selectableContains(WidgetTester tester, String text) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .any(
      (widget) =>
          (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains(text),
    );

TextStyle? _leafStyle(InlineSpan root, String leafText) {
  TextStyle? found;
  void visit(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan || found != null) return;
    final effective = inherited == null
        ? span.style
        : inherited.merge(span.style);
    if ((span.text ?? '').contains(leafText)) {
      found = effective ?? const TextStyle();
      return;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, effective);
    }
  }

  visit(root, null);
  return found;
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
    final support = Directory.systemTemp.createTempSync('main-chat-baseline-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final gateway = _IdleGateway();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-md-baseline',
      sessionTitle: 'Baseline markdown',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = _history()
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
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  HermesThemeColors colorsOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(ChatScreen))).hermes;

  testWidgets('T101 baseline: Markdown del asistente en el chat principal', (
    tester,
  ) async {
    await pumpChat(tester);
    final colors = colorsOf(tester);

    // Encabezado compacto (h2 = 16.5, w700, textPrimary).
    final heading = _spanContaining(tester, 'Resumen del despliegue');
    expect(heading, isNotNull);
    final headingStyle = _leafStyle(heading!, 'Resumen del despliegue')!;
    expect(headingStyle.fontSize, 16.5);
    expect(headingStyle.fontWeight, FontWeight.w700);
    expect(headingStyle.color, colors.textPrimary);

    // Párrafo 15/1.5 con código inline monoespaciado y enlace en secondary.
    final paragraph = _spanContaining(tester, 'quedó listo')!;
    final prose = _leafStyle(paragraph, 'quedó listo')!;
    expect(prose.fontSize, 15);
    expect(prose.height, 1.5);
    final inlineCode = _leafStyle(paragraph, 'hermes-gateway')!;
    expect(inlineCode.fontFamily, 'monospace');
    expect(inlineCode.fontSize, 13);
    final link = _leafStyle(paragraph, 'guía oficial')!;
    expect(link.color, colors.secondary);
    expect(link.decoration, TextDecoration.underline);

    // Listas ordenada y con viñetas.
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(_spanContaining(tester, 'Preparar el entorno'), isNotNull);
    expect(_spanContaining(tester, 'viñeta dos'), isNotNull);

    // Bloque de código con cabecera de lenguaje y botón copiar.
    expect(find.text('bash'), findsOneWidget);
    expect(_spanContaining(tester, 'echo "hola"'), isNotNull);

    // Tabla con el render propio.
    expect(find.byType(MarkdownTable), findsOneWidget);
    // Las celdas de la tabla son el único Markdown seleccionable propio.
    expect(_selectableContains(tester, 'modo'), isTrue);
    expect(_selectableContains(tester, 'local'), isTrue);

    // Marco del mensaje: nombre en acento, acción copiar y selección parcial
    // vía región estable (sin SelectableText).
    final name = tester.widget<Text>(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    expect(name.style?.color, colors.accent);
    expect(find.byType(ChatMessageSelectionArea), findsWidgets);
    expect(_selectableContains(tester, 'quedó listo'), isFalse);
    expect(_selectableContains(tester, 'Resumen del despliegue'), isFalse);

    await unmount(tester);
  });

  testWidgets('T101 baseline: burbuja del usuario en el chat principal', (
    tester,
  ) async {
    await pumpChat(tester);
    final userSpan = _spanContaining(tester, _userText);
    expect(userSpan, isNotNull);
    final userStyle = _leafStyle(userSpan!, _userText)!;
    expect(userStyle.color, colorsOf(tester).textPrimary);

    // La burbuja queda hacia el borde final, a la derecha del asistente.
    final userRect = tester.getRect(find.textContaining(_userText).first);
    final assistantRect = tester.getRect(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    expect(userRect.left, greaterThan(assistantRect.left));

    await unmount(tester);
  });

  testWidgets('T101 baseline: composer del chat principal', (tester) async {
    await pumpChat(tester);
    expect(find.byKey(const ValueKey('chat-composer-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-input-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('mic')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer-primary-action-switcher')),
      findsOneWidget,
    );
    final fieldFinder = find.descendant(
      of: find.byKey(const ValueKey('composer-input-row')),
      matching: find.byType(TextField),
    );
    final field = tester.widget<TextField>(fieldFinder);
    expect(field.minLines, 1);
    expect(field.maxLines, 4);
    final before = tester
        .getSize(find.byKey(const ValueKey('composer-input-row')))
        .height;
    await tester.enterText(fieldFinder, 'línea uno\nlínea dos\nlínea tres');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final after = tester
        .getSize(find.byKey(const ValueKey('composer-input-row')))
        .height;
    expect(after, greaterThan(before));
    expect(find.byKey(const ValueKey('send')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('T101 baseline: golden del chat principal', (tester) async {
    await pumpChat(tester);
    await expectLater(
      find.byType(ChatScreen),
      matchesGoldenFile('goldens/main_chat_baseline.png'),
    );
    await unmount(tester);
  });
}
