// Editing MEMORY.md / USER.md entries through the dashboard (no bridge):
// the same /api/learning/node route Hermes Desktop uses. Fixtures are
// synthetic; no real server or memory file is involved.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart' show fakeConnection;

/// In-memory stand-in for the dashboard's learning routes. Node ids follow
/// upstream: `memory:<source>:<index>:<fingerprint>`, where the fingerprint
/// names the entry's text, so an id minted before an edit goes stale.
class _MemServer {
  _MemServer(Map<String, Map<String, List<String>>> files)
    : files = {
        for (final p in files.entries)
          p.key: {
            for (final f in p.value.entries) f.key: [...f.value],
          },
      };

  /// profile -> source (`memory` | `profile`) -> entries.
  final Map<String, Map<String, List<String>>> files;
  final requests = <http.Request>[];
  int? putStatusOverride;
  String putDetail = '';

  /// Older upstream graphs mint `memory:<source>:<index>` ids with no
  /// fingerprint; the server then resolves them by position alone.
  bool legacyIds = false;

  static String fp(String text) =>
      text.trim().hashCode.toUnsigned(32).toRadixString(16);

  List<http.Request> get learning =>
      requests.where((r) => r.url.path.startsWith('/api/learning/')).toList();
  List<http.Request> get writes =>
      learning.where((r) => r.method == 'PUT' || r.method == 'DELETE').toList();

  List<Map<String, Object?>> _nodes(String profile) {
    final out = <Map<String, Object?>>[];
    var index = 0;
    for (final source in ['memory', 'profile']) {
      for (final text in files[profile]?[source] ?? const <String>[]) {
        out.add({
          'id': legacyIds
              ? 'memory:$source:$index'
              : 'memory:$source:$index:${fp(text)}',
          'label': text.split('\n').first,
          'kind': 'memory',
          'memorySource': source,
        });
        index++;
      }
    }
    return out;
  }

  /// (source, local index) the id still names, or null when stale.
  (String, int)? _resolve(String profile, String id) {
    final parts = id.split(':');
    final entries = files[profile]?[parts.length > 1 ? parts[1] : ''];
    if (entries == null || parts[0] != 'memory') return null;
    if (parts.length == 3) {
      final before = parts[1] == 'profile'
          ? (files[profile]?['memory']?.length ?? 0)
          : 0;
      final local = int.parse(parts[2]) - before;
      return local >= 0 && local < entries.length ? (parts[1], local) : null;
    }
    if (parts.length != 4) return null;
    final local = entries.indexWhere((e) => fp(e) == parts[3]);
    return local < 0 ? null : (parts[1], local);
  }

  /// A concurrent edit from another surface (Desktop, the agent).
  void editElsewhere(String profile, String source, int local, String text) =>
      files[profile]![source]![local] = text;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  DashboardClient get client => DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      requests.add(
        http.Request(request.method, request.url)..body = request.body,
      );
      final path = request.url.path;
      final query = request.url.queryParameters;
      if (path == '/api/memory') {
        return _json({
          'active': '',
          'providers': [],
          'builtin_files': {'memory': 120, 'user': 40},
        });
      }
      if (path == '/api/learning/graph') {
        final profile = query['profile'] ?? '';
        return _json({'nodes': _nodes(profile), 'edges': []});
      }
      if (path == '/api/learning/node') {
        final body = request.method == 'GET'
            ? query
            : Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        final profile = '${body['profile'] ?? query['profile'] ?? ''}';
        final id = '${body['id'] ?? ''}';
        final hit = _resolve(profile, id);
        if (request.method == 'GET') {
          if (hit == null) {
            return _json({
              'detail': 'memory node id is stale — refresh the graph',
            }, 404);
          }
          return _json({
            'ok': true,
            'kind': 'memory',
            'label': 'x',
            'content': files[profile]![hit.$1]![hit.$2].trim(),
          });
        }
        if (putStatusOverride != null) {
          return _json({'detail': putDetail}, putStatusOverride!);
        }
        if (hit == null) {
          return _json({
            'detail': 'memory node id is stale — refresh the graph',
          }, 400);
        }
        if (request.method == 'PUT') {
          files[profile]![hit.$1]![hit.$2] = '${body['content']}';
        } else {
          files[profile]![hit.$1]!.removeAt(hit.$2);
        }
        return _json({'ok': true, 'message': 'ok'});
      }
      return _json({'detail': 'not found'}, 404);
    }),
  );
}

