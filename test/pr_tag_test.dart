import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/session_pull_requests.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _s(
  String id, {
  String? repo = '/work/repo',
  String? branch = 'feat/x',
}) => Session(
  id: id,
  title: id,
  model: 'm',
  source: 'mobile',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 1,
  gitRepoRoot: repo,
  gitBranch: branch,
);

final class _FakeGateway implements HermesPullRequestGateway {
  final List<(String, List<String>, List<int>)> listCalls = [];
  final List<List<String>> scanCalls = [];
  Object? listError;
  Object? scanError;
  bool ghReady = true;
  Map<String, PullRequestInfo> prsByBranch = {};
  List<PullRequestInfo> prsByNumber = const [];
  Map<String, int> recovered = {};
  Future<void>? hold;

  @override
  Future<PullRequestList> prList(
    String repoPath, {
    List<String> branches = const [],
    List<int> numbers = const [],
  }) async {
    listCalls.add((repoPath, List.of(branches), List.of(numbers)));
    await hold;
    final error = listError;
    if (error != null) throw error;
    return PullRequestList(
      ghReady: ghReady,
      prs: [
        for (final b in branches)
          if (prsByBranch[b] != null) prsByBranch[b]!,
        if (numbers.isNotEmpty) ...prsByNumber,
      ],
    );
  }

  @override
  Future<PullRequestScan> scanSessionPullRequests(List<String> ids) async {
    scanCalls.add(List.of(ids));
    final error = scanError;
    if (error != null) throw error;
    return PullRequestScan(
      pullRequests: {
        for (final id in ids)
          if (recovered[id] != null) id: recovered[id]!,
      },
      scanned: ids,
    );
  }
}

PullRequestInfo _pr(
  String branch,
  int number, {
  String state = 'open',
  bool draft = false,
  String url = 'https://github.example.test/o/r/pull/1',
}) => PullRequestInfo(
  branch: branch,
  number: number,
  state: state,
  draft: draft,
  title: 't',
  url: url,
);

const _unsupported = DesktopControlFailure(
  DesktopControlFailureKind.unsupported,
  code: 404,
);

