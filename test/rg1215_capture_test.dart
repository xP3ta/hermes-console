// rg1215: PNG capture (412×915, Spanish, dark) of one agent turn made of
// three tool-only assistant rows plus the final text, while it is live. Writes PNGs only when
// RG1215_SHOTS_DIR is set; otherwise it checks the frame builds as one
// response bubble. Fixtures are synthetic.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _shotKey = ValueKey('rg1215-shot');

final _connection = SavedConnection(
  id: 'conn-rg1215',
  label: 'rg1215',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test',
);

const _session = Session(
  id: 'sess-rg1215',
  title: 'Revisión del informe',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 5,
  isActive: false,
  preview: '',
  startedAt: 0,
);

Map<String, dynamic> _toolRow(
  int n,
  List<(String, String)> calls, {
  String reasoning = '',
}) => {
  'role': 'assistant',
  'content': '',
  'id': 'rg-row-$n',
  'timestamp': 1790000000 + n * 20,
  'reasoning': ?(reasoning.isEmpty ? null : reasoning),
  '_activity_trace': [
    for (var i = 0; i < calls.length; i++)
      {
        'kind': 'tool',
        'label': calls[i].$1,
        'status': 'completed',
        'id': 'rg-call-$n-$i',
        'detail': calls[i].$2,
      },
  ],
};

/// Newest first, as ActiveChat stores it.
final _turn = <Map<String, dynamic>>[
  {
    'role': 'assistant',
    'content':
        'He revisado el informe y he dejado las notas en `notas.md`. '
        'Los tests pasan y no queda nada pendiente.',
    'id': 'rg-final',
    'timestamp': 1790000100,
  },
  _toolRow(3, [('terminal', 'flutter test'), ('terminal', 'git status')]),
  _toolRow(2, [('write_file', 'notas.md')]),
  _toolRow(1, [
    ('skill_view', 'github-pr-workflow'),
    ('skill_view', 'plan'),
    ('skill_view', 'dogfood'),
    ('clarify', ''),
    ('read_file', 'AGENTS.md'),
    ('read_file', 'informe.md'),
    ('execute_code', ''),
  ], reasoning: 'Primero leo el informe y las normas del repositorio.'),
  {
    'role': 'user',
    'content': 'Revisa el informe y deja notas.',
    'id': 'rg-user',
    'timestamp': 1789999990,
  },
];

Future<void> _save(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final dir = Platform.environment['RG1215_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TurnOutboxStore.resetSerializationForTesting();
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
          case 'readAll':
            return Map<String, String>.from(secure);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/methods',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    final temp = Directory.systemTemp.createTempSync('rg1215_shot_');
    addTearDown(() => temp.deleteSync(recursive: true));
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => temp.path,
    );
  });

  testWidgets('es dark: one agent turn renders as one response bubble', (
    tester,
  ) async {
    await loadDesignFonts();
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({
      'onboarding_done': true,
      'theme_mode': 'dark',
    });
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final service = ActiveChatService(attachDesktopRuntimeOnLoad: false);
    final chat = service.attach(
      connection: _connection,
      sessionId: _session.id,
      sessionTitle: _session.title,
      api: ApiClient(
        baseUrl: 'http://192.168.255.254:8642',
        apiKey: 'test',
        httpClient: MockClient((_) async => http.Response('nf', 404)),
      ),
      attachDesktopRuntimeOnLoad: false,
      allowUnownedDesktopSnapshotForTesting: true,
    );
    // The owner's case: the agent is still working, so the final text is the
    // live head and the earlier tool-only rows belong to the same turn.
    chat.internalMessagesForTesting = [
      {..._turn.first, '_pipeline': true},
      ..._turn.skip(1),
    ];
    chat.messagesLoaded = true;
    chat.state = ChatPipelineState.executing;

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: HermesApp(
          connManager: manager,
          appLock: AppLockService(prefs),
          approvalPolicy: ApprovalPolicyService(prefs),
          fontSize: FontSizeService(prefs),
          bridgeManager: BridgeManager(secure, manager),
          sshManager: SshManager(secure, manager),
          sftpTransfers: SftpTransferService(
            SshManager(secure, manager),
            NotificationService(prefs),
          ),
          sshSessions: SshSessionService(SshManager(secure, manager)),
          notifications: NotificationService(prefs),
          activeChats: service,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));

    final headers = find.byKey(const ValueKey('assistant-header-name'));
    final dir = Platform.environment['RG1215_SHOTS_DIR'] ?? '';
    // RG1215_BEFORE=1 records the base build, where each row is its own block.
    if (Platform.environment['RG1215_BEFORE'] != '1') {
      expect(headers, findsOneWidget);
    }
    final tag = Platform.environment['RG1215_BEFORE'] == '1'
        ? 'before'
        : 'after';
    if (dir.isNotEmpty) {
      debugPrint('rg1215 $tag headers=${headers.evaluate().length}');
    }
    await _save(tester, 'rg1215_turn_${tag}_es_dark');

    if (tag == 'after') {
      // Once the turn ends, the same single bubble expands its whole trace.
      chat.internalMessagesForTesting = _turn;
      chat.state = ChatPipelineState.idle;
      chat.debugEmitMessagesHydrated();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(headers, findsOneWidget);
      await tester.tap(find.byIcon(Icons.expand_more).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _save(tester, 'rg1215_turn_after_expanded_es_dark');
    }

    chat.state = ChatPipelineState.idle;
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
}
