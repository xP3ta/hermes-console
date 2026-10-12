import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/foreign_session.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/foreign_session_import_controller.dart';

ForeignSessionRow _row(
  String id, {
  ForeignSource source = ForeignSource.claude,
  String title = '',
  String? cwd,
  String excerpt = '',
}) => ForeignSessionRow(
  id: id,
  source: source,
  label: 'Claude Code',
  title: title,
  cwd: cwd,
  mtime: 1,
  turnCount: 2,
  excerpt: excerpt,
);

final class _FakeGateway implements HermesForeignSessionGateway {
  final List<(String, Map<String, Object?>)> calls = [];
  final Map<int, ForeignSessionPage> pages = {};
  ForeignPreview preview = const ForeignPreview(
    messages: [ForeignMessage(role: 'user', content: 'hi')],
    total: 1,
  );
  ForeignImportResult imported = const ForeignImportResult(sessionId: 'new-1');
  Object? listError;
  Completer<void>? importGate;

  @override
  Future<ForeignSessionPage> foreignList({
    String? profile,
    ForeignSource? source,
    int? offset,
  }) async {
    calls.add((
      'list',
      {'profile': profile, 'source': source?.wire, 'offset': offset},
    ));
    final error = listError;
    if (error != null) throw error;
    return pages[offset ?? 0] ??
        const ForeignSessionPage(sessions: [], host: 'host.example.test');
  }

  @override
  Future<ForeignPreview> foreignPreview(String id, {String? profile}) async {
    calls.add(('preview', {'profile': profile, 'id': id}));
    return preview;
  }

  @override
  Future<ForeignImportResult> foreignImport(
    String id, {
    String? profile,
  }) async {
    calls.add(('import', {'profile': profile, 'id': id}));
    await importGate?.future;
    return imported;
  }
}

ForeignSessionImportController _controller(_FakeGateway g) =>
    ForeignSessionImportController(gateway: g, profile: 'work');

void main() {
  test('first page carries the profile and no source for All', () async {
    final g = _FakeGateway()
      ..pages[0] = ForeignSessionPage(
        sessions: [_row('a'), _row('b')],
        nextOffset: 2,
        host: 'host.example.test',
        unreadable: 1,
      );
    final c = _controller(g);
    await c.loadFirst();
    expect(g.calls.single.$2, {
      'profile': 'work',
      'source': null,
      'offset': null,
    });
    expect(c.rows.map((r) => r.id), ['a', 'b']);
    expect(c.host, 'host.example.test');
    expect(c.unreadable, 1);
    expect(c.hasMore, isTrue);
  });

  test('pages follow next_offset, dedupe by id and stop at null', () async {
    final g = _FakeGateway()
      ..pages[0] = ForeignSessionPage(
        sessions: [_row('a'), _row('b')],
        nextOffset: 2,
        host: 'h',
      )
      ..pages[2] = ForeignSessionPage(
        sessions: [_row('b'), _row('c')],
        host: 'h',
        unreadable: 2,
      );
    final c = _controller(g);
    await c.loadFirst();
    await c.loadMore();
    expect(c.rows.map((r) => r.id), ['a', 'b', 'c']);
    expect(c.hasMore, isFalse);
    expect(c.unreadable, 2);
    await c.loadMore();
    expect(g.calls.where((e) => e.$1 == 'list').length, 2);
    expect(g.calls[1].$2['offset'], 2);
  });

  test('changing the source restarts from the first page', () async {
    final g = _FakeGateway()
      ..pages[0] = ForeignSessionPage(
        sessions: [_row('a', source: ForeignSource.codex)],
        host: 'h',
      );
    final c = _controller(g);
    await c.setSource(ForeignSource.codex);
    expect(g.calls.single.$2['source'], 'codex');
    expect(g.calls.single.$2['offset'], isNull);
  });

  test('local filter searches title, cwd and excerpt', () async {
    final g = _FakeGateway()
      ..pages[0] = ForeignSessionPage(
        sessions: [
          _row('a', title: 'Fix login'),
          _row('b', cwd: '/work/payments'),
          _row('c', excerpt: 'refactor the parser'),
          _row('d', title: 'other'),
        ],
        host: 'h',
      );
    final c = _controller(g);
    await c.loadFirst();
    c.setQuery('PARSER');
    expect(c.rows.map((r) => r.id), ['c']);
    c.setQuery('payments');
    expect(c.rows.map((r) => r.id), ['b']);
    c.setQuery('');
    expect(c.rows.length, 4);
    expect(g.calls.length, 1);
  });

  test('-32601 hides the entry', () async {
    final g = _FakeGateway()
      ..listError = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );
    final c = _controller(g);
    await c.loadFirst();
    expect(c.unsupported, isTrue);
    expect(c.rows, isEmpty);
  });

  test('another failure is reported and retryable, not hidden', () async {
    final g = _FakeGateway()..listError = StateError('x');
    final c = _controller(g);
    await c.loadFirst();
    expect(c.unsupported, isFalse);
    expect(c.failed, isTrue);
  });

  test('preview and import carry exactly profile and id', () async {
    final g = _FakeGateway();
    final c = _controller(g);
    final preview = await c.preview(_row('opaque-1'));
    expect(preview?.messages.single.content, 'hi');
    expect(g.calls.single.$2, {'profile': 'work', 'id': 'opaque-1'});
    final id = await c.import(_row('opaque-1'));
    expect(id, 'new-1');
    expect(g.calls.last.$1, 'import');
    expect(g.calls.last.$2, {'profile': 'work', 'id': 'opaque-1'});
  });

  test('a double tap sends one import', () async {
    final g = _FakeGateway()..importGate = Completer<void>();
    final c = _controller(g);
    final first = c.import(_row('x'));
    final second = c.import(_row('x'));
    g.importGate!.complete();
    expect(await first, 'new-1');
    expect(await second, isNull);
    expect(g.calls.where((e) => e.$1 == 'import').length, 1);
  });

  test(
    'already imported sends no import and opens the existing copy',
    () async {
      final g = _FakeGateway()
        ..preview = const ForeignPreview(
          messages: [],
          alreadyImported: 'local-7',
        );
      final c = _controller(g);
      final preview = await c.preview(_row('x'));
      expect(preview?.alreadyImported, 'local-7');
      final id = await c.open(preview!);
      expect(id, 'local-7');
      expect(g.calls.where((e) => e.$1 == 'import'), isEmpty);
    },
  );

  test('parsers treat JSON null as absent', () {
    final page = ForeignSessionPage.fromJson({
      'sessions': [
        {
          'id': 'a',
          'source': 'codex',
          'label': 'Codex',
          'title': null,
          'cwd': null,
          'mtime': 5,
          'turn_count': null,
          'excerpt': null,
        },
        {'id': 'bad', 'source': 'unknown'},
      ],
      'next_offset': null,
      'host': null,
      'unreadable': null,
    });
    expect(page.sessions.single.source, ForeignSource.codex);
    expect(page.sessions.single.title, '');
    expect(page.nextOffset, isNull);
    expect(page.unreadable, 0);
    final preview = ForeignPreview.fromJson({
      'messages': [
        {'role': 'user', 'content': 'a'},
        {'role': 3},
      ],
      'total': null,
      'truncated': null,
      'already_imported': null,
      'cwd': null,
    });
    expect(preview.messages.length, 1);
    expect(preview.alreadyImported, isNull);
    expect(preview.truncated, isFalse);
  });
}
