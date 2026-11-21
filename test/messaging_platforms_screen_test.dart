// Settings › Messaging over a stand-in of hermes_cli/web_routers/
// messaging.py, ops.py (pairing) and actions.py: what the page shows in
// each state, and the requests the server receives for what the user does.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/content.dart' show HermesStatusText;
import 'package:hermes_android/core/screens/messaging_platforms_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/messaging_pairing.dart';
import 'package:hermes_android/core/services/messaging_platforms.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _field(
  String key, {
  bool required = false,
  bool password = false,
  bool list = false,
  String saved = '',
}) => {
  'key': key,
  'required': required,
  'is_set': saved.isNotEmpty,
  'is_password': password,
  'is_list': list,
  'advanced': false,
  'prompt': key,
  'description': '',
  'url': null,
  'redacted_value': saved.isEmpty ? null : '«redacted:1234…wxyz»',
  'value': list ? saved : null,
};

List<Map<String, dynamic>> _platforms() => [
  {
    'id': 'telegram',
    'name': 'Telegram',
    'description': 'Telegram bot',
    'docs_url': 'https://docs.example.test/telegram',
    'enabled': true,
    'configured': true,
    'gateway_running': true,
    'state': 'connected',
    'env_vars': [
      _field(
        'TELEGRAM_BOT_TOKEN',
        required: true,
        password: true,
        saved: 'saved-secret',
      ),
      _field('TELEGRAM_ALLOWED_USERS', list: true, saved: '111,222'),
      _field('TELEGRAM_HOME_CHANNEL'),
    ],
  },
  {
    'id': 'discord',
    'name': 'Discord',
    'description': 'Discord bot',
    'enabled': false,
    'configured': false,
    'gateway_running': true,
    'state': 'disabled',
    'env_vars': [_field('DISCORD_BOT_TOKEN', required: true, password: true)],
  },
  {
    'id': 'slack',
    'name': 'Slack',
    'description': 'Slack app',
    'enabled': true,
    'configured': false,
    'gateway_running': true,
    'state': 'not_configured',
    'env_vars': [_field('SLACK_BOT_TOKEN', required: true, password: true)],
  },
];

