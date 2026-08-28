import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session_category.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _row(int index, {String source = 'mobile'}) => {
  'id': 'session-$index',
  '_lineage_root_id': 'root-$index',
  'title': 'Conversation $index',
  'preview': 'Preview $index',
  'model': 'model-a',
  'source': source,
  'message_count': 2,
  'started_at': 1000 + index,
  'last_active': 2000 + index,
  'archived': false,
};

Map<String, dynamic> _lineageRow({
  required String id,
  required String root,
  required double lastActive,
  String? title,
  String? preview,
  String model = 'model-a',
  int messageCount = 2,
  bool pinned = false,
  bool archived = false,
}) => {
  'id': id,
  '_lineage_root_id': root,
  'title': title ?? id,
  'preview': preview ?? id,
  'model': model,
  'source': 'mobile',
  'message_count': messageCount,
  'started_at': lastActive - 10,
  'last_active': lastActive,
  'archived': archived,
  'pinned': pinned,
};

DashboardClient _dashboard(http.Client client) => DashboardClient(
  host: '127.0.0.1',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: client,
);

ApiClient _gateway(http.Client client) => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'gateway-key',
  httpClient: client,
);

void main() {
  test('sources participa en endpoint y fingerprint antes de paginación', () {
    const query = SessionLibraryQuery(
      pageSize: 50,
      archived: SessionArchiveMode.only,
      sources: ['cron', 'tool', 'webhook'],
      profile: 'coding',
    );
    final endpoint = query.dashboardEndpoint(100);
    final uri = Uri.parse(endpoint);

    expect(uri.queryParameters['sources'], 'cron,tool,webhook');
    expect(uri.queryParameters['archived'], 'only');
    expect(uri.queryParameters['profile'], 'coding');
    expect(uri.queryParameters['limit'], '50');
    expect(uri.queryParameters['offset'], '100');
    expect(endpoint.indexOf('sources='), lessThan(endpoint.indexOf('limit=')));
    expect(
      endpoint.indexOf('archived='),
      lessThan(endpoint.indexOf('offset=')),
    );
    expect(
      query.fingerprint,
      const SessionLibraryQuery(
        pageSize: 50,
        archived: SessionArchiveMode.only,
        sources: ['webhook', 'cron', 'tool', 'cron'],
        profile: 'coding',
      ).fingerprint,
    );
    expect(
      query.fingerprint,
      isNot(
        const SessionLibraryQuery(
          pageSize: 50,
          archived: SessionArchiveMode.only,
          sources: ['cron', 'tool'],
          profile: 'coding',
        ).fingerprint,
      ),
    );
  });

  test(
    'pagina más de 250 sesiones sin duplicar ni cargar transcripts',
    () async {
      final dashboardRequests = <http.Request>[];
      final dashboardHttp = MockClient((request) async {
        dashboardRequests.add(request);
        expect(request.url.path, '/api/sessions');
        final limit = int.parse(request.url.queryParameters['limit']!);
        final offset = int.parse(request.url.queryParameters['offset']!);
        final end = (offset + limit).clamp(0, 260);
        return http.Response(
          jsonEncode({
            'sessions': [for (var i = offset; i < end; i++) _row(i)],
            'total': 260,
            'limit': limit,
            'offset': offset,
          }),
          200,
        );
      });
      var gatewayRequests = 0;
      final gatewayHttp = MockClient((_) async {
        gatewayRequests += 1;
        return http.Response('{}', 500);
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      var snapshot = await repository.refresh(
        const SessionLibraryQuery(
          pageSize: 100,
          excludeSources: ['cron', 'tool'],
        ),
      );
      expect(snapshot.sessions, hasLength(100));
      expect(snapshot.exhaustive, isFalse);
      snapshot = await repository.loadNext();
      expect(snapshot.sessions, hasLength(200));
      snapshot = await repository.loadNext();
      expect(snapshot.sessions, hasLength(260));
      expect(snapshot.sessions.map((row) => row.id).toSet(), hasLength(260));
      expect(snapshot.exhaustive, isTrue);
      expect(snapshot.total, 260);
      expect(gatewayRequests, 0);
      expect(dashboardRequests, hasLength(3));
      expect(
        dashboardRequests.first.url.queryParameters['exclude_sources'],
        'cron,tool',
      );
      expect(dashboardRequests.first.url.queryParameters['min_messages'], '1');
      expect(dashboardRequests.first.url.queryParameters['full'], '0');
    },
  );

  test(
    'paginación ignora backfills pinned y deduplica tips globalmente',
    () async {
      final offsets = <int>[];
      final dashboardHttp = MockClient((request) async {
        final limit = int.parse(request.url.queryParameters['limit']!);
        final offset = int.parse(request.url.queryParameters['offset']!);
        offsets.add(offset);
        final end = (offset + limit).clamp(0, 260);
        final rows = <Map<String, dynamic>>[
          for (var index = offset; index < end; index++)
            if (index == 259)
              _lineageRow(
                id: 'tip-final',
                root: 'root-259',
                lastActive: 4000,
                pinned: true,
              )
            else
              _row(index),
        ];
        if (offset < 200) {
          rows.add(
            _lineageRow(
              id: 'tip-backfill',
              root: 'root-259',
              lastActive: 3000,
              pinned: true,
            ),
          );
        }
        return http.Response(
          jsonEncode({
            'sessions': rows,
            'total': 260,
            'limit': limit,
            'offset': offset,
          }),
          200,
        );
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      var snapshot = await repository.refresh(
        const SessionLibraryQuery(pageSize: 100),
      );
      snapshot = await repository.loadNext();
      snapshot = await repository.loadNext();

      expect(offsets, [0, 100, 200]);
      expect(snapshot.sessions, hasLength(260));
      expect(
        snapshot.sessions.map((row) => row.logicalId).toSet(),
        hasLength(260),
      );
      expect(snapshot.sessions.any((row) => row.id == 'session-100'), isTrue);
      expect(snapshot.sessions.any((row) => row.id == 'tip-backfill'), isFalse);
      expect(
        snapshot.sessions.singleWhere((row) => row.logicalId == 'root-259').id,
        'tip-final',
      );
      expect(snapshot.exhaustive, isTrue);
    },
  );

  test(
    'merge elige el ganador completo del lineage en cualquier orden',
    () async {
      var refreshes = 0;
      final dashboardHttp = MockClient((_) async {
        refreshes += 1;
        final rows = refreshes.isOdd
            ? [
                _lineageRow(
                  id: 'tip-existing',
                  root: 'root-x',
                  lastActive: 3000,
                  title: 'existing title',
                  preview: 'existing preview',
                  model: 'existing-model',
                  messageCount: 3,
                ),
              ]
            : refreshes == 2
            ? [
                _lineageRow(
                  id: 'tip-new',
                  root: 'root-x',
                  lastActive: 5000,
                  title: 'new title',
                  preview: 'new preview',
                  model: 'new-model',
                  messageCount: 5,
                ),
                _lineageRow(
                  id: 'tip-old',
                  root: 'root-x',
                  lastActive: 4000,
                  title: 'old title',
                  preview: 'old preview',
                  model: 'old-model',
                  messageCount: 4,
                ),
              ]
            : [
                _lineageRow(
                  id: 'tip-old',
                  root: 'root-x',
                  lastActive: 4000,
                  title: 'old title',
                  preview: 'old preview',
                  model: 'old-model',
                  messageCount: 4,
                ),
                _lineageRow(
                  id: 'tip-new',
                  root: 'root-x',
                  lastActive: 5000,
                  title: 'new title',
                  preview: 'new preview',
                  model: 'new-model',
                  messageCount: 5,
                ),
              ];
        return http.Response(
          jsonEncode({
            'sessions': rows,
            'total': rows.length,
            'limit': 20,
            'offset': 0,
          }),
          200,
        );
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      var repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      await repository.refresh(const SessionLibraryQuery());
      final refreshed = await repository.refresh(const SessionLibraryQuery());
      expect(refreshed.sessions.single.id, 'tip-new');
      expect(refreshed.sessions.single.title, 'new title');
      expect(refreshed.sessions.single.preview, 'new preview');
      expect(refreshed.sessions.single.model, 'new-model');
      expect(refreshed.sessions.single.messageCount, 5);
      expect(refreshed.sessions.single.updatedAt, 5000);
      expect(refreshed.sessions.single.lastActivityAt, 5000);

      repository.close();
      repository = SessionRepository(dashboard, gateway);
      await repository.refresh(const SessionLibraryQuery());
      final reversed = await repository.refresh(const SessionLibraryQuery());
      expect(reversed.sessions.single.id, 'tip-new');
      expect(reversed.sessions.single.title, 'new title');
      expect(reversed.sessions.single.preview, 'new preview');
      expect(reversed.sessions.single.model, 'new-model');
      expect(reversed.sessions.single.messageCount, 5);
      expect(reversed.sessions.single.updatedAt, 5000);
      expect(reversed.sessions.single.lastActivityAt, 5000);
    },
  );

  test(
    'empate de actividad elige el id opaco menor en cualquier orden',
    () async {
      var requests = 0;
      final dashboardHttp = MockClient((_) async {
        requests += 1;
        final smaller = _lineageRow(
          id: 'tip-alpha',
          root: 'root-tie',
          lastActive: 5000,
          title: 'alpha title',
          preview: 'alpha preview',
          model: 'alpha-model',
          messageCount: 7,
        );
        final larger = _lineageRow(
          id: 'tip-zeta',
          root: 'root-tie',
          lastActive: 5000,
          title: 'zeta title',
          preview: 'zeta preview',
          model: 'zeta-model',
          messageCount: 9,
        );
        final rows = requests == 1 ? [smaller, larger] : [larger, smaller];
        return http.Response(
          jsonEncode({'sessions': rows, 'total': 2, 'limit': 20, 'offset': 0}),
          200,
        );
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      var repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      final firstOrder = await repository.refresh(const SessionLibraryQuery());
      expect(firstOrder.sessions.single.id, 'tip-alpha');
      expect(firstOrder.sessions.single.title, 'alpha title');
      expect(firstOrder.sessions.single.preview, 'alpha preview');
      expect(firstOrder.sessions.single.model, 'alpha-model');
      expect(firstOrder.sessions.single.messageCount, 7);
      expect(firstOrder.sessions.single.updatedAt, 5000);
      expect(firstOrder.sessions.single.lastActivityAt, 5000);

      repository.close();
      repository = SessionRepository(dashboard, gateway);
      final reversed = await repository.refresh(const SessionLibraryQuery());
      expect(reversed.sessions.single.id, 'tip-alpha');
      expect(reversed.sessions.single.title, 'alpha title');
      expect(reversed.sessions.single.preview, 'alpha preview');
      expect(reversed.sessions.single.model, 'alpha-model');
      expect(reversed.sessions.single.messageCount, 7);
      expect(reversed.sessions.single.updatedAt, 5000);
      expect(reversed.sessions.single.lastActivityAt, 5000);
    },
  );

  test('misma sesión y actividad refresca metadatos completos', () async {
    var requests = 0;
    final dashboardHttp = MockClient((_) async {
      requests += 1;
      final row = requests == 1
          ? _lineageRow(
              id: 'tip-same',
              root: 'root-same',
              lastActive: 5000,
              title: 'cached title',
              preview: 'cached preview',
              model: 'cached-model',
              messageCount: 3,
            )
          : _lineageRow(
              id: 'tip-same',
              root: 'root-same',
              lastActive: 5000,
              title: 'refreshed title',
              preview: 'refreshed preview',
              model: 'refreshed-model',
              messageCount: 8,
              pinned: true,
              archived: true,
            );
      return http.Response(
        jsonEncode({
          'sessions': [row],
          'total': 1,
          'limit': 20,
          'offset': 0,
        }),
        200,
      );
    });
    final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });

    await repository.refresh(const SessionLibraryQuery());
    final refreshed = await repository.refresh(const SessionLibraryQuery());
    final winner = refreshed.sessions.single;

    expect(winner.id, 'tip-same');
    expect(winner.title, 'refreshed title');
    expect(winner.preview, 'refreshed preview');
    expect(winner.model, 'refreshed-model');
    expect(winner.messageCount, 8);
    expect(winner.pinned, isTrue);
    expect(winner.archived, isTrue);
    expect(winner.updatedAt, 5000);
    expect(winner.lastActivityAt, 5000);
  });

  test(
    'backfill de página posterior no reemplaza el ganador ni altera el offset',
    () async {
      final offsets = <int>[];
      final dashboardHttp = MockClient((request) async {
        final offset = int.parse(request.url.queryParameters['offset']!);
        offsets.add(offset);
        final rows = offset == 0
            ? [
                _lineageRow(
                  id: 'tip-new',
                  root: 'root-x',
                  lastActive: 5000,
                  title: 'new title',
                  preview: 'new preview',
                  model: 'new-model',
                  messageCount: 5,
                ),
                _row(0),
              ]
            : [
                _lineageRow(
                  id: 'tip-old',
                  root: 'root-x',
                  lastActive: 4000,
                  title: 'old title',
                  preview: 'old preview',
                  model: 'old-model',
                  messageCount: 4,
                ),
                _row(1),
              ];
        return http.Response(
          jsonEncode({
            'sessions': rows,
            'total': 4,
            'limit': 2,
            'offset': offset,
          }),
          200,
        );
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      await repository.refresh(const SessionLibraryQuery(pageSize: 2));
      final snapshot = await repository.loadNext();
      final winner = snapshot.sessions.singleWhere(
        (row) => row.logicalId == 'root-x',
      );

      expect(offsets, [0, 2]);
      expect(winner.id, 'tip-new');
      expect(winner.title, 'new title');
      expect(winner.preview, 'new preview');
      expect(winner.model, 'new-model');
      expect(winner.messageCount, 5);
      expect(winner.updatedAt, 5000);
      expect(winner.lastActivityAt, 5000);
    },
  );

  test('refresh conserva working/pinned y rota el tip por lineage', () async {
    var refreshes = 0;
    final dashboardHttp = MockClient((_) async {
      refreshes += 1;
      final rows = refreshes == 1
          ? [
              _lineageRow(
                id: 'working-old',
                root: 'working-root',
                lastActive: 100,
              ),
              _lineageRow(
                id: 'pinned-old',
                root: 'pinned-root',
                lastActive: 90,
                pinned: true,
              ),
              _lineageRow(id: 'drop-me', root: 'drop-root', lastActive: 80),
            ]
          : [
              _lineageRow(
                id: 'working-new',
                root: 'working-root',
                lastActive: 200,
              ),
              _lineageRow(id: 'fresh', root: 'fresh-root', lastActive: 150),
            ];
      return http.Response(
        jsonEncode({
          'sessions': rows,
          'total': rows.length,
          'limit': 20,
          'offset': 0,
        }),
        200,
      );
    });
    final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });

    await repository.refresh(const SessionLibraryQuery());
    final refreshed = await repository.refresh(
      const SessionLibraryQuery(),
      keepIds: const {'working-root', 'pinned-root'},
    );

    expect(refreshed.sessions.map((row) => row.id), [
      'pinned-old',
      'working-new',
      'fresh',
    ]);
    expect(
      refreshed.sessions.where((row) => row.logicalId == 'working-root'),
      hasLength(1),
    );
    expect(refreshed.sessions.any((row) => row.id == 'drop-me'), isFalse);
  });

  test('una respuesta tardía de otra query no reemplaza la vigente', () async {
    final delayed = Completer<http.Response>();
    final dashboardHttp = MockClient((request) async {
      final source = request.url.queryParameters['source'];
      if (source == 'cron') return delayed.future;
      return http.Response(
        jsonEncode({
          'sessions': [_row(2, source: 'mobile')],
          'total': 1,
          'limit': 20,
          'offset': 0,
        }),
        200,
      );
    });
    final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });

    final oldRequest = repository.refresh(
      const SessionLibraryQuery(source: 'cron'),
    );
    final current = await repository.refresh(
      const SessionLibraryQuery(source: 'mobile'),
    );
    delayed.complete(
      http.Response(
        jsonEncode({
          'sessions': [_row(1, source: 'cron')],
          'total': 1,
          'limit': 20,
          'offset': 0,
        }),
        200,
      ),
    );
    await oldRequest;

    expect(current.sessions.single.id, 'session-2');
    expect(repository.snapshot.sessions.single.id, 'session-2');
  });

  test(
    'búsqueda remota usa FTS y fallback local queda no exhaustivo',
    () async {
      var searchAvailable = true;
      final dashboardHttp = MockClient((request) async {
        if (request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'sessions': [_row(1), _row(2)],
              'total': 2,
              'limit': 20,
              'offset': 0,
            }),
            200,
          );
        }
        expect(request.url.path, '/api/sessions/search');
        if (!searchAvailable) return http.Response('{}', 404);
        expect(request.url.queryParameters['q'], 'phrase after page one');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'session_id': 'tip-remote',
                'lineage_root': 'root-remote',
                'snippet': 'bounded match',
                'source': 'mobile',
                'model': 'model-a',
                'session_started': 1234,
              },
            ],
          }),
          200,
        );
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });
      await repository.refresh(const SessionLibraryQuery());

      final remote = await repository.search(' phrase after page one ');
      expect(remote.source, SessionLibrarySource.dashboard);
      expect(remote.exhaustive, isTrue);
      expect(remote.sessions.single.id, 'tip-remote');
      expect(remote.sessions.single.logicalId, 'root-remote');
      expect(remote.sessions.single.startedAt, 1234.0);
      expect(remote.sessions.single.endedAt, isNull);
      expect(remote.sessions.single.updatedAt, isNull);

      searchAvailable = false;
      final local = await repository.search('Conversation 2');
      expect(local.source, SessionLibrarySource.local);
      expect(local.exhaustive, isFalse);
      expect(local.sessions.single.id, 'session-2');
    },
  );

  test(
    'búsqueda normaliza timestamps ms y conserva fallback por campo',
    () async {
      final dashboardHttp = MockClient((request) async {
        expect(request.url.path, '/api/sessions/search');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'session_id': 'primary-started',
                'started_at': 1700000000000,
                'session_started': 1500000000000,
                'ended_at': 1700000060000,
                'last_active': 1700000120000,
              },
              {
                'session_id': 'fallback-started',
                'started_at': 'malformed',
                'session_started': 1600000000000,
                'ended_at': -1,
                'last_active': 'malformed',
              },
            ],
          }),
          200,
        );
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      final result = await repository.search('timestamp contract');
      final primary = result.sessions.singleWhere(
        (session) => session.id == 'primary-started',
      );
      final fallback = result.sessions.singleWhere(
        (session) => session.id == 'fallback-started',
      );

      expect(primary.startedAt, 1700000000.0);
      expect(primary.endedAt, 1700000060.0);
      expect(primary.updatedAt, 1700000120.0);
      expect(fallback.startedAt, 1600000000.0);
      expect(fallback.endedAt, isNull);
      expect(fallback.updatedAt, isNull);
    },
  );

  test(
    'búsqueda conserva sources/exclude_sources y descarta scope tardío',
    () async {
      final chats = Completer<http.Response>();
      final automation = Completer<http.Response>();
      final searchRequests = <http.Request>[];
      final dashboardHttp = MockClient((request) async {
        expect(request.url.path, '/api/sessions/search');
        searchRequests.add(request);
        return request.url.queryParameters.containsKey('sources')
            ? automation.future
            : chats.future;
      });
      final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      final stale = repository.search(
        'same phrase',
        libraryQuery: SessionLibraryQuery(
          excludeSources: AutomationSessionSources.values,
        ),
      );
      final current = repository.search(
        'same phrase',
        libraryQuery: SessionLibraryQuery(
          sources: AutomationSessionSources.values,
        ),
      );

      automation.complete(
        http.Response(
          jsonEncode({
            'results': [
              {
                'session_id': 'automation-result',
                'snippet': 'automation visible',
                'source': 'webhook',
                'model': 'model-a',
                'session_started': 1234,
                'archived': false,
              },
            ],
          }),
          200,
        ),
      );
      expect((await current).sessions.single.id, 'automation-result');

      chats.complete(
        http.Response(
          jsonEncode({
            'results': [
              {
                'session_id': 'stale-chat-result',
                'snippet': 'must be discarded',
                'source': 'mobile',
                'model': 'model-a',
                'session_started': 1234,
                'archived': false,
              },
            ],
          }),
          200,
        ),
      );
      expect((await stale).sessions, isEmpty);

      expect(searchRequests, hasLength(2));
      expect(
        searchRequests.first.url.queryParameters['exclude_sources'],
        AutomationSessionSources.values.join(','),
      );
      expect(searchRequests.first.url.queryParameters['sources'], isNull);
      expect(
        searchRequests.last.url.queryParameters['sources'],
        AutomationSessionSources.values.join(','),
      );
      expect(
        searchRequests.last.url.queryParameters['exclude_sources'],
        isNull,
      );
    },
  );

  test('Gateway legacy aplica sources localmente sin ocultar Todo', () async {
    final dashboardHttp = MockClient((_) async => http.Response('{}', 404));
    final gatewayHttp = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'data': [
            _row(0, source: 'mobile'),
            for (
              var index = 0;
              index < AutomationSessionSources.values.length;
              index++
            )
              _row(index + 1, source: AutomationSessionSources.values[index]),
          ],
        }),
        200,
      );
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });

    final automation = await repository.refresh(
      SessionLibraryQuery(sources: AutomationSessionSources.values),
    );

    expect(automation.source, SessionLibrarySource.gateway);
    expect(
      automation.sessions.map((session) => session.source),
      AutomationSessionSources.values,
    );
  });

  test('Gateway legacy vuelve a cargar al cambiar de categoría', () async {
    final dashboardHttp = MockClient((_) async => http.Response('{}', 404));
    var gatewayRequests = 0;
    final gatewayHttp = MockClient((_) async {
      gatewayRequests += 1;
      return http.Response(
        jsonEncode({
          'data': [_row(0, source: 'mobile'), _row(1, source: 'webhook')],
        }),
        200,
      );
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });

    final chats = await repository.refresh(
      SessionLibraryQuery(excludeSources: AutomationSessionSources.values),
    );
    expect(chats.sessions.single.source, 'mobile');

    final automation = await repository.refresh(
      SessionLibraryQuery(sources: AutomationSessionSources.values),
    );
    expect(automation.sessions.single.source, 'webhook');

    final everything = await repository.refresh(const SessionLibraryQuery());
    expect(everything.sessions, hasLength(2));
    expect(gatewayRequests, 3);
  });

  test('archive usa solo Dashboard y valida la confirmación', () async {
    http.Request? archiveRequest;
    final dashboardHttp = MockClient((request) async {
      archiveRequest = request;
      return http.Response(jsonEncode({'ok': true, 'archived': true}), 200);
    });
    var gatewayRequests = 0;
    final gatewayHttp = MockClient((_) async {
      gatewayRequests += 1;
      return http.Response('{}', 500);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });
    final session = Session.fromJson(_row(1)..['id'] = 'tip/branch');

    await repository.setArchived(session, true, profile: 'coding profile');

    expect(archiveRequest?.method, 'PATCH');
    expect(
      archiveRequest?.url.toString(),
      contains('/api/sessions/tip%2Fbranch'),
    );
    expect(jsonDecode(archiveRequest!.body), {
      'archived': true,
      'profile': 'coding profile',
    });
    expect(gatewayRequests, 0);
  });

  test('pin usa PATCH del lineage root y conserva el perfil', () async {
    http.Request? pinRequest;
    final dashboardHttp = MockClient((request) async {
      pinRequest = request;
      return http.Response(jsonEncode({'ok': true, 'pinned': true}), 200);
    });
    final gatewayHttp = MockClient((_) async => http.Response('{}', 500));
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(gatewayHttp);
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
      gateway.close();
    });
    final session = Session.fromJson(
      _row(1)
        ..['id'] = 'tip/branch'
        ..['_lineage_root_id'] = 'root/branch',
    );

    await repository.setPinned(session.logicalId, true, profile: 'coding');

    expect(pinRequest?.method, 'PATCH');
    expect(pinRequest?.url.toString(), contains('/api/sessions/root%2Fbranch'));
    expect(jsonDecode(pinRequest!.body), {'pinned': true, 'profile': 'coding'});
  });

  test(
    'Dashboard 404 degrada a Gateway limitado; 403 nunca cambia de host',
    () async {
      var dashboardStatus = 404;
      final dashboardHttp = MockClient(
        (_) async => http.Response('{}', dashboardStatus),
      );
      var gatewayRequests = 0;
      final gatewayHttp = MockClient((request) async {
        gatewayRequests += 1;
        return http.Response(
          jsonEncode({
            'data': [_row(1)],
          }),
          200,
        );
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(gatewayHttp);
      var repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });

      final fallback = await repository.refresh(const SessionLibraryQuery());
      expect(fallback.source, SessionLibrarySource.gateway);
      expect(fallback.exhaustive, isFalse);
      expect(fallback.sessions.single.id, 'session-1');
      expect(gatewayRequests, 1);

      repository.close();
      repository = SessionRepository(dashboard, gateway);
      dashboardStatus = 403;
      await expectLater(
        repository.refresh(const SessionLibraryQuery()),
        throwsA(
          isA<DashboardHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(gatewayRequests, 1);
    },
  );
}
