import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/bot_presence.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_rows.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

final _now = DateTime.utc(2026, 9, 27, 12);

AgentProfile _bot(
  String name, {
  String? canonical,
  String canonicalTitle = '',
  String? last,
  String lastTitle = '',
}) => AgentProfile.fromJson({
  'name': name,
  if (canonical != null)
    'canonical_session': {'id': canonical, 'title': canonicalTitle},
  if (last != null) 'last_session': {'id': last, 'title': lastTitle},
});

DesktopActiveSession _row(
  String storedId,
  String status, {
  String? title,
  String runtime = 'rt',
}) => DesktopActiveSession.tryParse({
  'id': '$runtime-$storedId',
  'session_key': storedId,
  'status': status,
  'title': title,
  'preview': null,
  'model': null,
  'last_active': null,
})!;

MissionAgent _agentOf(
  List<AgentProfile> profiles,
  String name,
  List<DesktopActiveSession> rows, {
  List<MissionLiveChat> chats = const [],
  DateTime? observedAt,
}) {
  final projection = MissionProjector.build(
    snapshot: MissionBackendSnapshot(
      profiles: profiles,
      activeSessions: rows,
      activeSessionsObservedAt: observedAt,
      loadedAt: _now,
    ),
    liveChats: chats,
    now: _now,
  );
  return projection.agents.singleWhere((agent) => agent.profile.name == name);
}

BotRosterEntry _entry(MissionAgent agent) => BotRosterEntry.from(
  agent: agent,
  live: BotLiveStatus.forAgent(agent: agent, now: _now),
  now: _now,
);

