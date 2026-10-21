// «Tareas = sesiones normales»: Nueva tarea abre un chat normal (como Desktop:
// session.create + prompt.submit por el WS del Dashboard) y el histórico de
// runs antiguos es de solo lectura, sin ninguna llamada a /v1/runs.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesStatusText;
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/runs_screen.dart';
import 'package:hermes_android/core/screens/task_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesDecisionBlock;
import 'package:hermes_android/core/widgets/run_template_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/desktop_chat_socket.dart' show HostCounter;

const _regKey = 'runs_conn-1';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'conn-1',
  label: 'Synthetic',
  host: 'localhost',
  port: 9131,
  apiKey: 'synthetic-fixture-key',
  kind: InstanceKind.localhost,
  readOnly: readOnly,
);

Map<String, dynamic> _row(String id, String prompt, String status, double at) =>
    {
      'run_id': id,
      'prompt': prompt,
      'created_at': at,
      'last_status': status,
      'conn_id': 'conn-1',
      'profile': 'default',
      if (status == 'completed') 'output': 'Output of $id',
      if (status == 'failed') 'error': 'Error of $id',
    };

Widget _app(Widget home, {List<NavigatorObserver> observers = const []}) =>
    MaterialApp(
      theme: AppTheme.hermesRedDark,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      navigatorObservers: observers,
      home: home,
    );

class _PushRecorder extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) =>
      pushed.add(route);
}

Finder _label(String text) => find.byWidgetPredicate(
  (w) => w is Text && w.data?.toLowerCase() == text.toLowerCase(),
);

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('new task with a template opens a normal chat with that prompt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _bigView(tester);
    final hosts = HostCounter();
    final recorder = _PushRecorder();
    final opened = <ChatScreen>[];
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(_regKey);
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _app(
          TaskCenterScreen(
            connection: _connection(),
            profile: 'work_bot',
            chatHost: (chat) {
              opened.add(chat);
              return const SizedBox(key: ValueKey('chat-stub'));
            },
          ),
          observers: [recorder],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('runs-create')));
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(TextField).first));
      final template = builtinRunTemplates(
        s,
      ).firstWhere((t) => !t.prompt.contains('{'));
      await tester.tap(find.text(template.name));
      await tester.pumpAndSettle();
      final launch = find.text(s.runComposerLaunch);
      await tester.ensureVisible(launch);
      await tester.tap(launch);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('chat-stub')), findsOneWidget);
      expect(opened, hasLength(1));
      final chat = opened.single;
      expect(chat.initialPrompt, template.prompt.trim());
      expect(chat.session.source, 'mobile');
      expect(chat.session.messageCount, 0);
      expect(chat.connection.id, 'conn-1');
      expect(hosts.runsRequests, isEmpty);
      expect(prefs.getString(_regKey), before);
      expect(
        recorder.pushed.whereType<MaterialPageRoute<void>>().length,
        greaterThanOrEqualTo(2),
      );
    }, () => hosts);
  });

  testWidgets('read-only connection still blocks new task', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _bigView(tester);
    final hosts = HostCounter();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _app(TaskCenterScreen(connection: _connection(readOnly: true))),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runs-create')), findsNothing);
      expect(find.byType(ChatScreen), findsNothing);
      expect(hosts.requests, isEmpty);
    }, () => hosts);
  });

  testWidgets('old runs show as read-only history, untouched, no network', (
    tester,
  ) async {
    final raw = jsonEncode([
      _row('run-done', 'Prompt done', 'completed', 300),
      _row('run-live', 'Prompt live', 'running', 200),
      _row('run-wait', 'Prompt wait', 'waiting_for_approval', 100),
    ]);
    SharedPreferences.setMockInitialValues({_regKey: raw});
    _bigView(tester);
    final hosts = HostCounter();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _app(TaskCenterScreen(connection: _connection())),
      );
      await tester.pumpAndSettle();
      for (final p in ['Prompt done', 'Prompt live', 'Prompt wait']) {
        expect(find.text(p), findsOneWidget);
      }
      final s = Strings.of(tester.element(find.byType(TaskCenterScreen)));
      expect(_label(s.runsStatusCompleted), findsOneWidget);
      // The two non-terminal rows are shown as expired, only on screen.
      expect(_label(s.runsStatusExpired), findsNWidgets(2));
      expect(_label(s.runsStatusRunning), findsNothing);
      expect(_label(s.runsStatusWaiting), findsNothing);
      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);

      await tester.tap(find.text('Prompt wait'));
      await tester.pumpAndSettle();
      expect(find.byType(RunDetailScreen), findsOneWidget);
      expect(find.byType(HermesDecisionBlock), findsNothing);
      expect(find.text('Denegar'), findsNothing);
      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_regKey), raw);
      expect(hosts.requests, isEmpty);
    }, () => hosts);
  });

  testWidgets('completed run detail shows saved output and error, no network', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _bigView(tester);
    final hosts = HostCounter();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _app(
          RunDetailScreen(
            connection: _connection(),
            record: RunRecord.fromJson(
              _row('run-done', 'Prompt done', 'completed', 1),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Prompt done'), findsOneWidget);
      expect(find.textContaining('Output of run-done'), findsWidgets);
      expect(hosts.requests, isEmpty);
    }, () => hosts);
  });

  testWidgets('initialApprovalId frees the notification tap exactly once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _bigView(tester);
    var ready = 0;
    final hosts = HostCounter();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _app(
          RunDetailScreen(
            connection: _connection(),
            record: RunRecord.fromJson(
              _row('run-wait', 'Prompt wait', 'waiting_for_approval', 1),
            ),
            initialApprovalId: 'request-a',
            onInitialApprovalReady: () => ready++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ready, 1);
      // Rebuilds do not call it again.
      await tester.pumpWidget(
        _app(
          RunDetailScreen(
            connection: _connection(),
            record: RunRecord.fromJson(
              _row('run-wait', 'Prompt wait', 'waiting_for_approval', 1),
            ),
            initialApprovalId: 'request-a',
            onInitialApprovalReady: () => ready++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ready, 1);
      final s = Strings.of(tester.element(find.byType(RunDetailScreen)));
      expect(
        tester
            .widget<HermesStatusText>(
              find.byKey(const ValueKey('run-detail-status')),
            )
            .label,
        s.runsStatusExpired,
      );
      expect(find.byType(HermesDecisionBlock), findsNothing);
      expect(hosts.requests, isEmpty);
    }, () => hosts);
  });
}
