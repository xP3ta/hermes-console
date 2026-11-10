// «Artefactos» across conversations: Desktop's loadArtifactsForSessions
// (recent sessions of every profile, transcripts in pages of 100 oldest
// first, one page at a time, failures skipped and counted), bounded for a
// phone (batches of 10 up to 30, a page cap per conversation, cancel).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_artifacts.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session(String id, {String profile = 'default', double at = 1000}) =>
    Session.tryParse({
      'id': id,
      'title': 'Chat $id',
      'profile': profile,
      'started_at': at,
    })!;

Map<String, dynamic> _media(String path, {num? ts}) => {
  'role': 'assistant',
  'content': 'MEDIA:$path',
  'timestamp': ?ts,
};

class _FakeSource implements GlobalArtifactsSource {
  _FakeSource(this.sessions, this.transcripts);

  final List<Session> sessions;

  /// Chronological rows per conversation id.
  final Map<String, List<Map<String, dynamic>>> transcripts;
  final failing = <String>{};
  final tooLarge = <String>{};
  final slow = <String>{};
  final pages = <String>[];
  int listCalls = 0;
  int? listLimit;
  bool listFails = false;
  int active = 0;
  int maxActive = 0;

  /// While set, every page waits for it.
  Completer<void>? gate;

  @override
  Future<List<Session>> recentSessions(int limit) async {
    listCalls++;
    listLimit = limit;
    if (listFails) throw StateError('offline');
    return sessions;
  }

  @override
  Future<SessionMessagesPage> page(
    Session session, {
    required int offset,
    required int limit,
  }) async {
    pages.add('${session.id}@$offset');
    active++;
    maxActive = math.max(maxActive, active);
    try {
      await Future<void>.value();
      final wait = gate;
      if (wait != null) await wait.future;
      if (failing.contains(session.id)) throw StateError('read failed');
      if (tooLarge.contains(session.id)) {
        throw const SessionTranscriptTooLargeException();
      }
      if (slow.contains(session.id)) throw TimeoutException('REST deadline');
      final rows = transcripts[session.id] ?? const [];
      final slice = rows.skip(offset).take(limit).toList();
      return SessionMessagesPage(
        messages: slice,
        pagination: {
          'limit': limit,
          'offset': offset,
          'returned': slice.length,
        },
      );
    } finally {
      active--;
    }
  }
}

GlobalArtifactsController _controller(_FakeSource source, {int pages = 20}) =>
    GlobalArtifactsController(
      source: source,
      cacheKey: 'test',
      maxPagesPerSession: pages,
    );

