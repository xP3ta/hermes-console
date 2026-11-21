// Messaging access: the pairing list, approve and revoke, over a loopback
// stand-in of `/api/pairing`, `/approve` and `/revoke` (hermes_cli/web_routers
// /ops.py). The assertions are the requests the server receives and what the
// page shows afterwards.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/messaging_pairing_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/messaging_pairing.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Server {
  final requests = <http.Request>[];
  int listStatus = 200;
  int approveStatus = 200;
  final pending = <Map<String, dynamic>>[
    {
      'platform': 'telegram',
      'request_id': 'req-1',
      'user_id': '4242',
      'user_name': 'Ana',
      'age_minutes': 7,
    },
    {
      'platform': 'telegram',
      'request_id': '',
      'user_id': '9000',
      'user_name': '',
      'age_minutes': 0,
    },
  ];
  final approved = <Map<String, dynamic>>[
    {'platform': 'discord', 'user_id': '77', 'user_name': 'Bruno'},
  ];

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/pairing') {
      if (listStatus != 200) return http.Response('{}', listStatus);
      return http.Response(
        jsonEncode({'pending': pending, 'approved': approved}),
        200,
      );
    }
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (request.method == 'POST' && path == '/api/pairing/approve') {
      if (approveStatus != 200) return http.Response('{}', approveStatus);
      final index = pending.indexWhere(
        (row) => row['request_id'] == body['request_id'],
      );
      if (index < 0) return http.Response('{}', 404);
      final row = pending.removeAt(index);
      approved.add({
        'platform': row['platform'],
        'user_id': row['user_id'],
        'user_name': row['user_name'],
      });
      return http.Response(jsonEncode({'ok': true, 'user': row}), 200);
    }
    if (request.method == 'POST' && path == '/api/pairing/revoke') {
      final before = approved.length;
      approved.removeWhere(
        (row) =>
            row['platform'] == body['platform'] &&
            row['user_id'] == body['user_id'],
      );
      return approved.length == before
          ? http.Response('{}', 404)
          : http.Response(jsonEncode({'ok': true}), 200);
    }
    return http.Response('{}', 404);
  }

  List<http.Request> posts() => [
    for (final request in requests)
      if (request.method == 'POST') request,
  ];

  Map<String, dynamic> lastBody() =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;
}

DashboardClient _dashboard(_Server server) => DashboardClient(
  host: 'hermes.local',
  manualToken: 'token',
  httpClientOverride: MockClient(server.handle),
);

final _connection = SavedConnection(
  id: 'pairing-test',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: '',
);