_MemServer _server() => _MemServer({
  'research': {
    'memory': ['Prefers Spanish replies', 'Homelab: Proxmox'],
    'profile': ['Name: Ana'],
  },
  'default': {
    'memory': ['Default note'],
    'profile': <String>[],
  },
});

Future<void> _pump(
  WidgetTester tester,
  _MemServer server, {
  String? profile = 'research',
  bool readOnly = false,
  ValueListenable<bool>? locked,
}) async {
  tester.view.physicalSize = const Size(412, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: MemoryScreen(
        connection: fakeConnection(readOnly: readOnly),
        profileOverride: profile,
        dashboardClientForTesting: server.client,
        appLockedForTesting: locked,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// MemoryScreen → MEMORY.md (or USER.md) detail → entries list.
Future<void> _openEntries(WidgetTester tester, {String file = 'memory'}) async {
  await tester.tap(find.text('$file.md'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('memory-file-edit-entries')));
  await tester.pumpAndSettle();
}

Future<void> _openEntry(WidgetTester tester, int index) async {
  await tester.tap(find.byKey(ValueKey('memory-entry-$index')));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('memory-entry-save')));
  await tester.pumpAndSettle();
  final confirm = find.byKey(const ValueKey('memory-entry-confirm'));
  if (confirm.evaluate().isNotEmpty) {
    await tester.tap(confirm);
    await tester.pumpAndSettle();
  }
}

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('memory-entry-field')))
    .controller!
    .text;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists the MEMORY.md entries of the scoped profile', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);

    expect(find.text('Prefers Spanish replies'), findsOneWidget);
    expect(find.text('Homelab: Proxmox'), findsOneWidget);
    // USER.md entries belong to the other file.
    expect(find.text('Name: Ana'), findsNothing);
    final graph = server.learning.single;
    expect(graph.url.path, '/api/learning/graph');
    expect(graph.url.queryParameters['profile'], 'research');
  });

  testWidgets('USER.md lists only the user profile entries', (tester) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester, file: 'user');
    expect(find.text('Name: Ana'), findsOneWidget);
    expect(find.text('Prefers Spanish replies'), findsNothing);
  });

  testWidgets('edits an entry: re-reads, then writes to the same profile', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    expect(_field(tester), 'Prefers Spanish replies');

    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'Prefers Spanish replies, English code',
    );
    await _save(tester);

    expect(
      server.files['research']!['memory']!.first,
      'Prefers Spanish replies, English code',
    );
    final calls = server.learning
        .map((r) => '${r.method} ${r.url.path}')
        .toList();
    expect(calls, [
      'GET /api/learning/graph',
      'GET /api/learning/node', // load
      'GET /api/learning/node', // re-read right before the write
      'PUT /api/learning/node',
      'GET /api/learning/graph', // list refresh
    ]);
    final put = server.writes.single;
    final body = jsonDecode(put.body) as Map<String, dynamic>;
    expect(body['profile'], 'research');
    expect(body['content'], 'Prefers Spanish replies, English code');
    expect('${body['id']}', startsWith('memory:memory:0:'));
    // Back on the list, which shows the new text.
    expect(find.text('Prefers Spanish replies, English code'), findsOneWidget);
  });

  testWidgets('the default profile is named explicitly', (tester) async {
    final server = _server();
    await _pump(tester, server, profile: null);
    await _openEntries(tester);
    expect(find.text('Default note'), findsOneWidget);
    expect(server.learning.single.url.queryParameters['profile'], 'default');
  });

  testWidgets('a Desktop edit since load is never overwritten', (tester) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'my phone edit',
    );
    server.editElsewhere('research', 'memory', 0, 'desktop edit');

    await _save(tester);

    expect(server.writes, isEmpty);
    expect(server.files['research']!['memory']!.first, 'desktop edit');
    expect(find.byKey(const ValueKey('memory-entry-conflict')), findsOneWidget);
    // Keep editing: the user's text is still there.
    await tester.tap(find.byKey(const ValueKey('memory-entry-conflict-keep')));
    await tester.pumpAndSettle();
    expect(_field(tester), 'my phone edit');
  });

  testWidgets('conflict offers the server version without writing', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 1);
    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'mine',
    );
    server.editElsewhere('research', 'memory', 1, 'Homelab: Proxmox + NAS');
    await _save(tester);
    await tester.tap(
      find.byKey(const ValueKey('memory-entry-conflict-reload')),
    );
    await tester.pumpAndSettle();
    // The list reloads with the server's current entries; nothing written.
    expect(server.writes, isEmpty);
    expect(find.text('Homelab: Proxmox + NAS'), findsOneWidget);
  });

  testWidgets('without fingerprinted ids the re-read still catches a change', (
    tester,
  ) async {
    // Only the client's content comparison protects this case: the old id
    // still resolves (by position) after the entry was rewritten elsewhere.
    final server = _server()..legacyIds = true;
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'my phone edit',
    );
    server.editElsewhere('research', 'memory', 0, 'desktop edit');
    await _save(tester);
    expect(server.writes, isEmpty);
    expect(server.files['research']!['memory']!.first, 'desktop edit');
    expect(find.byKey(const ValueKey('memory-entry-conflict')), findsOneWidget);
  });

  testWidgets('an entry removed elsewhere is a conflict, not a write', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'edited',
    );
    server.files['research']!['memory']!.removeAt(0);
    await _save(tester);
    expect(server.writes, isEmpty);
    expect(find.byKey(const ValueKey('memory-entry-conflict')), findsOneWidget);
  });

  testWidgets('an oversized entry is refused before any request', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    final before = server.learning.length;
    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'x' * (64 * 1024 + 1),
    );
    await tester.tap(find.byKey(const ValueKey('memory-entry-save')));
    await tester.pumpAndSettle();
    expect(server.learning.length, before);
    expect(find.byKey(const ValueKey('memory-entry-confirm')), findsNothing);
  });

  testWidgets('a server limit rejection keeps the text and says why', (
    tester,
  ) async {
    final server = _server()
      ..putStatusOverride = 400
      ..putDetail = 'Replacement would put memory at 2,300/2,200 chars.';
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    await tester.enterText(
      find.byKey(const ValueKey('memory-entry-field')),
      'longer text',
    );
    await _save(tester);
    expect(find.textContaining('2,300/2,200'), findsOneWidget);
    expect(_field(tester), 'longer text');
  });

  testWidgets('deletes an entry after a re-read', (tester) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 1);
    await tester.tap(find.byKey(const ValueKey('memory-entry-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('memory-entry-confirm')));
    await tester.pumpAndSettle();
    expect(server.files['research']!['memory'], ['Prefers Spanish replies']);
    final del = server.writes.single;
    expect(del.method, 'DELETE');
    expect((jsonDecode(del.body) as Map)['profile'], 'research');
    expect(find.text('Homelab: Proxmox'), findsNothing);
  });

  testWidgets('delete refuses an entry changed elsewhere', (tester) async {
    final server = _server();
    await _pump(tester, server);
    await _openEntries(tester);
    await _openEntry(tester, 1);
    server.editElsewhere('research', 'memory', 1, 'Homelab: Proxmox + NAS');
    await tester.tap(find.byKey(const ValueKey('memory-entry-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('memory-entry-confirm')));
    await tester.pumpAndSettle();
    expect(server.writes, isEmpty);
    expect(server.files['research']!['memory']!.last, 'Homelab: Proxmox + NAS');
    expect(find.byKey(const ValueKey('memory-entry-conflict')), findsOneWidget);
  });

  testWidgets('a read-only instance can read entries but not write', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server, readOnly: true);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    expect(_field(tester), 'Prefers Spanish replies');
    expect(find.byKey(const ValueKey('memory-entry-save')), findsNothing);
    expect(find.byKey(const ValueKey('memory-entry-delete')), findsNothing);
  });

  testWidgets('nothing is read while the app is locked', (tester) async {
    final server = _server();
    final locked = ValueNotifier<bool>(true);
    addTearDown(locked.dispose);
    await _pump(tester, server, locked: locked);
    await _openEntries(tester);
    expect(server.learning, isEmpty);
    expect(find.text('Prefers Spanish replies'), findsNothing);

    locked.value = false;
    await tester.pumpAndSettle();
    expect(server.learning.length, 1);
    expect(find.text('Prefers Spanish replies'), findsOneWidget);
  });

  testWidgets('relocking hides the open entry and blocks the save re-read', (
    tester,
  ) async {
    final server = _server();
    final locked = ValueNotifier<bool>(false);
    addTearDown(locked.dispose);
    await _pump(tester, server, locked: locked);
    await _openEntries(tester);
    await _openEntry(tester, 0);
    final reads = server.learning.length;
    locked.value = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-entry-field')), findsNothing);
    expect(find.text('Prefers Spanish replies'), findsNothing);
    expect(server.learning.length, reads);
  });
}
