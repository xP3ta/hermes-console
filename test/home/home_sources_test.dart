import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/home_sources.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/home/home_now.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/utils/home_recent_sessions.dart';

import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

import '../support/spec070_fixtures.dart';

HostedGroupsSnapshot _groups() => HostedGroupsSnapshot(
  capabilities: spec070Capabilities(),
  rooms: [spec070Room()],
  logs: [
    HostedGroupLogPage.append(
      spec070LogPage('groups_log_page1'),
      spec070LogPage('groups_log_page2'),
    ),
  ],
  driverStatuses: {'room-devs': spec070DriverStatus()},
);

CronJob _job(Map<String, dynamic> json) =>
    CronJob.fromJson({'id': 'j1', 'name': 'Backup', ...json});

void main() {
  group('team', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1790000600 * 1000);

    test('every bot with its Bot Chat state; never the main bot or a '
        'hidden one', () {
      final team = homeBoardBots(
        profiles: spec070Profiles(),
        activeSessions: const [
          // default (main) Bot Chat tip: working, but it is the main bot.
          DesktopActiveSession(
            runtimeSessionId: 'rt-hermes',
            storedSessionId: '20260920_100000_tip001',
            status: 'working',
          ),
          DesktopActiveSession(
            runtimeSessionId: 'rt-astra',
            storedSessionId: '20260901_120000_astra1',
            status: 'working',
            title: 'Bot Chat',
          ),
        ],
        liveChats: const [],
        now: now,
      );
      expect(team.map((b) => b.profileName), isNot(contains('default')));
      final astra = team.singleWhere((b) => b.profileName == 'astra');
      expect(astra.state, HomeBotState.working);
      expect(astra.profile?.name, 'astra');
      expect(
        team.where((b) => b.profileName != 'astra').map((b) => b.state),
        everyElement(HomeBotState.idle),
      );
    });

    test('an idle canonical chat is listed as idle, without a step', () {
      final team = homeBoardBots(
        profiles: spec070Profiles(),
        activeSessions: spec070ActiveSessions().sessions,
        liveChats: const [],
        now: now,
      );
      expect(team, isNotEmpty);
      expect(team.map((b) => b.state), everyElement(HomeBotState.idle));
      expect(team.map((b) => b.step), everyElement(isNull));
    });

    test('no profiles, no team', () {
      expect(
        homeBoardBots(
          profiles: const [],
          activeSessions: spec070ActiveSessions().sessions,
          liveChats: const [],
          now: now,
        ),
        isEmpty,
      );
    });
  });

  group('room approvals and news', () {
    test('the driver approval with its exact action and member', () {
      final groups = _groups();
      final items = homeRoomApprovals(
        groups,
        AttentionSummary.fromSnapshot(groups),
      );
      final item = items.single;
      expect(item.roomKey, 'room-devs');
      expect(item.where, 'Console Devs');
      expect(item.actor, 'Astra');
      expect(item.command, contains('git push origin main'));
      expect(item.canAllow, isTrue);
      expect(item.canDeny, isTrue);
      final ref = item.ref as HomeRoomApprovalRef;
      expect(ref.action.requestId, 'apr-1');
      expect(ref.room.roomId, 'room-devs');
    });

    test('member messages after the seen mark count as news', () {
      final news = homeRoomNews(
        _groups(),
        acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
      );
      expect(news.single.count, 1);
      expect(news.single.title, 'Console Devs');
    });

    test('a Sala sees the same news count, the newest lines (at most 3, '
        'oldest first) and nobody replying in a settled round', () {
      final groups = _groups();
      final rooms = homeBoardRooms(
        groups,
        acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
      );
      final room = rooms.single;
      expect(room.key, 'room-devs');
      expect(room.title, 'Console Devs');
      expect(
        room.unread,
        homeRoomNews(
          groups,
          acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
        ).single.count,
      );
      final texts = [
        for (final log in groups.logs)
          for (final e in log.events)
            if ((e.kind == 'message.member' || e.kind == 'message.user') &&
                (e.publicText?.trim().isNotEmpty ?? false))
              e,
      ]..sort((a, b) => a.sequence.compareTo(b.sequence));
      expect(room.lines, isNotEmpty);
      expect(room.lines.length, lessThanOrEqualTo(3));
      expect(room.lines.last.text, isNotEmpty);
      expect(
        room.lines.last.text,
        humanReadableSessionPreview(texts.last.publicText!) ??
            texts.last.publicText!.trim(),
      );
      expect(room.memberProfiles, isNotEmpty);
    });

    test('a Sala carries the replies addressed to the user and the members '
        'whose turn failed, from the same attention as the Bots dot', () {
      final rooms = homeBoardRooms(
        _groups(),
        acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
        attention: const AttentionSummary({
          'room-devs': RoomAttention('room-devs', [
            AttentionItem(
              kind: AttentionKind.mention,
              roomId: 'room-devs',
              memberId: 'member-astra',
              eventId: 'e1',
            ),
            AttentionItem(
              kind: AttentionKind.mention,
              roomId: 'room-devs',
              memberId: 'member-radar',
              eventId: 'e2',
            ),
            AttentionItem(
              kind: AttentionKind.failedTurn,
              roomId: 'room-devs',
              memberId: 'member-radar',
              taskId: 't1',
            ),
            AttentionItem(
              kind: AttentionKind.retry,
              roomId: 'room-devs',
              memberId: 'member-astra',
              taskId: 't2',
            ),
            AttentionItem(
              kind: AttentionKind.retry,
              roomId: 'room-devs',
              memberId: 'member-radar',
              taskId: 't3',
            ),
          ]),
        }),
      );
      expect(rooms.single.mentions, 2);
      // A failed turn and a retry offer both count; each member once.
      expect(rooms.single.failed, ['radar', 'Astra']);
    });

    test('without attention a Sala has no replies and no failures', () {
      final room = homeBoardRooms(
        _groups(),
        acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
      ).single;
      expect(room.mentions, 0);
      expect(room.failed, isEmpty);
    });

    test('a room never opened here has no unread count', () {
      expect(
        homeBoardRooms(
          _groups(),
          acksFor: (_) => RoomAttentionAcks.none,
        ).single.unread,
        0,
      );
    });

    test('nothing new after the mark, or a room never seen: no news', () {
      expect(
        homeRoomNews(
          _groups(),
          acksFor: (_) => const RoomAttentionAcks(seenSeq: 3),
        ),
        isEmpty,
      );
      expect(
        homeRoomNews(_groups(), acksFor: (_) => RoomAttentionAcks.none),
        isEmpty,
      );
    });
  });

  group('chat approvals', () {
    late ActiveChatService chats;
    final connection = SavedConnection(
      id: 'c1',
      label: 'QA',
      host: '127.0.0.2',
      port: 8642,
      apiKey: 'k',
    );

    setUp(() => chats = ActiveChatService(attachDesktopRuntimeOnLoad: false));
    tearDown(() => chats.dispose());

    ActiveChat attach(String id, Map<String, dynamic>? request) {
      final chat = chats.attach(
        connection: connection,
        sessionId: id,
        sessionTitle: 'Deploy $id',
        sessionProfile: 'default',
        disableForegroundKeepAlive: true,
      );
      chat
        ..state = ChatPipelineState.executing
        ..pendingApproval = request;
      return chat;
    }

    test('one item per pending request, answered by its own chat', () {
      final pending = attach('s1', {
        'request_id': 'r1',
        'command': 'rm -rf build',
        'choices': ['once', 'session', 'deny'],
      });
      final idle = attach('s2', null);
      final items = homeChatApprovals(
        [pending, idle],
        chatKey: (chat) => chat.sessionId,
        whereOf: (chat) => chat.sessionTitle,
      );
      final item = items.single;
      expect(item.sessionKey, 's1');
      expect(item.where, 'Deploy s1');
      expect(item.command, 'rm -rf build');
      expect(item.canAllow, isTrue);
      expect(item.canDeny, isTrue);
      expect(item.profileName, 'default');
      expect(
        identical((item.ref as HomeChatApprovalRef).chat, pending),
        isTrue,
      );
    });

    test('a room approval carries the asking member profile for its face', () {
      final groups = _groups();
      final item = homeRoomApprovals(
        groups,
        AttentionSummary.fromSnapshot(groups),
      ).single;
      expect(item.profileName, 'astra');
    });

    test('Permitir only when the request offers a one-time allow', () {
      final chat = attach('s1', {
        'request_id': 'r1',
        'command': 'ls',
        'choices': ['deny'],
      });
      final item = homeChatApprovals(
        [chat],
        chatKey: (_) => null,
        whereOf: (_) => '',
      ).single;
      expect(item.canAllow, isFalse);
      expect(item.canDeny, isTrue);
    });

    test('a request without an id is not answerable and not shown', () {
      final chat = attach('s1', {'command': 'ls'});
      expect(
        homeChatApprovals([chat], chatKey: (_) => null, whereOf: (_) => ''),
        isEmpty,
      );
    });
  });

  group('questions', () {
    late ActiveChatService chats;
    final connection = SavedConnection(
      id: 'c1',
      label: 'QA',
      host: '127.0.0.2',
      port: 8642,
      apiKey: 'k',
    );

    setUp(() => chats = ActiveChatService(attachDesktopRuntimeOnLoad: false));
    tearDown(() => chats.dispose());

    ActiveChat attach(String id) => chats.attach(
      connection: connection,
      sessionId: id,
      sessionTitle: 'Chat $id',
      sessionProfile: 'astra',
      disableForegroundKeepAlive: true,
    );

    InteractivePromptEntry clarify(
      String id, {
      String question = '¿Uso Sonnet 5.5 como modelo de reserva?',
      List<String> choices = const ['Sí, úsalo', 'No'],
      bool multiSelect = false,
      List<ClarifyQuestion> questions = const [],
    }) {
      final key = InteractivePromptKey(
        runtimeSessionId: 'rt-$id',
        requestId: id,
      );
      return InteractivePromptEntry(
        key: key,
        status: InteractivePromptStatus.pending,
        request: ClarifyPromptRequest(
          key: key,
          question: question,
          choices: choices,
          multiSelect: multiSelect,
          questions: questions,
        ),
      );
    }

    List<HomeQuestionItem> questions(
      Map<ActiveChat, InteractivePromptEntry?> prompts, {
      bool readOnly = false,
    }) => homeChatQuestions(
      prompts.keys,
      chatKey: (chat) => 'key-${chat.sessionId}',
      whereOf: (chat) => chat.sessionTitle,
      actorOf: (_) => 'Astra',
      readOnly: readOnly,
      promptOf: (chat) => prompts[chat],
    );

    test(
      'the question of an attached chat, with the choices Home can send',
      () {
        final chat = attach('s1');
        final item = questions({
          chat: clarify('q1'),
          attach('s2'): null,
        }).single;
        expect(item.key, 'chat:s1:q1');
        expect(item.sessionKey, 'key-s1');
        expect(item.where, 'Chat s1');
        expect(item.actor, 'Astra');
        expect(item.profileName, 'astra');
        expect(item.question, '¿Uso Sonnet 5.5 como modelo de reserva?');
        expect(item.choices, ['Sí, úsalo', 'No']);
        final ref = item.ref as HomeChatQuestionRef;
        expect(identical(ref.chat, chat), isTrue);
        expect(ref.prompt.requestId, 'q1');
      },
    );

    test('no choices when the answer is free text, several can be picked, '
        'or the connection is read-only: it is answered in the chat', () {
      final open = questions({attach('s1'): clarify('q1', choices: const [])});
      expect(open.single.choices, isEmpty);
      final many = questions({attach('s2'): clarify('q2', multiSelect: true)});
      expect(many.single.choices, isEmpty);
      final locked = questions({attach('s3'): clarify('q3')}, readOnly: true);
      expect(locked.single.choices, isEmpty);
      expect(locked.single.question, isNotEmpty);
    });

    test('a batch of questions, a prompt without text or one that is not a '
        'question is not Home\'s to list', () {
      final batch = clarify(
        'q1',
        questions: const [
          ClarifyQuestion(qid: 'a', question: '¿Uno?'),
          ClarifyQuestion(qid: 'b', question: '¿Dos?'),
        ],
      );
      final empty = clarify('q2', question: '  ');
      final key = InteractivePromptKey(runtimeSessionId: 'rt', requestId: 'q3');
      final settled = InteractivePromptEntry(
        key: key,
        status: InteractivePromptStatus.pending,
        request: null,
      );
      expect(
        questions({
          attach('s1'): batch,
          attach('s2'): empty,
          attach('s3'): settled,
        }),
        isEmpty,
      );
    });

    test(
      'an answer is refused once the chat waits on something else',
      () async {
        final chat = attach('s1');
        final item = questions({chat: clarify('q1')}).single;
        // The chat itself has no pending prompt (it was answered elsewhere).
        expect(chat.pendingInteractivePrompt, isNull);
        await expectLater(
          (item.ref as HomeChatQuestionRef).answer('No'),
          throwsStateError,
        );
      },
    );
  });

  group('automations', () {
    DateTime? parse(Object? raw) =>
        raw == null ? null : DateTime.tryParse(raw.toString());

    test('a failed last run is red', () {
      final jobs = homeAutomations([
        _job({'last_status': 'error'}),
        _job({'id': 'j2', 'state': 'error'}),
        _job({'id': 'j3', 'last_status': 'ok'}),
      ], parseTime: parse);
      expect(jobs.map((j) => j.failed), [true, true, false]);
      expect(jobs.map((j) => j.lastRunOk), [false, false, true]);
    });

    test('a paused job has no next run', () {
      final jobs = homeAutomations([
        _job({'state': 'paused', 'next_run_at': '2026-10-06T18:00:00'}),
        _job({'id': 'j2', 'next_run_at': '2026-10-06T18:00:00'}),
      ], parseTime: parse);
      expect(jobs.first.nextRun, isNull);
      expect(jobs.first.enabled, isFalse);
      expect(jobs.last.nextRun, DateTime(2026, 10, 6, 18));
      expect(jobs.last.name, 'Backup');
    });

    test('a job that repeats on an interval says every how long; a clock '
        'schedule does not', () {
      final jobs = homeAutomations([
        _job({
          'schedule': {'kind': 'interval', 'minutes': 360},
        }),
        _job({
          'id': 'j2',
          'schedule': {'kind': 'cron', 'expr': '*/30 * * * *'},
        }),
        _job({
          'id': 'j3',
          'schedule': {'kind': 'cron', 'expr': '0 3 * * *'},
        }),
        _job({'id': 'j4'}),
      ], parseTime: parse);
      expect(jobs.map((j) => j.everyMinutes), [360, 30, null, null]);
    });
  });

  group('Kanban tasks', () {
    KanbanTask task(String id, String status, {String? assignee}) =>
        KanbanTask.fromJson({
          'id': id,
          'title': 'Tarea $id',
          'status': status,
          'assignee': ?assignee,
        });

    test('what runs; then what waits: blocked and in review first, then '
        'queued, then notes; done and archived are not Home\'s', () {
      final tasks = homeTasks(
        KanbanBoard(
          columns: [
            KanbanColumn(
              name: 'todo',
              tasks: [
                task('note', 'todo'),
                task('queued', 'ready', assignee: 'astra'),
              ],
            ),
            KanbanColumn(
              name: 'running',
              tasks: [
                task('r1', 'running', assignee: 'forja'),
                task('r2', 'running'),
              ],
            ),
            KanbanColumn(
              name: 'blocked',
              tasks: [
                task('b', 'blocked', assignee: 'radar'),
                task('rev', 'review'),
              ],
            ),
            KanbanColumn(
              name: 'done',
              tasks: [task('d', 'done'), task('arch', 'archived')],
            ),
          ],
        ),
      );
      expect(tasks.running.map((t) => t.key), ['r1', 'r2']);
      expect(tasks.running.map((t) => t.assignee), ['forja', null]);
      expect(tasks.pending.map((t) => t.key), ['b', 'rev', 'queued', 'note']);
      expect(tasks.pending.map((t) => t.attention), [true, true, false, false]);
      expect(tasks.running.first.title, 'Tarea r1');
      expect(tasks.running.first.ref, isA<KanbanTask>());
      expect(tasks.isEmpty, isFalse);
    });

    test('an empty board is empty; a task without a title goes by its id', () {
      expect(homeTasks(const KanbanBoard(columns: [])).isEmpty, isTrue);
      final tasks = homeTasks(
        KanbanBoard(
          columns: [
            KanbanColumn(
              name: 'running',
              tasks: [
                KanbanTask.fromJson({'id': 't9', 'status': 'running'}),
              ],
            ),
          ],
        ),
      );
      expect(tasks.running.single.title, 't9');
    });
  });

  group('what a chat is doing, in Home\'s words', () {
    final s = StringsEs();
    SessionLiveStatus status(
      SessionLivePhase phase, {
      String? tool,
      int subagents = 0,
    }) => SessionLiveStatus(
      phase: phase,
      toolLabel: tool,
      subagentCount: subagents,
    );

    test('the tool, the subagents, the background work; nothing while it '
        'only thinks or writes', () {
      expect(
        homeStepLabel(
          s,
          status(SessionLivePhase.runningTool, tool: 'terminal'),
        ),
        'Ejecutando comando',
      );
      expect(
        homeStepLabel(s, status(SessionLivePhase.delegated, subagents: 2)),
        '2 subagentes',
      );
      expect(
        homeStepLabel(s, status(SessionLivePhase.delegated)),
        '1 subagente',
      );
      expect(
        homeStepLabel(s, status(SessionLivePhase.background)),
        'Segundo plano',
      );
      expect(homeStepLabel(s, status(SessionLivePhase.runningTool)), isNull);
      for (final phase in const [
        SessionLivePhase.thinking,
        SessionLivePhase.responding,
        SessionLivePhase.working,
        SessionLivePhase.idle,
      ]) {
        expect(homeStepLabel(s, status(phase)), isNull, reason: '$phase');
      }
    });

    test('a tool announced by its wire name goes by its registered one', () {
      expect(homeToolLabel(s, 'mcp__terminal'), 'Ejecutando comando');
      expect(homeToolLabel(s, '  '), isNull);
      expect(homeToolLabel(s, null), isNull);
    });
  });

  group('bots: what each one did last', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1790000600 * 1000);

    Session chat(String id, String title, int at, {String? said}) => Session(
      id: id,
      title: title,
      model: 'm',
      source: 'mobile',
      messageCount: 4,
      isActive: false,
      preview: '',
      startedAt: at.toDouble(),
      profile: 'astra',
      lastAssistantPreview: said,
    );

    test('a free bot carries the title and time of its newest chat; without '
        'the Bots list there is none', () {
      final without = homeBoardBots(
        profiles: spec070Profiles(),
        activeSessions: const [],
        liveChats: const [],
        now: now,
      );
      final before = without.singleWhere((b) => b.profileName == 'astra');
      expect(before.lastTitle, isNull);
      expect(before.lastAt, isNull);

      final team = homeBoardBots(
        profiles: spec070Profiles(),
        sessions: [
          chat('old', 'Revisar disco', 1790000000),
          chat('new', 'Carga del NAS', 1790000300),
        ],
        activeSessions: const [],
        liveChats: const [],
        now: now,
      );
      final astra = team.singleWhere((b) => b.profileName == 'astra');
      expect(astra.state, HomeBotState.idle);
      expect(astra.lastTitle, 'Carga del NAS');
      expect(
        astra.lastAt,
        DateTime.fromMillisecondsSinceEpoch(1790000300 * 1000),
      );
      // The chats of other profiles are not its work.
      expect(
        team.where((b) => b.profileName != 'astra').map((b) => b.lastTitle),
        everyElement(isNull),
      );
    });

    test('its one Bot Chat goes by the last thing it said', () {
      final team = homeBoardBots(
        profiles: spec070Profiles(),
        sessions: [
          chat(
            '20260901_120000_astra1',
            'Bot Chat',
            1790000400,
            said: 'Disco al 93 %, sin cambios.',
          ),
          chat('task', 'Revisar disco', 1790000100),
        ],
        activeSessions: const [],
        liveChats: const [],
        now: now,
      );
      final astra = team.singleWhere((b) => b.profileName == 'astra');
      expect(astra.lastTitle, 'Disco al 93 %, sin cambios.');
    });

    test('an untitled run of a bot goes by its generic name in the app '
        'language, never in the Spanish of the model', () {
      Session run(String id, int at) => Session(
        id: id,
        title: '',
        model: 'm',
        source: 'cron',
        messageCount: 6,
        isActive: false,
        preview: '',
        startedAt: at.toDouble(),
        profile: 'astra',
      );

      HomeBoardBot astra(Strings strings) => homeBoardBots(
        profiles: spec070Profiles(),
        sessions: [run('local-run', 1790000300)],
        activeSessions: const [],
        liveChats: const [],
        now: now,
        strings: strings,
      ).singleWhere((b) => b.profileName == 'astra');

      expect(astra(StringsEn()).lastTitle, 'Scheduled task');
      expect(astra(StringsEs()).lastTitle, 'Tarea programada');

      // A caller with no screen keeps the model's own fallback; Home always
      // passes the app language.
      final withoutStrings = homeBoardBots(
        profiles: spec070Profiles(),
        sessions: [run('local-run', 1790000300)],
        activeSessions: const [],
        liveChats: const [],
        now: now,
      );
      expect(
        withoutStrings.singleWhere((b) => b.profileName == 'astra').lastTitle,
        'Tarea programada',
      );
    });

    test('a working bot never uses the session start as its turn clock', () {
      final started = now.subtract(const Duration(seconds: 134));
      final team = homeBoardBots(
        profiles: spec070Profiles(),
        activeSessions: [
          DesktopActiveSession(
            runtimeSessionId: 'rt-astra',
            storedSessionId: '20260901_120000_astra1',
            status: 'working',
            title: 'Bot Chat',
            startedAt: started,
          ),
        ],
        liveChats: const [],
        now: now,
      );
      final astra = team.singleWhere((b) => b.profileName == 'astra');
      expect(astra.state, HomeBotState.working);
      expect(astra.since, isNull);
    });
  });

  group('rooms: the turn, in order', () {
    test('who replies carries its profile, the newest line its time, and '
        'who is next is never the one replying', () {
      final rooms = homeBoardRooms(
        _groups(),
        acksFor: (_) => const RoomAttentionAcks(seenSeq: 2),
      );
      final room = rooms.single;
      expect(room.respondingProfiles.length, room.responding.length);
      expect(room.live, room.responding.isNotEmpty);
      expect(room.lastAt, isNotNull);
      for (final profile in room.respondingProfiles) {
        expect(room.memberProfiles, contains(profile));
      }
      if (room.next case final next?) {
        expect(room.responding, isNot(contains(next)));
      }
    });
  });
}
