import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/roster_known_filter.dart';

DesktopActiveSession _row(String stored, [String status = 'running']) =>
    DesktopActiveSession(
      runtimeSessionId: 'rt-$stored',
      storedSessionId: stored,
      status: status,
    );

Session _session(String id, {String? root}) => Session(
  id: id,
  title: id,
  model: 'm',
  source: 'desktop',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 1.0,
  lineageRootId: root,
);

GlobalActivity? _apply(
  DesktopActiveSessionList roster,
  Set<String> known, {
  bool filter = true,
}) {
  final aggregate = GlobalActivityAggregate.inMemory();
  addTearDown(aggregate.dispose);
  aggregate.applyRoster(
    connectionId: 'c',
    profile: 'default',
    replayEpoch: 'e',
    requestGeneration: aggregate.beginRosterRequest('c', 'default'),
    roster: filter ? filterRosterToKnown(roster, known) : roster,
  );
  return aggregate.activityFor('c', 'default', 'ddc552');
}

void main() {
  final roster = DesktopActiveSessionList(
    sessions: [_row('ddc552'), _row('mine')],
  );

  test('a roster row the profile does not know never becomes activity', () {
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    aggregate.applyRoster(
      connectionId: 'c',
      profile: 'default',
      replayEpoch: 'e',
      requestGeneration: aggregate.beginRosterRequest('c', 'default'),
      roster: filterRosterToKnown(roster, {'mine'}),
    );
    expect(aggregate.activityFor('c', 'default', 'ddc552'), isNull);
    expect(aggregate.activities, hasLength(1));
  });

  test('a known busy row stays generating', () {
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    aggregate.applyRoster(
      connectionId: 'c',
      profile: 'default',
      replayEpoch: 'e',
      requestGeneration: aggregate.beginRosterRequest('c', 'default'),
      roster: filterRosterToKnown(
        DesktopActiveSessionList(sessions: [_row('mine', 'working')]),
        {'mine'},
      ),
    );
    expect(
      aggregate.activityFor('c', 'default', 'mine')?.phase,
      GlobalActivityPhase.generating,
    );
  });

  test('malformed flag survives the filter', () {
    final filtered = filterRosterToKnown(
      const DesktopActiveSessionList(hasMalformedRows: true),
      {'mine'},
    );
    expect(filtered.hasMalformedRows, isTrue);
  });

  test('known ids: loaded rows, lineage, pins and local chats', () {
    final known = knownSessionIds(
      sessions: [_session('tip', root: 'root')],
      pinnedIds: const ['pinned'],
      roster: DesktopActiveSessionList(
        sessions: [_row('fresh'), _row('ddc552'), _row('pinned')],
      ),
      hasLocalChat: (id) => id == 'fresh',
    );
    expect(known, containsAll(['tip', 'root', 'pinned', 'fresh']));
    expect(known, isNot(contains('ddc552')));
  });

  test('a freshly created own session with a local chat stays visible', () {
    final known = knownSessionIds(
      sessions: const [],
      pinnedIds: const [],
      roster: DesktopActiveSessionList(sessions: [_row('ddc552')]),
      hasLocalChat: (id) => id == 'ddc552',
    );
    expect(_apply(roster, known)?.phase, isNotNull);
  });

  test('control: without the filter the foreign row is stamped', () {
    expect(_apply(roster, {'mine'}, filter: false), isNotNull);
  });
}