class _Server {
  final requests = <http.Request>[];
  List<Map<String, dynamic>> platforms = _platforms();
  int listStatus = 200;
  int putStatus = 200;
  String putDetail = '';
  bool hotServed = false;
  bool telegramReady = false;
  int telegramStartStatus = 200;
  int applyStatus = 200;
  int relayStatus = 200;
  final relayAccounts = <Map<String, dynamic>>[];
  final relayStates = <String>[];
  Completer<void>? holdList;
  final pending = <Map<String, dynamic>>[
    {
      'platform': 'telegram',
      'request_id': 'req-1',
      'user_id': '4242',
      'user_name': 'Ana',
      'age_minutes': 3,
    },
  ];
  final approved = <Map<String, dynamic>>[];

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    final method = request.method;
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (method == 'GET' && path == '/api/messaging/platforms') {
      await holdList?.future;
      if (listStatus != 200) {
        return _json({
          'detail': listStatus == 404 ? 'Not Found' : 'boom',
        }, listStatus);
      }
      return _json({'platforms': platforms});
    }
    final put = RegExp(r'^/api/messaging/platforms/(\w+)$').firstMatch(path);
    if (method == 'PUT' && put != null) {
      if (putStatus != 200) return _json({'detail': putDetail}, putStatus);
      final row = platforms.firstWhere((p) => p['id'] == put.group(1));
      if (body['enabled'] is bool) {
        row['enabled'] = body['enabled'];
        row['state'] = body['enabled'] == true ? 'pending_restart' : 'disabled';
      }
      final env = (body['env'] as Map?) ?? const {};
      final clear = (body['clear_env'] as List?) ?? const [];
      for (final field in row['env_vars'] as List) {
        final map = field as Map<String, dynamic>;
        if (env.containsKey(map['key'])) {
          map['is_set'] = true;
          map['redacted_value'] = '«redacted:new…»';
          if (map['is_list'] == true) map['value'] = env[map['key']];
        }
        if (clear.contains(map['key'])) {
          map['is_set'] = false;
          map['redacted_value'] = null;
          if (map['is_list'] == true) map['value'] = '';
        }
      }
      return _json({
        'ok': true,
        'platform': put.group(1),
        'hot_served': hotServed,
      });
    }
    if (method == 'POST' && path.endsWith('/test')) {
      return _json({
        'ok': true,
        'state': 'connected',
        'message': 'Telegram is connected.',
      });
    }
    if (method == 'GET' && path == '/api/pairing') {
      return _json({'pending': pending, 'approved': approved});
    }
    if (method == 'POST' && path == '/api/pairing/approve') {
      final row = pending.firstWhere(
        (r) => r['request_id'] == body['request_id'],
      );
      pending.remove(row);
      approved.add(row);
      return _json({'ok': true, 'user': row});
    }
    if (method == 'POST' &&
        path == '/api/messaging/telegram/onboarding/start') {
      if (telegramStartStatus != 200) {
        return _json({'detail': 'Not Found'}, telegramStartStatus);
      }
      return _json({
        'pairing_id': 'pair-1',
        'deep_link': 'https://t.me/newbot?start=pair-1',
        'qr_payload': 'https://t.me/newbot?start=pair-1',
        'expires_at': '2099-01-01T00:00:00Z',
      });
    }
    if (method == 'GET' &&
        path == '/api/messaging/telegram/onboarding/pair-1') {
      return _json(
        telegramReady
            ? {
                'status': 'ready',
                'bot_username': 'hermes_bot',
                'owner_user_id': '424242',
              }
            : {'status': 'waiting', 'expires_at': '2099-01-01T00:00:00Z'},
      );
    }
    if (method == 'POST' &&
        path == '/api/messaging/telegram/onboarding/pair-1/apply') {
      if (applyStatus != 200) {
        return _json({'detail': 'Could not write the env file.'}, applyStatus);
      }
      return _json({
        'ok': true,
        'platform': 'telegram',
        'bot_username': 'hermes_bot',
        'needs_restart': false,
        'restart_started': true,
      });
    }
    if (method == 'GET' && path == '/api/messaging/relay') {
      if (relayStatus != 200) return _json({'detail': 'Not Found'}, 404);
      return _json({
        'managed_by': 'connector',
        'platforms': [
          {
            'platform': 'discord',
            'bot_url': 'https://discord.example.test/shared-bot',
            'accounts': relayAccounts,
          },
        ],
      });
    }
    if (method == 'POST' && path == '/api/messaging/relay/discord/link') {
      return _json({
        'platform': 'discord',
        'code': 'ABC123',
        'command': '/link ABC123',
        'bot_url': 'https://discord.example.test/shared-bot',
        'expires_at': '2099-01-01T00:00:00Z',
      });
    }
    if (method == 'GET' && path == '/api/messaging/relay/link/ABC123') {
      final state = relayStates.isEmpty ? 'pending' : relayStates.removeAt(0);
      if (state == 'inactive') {
        relayAccounts.add({'platformUserId': '99', 'displayName': 'Ana'});
      }
      return _json({'state': state});
    }
    if (method == 'POST' && path == '/api/gateway/restart') {
      return _json({'ok': true, 'pid': 1, 'name': 'gateway-restart'});
    }
    if (method == 'GET' && path == '/api/actions/gateway-restart/status') {
      return _json({'running': false, 'exit_code': 0, 'lines': []});
    }
    return _json({'detail': 'Not Found'}, 404);
  }

  List<http.Request> writes() => [
    for (final request in requests)
      if (request.method != 'GET') request,
  ];

  int reads(String path) => requests
      .where((r) => r.method == 'GET' && r.url.path == path)
      .length;

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;
}

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'messaging-test',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: '',
  readOnly: readOnly,
);

/// A section heading, whatever case the theme paints it in.
Finder _header(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is Text && (widget.data ?? '').toLowerCase() == text.toLowerCase(),
);

TextField _input(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey('msgplat-input-$key')));

