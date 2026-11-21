// Messaging platform setup over a real loopback socket standing in for
// hermes_cli/web_routers/messaging.py, messaging_relay.py and actions.py:
// every action's method, path, query and body as the server receives them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/messaging_platforms.dart';

class _RealHttp extends HttpOverrides {}

class _Seen {
  _Seen(this.method, this.path, this.query, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Object? body;

  String get line => '$method $path';
}

/// Answers each request from [routes] (`'<METHOD> <path>'` → status and
/// JSON); anything else is FastAPI's own 404.
class _Server {
  _Server._(this._socket);

  final HttpServer _socket;
  final seen = <_Seen>[];
  final routes = <String, (int, Object)>{};

  /// Answers for `GET /api/actions/gateway-restart/status`, in order; null
  /// drops the connection, the way a restarting server refuses it.
  final restartReads = <Map<String, Object?>?>[];

  static Future<_Server> start() async {
    final socket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _Server._(socket);
    socket.listen(server._handle);
    return server;
  }

  int get port => _socket.port;

  Future<void> close() => _socket.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    final path = request.uri.path;
    seen.add(
      _Seen(
        request.method,
        path,
        request.uri.queryParameters,
        raw.isEmpty ? null : jsonDecode(raw),
      ),
    );
    if (path == '/api/actions/gateway-restart/status' &&
        restartReads.isNotEmpty) {
      final next = restartReads.removeAt(0);
      if (next == null) {
        await request.response.detachSocket().then((s) => s.destroy());
        return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(next));
      await request.response.close();
      return;
    }
    final route = routes['${request.method} $path'];
    request.response.statusCode = route?.$1 ?? 404;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(route?.$2 ?? {'detail': 'Not Found'}));
    await request.response.close();
  }
}

const _token = 'synthetic-fixture-token';

Map<String, Object?> _platformsJson() => {
  'env_path': '/srv/.env',
  'platforms': [
    {
      'id': 'telegram',
      'name': 'Telegram',
      'description': 'Telegram bot',
      'docs_url': 'https://docs.example.test/telegram',
      'enabled': true,
      'configured': true,
      'gateway_running': true,
      'state': 'connected',
      'error_message': null,
      'env_vars': [
        {
          'key': 'TELEGRAM_BOT_TOKEN',
          'required': true,
          'is_set': true,
          'is_password': true,
          'is_list': false,
          'advanced': false,
          'prompt': 'Bot token',
          'description': 'From BotFather',
          'url': 'https://t.me/BotFather',
          'redacted_value': '«redacted:1234…wxyz»',
          'value': null,
        },
        {
          'key': 'TELEGRAM_ALLOWED_USERS',
          'required': false,
          'is_set': true,
          'is_password': false,
          'is_list': true,
          'advanced': false,
          'prompt': 'Allowed users',
          'description': '',
          'url': null,
          'redacted_value': '«redacted:111,222»',
          'value': '111,222',
        },
        {
          'key': 'TELEGRAM_PROXY',
          'required': false,
          'is_set': false,
          'is_password': false,
          'advanced': false,
          'prompt': 'Proxy',
          'description': '',
          'redacted_value': null,
        },
      ],
      'relay_fronted': false,
      'relay_exclusive': false,
      'disabled_by_relay': false,
      'ingress_url': null,
    },
    {
      'id': 'discord',
      'name': 'Discord',
      'enabled': false,
      'configured': false,
      'gateway_running': true,
      'state': 'disabled',
      'env_vars': [],
    },
  ],
};

