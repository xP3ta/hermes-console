import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/widgets/chat_row_boundary.dart';
import 'package:hermes_android/main.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-rowerr',
  label: 'Row errors',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-rowerr',
  title: 'Errores de fila',
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
    ChatPerformanceProbe? probe,
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
        builder: (_) => ChatScreen(
          connection: connection,
          session: _session(),
          performanceProbe: probe,
        ),
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

  // Newest first, as ActiveChat stores it. Reply B is the one that fails.
  final longB =
      '${List.filled(160, 'Resultado del análisis de la sesión.').join('\n\n')}'
      '\nFIN-B';
  const shortB = 'Respuesta B con FIN-B';
  List<Map<String, dynamic>> history([String b = shortB]) => [
    {'id': 'm-c', 'role': 'assistant', 'content': 'Respuesta C'},
    {'id': 'u-c', 'role': 'user', 'content': 'Pregunta C'},
    {'id': 'm-b', 'role': 'assistant', 'content': b},
    {'id': 'u-b', 'role': 'user', 'content': 'Pregunta B'},
    {'id': 'm-a', 'role': 'assistant', 'content': 'Respuesta A'},
    {'id': 'u-a', 'role': 'user', 'content': 'Pregunta A'},
  ];

  bool isB(Object? unit) => unit is Map && unit['id'] == 'm-b';
  final card = find.byKey(const ValueKey('chat-row-failure'));
  final title = find.text('Este mensaje no se pudo mostrar');
  Finder reply(String text) => find.text(text, findRichText: true);
  List<AppErrorRecord> rowErrors() => [
    for (final r in AppErrorLog.recent)
      if (r.source == 'chat-row') r,
  ];

  void expectRowContained(WidgetTester tester) {
    expect(reply('Respuesta A'), findsOneWidget);
    expect(reply('Respuesta C'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(card, findsOneWidget);
    expect(title, findsOneWidget);
  }

  void expectLogged(String type) {
    final records = rowErrors();
    expect(records, hasLength(1));
    expect(records.single.errorType, type);
    expect(records.single.rowId, 'message:m-b');
    expect(records.single.toString(), isNot(contains('FIN-B')));
    expect(records.single.toString(), isNot(contains('SECRETO')));
  }

  setUp(() {
    AppErrorLog.resetForTesting();
    final saved = ErrorWidget.builder;
    installChatRowErrorWidget();
    addTearDown(() {
      ChatRowFaults.debugPlanFault = null;
      ChatRowFaults.debugRowChild = null;
      ErrorWidget.builder = saved;
    });
  });

  testWidgets('T1 a plan fault in one reply leaves the others and logs it', (
    tester,
  ) async {
    final probe = ChatPerformanceProbe();
    ChatRowFaults.debugPlanFault = (message) {
      if (isB(message)) throw const FormatException('SECRETO plan');
    };
    expect(longB.length, greaterThan(5200));
    final chat = await pumpChat(tester, history: history(longB), probe: probe);

    expect(tester.takeException(), isNull);
    expectRowContained(tester);
    expectLogged('FormatException');

    // Streaming flushes replace the head map: the failed plan is latched in
    // the plan cache, so it is neither recomputed nor logged again.
    final plans = probe.assistantRenderPlanComputations;
    expect(plans, 1);
    for (var i = 0; i < 3; i++) {
      chat.internalMessagesForTesting = [
        {...chat.internalMessagesForTesting.first},
        ...chat.internalMessagesForTesting.skip(1),
      ];
      tester.element(find.byType(ChatScreen)).markNeedsBuild();
      await tester.pump();
    }
    expect(probe.assistantRenderPlanComputations, plans);
    expectRowContained(tester);
    expect(rowErrors(), hasLength(1));
  });

  testWidgets('T2 a descendant that throws while building stays in its row', (
    tester,
  ) async {
    ChatRowFaults.debugRowChild = (unit) =>
        isB(unit) ? const _Boom('SECRETO build') : null;
    await pumpChat(tester, history: history());

    expect(tester.takeException(), isA<StateError>());
    expectRowContained(tester);
    expectLogged('StateError');
  });

  testWidgets('T2 a descendant that throws on a later rebuild is contained', (
    tester,
  ) async {
    final broken = ValueNotifier(false);
    addTearDown(broken.dispose);
    ChatRowFaults.debugRowChild = (unit) => isB(unit)
        ? ValueListenableBuilder<bool>(
            valueListenable: broken,
            builder: (_, value, _) {
              if (value) throw StateError('SECRETO late');
              return const Text('Cuerpo de B');
            },
          )
        : null;
    await pumpChat(tester, history: history());
    expect(find.text('Cuerpo de B'), findsOneWidget);
    expect(card, findsNothing);

    broken.value = true;
    await tester.pump();

    expect(tester.takeException(), isA<StateError>());
    expectRowContained(tester);
    expectLogged('StateError');
  });

  testWidgets('T3 an item-builder fault becomes a card, not a grey list', (
    tester,
  ) async {
    ChatRowFaults.debugRowChild = (unit) {
      if (isB(unit)) throw const FormatException('SECRETO builder');
      return null;
    };
    await pumpChat(tester, history: history());

    expect(tester.takeException(), isNull);
    expectRowContained(tester);
    expectLogged('FormatException');
  });

  testWidgets('T4 outside a chat row the default error widget is unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedLight,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: _Boom('fuera')),
      ),
    );

    expect(tester.takeException(), isA<StateError>());
    expect(find.byType(ErrorWidget), findsOneWidget);
    expect(card, findsNothing);
    expect(title, findsNothing);
    expect(rowErrors(), isEmpty);
  });

  testWidgets('T6 a card that cannot build does not recurse into cards', (
    tester,
  ) async {
    // No Strings delegate: the card itself throws while building.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedLight,
        home: const Scaffold(
          body: ChatRowScope(rowId: 'message:x', raw: null, child: _Boom('x')),
        ),
      ),
    );

    expect(tester.takeException(), isNotNull);
    expect(find.byType(ErrorWidget), findsOneWidget);
    expect(card, findsNothing);
  });

  testWidgets('T5 Copy plain text copies the raw reply; tool rows hide it', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    ChatRowFaults.debugRowChild = (unit) =>
        isB(unit) ? const _Boom('SECRETO') : null;
    await pumpChat(tester, history: history());
    tester.takeException();

    await tester.tap(find.text('Copiar texto sin formato'));
    await tester.pump();
    expect(copied, shortB);
    expect(find.text('Texto copiado'), findsOneWidget);
  });

  for (final (label, theme) in [
    ('light', AppTheme.hermesRedLight),
    ('dark', AppTheme.hermesRedDark),
  ]) {
    testWidgets('T5 the card fits a tablet in $label; no raw text, no copy', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1600, 2400)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      for (final raw in <String?>[null, 'texto']) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: Scaffold(body: ChatRowFailureCard(raw: raw)),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text("This message couldn't be shown"), findsOneWidget);
        expect(
          find.text('Copy plain text'),
          raw == null ? findsNothing : findsOneWidget,
        );
        expect(tester.getSize(card).height, lessThan(120));
      }
    });
  }

  testWidgets('performance: counters for 500 messages, scroll and flushes', (
    tester,
  ) async {
    final probe = ChatPerformanceProbe();
    final long = List.filled(
      160,
      'Resultado del análisis de la sesión.',
    ).join('\n\n');
    expect(long.length, greaterThan(5200));
    final messages = [
      for (var i = 499; i >= 0; i--)
        {
          'id': 'p-$i',
          'role': i.isEven ? 'assistant' : 'user',
          'content': i % 40 == 0 ? long : 'Mensaje $i',
        },
    ];
    final chat = await pumpChat(tester, history: messages, probe: probe);
    final list = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(ListView),
    );
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 20; i++) {
      final current = chat.internalMessagesForTesting;
      chat.internalMessagesForTesting = [
        {...current.first, 'content': '${current.first['content']} +$i'},
        ...current.skip(1),
      ];
      tester.element(find.byType(ChatScreen)).markNeedsBuild();
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(tester.takeException(), isNull);
    // ignore: avoid_print
    print(
      'ROWERR-COUNTERS renderProjectionBuilds=${probe.renderProjectionBuilds} '
      'listEntryProjections=${probe.listEntryProjections} '
      'assistantRenderPlanComputations='
      '${probe.assistantRenderPlanComputations}',
    );
    expect(rowErrors(), isEmpty);
  });
}

class _Boom extends StatelessWidget {
  const _Boom(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => throw StateError(message);
}