void main() {
  setUp(GlobalArtifactsController.clearMemory);

  test('lists 30 recent conversations and reads the first 10, one page at '
      'a time, pages of 100 oldest first', () async {
    final sessions = [for (var i = 0; i < 30; i++) _session('s$i')];
    final source = _FakeSource(sessions, {
      for (var i = 0; i < 30; i++)
        's$i': [
          for (var row = 0; row < 150; row++) {'role': 'user', 'content': 'x'},
          _media('/out/s$i.pdf'),
        ],
    });
    final controller = _controller(source);
    await controller.refresh();

    expect(source.listCalls, 1);
    expect(source.listLimit, 30);
    expect(source.maxActive, 1);
    // 151 rows: a full page of 100 at 0, then 51 at 100, then stop.
    expect(source.pages.take(2), ['s0@0', 's0@100']);
    expect(source.pages, hasLength(20));
    expect(source.pages.last, 's9@100');
    final state = controller.state;
    expect(state.phase, GlobalArtifactsPhase.ready);
    expect(state.listed, 30);
    expect(state.indexed, 10);
    expect(state.hasMore, isTrue);
    expect(state.artifacts, hasLength(10));

    await controller.loadMore();
    await controller.loadMore();
    expect(controller.state.indexed, 30);
    expect(controller.state.hasMore, isFalse);
    await controller.loadMore();
    expect(source.pages, hasLength(60));
  });

  test('a conversation whose page does not arrive in time is counted '
      'apart', () async {
    // R5C C-V10: it was skipped with the generic notice.
    final source = _FakeSource(
      [_session('ok'), _session('slow')],
      {
        'ok': [_media('/out/a.png')],
        'slow': [_media('/out/b.png')],
      },
    );
    source.slow.add('slow');
    final controller = _controller(source);
    await controller.refresh();

    final state = controller.state;
    expect(state.skipped, 1);
    expect(state.skippedTimedOut, 1);
    expect(state.skippedTooLarge, 0);
  });

  test('a bounded read gets time for its size, 30 to 60 s', () {
    expect(
      DashboardClient.boundedReadDeadline(16 * 1024),
      const Duration(seconds: 30),
    );
    expect(
      DashboardClient.boundedReadDeadline(4 * 1024 * 1024),
      const Duration(seconds: 46),
    );
    expect(
      DashboardClient.boundedReadDeadline(64 * 1024 * 1024),
      const Duration(seconds: 60),
    );
  });

  test('a conversation that fails or is too large is skipped and counted, '
      'the rest is read', () async {
    final source = _FakeSource(
      [_session('ok'), _session('bad'), _session('big'), _session('ok2')],
      {
        'ok': [_media('/out/a.png')],
        'ok2': [_media('/out/b.png')],
      },
    );
    source.failing.add('bad');
    source.tooLarge.add('big');
    final controller = _controller(source);
    await controller.refresh();

    final state = controller.state;
    expect(state.indexed, 4);
    expect(state.skipped, 2);
    expect(state.skippedTooLarge, 1);
    expect(state.artifacts.map((a) => a.item.label).toSet(), {
      'a.png',
      'b.png',
    });
  });

  test('the recent list failing is an error, not an empty view', () async {
    final source = _FakeSource(const [], const {})..listFails = true;
    final controller = _controller(source);
    await controller.refresh();
    expect(controller.state.phase, GlobalArtifactsPhase.failed);
    expect(source.pages, isEmpty);
  });

  test('cancel stops after the page in flight; loadMore resumes', () async {
    final source = _FakeSource([_session('s0'), _session('s1')], {
      's0': [_media('/out/a.png')],
      's1': [_media('/out/b.png')],
    });
    final gate = source.gate = Completer<void>();
    final controller = _controller(source);
    final running = controller.refresh();
    await pumpEventQueue();
    expect(source.pages, ['s0@0']);
    expect(controller.state.phase, GlobalArtifactsPhase.indexing);

    controller.cancel();
    gate.complete();
    await running;
    expect(controller.state.phase, GlobalArtifactsPhase.ready);
    expect(controller.state.indexed, 0);
    expect(controller.state.artifacts, isEmpty);
    expect(source.pages, ['s0@0']);

    source.gate = null;
    await controller.loadMore();
    expect(controller.state.indexed, 2);
    expect(source.pages, ['s0@0', 's0@0', 's1@0']);
  });

  test('a conversation past the page cap is read up to it', () async {
    final source = _FakeSource([_session('long')], {
      'long': [
        _media('/out/first.pdf'),
        for (var row = 0; row < 1000; row++) {'role': 'user', 'content': 'x'},
      ],
    });
    final controller = _controller(source, pages: 3);
    await controller.refresh();
    expect(source.pages, ['long@0', 'long@100', 'long@200']);
    expect(controller.state.truncated, 1);
    expect(controller.state.artifacts.single.item.label, 'first.pdf');
  });

  test('newest first by message time, else the conversation time; one '
      'conversation lists a file once, two conversations twice', () async {
    final source = _FakeSource(
      [_session('old', at: 100), _session('new', at: 900)],
      {
        'old': [
          _media('/out/shared.pdf', ts: 200),
          _media('/out/shared.pdf', ts: 300),
          _media('/out/untimed.png'),
        ],
        'new': [_media('/out/shared.pdf', ts: 500)],
      },
    );
    final controller = _controller(source);
    await controller.refresh();

    final artifacts = controller.state.artifacts;
    expect([for (final a in artifacts) '${a.session.id}:${a.item.label}'], [
      'new:shared.pdf',
      'old:shared.pdf',
      'old:untimed.png',
    ]);
    // The first sighting in a conversation keeps its time.
    expect(artifacts[1].item.timestamp?.millisecondsSinceEpoch, 200000);
  });

  test('reopening shows what was read without reading again', () async {
    final source = _FakeSource([_session('s0')], {
      's0': [_media('/out/a.png')],
    });
    await _controller(source).refresh();
    final calls = source.pages.length;

    final reopened = _controller(source);
    expect(reopened.hasRead, isTrue);
    expect(reopened.state.artifacts.single.item.label, 'a.png');
    expect(source.pages, hasLength(calls));
    expect(source.listCalls, 1);
  });

  test('the Dashboard source asks what Desktop asks', () async {
    final client = _RecordingDashboard();
    final source = DashboardGlobalArtifactsSource(client, maxPageBytes: 1024);
    final sessions = await source.recentSessions(30);
    expect(sessions.map((s) => s.id), ['s1']);
    // The conversation keeps its owner, which ChatScreen opens it in.
    expect(sessions.single.profile, 'work');
    final list = Uri.parse(client.endpoints.first);
    expect(list.path, 'profiles/sessions');
    expect(list.queryParameters, {
      'limit': '30',
      'offset': '0',
      'min_messages': '1',
      'archived': 'exclude',
      'order': 'recent',
      'profile': 'all',
    });

    await source.page(sessions.single, offset: 100, limit: 100);
    final page = Uri.parse(client.endpoints.last);
    expect(page.path, 'sessions/s1/messages');
    expect(page.queryParameters['order'], 'oldest');
    expect(page.queryParameters['offset'], '100');
    expect(page.queryParameters['include_compacted'], 'true');
    expect(page.queryParameters['inline_images'], 'false');
    expect(page.queryParameters['profile'], 'work');
    expect(client.budgets.last, 1024);
  });

  group('REVIEW-R4', () {
    Map<String, dynamic> filler(int i) => {
      'role': 'user',
      'content': 'x' * 1000,
      'id': i,
    };

    test('B2: a batch stops at its byte budget; the next goes on', () async {
      final source = _FakeSource(
        [for (var i = 0; i < 5; i++) _session('s$i')],
        {
          for (var i = 0; i < 5; i++)
            's$i': [
              _media('/out/s$i.pdf'),
              for (var row = 0; row < 300; row++) filler(row),
            ],
        },
      );
      final controller = GlobalArtifactsController(
        source: source,
        cacheKey: 'test',
        // About 100 KB a page: the second page of the first conversation
        // passes the budget.
        batchByteBudget: 150 * 1000,
      );
      await controller.refresh();
      expect(source.pages, ['s0@0', 's0@100']);
      var state = controller.state;
      expect(state.indexed, 1);
      expect(state.budgetReached, isTrue);
      expect(state.truncated, 1);
      expect(state.hasMore, isTrue);
      expect(state.artifacts.single.item.label, 's0.pdf');

      await controller.loadMore();
      state = controller.state;
      expect(source.pages.skip(2), ['s1@0', 's1@100']);
      expect(state.indexed, 2);
      expect(state.budgetReached, isTrue);
    });

    test('B3: one conversation keeps at most its item cap', () async {
      final source = _FakeSource([_session('tree')], {
        'tree': [
          for (var i = 0; i < 10000; i++)
            {'role': 'assistant', 'content': 'https://example.com/p$i'},
        ],
      });
      final controller = GlobalArtifactsController(
        source: source,
        cacheKey: 'test',
        maxItemsPerSession: 500,
      );
      await controller.refresh();
      expect(controller.state.artifacts, hasLength(500));
      expect(controller.state.truncated, 1);
      // It stopped reading as soon as the cap was full.
      expect(source.pages, hasLength(6));
    });

    test('B3: the view and its memory keep at most maxArtifacts', () async {
      final source = _FakeSource(
        [for (var i = 0; i < 3; i++) _session('s$i', at: 1000.0 - i)],
        {
          for (var i = 0; i < 3; i++)
            's$i': [
              for (var n = 0; n < 40; n++)
                _media('/out/s$i-$n.png', ts: 3000 - i * 100 - n),
            ],
        },
      );
      final controller = GlobalArtifactsController(
        source: source,
        cacheKey: 'test',
        maxArtifacts: 50,
      );
      await controller.refresh();
      final kept = controller.state.artifacts;
      expect(kept, hasLength(50));
      expect(controller.state.capped, isTrue);
      // The newest are kept: all of s0, then s1's newest.
      expect(kept.first.item.label, 's0-0.png');
      expect(kept.last.item.label, 's1-9.png');

      final reopened = GlobalArtifactsController(
        source: source,
        cacheKey: 'test',
        maxArtifacts: 50,
      );
      expect(reopened.state.artifacts, hasLength(50));
    });

    test('B4: a connection that changes or goes forgets its read', () async {
      final source = _FakeSource([_session('s0')], {
        's0': [_media('/out/a.png')],
      });
      for (final key in ['gone', 'kept']) {
        await GlobalArtifactsController(
          source: source,
          cacheKey: key,
        ).refresh();
      }
      PrivateRenderCaches.forgetConnection('gone');
      expect(
        GlobalArtifactsController(source: source, cacheKey: 'gone').hasRead,
        isFalse,
      );
      expect(
        GlobalArtifactsController(source: source, cacheKey: 'kept').hasRead,
        isTrue,
      );
      PrivateRenderCaches.clearAll();
      expect(
        GlobalArtifactsController(source: source, cacheKey: 'kept').hasRead,
        isFalse,
      );
    });

    test('B4: ConnectionManager forgets it when the profile changes', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _FakeSource([_session('s0')], {
        's0': [_media('/out/a.png')],
      });
      await GlobalArtifactsController(source: source, cacheKey: 'c1').refresh();
      await manager.setActiveProfile('c1', 'work');
      expect(
        GlobalArtifactsController(source: source, cacheKey: 'c1').hasRead,
        isFalse,
      );
    });
  });
}

final class _RecordingDashboard extends DashboardClient {
  _RecordingDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final endpoints = <String>[];
  final budgets = <int?>[];

  Map<String, dynamic> _answer(String endpoint) {
    if (!endpoint.startsWith('profiles')) {
      return {
        'messages': <Object>[],
        'pagination': {'limit': 100, 'offset': 100},
      };
    }
    return {
      'sessions': [
        {'id': 's1', 'title': 'Uno', 'profile': 'work'},
        // No owner: the chat could only guess its profile (R4 P2-B6).
        {'id': 's2', 'title': 'Sin perfil'},
        {'id': 'mob-aux-1', 'title': 'Aux', 'profile': 'work'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    endpoints.add(endpoint);
    budgets.add(null);
    return _answer(endpoint);
  }

  @override
  Future<Map<String, dynamic>> apiGetBounded(
    String endpoint, {
    required int maxBytes,
    bool retried = false,
  }) async {
    endpoints.add(endpoint);
    budgets.add(maxBytes);
    return _answer(endpoint);
  }
}