void main() {
  late _Server server;
  late DashboardClient dashboard;
  late List<Duration> slept;
  late MessagingPlatformsClient client;

  Future<T> real<T>(Future<T> Function() body) =>
      HttpOverrides.runWithHttpOverrides(body, _RealHttp());

  setUp(() async {
    await real(() async {
      server = await _Server.start();
      dashboard = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        manualToken: _token,
      );
    });
    slept = [];
    client = MessagingPlatformsClient(
      dashboard,
      sleep: (duration) async => slept.add(duration),
    );
  });

  tearDown(() async {
    dashboard.close();
    await server.close();
  });

  test('the platform list is read from the server schema of the named '
      'profile', () async {
    server.routes['GET /api/messaging/platforms'] = (200, _platformsJson());
    final platforms = await real(() => client.load('research'));

    expect(server.seen.single.line, 'GET /api/messaging/platforms');
    expect(server.seen.single.query, {'profile': 'research'});
    expect(platforms.map((p) => p.id), ['telegram', 'discord']);
    final telegram = platforms.first;
    expect(telegram.tone, MessagingTone.good);
    expect(platforms.last.tone, MessagingTone.muted);
    expect(telegram.envVars.map((f) => f.key), [
      'TELEGRAM_BOT_TOKEN',
      'TELEGRAM_ALLOWED_USERS',
      'TELEGRAM_PROXY',
    ]);
    final token = telegram.envVars.first;
    expect(token.isPassword && token.isSet && token.required, isTrue);
    // A secret's saved value never arrives; only its display preview.
    expect(token.value, isEmpty);
    expect(credentialPreview(token.redactedValue), '1234…wxyz');
    // An allowlist carries its plain ids.
    expect(telegram.envVars[1].isList, isTrue);
    expect(telegram.envVars[1].value, '111,222');
    // Desktop folds the proxy under Advanced although the server does not.
    expect(telegram.envVars[2].isAdvanced, isTrue);
  });

  test('a picked default profile is named; no selection travels unnamed, so '
      'a Dashboard serving a named profile keeps its own credentials', () async {
    server.routes['GET /api/messaging/platforms'] = (200, _platformsJson());
    server.routes['PUT /api/messaging/platforms/telegram'] = (
      200,
      {'ok': true, 'platform': 'telegram', 'hot_served': false},
    );
    final telegram = (await real(() => client.load('default'))).first;
    await real(() => client.load(''));
    await real(
      () => client.update(
        'telegram',
        messagingChanges(telegram, {'TELEGRAM_PROXY': 'socks5://p.test:1'}),
        '',
      ),
    );
    expect(server.seen.map((r) => r.query.containsKey('profile')), [
      true,
      false,
      false,
    ]);
    expect(server.seen.first.query['profile'], 'default');
  });

  test('saving sends only what was typed: never a saved secret, never its '
      'preview, and an emptied allowlist is a clear', () async {
    server.routes['GET /api/messaging/platforms'] = (200, _platformsJson());
    server.routes['PUT /api/messaging/platforms/telegram'] = (
      200,
      {'ok': true, 'platform': 'telegram', 'hot_served': false},
    );
    final telegram = (await real(() => client.load('research'))).first;

    // The token was not touched, the proxy was typed with spaces around it
    // and the allowlist was emptied.
    final update = messagingChanges(telegram, {
      'TELEGRAM_PROXY': '  socks5://proxy.example.test:1080 ',
      'TELEGRAM_ALLOWED_USERS': '',
    });
    final result = await real(
      () => client.update('telegram', update, 'research'),
    );

    final put = server.seen.last;
    expect(put.line, 'PUT /api/messaging/platforms/telegram');
    expect(put.query, {'profile': 'research'});
    expect(put.body, {
      'env': {'TELEGRAM_PROXY': 'socks5://proxy.example.test:1080'},
      'clear_env': ['TELEGRAM_ALLOWED_USERS'],
    });
    expect(jsonEncode(put.body), isNot(contains('redacted')));
    expect(jsonEncode(put.body), isNot(contains('TELEGRAM_BOT_TOKEN')));
    expect(result.hotServed, isFalse);

    // Nothing typed at all: nothing to save.
    expect(messagingChanges(telegram, const {}).hasChanges, isFalse);
    final blank = messagingChanges(telegram, const {
      'TELEGRAM_BOT_TOKEN': '   ',
    });
    expect(blank.hasChanges, isFalse);
  });

  test('enable, disable and clear send exactly Desktop\'s bodies', () async {
    server.routes['PUT /api/messaging/platforms/discord'] = (
      200,
      {'ok': true, 'platform': 'discord', 'hot_served': true},
    );
    final on = await real(
      () => client.update(
        'discord',
        const MessagingPlatformUpdate(enabled: true),
        'research',
      ),
    );
    await real(
      () => client.update(
        'discord',
        const MessagingPlatformUpdate(enabled: false),
        'research',
      ),
    );
    await real(
      () => client.update(
        'discord',
        const MessagingPlatformUpdate(clearEnv: ['DISCORD_BOT_TOKEN']),
        'research',
      ),
    );
    expect(on.hotServed, isTrue);
    expect(server.seen.map((r) => r.line).toSet(), {
      'PUT /api/messaging/platforms/discord',
    });
    expect(server.seen.map((r) => r.query['profile']).toSet(), {'research'});
    expect(server.seen.map((r) => r.body), [
      {'enabled': true},
      {'enabled': false},
      {
        'clear_env': ['DISCORD_BOT_TOKEN'],
      },
    ]);
  });

  test('a refusal carries the server sentence; a missing route is '
      'typed', () async {
    server.routes['PUT /api/messaging/platforms/api_server'] = (
      409,
      {'detail': "Cannot enable 'api_server' on profile 'research'"},
    );
    await expectLater(
      real(
        () => client.update(
          'api_server',
          const MessagingPlatformUpdate(enabled: true),
          'research',
        ),
      ),
      throwsA(
        isA<MessagingRequestFailed>()
            .having((e) => e.statusCode, 'status', 409)
            .having(
              (e) => e.detail,
              'detail',
              "Cannot enable 'api_server' on profile 'research'",
            ),
      ),
    );
    // An older server answers FastAPI's own 404.
    await expectLater(
      real(() => client.load('research')),
      throwsA(isA<MessagingRouteMissing>()),
    );
  });

  test('test asks the server for its verdict on the named profile', () async {
    server.routes['POST /api/messaging/platforms/telegram/test'] = (
      200,
      {'ok': false, 'state': 'gateway_stopped', 'message': 'Gateway is down.'},
    );
    final result = await real(() => client.test('telegram', 'research'));
    expect(
      server.seen.single.line,
      'POST /api/messaging/platforms/telegram/test',
    );
    expect(server.seen.single.query, {'profile': 'research'});
    expect(result.ok, isFalse);
    expect(result.message, 'Gateway is down.');
  });

  test('Telegram quick setup: start, poll, apply and cancel all name the '
      'profile, and apply carries it in the body', () async {
    server.routes['POST /api/messaging/telegram/onboarding/start'] = (
      200,
      {
        'pairing_id': 'pair-1',
        'suggested_username': 'hermes_bot',
        'deep_link': 'https://t.me/newbot?start=pair-1',
        'qr_payload': 'https://t.me/newbot?start=pair-1',
        'expires_at': '2030-01-01T00:10:00Z',
      },
    );
    server.routes['GET /api/messaging/telegram/onboarding/pair-1'] = (
      200,
      {
        'status': 'ready',
        'bot_username': 'hermes_bot',
        'owner_user_id': '424242',
        'expires_at': '2030-01-01T00:10:00Z',
      },
    );
    server.routes['POST /api/messaging/telegram/onboarding/pair-1/apply'] = (
      200,
      {
        'ok': true,
        'platform': 'telegram',
        'bot_username': 'hermes_bot',
        'needs_restart': false,
        'restart_started': true,
      },
    );
    server.routes['DELETE /api/messaging/telegram/onboarding/pair-1'] = (
      200,
      {'ok': true},
    );

    final start = await real(() => client.startTelegram('research'));
    final status = await real(
      () => client.telegramStatus(start.pairingId, 'research'),
    );
    final applied = await real(
      () => client.applyTelegram('pair-1', ['424242', '777'], 'research'),
    );
    await real(() => client.cancelTelegram('pair-1', 'research'));

    expect(start.deepLink, 'https://t.me/newbot?start=pair-1');
    expect(start.expiresAt, DateTime.utc(2030, 1, 1, 0, 10));
    expect(status.ready, isTrue);
    expect(status.ownerUserId, '424242');
    expect(applied.restartStarted, isTrue);
    expect(server.seen.map((r) => r.line), [
      'POST /api/messaging/telegram/onboarding/start',
      'GET /api/messaging/telegram/onboarding/pair-1',
      'POST /api/messaging/telegram/onboarding/pair-1/apply',
      'DELETE /api/messaging/telegram/onboarding/pair-1',
    ]);
    expect(server.seen.map((r) => r.query['profile']).toSet(), {'research'});
    expect(server.seen.first.body, <String, dynamic>{});
    expect(server.seen[2].body, {
      'allowed_user_ids': ['424242', '777'],
      'profile': 'research',
    });
  });

  test('a pairing that expired is gone; a waiting one keeps '
      'waiting', () async {
    server.routes['GET /api/messaging/telegram/onboarding/old'] = (
      410,
      {'detail': 'Telegram setup expired. Start a new setup.'},
    );
    server.routes['GET /api/messaging/telegram/onboarding/new'] = (
      200,
      {'status': 'waiting', 'expires_at': '2030-01-01T00:10:00Z'},
    );
    await expectLater(
      real(() => client.telegramStatus('old', 'research')),
      throwsA(isA<TelegramOnboardingGone>()),
    );
    final waiting = await real(() => client.telegramStatus('new', 'research'));
    expect(waiting.ready, isFalse);
  });

  test('Team Gateway links: list, mint, poll and unlink on the named '
      'profile; the gateway\'s refusal is its own sentence', () async {
    server.routes['GET /api/messaging/relay'] = (
      200,
      {
        'managed_by': 'connector',
        'platforms': [
          {
            'platform': 'telegram',
            'bot_url': 'https://t.me/shared_bot',
            'accounts': [
              {'platformUserId': '55', 'handle': 'ana'},
            ],
          },
        ],
      },
    );
    server.routes['POST /api/messaging/relay/telegram/link'] = (
      200,
      {
        'platform': 'telegram',
        'code': 'ABC123',
        'command': '/link ABC123',
        'bot_url': 'https://t.me/shared_bot',
        'expires_at': '2030-01-01T00:10:00Z',
      },
    );
    server.routes['GET /api/messaging/relay/link/ABC123'] = (
      200,
      {'state': 'pending'},
    );
    server.routes['DELETE /api/messaging/relay/telegram/accounts/55'] = (
      200,
      {'unlinked': true},
    );
    server.routes['POST /api/messaging/relay/discord/link'] = (
      409,
      {
        'detail': {
          'code': 'connector_refused',
          'message': 'Discord is not carried by this relay.',
        },
      },
    );

    final links = await real(() => client.relayLinks('telegram', 'research'));
    final code = await real(
      () => client.requestRelayLink('telegram', 'research'),
    );
    final state = await real(
      () => client.relayLinkState('ABC123', 'research'),
    );
    await real(() => client.unlinkRelayAccount('telegram', '55', 'research'));

    expect(links.accounts.single.handle, 'ana');
    expect(links.botUrl, 'https://t.me/shared_bot');
    expect(links.portalUrl, isEmpty);
    expect(code.command, '/link ABC123');
    expect(state, RelayLinkState.pending);
    expect(server.seen.map((r) => r.line), [
      'GET /api/messaging/relay',
      'POST /api/messaging/relay/telegram/link',
      'GET /api/messaging/relay/link/ABC123',
      'DELETE /api/messaging/relay/telegram/accounts/55',
    ]);
    expect(server.seen.map((r) => r.query['profile']).toSet(), {'research'});
    await expectLater(
      real(() => client.requestRelayLink('discord', 'research')),
      throwsA(
        isA<MessagingRequestFailed>().having(
          (e) => e.detail,
          'detail',
          'Discord is not carried by this relay.',
        ),
      ),
    );
  });

  group('the gateway restart', () {
    test('is requested for the named profile and followed until the '
        'action exits cleanly, through the restart window', () async {
      server.routes['POST /api/gateway/restart'] = (
        200,
        {'ok': true, 'pid': 4321, 'name': 'gateway-restart'},
      );
      server.restartReads.addAll([
        null,
        {'running': false, 'exit_code': null},
        {'running': true, 'exit_code': null},
        {'running': false, 'exit_code': 0},
      ]);
      await real(() => client.requestGatewayRestart('research'));
      final ok = await real(() => client.awaitGatewayRestart('research'));

      expect(ok, isTrue);
      expect(server.seen.first.line, 'POST /api/gateway/restart');
      expect(server.seen.first.query, {'profile': 'research'});
      final reads = server.seen.skip(1).toList();
      expect(reads, hasLength(4));
      expect(reads.map((r) => r.line).toSet(), {
        'GET /api/actions/gateway-restart/status',
      });
      expect(reads.first.query, {'lines': '200', 'profile': 'research'});
      expect(slept, List.filled(4, const Duration(milliseconds: 1200)));
    });

    test('a recorded non-zero exit is a failure', () async {
      server.restartReads.addAll([
        {'running': true, 'exit_code': null},
        {'running': false, 'exit_code': 1},
      ]);
      expect(await real(() => client.awaitGatewayRestart('research')), isFalse);
      expect(server.seen, hasLength(2));
    });

    test('a window in which no read was answered is a failure, and one '
        'still running at its end is done', () async {
      server.restartReads.addAll(List.filled(18, null));
      expect(await real(() => client.awaitGatewayRestart('research')), isFalse);
      expect(slept, hasLength(MessagingPlatformsClient.restartPollAttempts));

      server.restartReads.addAll(
        List.filled(18, {'running': true, 'exit_code': null}),
      );
      expect(await real(() => client.awaitGatewayRestart('research')), isTrue);
    });
  });
}
