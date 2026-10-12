import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Chats on a tablet: the conversation list and the open conversation side by
// side in expanded windows, one at a time in medium ones, and the phone flow
// (a full-screen chat route) on compact windows.

const _connectionId = 'conn-tablet-chats';

Map<String, dynamic> _row(String id, String title, int lastActive) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': '',
  'model': 'model-a',
  'source': 'mobile',
  'message_count': 2,
  'is_active': false,
  'started_at': lastActive - 30,
  'ended_at': lastActive - 1,
  'last_active': lastActive,
  'archived': false,
};

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Tablet QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

/// Stand-in for the chat: the real ChatScreen needs the whole app. It has a
/// composer-like field so the draft can be followed across rotations.
class _ChatProbe extends StatefulWidget {
  final Session session;
  const _ChatProbe(this.session);
  static int mounts = 0;
  @override
  State<_ChatProbe> createState() => _ChatProbeState();
}

class _ChatProbeState extends State<_ChatProbe> {
  final draft = TextEditingController();
  @override
  void initState() {
    super.initState();
    _ChatProbe.mounts++;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: ValueKey('chat-probe-${widget.session.id}'),
    body: ListView(
      children: [
        Text('chat ${widget.session.id}'),
        TextField(key: const ValueKey('probe-composer'), controller: draft),
      ],
    ),
  );
}

class _Recorder extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    _ChatProbe.mounts = 0;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments is Map
                ? Map<Object?, Object?>.from(call.arguments as Map)
                : const <Object?, Object?>{};
            switch (call.method) {
              case 'write':
                secureValues[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureValues[args['key']];
              case 'readAll':
                return Map<String, String>.of(secureValues);
              case 'delete':
                secureValues.remove(args['key']);
                return null;
            }
            return null;
          },
        );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
    await DockPreferencesController.instance.setUseDock(true);
  });

  Future<_Recorder> pump(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = [
      _row('s-1', 'Firma del keystore en CI', now - 60),
      _row('s-2', 'Notas de la release', now - 120),
    ];
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'sessions': rows,
              'total': rows.length,
              'limit': 50,
              'offset': 0,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final gateway = ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'k',
      connectionId: _connectionId,
      httpClient: MockClient((request) async {
        if (request.url.path == '/health' ||
            request.url.path == '/api/sessions') {
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });
    final recorder = _Recorder();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        navigatorObservers: [recorder],
        home: SessionListScreen(
          connection: _connection(),
          connManager: manager,
          clientOverride: gateway,
          repositoryOverride: repository,
          chatScreenBuilderOverride: (session) => _ChatProbe(session),
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (find.text('Notas de la release').evaluate().isNotEmpty) break;
    }
    expect(find.text('Notas de la release'), findsOneWidget);
    return recorder;
  }

  Finder pane() => find.byKey(const ValueKey('adaptive-detail-pane'));
  Finder probe(String id) => find.byKey(ValueKey('chat-probe-$id'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final size in const [Size(1024, 768), Size(1280, 800)]) {
    testWidgets('expanded ${size.width.toInt()}x${size.height.toInt()}: '
        'list beside the chat; a tap opens it in the pane', (tester) async {
      final recorder = await pump(tester, size);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('general-mode-dock-rail')),
        findsOneWidget,
      );
      expect(pane(), findsOneWidget);
      final pushesBefore = recorder.pushes;
      final listTitle = tester.getRect(find.text('Notas de la release'));

      await tester.tap(find.text('Firma del keystore en CI'));
      await settle(tester);
      expect(recorder.pushes, pushesBefore, reason: 'no app route push');
      expect(
        find.descendant(of: pane(), matching: probe('s-1')),
        findsOneWidget,
      );
      // The list stays on screen, left of the chat, at the list width.
      expect(find.text('Notas de la release'), findsOneWidget);
      final chat = tester.getRect(probe('s-1'));
      expect(chat.left, greaterThan(listTitle.right));
      expect(
        tester.getRect(pane()).left -
            tester.getRect(find.byType(SessionListScreen)).left,
        greaterThan(Responsive.listPaneWidth),
      );

      // Selecting the same conversation again does not reopen it.
      await tester.tap(find.text('Firma del keystore en CI'));
      await settle(tester);
      expect(_ChatProbe.mounts, 1);

      // Another one replaces it in place.
      await tester.tap(find.text('Notas de la release'));
      await settle(tester);
      expect(probe('s-1'), findsNothing);
      expect(probe('s-2'), findsOneWidget);
      expect(recorder.pushes, pushesBefore);

      // Back closes the open conversation first, staying on the list.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(probe('s-2'), findsNothing);
      expect(find.text('Notas de la release'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('compact 411x915: the phone flow is unchanged', (tester) async {
    final recorder = await pump(tester, const Size(411, 915));
    await settle(tester);
    expect(pane(), findsNothing);
    expect(
      find.byKey(const ValueKey('general-mode-floating-dock')),
      findsOneWidget,
    );
    final before = recorder.pushes;
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    expect(recorder.pushes, before + 1, reason: 'full-screen chat route');
    expect(probe('s-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium 700x1000: the chat replaces the list; Back returns', (
    tester,
  ) async {
    final recorder = await pump(tester, const Size(700, 1000));
    await settle(tester);
    final before = recorder.pushes;
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    expect(recorder.pushes, before);
    expect(probe('s-1'), findsOneWidget);
    expect(find.text('Notas de la release'), findsNothing);
    final chat = tester.getRect(probe('s-1'));
    expect(chat.width, lessThanOrEqualTo(Responsive.maxContentWidth));
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('Notas de la release'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation keeps the open chat and its composer draft', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('probe-composer')),
      'half a thought',
    );
    final state = tester.state(find.byType(_ChatProbe));
    for (final size in const [Size(800, 1280), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(probe('s-1'), findsOneWidget);
      expect(tester.state(find.byType(_ChatProbe)), same(state));
      expect(find.text('half a thought'), findsOneWidget);
    }
    expect(_ChatProbe.mounts, 1);
  });
}