void main() {
  final profile = _bot(
    'infra',
    canonical: 'canon-1',
    canonicalTitle: 'Bot Chat',
  );

  group('projection of session.active_list onto a bot', () {
    test(
      'a working row of the bot\'s canonical chat lights it with that title',
      () {
        final agent = _agentOf(
          [profile],
          'infra',
          [_row('canon-1', 'working', title: 'Migrar la base')],
        );
        expect(agent.livePresence, BotPresence.working);
        expect(agent.livePresenceTitle, 'Migrar la base');
        final entry = _entry(agent);
        expect(entry.signal, BotFaceSignal.working);
        expect(entry.workingOn, 'Migrar la base');
        expect(
          rosterBotLine(StringsEs(), entry),
          'Trabajando · Migrar la base',
        );
        expect(rosterBotLine(StringsEn(), entry), 'Working · Migrar la base');
      },
    );

    test('a waiting row asks for attention and names the chat', () {
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'waiting', title: 'Aprobar despliegue')],
      );
      expect(agent.livePresence, BotPresence.attention);
      final entry = _entry(agent);
      expect(entry.signal, BotFaceSignal.attention);
      expect(entry.needsYou, isTrue);
      expect(
        rosterBotLine(StringsEs(), entry),
        'Esperando tu respuesta · Aprobar despliegue',
      );
      expect(
        rosterBotLine(StringsEn(), entry),
        'Waiting for you · Aprobar despliegue',
      );
    });

    test('a starting row reads as thinking', () {
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'starting', title: 'Arrancando')],
      );
      expect(agent.livePresence, BotPresence.thinking);
      expect(_entry(agent).signal, BotFaceSignal.thinking);
    });

    // LiveSessionStatus in the vendored contract also has `streaming` and
    // `resuming`: a bot emitting or resuming must never read as idle.
    test('a streaming row reads as working and a resuming row as thinking', () {
      final streaming = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'streaming', title: 'Emitiendo')],
      );
      expect(streaming.livePresence, BotPresence.working);
      expect(_entry(streaming).signal, BotFaceSignal.working);
      expect(streaming.livePresenceTitle, 'Emitiendo');

      final resuming = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'resuming', title: 'Reanudando')],
      );
      expect(resuming.livePresence, BotPresence.thinking);
      expect(_entry(resuming).signal, BotFaceSignal.thinking);
    });

    test('an idle row, an unknown status and no rows leave the bot idle', () {
      for (final rows in [
        [_row('canon-1', 'idle')],
        [_row('canon-1', 'somethingnew')],
        <DesktopActiveSession>[],
      ]) {
        final agent = _agentOf([profile], 'infra', rows);
        expect(agent.livePresence, BotPresence.idle);
        expect(_entry(agent).signal, BotFaceSignal.idle);
        expect(agent.livePresenceTitle, isNull);
      }
    });

    test('a row whose id belongs to no session of the bot never lights it', () {
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('someone-else', 'working', title: 'No es mío')],
      );
      expect(agent.livePresence, BotPresence.idle);
    });

    test('a row without a title falls back to the bot\'s own chat title', () {
      final agent = _agentOf([profile], 'infra', [_row('canon-1', 'working')]);
      expect(agent.livePresence, BotPresence.working);
      expect(agent.livePresenceTitle, 'Bot Chat');
    });

    test('the busiest row wins when a bot has several', () {
      final both = _bot(
        'infra',
        canonical: 'canon-1',
        canonicalTitle: 'Bot Chat',
        last: 'last-1',
        lastTitle: 'Otro chat',
      );
      final agent = _agentOf(
        [both],
        'infra',
        [
          _row('last-1', 'working', title: 'Otro chat'),
          _row('canon-1', 'waiting', title: 'Pregunta'),
        ],
      );
      expect(agent.livePresence, BotPresence.attention);
      expect(agent.livePresenceTitle, 'Pregunta');
    });

    test('an id that two profiles own lights neither of them', () {
      final first = _bot('alpha', canonical: 'same-id', canonicalTitle: 'A');
      final second = _bot('beta', canonical: 'same-id', canonicalTitle: 'B');
      final rows = [_row('same-id', 'working', title: 'Ambiguo')];

      expect(
        _agentOf([first, second], 'alpha', rows).livePresence,
        BotPresence.idle,
      );
      expect(
        _agentOf([first, second], 'beta', rows).livePresence,
        BotPresence.idle,
      );
      // Without the collision the same row does light the bot.
      expect(
        _agentOf([first], 'alpha', rows).livePresence,
        BotPresence.working,
      );
    });

    test('a later read without the row turns the bot idle again', () {
      final busy = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'working', title: 'Migrar')],
      );
      final done = _agentOf([profile], 'infra', const []);
      expect(busy.livePresence, BotPresence.working);
      expect(done.livePresence, BotPresence.idle);
      expect(_entry(done).signal, BotFaceSignal.idle);
    });
  });

  group('the open chat against the row', () {
    MissionLiveChat chat({
      MissionLivePhase phase = MissionLivePhase.idle,
      DateTime? settledAt,
    }) => MissionLiveChat(
      profileName: 'infra',
      sessionId: 'canon-1',
      title: 'Bot Chat',
      phase: phase,
      settledAt: settledAt,
    );

    test('a row read before the chat settled its turn loses to the chat', () {
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'working', title: 'Viejo')],
        chats: [chat(settledAt: _now)],
        observedAt: _now.subtract(const Duration(seconds: 5)),
      );
      expect(agent.livePresence, BotPresence.idle);
    });

    test('a row read after the chat settled wins over the idle chat', () {
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'working', title: 'Nuevo')],
        chats: [chat(settledAt: _now.subtract(const Duration(seconds: 5)))],
        observedAt: _now,
      );
      expect(agent.livePresence, BotPresence.working);
    });

    test('a chat that is working speaks for its own session', () {
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'waiting', title: 'Remoto')],
        chats: [chat(phase: MissionLivePhase.working)],
        observedAt: _now,
      );
      expect(agent.livePresence, BotPresence.idle);
      expect(agent.status, MissionAgentStatus.working);
    });

    test('without a read time the snapshot load time stands in for it', () {
      // `_now` is the snapshot's loadedAt: a chat that settled after it wins,
      // one that settled before it loses to the row.
      final settledAfter = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'working', title: 'Viejo')],
        chats: [chat(settledAt: _now.add(const Duration(seconds: 5)))],
      );
      expect(settledAfter.livePresence, BotPresence.idle);

      final settledBefore = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'working', title: 'Nuevo')],
        chats: [chat(settledAt: _now.subtract(const Duration(seconds: 5)))],
      );
      expect(settledBefore.livePresence, BotPresence.working);
    });

    test('a chat of another session does not hide the row', () {
      final other = MissionLiveChat(
        profileName: 'infra',
        sessionId: 'unrelated',
        title: 'Otra',
        phase: MissionLivePhase.idle,
        settledAt: _now,
      );
      final agent = _agentOf(
        [profile],
        'infra',
        [_row('canon-1', 'working', title: 'Sigue')],
        chats: [other],
        observedAt: _now.subtract(const Duration(seconds: 5)),
      );
      expect(agent.livePresence, BotPresence.working);
    });
  });
}
