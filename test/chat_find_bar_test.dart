import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
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
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/main.dart';
import 'support/chat_header_menu.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-chat-find',
  label: 'Chat find',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-chat-find',
  title: 'Búsqueda en chat',
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

const _farNeedle = 'Aquí mencionamos la CANCIÓN secreta del principio.';
const _nearNeedle = 'Y al final volvemos a la cancion secreta.';

/// Newest first, as ActiveChat stores it. The far match sits many screens
/// above the near one, so it is not materialized until the search scrolls.
List<Map<String, dynamic>> _history() {
  final messages = <Map<String, dynamic>>[
    {'role': 'assistant', 'content': _nearNeedle},
    {'role': 'user', 'content': 'Pregunta reciente sin coincidencias.'},
  ];
  for (var turn = 30; turn >= 0; turn--) {
    messages.add({
      'role': 'assistant',
      'content':
          'Respuesta de relleno $turn. Este texto ocupa varias líneas para '
          'que el historial tenga recorrido suficiente entre coincidencias.',
    });
    messages.add({'role': 'user', 'content': 'Relleno $turn.'});
  }
  messages.add({'role': 'assistant', 'content': _farNeedle});
  messages.add({'role': 'user', 'content': 'Primera pregunta.'});
  return messages;
}

ScrollPosition _transcriptPosition(WidgetTester tester) {
  final list = find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );
  return tester.widget<ListView>(list).controller!.position;
}