/// A section heading, whatever case the theme paints it in.
Finder _header(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is Text && (widget.data ?? '').toLowerCase() == text.toLowerCase(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the client', () {
    test('reads the pending and approved lists of the named profile', () async {
      final server = _Server();
      final client = _dashboard(server);
      addTearDown(client.close);
      final snapshot = await MessagingPairingClient(client).load('research');

      expect(server.requests.single.method, 'GET');
      expect(server.requests.single.url.path, '/api/pairing');
      expect(server.requests.single.url.queryParameters, {
        'profile': 'research',
      });
      expect(snapshot.pending.map((row) => row.label), ['Ana', '9000']);
      expect(snapshot.pending.first.requestId, 'req-1');
      expect(snapshot.pending.first.ageMinutes, 7);
      // A legacy row has no request id: it cannot be approved from here.
      expect(snapshot.pending.last.canApprove, isFalse);
      expect(snapshot.approved.single.platform, 'discord');
    });

    test('the default profile is named too', () async {
      final server = _Server();
      final client = _dashboard(server);
      addTearDown(client.close);
      await MessagingPairingClient(client).load('default');
      expect(server.requests.single.url.queryParameters, {
        'profile': 'default',
      });
    });

    test('no selected profile travels unnamed, on the read and in the '
        'bodies', () async {
      final server = _Server();
      final client = _dashboard(server);
      addTearDown(client.close);
      final pairing = MessagingPairingClient(client);
      final snapshot = await pairing.load('');
      await pairing.approve(snapshot.pending.first, '');
      await pairing.revoke(snapshot.approved.single, '');

      expect(server.requests.first.url.queryParameters, isEmpty);
      for (final request in server.requests.skip(1)) {
        expect(
          (jsonDecode(request.body) as Map).containsKey('profile'),
          isFalse,
        );
      }
    });

    test('approving sends the request id, never a code', () async {
      final server = _Server();
      final client = _dashboard(server);
      addTearDown(client.close);
      final pairing = MessagingPairingClient(client);
      final snapshot = await pairing.load('research');
      await pairing.approve(snapshot.pending.first, 'research');

      final post = server.posts().single;
      expect(post.url.path, '/api/pairing/approve');
      expect(jsonDecode(post.body), {
        'platform': 'telegram',
        'request_id': 'req-1',
        'profile': 'research',
      });
    });

    test('revoking sends the platform, the user id and the profile', () async {
      final server = _Server();
      final client = _dashboard(server);
      addTearDown(client.close);
      final pairing = MessagingPairingClient(client);
      final snapshot = await pairing.load('research');
      await pairing.revoke(snapshot.approved.single, 'research');

      final post = server.posts().single;
      expect(post.url.path, '/api/pairing/revoke');
      expect(jsonDecode(post.body), {
        'platform': 'discord',
        'user_id': '77',
        'profile': 'research',
      });
    });

    test('a server without the route, and a lock-out, are typed', () async {
      final server = _Server()..listStatus = 404;
      final client = _dashboard(server);
      addTearDown(client.close);
      final pairing = MessagingPairingClient(client);
      await expectLater(
        pairing.load('default'),
        throwsA(isA<PairingRouteMissing>()),
      );
      server
        ..listStatus = 200
        ..approveStatus = 429;
      final snapshot = await pairing.load('default');
      await expectLater(
        pairing.approve(snapshot.pending.first, 'default'),
        throwsA(isA<PairingLockedOut>()),
      );
      server.listStatus = 500;
      await expectLater(
        pairing.load('default'),
        throwsA(isA<DashboardHttpException>()),
      );
    });
  });

  group('the page', () {
    Future<_Server> open(
      WidgetTester tester, {
      _Server? server,
      Future<bool> Function(String reason)? verifyLock,
    }) async {
      final fake = server ?? _Server();
      final dashboard = _dashboard(fake);
      addTearDown(dashboard.close);
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('dark'),
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: MessagingPairingScreen(
            connection: _connection,
            profile: 'research',
            client: MessagingPairingClient(dashboard),
            verifyLock: verifyLock ?? (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('lists who waits and who is approved, by platform', (
      tester,
    ) async {
      await open(tester);
      expect(_header('Pending requests (2)'), findsOneWidget);
      expect(_header('Approved users (1)'), findsOneWidget);
      expect(find.text('Telegram'), findsOneWidget);
      expect(find.text('Discord'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      // A named requester shows the id and how long ago they asked.
      expect(find.text('4242 · 7 min ago'), findsOneWidget);
      // An unnamed one is only its id, and "just now" when brand new.
      expect(find.text('9000'), findsOneWidget);
      expect(find.text('just now'), findsOneWidget);
      expect(find.text('Bruno'), findsOneWidget);
    });

    testWidgets('approve grants on the request id, then the list moves', (
      tester,
    ) async {
      final server = await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('pairing-approve-telegram:4242')),
      );
      await tester.pumpAndSettle();

      expect(server.posts(), hasLength(1));
      expect(server.posts().single.url.path, '/api/pairing/approve');
      expect(jsonDecode(server.posts().single.body), {
        'platform': 'telegram',
        'request_id': 'req-1',
        'profile': 'research',
      });
      // The list was read again and Ana is now an approved user.
      expect(server.requests.last.method, 'GET');
      expect(_header('Pending requests (1)'), findsOneWidget);
      expect(_header('Approved users (2)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pairing-revoke-telegram:4242')),
        findsOneWidget,
      );
      expect(find.textContaining('Ana approved'), findsOneWidget);
    });

    testWidgets('a legacy row without a request id cannot be approved', (
      tester,
    ) async {
      final server = await open(tester);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('pairing-approve-telegram:9000')),
      );
      expect(button.onPressed, isNull);
      expect(server.posts(), isEmpty);
    });

    testWidgets('a lock-out says so and nothing moves', (tester) async {
      final server = await open(tester, server: _Server()..approveStatus = 429);
      await tester.tap(
        find.byKey(const ValueKey('pairing-approve-telegram:4242')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('this platform is locked out'),
        findsOneWidget,
      );
      expect(_header('Pending requests (2)'), findsOneWidget);
      expect(server.posts(), hasLength(1));
    });

    testWidgets('a refused App Lock sends nothing', (tester) async {
      final asked = <String>[];
      final server = await open(
        tester,
        verifyLock: (reason) async {
          asked.add(reason);
          return false;
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('pairing-approve-telegram:4242')),
      );
      await tester.pumpAndSettle();
      expect(asked, ['Verify to approve access']);
      expect(server.posts(), isEmpty);
    });

    testWidgets('revoke asks first: cancel sends nothing, confirm revokes', (
      tester,
    ) async {
      final server = await open(tester);
      final revoke = find.byKey(const ValueKey('pairing-revoke-discord:77'));
      Finder inDialog(String label) => find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.text(label),
      );

      await tester.tap(revoke);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Bruno will lose access and stop being recognized on their next '
          'message.',
        ),
        findsOneWidget,
      );
      await tester.tap(inDialog('Cancel'));
      await tester.pumpAndSettle();
      expect(server.posts(), isEmpty);
      expect(_header('Approved users (1)'), findsOneWidget);

      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(inDialog('Revoke'));
      await tester.pumpAndSettle();
      expect(server.posts(), hasLength(1));
      expect(server.posts().single.url.path, '/api/pairing/revoke');
      expect(jsonDecode(server.posts().single.body), {
        'platform': 'discord',
        'user_id': '77',
        'profile': 'research',
      });
      expect(_header('Approved users (1)'), findsNothing);
      expect(find.text('Bruno revoked'), findsOneWidget);
    });

    testWidgets('a server without the route says so and offers nothing', (
      tester,
    ) async {
      final server = await open(tester, server: _Server()..listStatus = 404);
      expect(
        find.text('This server does not offer messaging access management.'),
        findsOneWidget,
      );
      expect(find.byType(TextButton), findsNothing);
      expect(server.posts(), isEmpty);
    });
  });
}