void main() {
  late DateTime clock;
  late _FakeGateway gateway;
  late PullRequestTagService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clock = DateTime.utc(2026, 1, 1);
    gateway = _FakeGateway();
    service = PullRequestTagService(
      gateway: gateway,
      now: () => clock,
      prefs: await SharedPreferences.getInstance(),
      connectionId: 'conn1',
    );
  });

  test('trunk branches are never asked for', () async {
    for (final branch in ['main', 'master', 'dev', 'develop', 'trunk']) {
      expect(await service.tagFor(_s('s-$branch', branch: branch)), isNull);
    }
    expect(gateway.listCalls, isEmpty);
  });

  test('a session without repo or branch asks nothing', () async {
    expect(await service.tagFor(_s('a', repo: null)), isNull);
    expect(await service.tagFor(_s('b', branch: null)), isNull);
    expect(gateway.listCalls, isEmpty);
  });

  test('a feature branch is looked up once and mapped to a tag', () async {
    gateway.prsByBranch['feat/x'] = _pr('feat/x', 7);
    final tag = await service.tagFor(_s('a'));
    expect(tag?.number, 7);
    expect(tag?.bucket, PullRequestBucket.open);
    expect(gateway.listCalls.single.$1, '/work/repo');
    expect(gateway.listCalls.single.$2, ['feat/x']);
  });

  test('per-repo cache lasts 60 seconds on the fake clock', () async {
    gateway.prsByBranch['feat/x'] = _pr('feat/x', 7);
    await service.tagFor(_s('a'));
    await service.tagFor(_s('a'));
    clock = clock.add(const Duration(seconds: 59));
    await service.tagFor(_s('a'));
    expect(gateway.listCalls.length, 1);
    clock = clock.add(const Duration(seconds: 2));
    await service.tagFor(_s('a'));
    expect(gateway.listCalls.length, 2);
  });

  test(
    'a second branch of the same repo inside the window sends nothing',
    () async {
      gateway.prsByBranch['feat/x'] = _pr('feat/x', 7);
      await service.tagFor(_s('a'));
      expect(await service.tagFor(_s('b', branch: 'feat/y')), isNull);
      expect(gateway.listCalls.length, 1);
    },
  );

  test('only one request is in flight per repo', () async {
    gateway.prsByBranch['feat/x'] = _pr('feat/x', 7);
    final hold = Completer<void>();
    gateway.hold = hold.future;
    final first = service.tagFor(_s('a'));
    final second = service.tagFor(_s('a'));
    hold.complete();
    expect((await first)?.number, 7);
    expect((await second)?.number, 7);
    expect(gateway.listCalls.length, 1);
  });

  test('404 turns the capability off for good', () async {
    gateway.listError = _unsupported;
    expect(await service.tagFor(_s('a')), isNull);
    expect(service.supported, isFalse);
    clock = clock.add(const Duration(minutes: 10));
    expect(await service.tagFor(_s('a')), isNull);
    expect(gateway.listCalls.length, 1);
  });

  test('other failures keep what was known and stay quiet', () async {
    gateway.prsByBranch['feat/x'] = _pr('feat/x', 7);
    await service.tagFor(_s('a'));
    clock = clock.add(const Duration(seconds: 61));
    gateway.listError = StateError('boom');
    expect((await service.tagFor(_s('a')))?.number, 7);
    expect(service.supported, isTrue);
  });

  test('ghReady false shows no tag', () async {
    gateway.ghReady = false;
    gateway.prsByBranch['feat/x'] = _pr('feat/x', 7);
    expect(await service.tagFor(_s('a')), isNull);
  });

  test('buckets map state and draft', () {
    expect(_pr('b', 1, state: 'merged').bucket, PullRequestBucket.merged);
    expect(_pr('b', 1, state: 'closed').bucket, PullRequestBucket.closed);
    expect(_pr('b', 1, draft: true).bucket, PullRequestBucket.draft);
    expect(_pr('b', 1).bucket, PullRequestBucket.open);
    expect(_pr('b', 1, state: 'weird').bucket, PullRequestBucket.none);
  });

  test(
    'a recovered number is asked as numbers and the scan runs once',
    () async {
      gateway.recovered = {'a': 42};
      gateway.prsByNumber = [_pr('x', 42, state: 'merged')];
      final tag = await service.tagFor(_s('a', branch: 'main'));
      expect(tag?.number, 42);
      expect(tag?.bucket, PullRequestBucket.merged);
      expect(gateway.listCalls.single.$3, [42]);
      expect(gateway.listCalls.single.$2, isEmpty);
      await service.tagFor(_s('a', branch: 'main'));
      expect(gateway.scanCalls.length, 1);
    },
  );

  test('scanned ids survive a restart of the service', () async {
    gateway.recovered = {};
    await service.tagFor(_s('a', branch: 'main'));
    final again = PullRequestTagService(
      gateway: gateway,
      now: () => clock,
      prefs: await SharedPreferences.getInstance(),
      connectionId: 'conn1',
    );
    await again.tagFor(_s('a', branch: 'main'));
    expect(gateway.scanCalls.length, 1);
  });

  test('a 404 on the scan stops scanning', () async {
    gateway.scanError = _unsupported;
    await service.tagFor(_s('a', branch: 'main'));
    await service.tagFor(_s('b', branch: 'main'));
    expect(gateway.scanCalls.length, 1);
  });

  group('safeExternalUri', () {
    test('only https urls open', () {
      expect(
        safePullRequestUri('https://github.example.test/o/r/pull/1'),
        isNotNull,
      );
      expect(safePullRequestUri('http://github.example.test/x'), isNull);
      expect(safePullRequestUri('javascript:alert(1)'), isNull);
      expect(safePullRequestUri('file:///etc/passwd'), isNull);
      expect(safePullRequestUri(''), isNull);
    });
  });
}