bool _isOnScreen(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  final rect = tester.getRect(finder.first);
  final viewport = tester.getRect(find.byType(ChatScrollInteractionGuard));
  return rect.bottom > viewport.top && rect.top < viewport.bottom;
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
    WidgetTester tester, {
    List<Map<String, dynamic>>? history,
    ApiClient? api,
    bool messagesLoaded = true,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view
      ..physicalSize = const Size(1080, 2280)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService(attachDesktopRuntimeOnLoad: false);
    addTearDown(activeChats.dispose);
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: _session().id,
      sessionTitle: _session().title,
      api: api ?? _safeApi(),
      attachDesktopRuntimeOnLoad: false,
      allowUnownedDesktopSnapshotForTesting: messagesLoaded,
      transcriptPageSizeForTesting: 120,
    );
    if (history != null) chat.internalMessagesForTesting = history;
    chat.messagesLoaded = messagesLoaded;

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    return chat;
  }

  // Find moved from the header into the notch sheet ("Buscar en este chat").
  Future<void> openFindFromAppBar(WidgetTester tester) async {
    expect(find.byKey(const ValueKey('chat-find-trigger')), findsNothing);
    final trigger = find.byKey(const ValueKey('chat-notch'));
    expect(tester.getSize(trigger).height, greaterThanOrEqualTo(48));
    await tester.tap(trigger);
    await tester.pump();
    await tester.pump(kChatNotchSheetOpen);
    final row = find.byKey(const ValueKey('chat-control-find'));
    expect(find.text('Buscar en este chat'), findsOneWidget);
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// The reveal walks the lazy list one frame at a time until the target row
  /// materializes; give it enough frames plus the final alignment animation.
  Future<void> settleReveal(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('chat-find-field')),
        matching: find.byType(TextField),
      ),
      query,
    );
    // Debounce (150 ms) plus the reveal scroll.
    await tester.pump(const Duration(milliseconds: 160));
    await settleReveal(tester);
  }

  testWidgets('find bar counts hits, jumps to an off-screen match and closes', (
    tester,
  ) async {
    await pumpChat(tester, history: _history());
    await tester.pump(const Duration(milliseconds: 200));

    final far = find.textContaining('CANCIÓN secreta', findRichText: true);
    final near = find.textContaining('cancion secreta', findRichText: true);
    expect(_isOnScreen(tester, near), isTrue);
    expect(_isOnScreen(tester, far), isFalse);

    await openFindFromAppBar(tester);
    expect(find.byKey(const ValueKey('chat-find-bar')), findsOneWidget);
    expect(find.bySemanticsLabel('Buscar en este chat'), findsWidgets);

    await typeQuery(tester, 'canción SECRETA');
    expect(find.text('1 de 2'), findsOneWidget);
    expect(_isOnScreen(tester, near), isTrue);

    await tester.tap(find.byKey(const ValueKey('chat-find-older')));
    await settleReveal(tester);
    expect(find.text('2 de 2'), findsOneWidget);
    expect(_isOnScreen(tester, far), isTrue);
    expect(
      find.bySemanticsLabel(RegExp('^Resultado de búsqueda actual')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('chat-find-newer')));
    await settleReveal(tester);
    expect(find.text('1 de 2'), findsOneWidget);
    expect(_isOnScreen(tester, near), isTrue);

    await tester.tap(find.byKey(const ValueKey('chat-find-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('chat-find-bar')), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp('^Resultado de búsqueda actual')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('open find bar suspends bottom follow; closing restores it', (
    tester,
  ) async {
    final chat = await pumpChat(tester, history: _history());
    await tester.pump(const Duration(milliseconds: 200));
    final position = _transcriptPosition(tester);
    expect(position.pixels, position.minScrollExtent);

    await openFindFromAppBar(tester);
    await typeQuery(tester, 'cancion');
    await tester.tap(find.byKey(const ValueKey('chat-find-older')));
    await settleReveal(tester);
    final readingOffset = position.pixels;
    expect(readingOffset, greaterThan(position.minScrollExtent + 100));

    // A transcript refresh that would normally re-anchor the bottom must not
    // steal the search target while the bar is open.
    chat.debugEmitMessagesHydrated();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, readingOffset);
    expect(find.text('2 de 2'), findsOneWidget);

    // Back to the newest hit (near the bottom), then close: follow resumes, so
    // the same refresh lands the reader at the bottom again.
    await tester.tap(find.byKey(const ValueKey('chat-find-newer')));
    await settleReveal(tester);
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-find-close')));
    await tester.pump();
    position.jumpTo(position.minScrollExtent + 40);
    await tester.pump();
    chat.debugEmitMessagesHydrated();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, position.minScrollExtent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('/buscar opens the bar with the query applied', (tester) async {
    await pumpChat(tester, history: _history());
    await tester.pump(const Duration(milliseconds: 200));

    final composer = find.byType(TextField).last;
    await tester.tap(composer);
    await tester.enterText(composer, '/buscar canción');
    await tester.pump(const Duration(milliseconds: 250));
    final send = tester
        .widget<HermesTactileAction>(
          find.descendant(
            of: find.byKey(const ValueKey('send')),
            matching: find.byType(HermesTactileAction),
          ),
        )
        .onPressed;
    expect(send, isNotNull);
    send!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('chat-find-bar')), findsOneWidget);
    expect(find.text('1 de 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no local hit offers older pages and pages until found', (
    tester,
  ) async {
    // Only requests for older pages count: a passive refresh of the latest
    // window (offset 0) is unrelated to search.
    var reads = 0;
    final rows = <Map<String, dynamic>>[
      for (var index = 1; index <= 360; index++)
        {
          'id': index,
          'message_id': 'history-$index',
          'role': index.isOdd ? 'user' : 'assistant',
          'content': index == 3
              ? 'El ÁRBOL genealógico quedó al principio.'
              : 'historial $index',
        },
    ];
    final client = MockClient((request) async {
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      if (offset > 0) reads += 1;
      final end = math.max(0, rows.length - offset);
      final start = math.max(0, end - 120);
      final page = rows.sublist(start, end);
      return http.Response(
        jsonEncode({
          'object': 'list',
          'session_id': 'sess-chat-find',
          'messages': page,
          'pagination': {
            'limit': 120,
            'offset': offset,
            'order': 'latest',
            'returned': page.length,
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final api = ApiClient(
      baseUrl: 'https://example.test',
      apiKey: 'test-key',
      httpClient: client,
    );
    addTearDown(api.close);

    final chat = await pumpChat(tester, api: api, messagesLoaded: false);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(chat.hasEarlierMessages, isTrue);
    final initialReads = reads;

    await openFindFromAppBar(tester);
    await typeQuery(tester, 'arbol genealogico');
    expect(find.text('Sin resultados'), findsOneWidget);
    expect(reads, initialReads, reason: 'typing must never page history');
    final older = find.byKey(const ValueKey('chat-find-search-older'));
    expect(older, findsOneWidget);
    expect(find.text('Buscar en mensajes anteriores'), findsOneWidget);

    await tester.tap(older);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settleReveal(tester);
    expect(reads, initialReads + 2);
    expect(find.text('1 de 1'), findsOneWidget);
    expect(
      _isOnScreen(
        tester,
        find.textContaining('ÁRBOL genealógico', findRichText: true),
      ),
      isTrue,
    );

    // A miss pages until the history is exhausted, then says so.
    await typeQuery(tester, 'palabra inexistente');
    expect(find.text('Sin resultados'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-find-search-older')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settleReveal(tester);
    expect(chat.hasEarlierMessages, isFalse);
    expect(find.byKey(const ValueKey('chat-find-search-older')), findsNothing);
    expect(find.byKey(const ValueKey('chat-find-exhausted')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rg1215 a hit in an earlier row of a grouped turn reveals and '
      'highlights the single response bubble', (tester) async {
    final history = <Map<String, dynamic>>[
      {'role': 'assistant', 'content': 'Respuesta final del turno.'},
      {
        'role': 'assistant',
        'content': 'Primero reviso la AGUJA intermedia.',
        '_activity_trace': [
          {'kind': 'tool', 'label': 'read_file', 'id': 'rg-find-1'},
        ],
      },
      {'role': 'user', 'content': 'Pregunta del turno.'},
      ..._history().skip(2),
    ];
    await pumpChat(tester, history: history);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('assistant-header-name')), findsWidgets);

    await openFindFromAppBar(tester);
    await typeQuery(tester, 'aguja intermedia');
    expect(find.text('1 de 1'), findsOneWidget);
    final hit = find.textContaining('AGUJA intermedia', findRichText: true);
    expect(_isOnScreen(tester, hit), isTrue);
    final highlight = find.bySemanticsLabel(
      RegExp('^Resultado de búsqueda actual'),
    );
    expect(highlight, findsOneWidget);
    // The highlighted bubble is the whole turn: the earlier row and the
    // final answer render inside it.
    expect(
      find.descendant(
        of: highlight,
        matching: find.textContaining(
          'Respuesta final del turno.',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