String _status(WidgetTester tester) => tester
    .widget<HermesStatusText>(find.byKey(const ValueKey('msgplat-status')))
    .label;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Server> open(
    WidgetTester tester, {
    _Server? server,
    bool readOnly = false,
    Duration? pollInterval,
    List<String>? opened,
    bool settle = true,
  }) async {
    final fake = server ?? _Server();
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient(fake.handle),
    );
    addTearDown(dashboard.close);
    tester.view.physicalSize = const Size(480, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: MessagingPlatformsScreen(
          connection: _connection(readOnly: readOnly),
          profile: 'research',
          client: MessagingPlatformsClient(dashboard),
          pairingClient: MessagingPairingClient(dashboard),
          verifyLock: (_) async => true,
          openUrl: (url) async {
            opened?.add(url);
            return true;
          },
          pollInterval: pollInterval,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
    return fake;
  }

  Future<void> openPlatform(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('msgplat-row-$id')));
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('msgplat-save')));
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) {
    final button = find.descendant(
      of: find.byKey(const ValueKey('msgplat-save')),
      matching: find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton,
      ),
    );
    return tester.widget<ButtonStyleButton>(button).onPressed != null;
  }

  group('the list', () {
    testWidgets('shows a loader, then each platform with its state and who '
        'waits, read for the named profile', (tester) async {
      final semantics = tester.ensureSemantics();
      final server = _Server()..holdList = Completer<void>();
      await open(tester, server: server, settle: false);
      await tester.pump();
      expect(find.byKey(const ValueKey('msgplat-row-telegram')), findsNothing);
      expect(find.text('Messaging'), findsOneWidget);

      server.holdList!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Telegram'), findsOneWidget);
      expect(find.text('Connected'), findsWidgets);
      expect(find.text('Disabled'), findsOneWidget);
      expect(find.text('Needs setup'), findsOneWidget);
      // Ana waits on Telegram: the row says so before it is opened.
      expect(
        find.bySemanticsLabel(RegExp('1 pending pairing request')),
        findsOneWidget,
      );
      final reads = {
        for (final request in server.requests)
          request.url.path: request.url.queryParameters,
      };
      expect(reads['/api/messaging/platforms'], {'profile': 'research'});
      expect(reads['/api/pairing'], {'profile': 'research'});
      expect(server.writes(), isEmpty);
      semantics.dispose();
    });

    testWidgets('search and the status filter narrow the list', (
      tester,
    ) async {
      await open(tester);
      final search = find.byKey(const ValueKey('msgplat-search'));
      await tester.enterText(search, 'sl');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('msgplat-row-slack')), findsOneWidget);
      expect(find.byKey(const ValueKey('msgplat-row-telegram')), findsNothing);

      await tester.enterText(search, '');
      await tester.tap(find.byKey(const ValueKey('msgplat-filter-good')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('msgplat-row-telegram')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('msgplat-row-slack')), findsNothing);
      expect(find.byKey(const ValueKey('msgplat-row-discord')), findsNothing);
    });

    testWidgets('an empty server and a failed load each say so, and retry '
        'reads again', (tester) async {
      final empty = _Server()..platforms = [];
      await open(tester, server: empty);
      expect(find.byKey(const ValueKey('msgplat-empty')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      final failing = _Server()..listStatus = 500;
      await open(tester, server: failing);
      expect(find.byKey(const ValueKey('msgplat-load-failed')), findsOneWidget);
      failing.listStatus = 200;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('msgplat-row-telegram')),
        findsOneWidget,
      );
      expect(failing.reads('/api/messaging/platforms'), 2);
    });

    testWidgets('an older server without the route is told to update, and '
        'is not asked again', (tester) async {
      final server = await open(
        tester,
        server: _Server()..listStatus = 404,
        pollInterval: const Duration(seconds: 6),
      );
      expect(find.byKey(const ValueKey('msgplat-too-old')), findsOneWidget);
      expect(
        find.text(
          'Your Hermes server is too old for messaging setup. Update Hermes '
          'to set up platforms from here.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 30));
      expect(server.reads('/api/messaging/platforms'), 1);
      expect(
        find.byKey(const ValueKey('msgplat-refresh-failed')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the poll reads quietly: a failed read says nothing', (
      tester,
    ) async {
      final server = await open(
        tester,
        pollInterval: const Duration(seconds: 6),
      );
      server.platforms[2]['state'] = 'connected';
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(server.reads('/api/messaging/platforms'), 2);
      expect(find.text('Needs setup'), findsNothing);

      server.listStatus = 500;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(server.reads('/api/messaging/platforms'), 3);
      expect(
        find.byKey(const ValueKey('msgplat-refresh-failed')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('msgplat-row-telegram')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('a platform', () {
    testWidgets('a saved secret is never put in its field and never sent '
        'back; only what is typed is saved', (tester) async {
      final server = await open(tester);
      await openPlatform(tester, 'telegram');

      // The token is saved: its field is empty, obscured, and the preview
      // is only the hint.
      final token = _input(tester, 'TELEGRAM_BOT_TOKEN');
      expect(token.controller!.text, isEmpty);
      expect(token.obscureText, isTrue);
      expect(token.enableSuggestions, isFalse);
      expect(find.text('1234…wxyz'), findsOneWidget);
      // The allowlist shows its plain ids, one per box.
      expect(find.text('111'), findsOneWidget);
      expect(find.text('222'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
      expect(find.byKey(const ValueKey('msgplat-unsaved')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('msgplat-input-TELEGRAM_HOME_CHANNEL')),
        ' -1001 ',
      );
      await tester.pump();
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(saveEnabled(tester), isTrue);
      await tapSave(tester);

      final put = server.writes().single;
      expect(put.method, 'PUT');
      expect(put.url.path, '/api/messaging/platforms/telegram');
      expect(put.url.queryParameters, {'profile': 'research'});
      expect(server.bodyOf(put), {
        'env': {'TELEGRAM_HOME_CHANNEL': '-1001'},
      });
      expect(put.body, isNot(contains('redacted')));
      expect(put.body, isNot(contains('TELEGRAM_BOT_TOKEN')));
      expect(put.body, isNot(contains('1234')));
      // Read again, then the edit is dropped: the field is empty again.
      expect(server.requests.last.url.path, '/api/messaging/platforms');
      expect(_input(tester, 'TELEGRAM_HOME_CHANNEL').controller!.text, '');
      expect(_input(tester, 'TELEGRAM_BOT_TOKEN').controller!.text, '');
      expect(
        _status(tester),
        'Telegram setup saved. New credentials take effect after a gateway '
        'restart.',
      );
      expect(
        find.byKey(const ValueKey('msgplat-restart-needed')),
        findsOneWidget,
      );

      // A new token typed in replaces the saved one: it is the one thing
      // sent.
      await tester.enterText(
        find.byKey(const ValueKey('msgplat-input-TELEGRAM_BOT_TOKEN')),
        '123:new-token',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('msgplat-eye-TELEGRAM_BOT_TOKEN')),
      );
      await tester.pump();
      expect(_input(tester, 'TELEGRAM_BOT_TOKEN').obscureText, isFalse);
      await tapSave(tester);
      expect(server.bodyOf(server.writes().last), {
        'env': {'TELEGRAM_BOT_TOKEN': '123:new-token'},
      });
      expect(_input(tester, 'TELEGRAM_BOT_TOKEN').controller!.text, '');
      expect(_input(tester, 'TELEGRAM_BOT_TOKEN').obscureText, isTrue);
    });

    testWidgets('a failed save keeps what was typed and says why', (
      tester,
    ) async {
      final server = await open(
        tester,
        server: _Server()
          ..putStatus = 400
          ..putDetail = 'TELEGRAM_HOME_CHANNEL must be a chat id',
      );
      await openPlatform(tester, 'telegram');
      await tester.enterText(
        find.byKey(const ValueKey('msgplat-input-TELEGRAM_HOME_CHANNEL')),
        'not-a-chat',
      );
      await tester.pump();
      await tapSave(tester);

      expect(server.writes(), hasLength(1));
      expect(
        _status(tester),
        'Failed to save Telegram: TELEGRAM_HOME_CHANNEL must be a chat id',
      );
      expect(
        _input(tester, 'TELEGRAM_HOME_CHANNEL').controller!.text,
        'not-a-chat',
      );
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(saveEnabled(tester), isTrue);
      expect(
        find.byKey(const ValueKey('msgplat-restart-needed')),
        findsNothing,
      );
    });

    testWidgets('an edit survives going back to the list', (tester) async {
      await open(tester);
      await openPlatform(tester, 'telegram');
      await tester.enterText(
        find.byKey(const ValueKey('msgplat-input-TELEGRAM_HOME_CHANNEL')),
        '-42',
      );
      await tester.pump();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await openPlatform(tester, 'telegram');
      expect(_input(tester, 'TELEGRAM_HOME_CHANNEL').controller!.text, '-42');
      expect(find.text('Unsaved changes'), findsOneWidget);
    });

    testWidgets('emptying a saved allowlist clears it', (tester) async {
      final server = await open(tester);
      await openPlatform(tester, 'telegram');
      final remove = find.byTooltip('Remove');
      await tester.tap(remove.first);
      await tester.pump();
      await tester.tap(remove.first);
      await tester.pump();
      await tapSave(tester);
      expect(server.bodyOf(server.writes().single), {
        'clear_env': ['TELEGRAM_ALLOWED_USERS'],
      });
    });

    testWidgets('switching a platform on owes a restart unless the gateway '
        'serves it live; Restart now confirms and follows the restart of '
        'the named profile', (tester) async {
      final server = await open(tester);
      await openPlatform(tester, 'discord');
      await tester.tap(find.byKey(const ValueKey('msgplat-enabled')));
      await tester.pumpAndSettle();
      expect(server.bodyOf(server.writes().single), {'enabled': true});
      expect(server.writes().single.url.queryParameters, {
        'profile': 'research',
      });
      expect(
        _status(tester),
        'Discord enabled. This change takes effect after a gateway restart.',
      );
      expect(
        find.byKey(const ValueKey('msgplat-restart-needed')),
        findsOneWidget,
      );

      await tester.tap(find.text('Restart now'));
      await tester.pumpAndSettle();
      // The same question Settings asks before a restart.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('hermes-dialog')),
          matching: find.text('Restart'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final restart = server.writes().last;
      expect(restart.url.path, '/api/gateway/restart');
      expect(restart.url.queryParameters, {'profile': 'research'});
      expect(server.reads('/api/actions/gateway-restart/status'), 1);
      expect(_status(tester), 'Gateway restarted.');
      expect(
        find.byKey(const ValueKey('msgplat-restart-needed')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a change the running gateway applies live owes no '
        'restart', (tester) async {
      await open(tester, server: _Server()..hotServed = true);
      await openPlatform(tester, 'discord');
      await tester.tap(find.byKey(const ValueKey('msgplat-enabled')));
      await tester.pumpAndSettle();
      expect(
        _status(tester),
        'Discord enabled. Applied to the running gateway.',
      );
      expect(
        find.byKey(const ValueKey('msgplat-restart-needed')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Test shows the server verdict', (tester) async {
      final server = await open(tester);
      await openPlatform(tester, 'telegram');
      await tester.tap(find.byKey(const ValueKey('msgplat-test')));
      await tester.pumpAndSettle();
      final post = server.writes().single;
      expect(post.url.path, '/api/messaging/platforms/telegram/test');
      expect(post.url.queryParameters, {'profile': 'research'});
      expect(_status(tester), 'Telegram: Telegram is connected.');
    });

    testWidgets('who waits on this platform can be approved into the named '
        'profile', (tester) async {
      final server = await open(tester);
      await openPlatform(tester, 'telegram');
      expect(_header('Pending requests (1)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('msgplat-approve-4242')));
      await tester.pumpAndSettle();
      final post = server.writes().single;
      expect(post.url.path, '/api/pairing/approve');
      expect(server.bodyOf(post), {
        'platform': 'telegram',
        'request_id': 'req-1',
        'profile': 'research',
      });
      expect(_header('Approved users (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('msgplat-revoke-4242')), findsOneWidget);
    });

    testWidgets('read-only: everything shows, nothing can be changed', (
      tester,
    ) async {
      final server = await open(tester, readOnly: true);
      await openPlatform(tester, 'telegram');
      expect(
        find.text(
          'This connection is read-only: platforms can be viewed but not '
          'changed.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Switch>(find.byKey(const ValueKey('msgplat-enabled')))
            .onChanged,
        isNull,
      );
      expect(find.byKey(const ValueKey('msgplat-save')), findsNothing);
      expect(_input(tester, 'TELEGRAM_BOT_TOKEN').enabled, isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('msgplat-clear-TELEGRAM_BOT_TOKEN')),
            )
            .onPressed,
        isNull,
      );
      expect(server.writes(), isEmpty);
    });

    testWidgets('Telegram quick setup: open Telegram, confirm, review who '
        'may talk to the bot, save into the named profile', (tester) async {
      final opened = <String>[];
      final server = await open(tester, opened: opened);
      await openPlatform(tester, 'telegram');
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-start')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('msgplat-tg-waiting')), findsOneWidget);
      final start = server.writes().single;
      expect(start.url.path, '/api/messaging/telegram/onboarding/start');
      expect(start.url.queryParameters, {'profile': 'research'});

      await tester.tap(find.byKey(const ValueKey('msgplat-tg-open')));
      await tester.pump();
      expect(opened, ['https://t.me/newbot?start=pair-1']);

      // Still waiting on the first read; ready on the next.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('msgplat-tg-waiting')), findsOneWidget);
      server.telegramReady = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Owner detected'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('msgplat-tg-id-424242')),
        findsOneWidget,
      );
      final status = server.requests.lastWhere(
        (r) => r.url.path == '/api/messaging/telegram/onboarding/pair-1',
      );
      expect(status.url.queryParameters, {'profile': 'research'});

      // Another id joins the owner's.
      await tester.enterText(
        find.byKey(const ValueKey('msgplat-tg-new-id')),
        '777',
      );
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-add')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-apply')));
      await tester.pump();
      await tester.pump();
      final apply = server.writes().last;
      expect(apply.url.path, '/api/messaging/telegram/onboarding/pair-1/apply');
      expect(apply.url.queryParameters, {'profile': 'research'});
      expect(server.bodyOf(apply), {
        'allowed_user_ids': ['424242', '777'],
        'profile': 'research',
      });
      // The server restarts the gateway itself: only its outcome is read.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(server.reads('/api/actions/gateway-restart/status'), 1);
      expect(
        server.writes().where((r) => r.url.path == '/api/gateway/restart'),
        isEmpty,
      );
      expect(find.text('@hermes_bot'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('msgplat-restart-needed')),
        findsNothing,
      );
    });

    testWidgets('a failed quick setup save keeps the review open and says '
        'why', (tester) async {
      final server = _Server()
        ..telegramReady = true
        ..applyStatus = 500;
      await open(tester, server: server);
      await openPlatform(tester, 'telegram');
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-start')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-apply')));
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<HermesStatusText>(
              find.byKey(const ValueKey('msgplat-tg-error')),
            )
            .label,
        'Failed to save Telegram: Could not write the env file.',
      );
      expect(
        find.byKey(const ValueKey('msgplat-tg-id-424242')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-cancel-review')));
      await tester.pumpAndSettle();
    });

    testWidgets('a server without Telegram quick setup says so in the card '
        'and asks once', (tester) async {
      final server = await open(
        tester,
        server: _Server()..telegramStartStatus = 404,
      );
      await openPlatform(tester, 'telegram');
      await tester.tap(find.byKey(const ValueKey('msgplat-tg-start')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('msgplat-tg-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('msgplat-tg-start')), findsNothing);
      expect(find.byKey(const ValueKey('msgplat-tg-error')), findsNothing);
      expect(server.writes(), hasLength(1));
      // The rest of the page still works: a token can be pasted.
      expect(
        find.byKey(const ValueKey('msgplat-input-TELEGRAM_BOT_TOKEN')),
        findsOneWidget,
      );
    });

    testWidgets('Team Gateway: a platform the relay owns has nothing to '
        'configure; linking an account waits for a new account', (
      tester,
    ) async {
      final server = _Server();
      server.platforms[1]
        ..['relay_fronted'] = true
        ..['relay_exclusive'] = true;
      await open(tester, server: server);
      await openPlatform(tester, 'discord');
      expect(find.byKey(const ValueKey('msgplat-save')), findsNothing);
      expect(find.byKey(const ValueKey('msgplat-enabled')), findsNothing);
      expect(
        find.byKey(const ValueKey('msgplat-input-DISCORD_BOT_TOKEN')),
        findsNothing,
      );
      final relay = server.requests.lastWhere(
        (r) => r.url.path == '/api/messaging/relay',
      );
      expect(relay.url.queryParameters, {'profile': 'research'});

      server.relayStates.addAll(['pending', 'inactive']);
      await tester.tap(find.byKey(const ValueKey('msgplat-relay-link')));
      await tester.pump();
      await tester.pump();
      expect(find.text('/link ABC123'), findsOneWidget);
      final link = server.writes().single;
      expect(link.url.path, '/api/messaging/relay/discord/link');
      expect(link.url.queryParameters, {'profile': 'research'});

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('/link ABC123'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('/link ABC123'), findsNothing);
      expect(
        find.text(
          'Discord account linked. Message the bot to talk to your agent.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('msgplat-relay-account-99')),
        findsOneWidget,
      );
    });

    testWidgets('a server without Team Gateway links says so in the card', (
      tester,
    ) async {
      final server = _Server()..relayStatus = 404;
      server.platforms[1]['relay_fronted'] = true;
      await open(tester, server: server);
      await openPlatform(tester, 'discord');
      expect(
        find.byKey(const ValueKey('msgplat-relay-unavailable')),
        findsOneWidget,
      );
      // Not owned by the relay: the direct setup is still offered.
      expect(
        find.byKey(const ValueKey('msgplat-input-DISCORD_BOT_TOKEN')),
        findsOneWidget,
      );
    });
  });
}
