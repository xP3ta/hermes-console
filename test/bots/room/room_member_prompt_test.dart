import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_member_prompts.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/design_shots.dart' show loadDesignFonts;
import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// Fake hosted gateway for the member-prompt RPCs. It mirrors the upstream
/// contract: `session.active_list` rows (`status: "waiting"` while a
/// server→client request is open), the exact-title `session.list` lookup of
/// the member's `Group: <room_id>` session, `session.events.since`
/// `open_requests`, and the answer methods settling the open request.
final class FakePromptGateway {
  final List<(String, Map<String, dynamic>)> calls = [];

  /// stored session id -> runtime id, per profile.
  final Map<String, String> storedByProfile = {
    'review': 'stored-review',
    'builder': 'stored-builder',
  };
  final Map<String, String> runtimeByStored = {
    'stored-review': 'rt-review',
    'stored-builder': 'rt-builder',
  };

  /// runtime -> open requests.
  final Map<String, List<Map<String, dynamic>>> open = {};

  /// When set, `session.events.since` fails for this runtime.
  final Set<String> replayFails = {};

  /// Runtimes whose status is `waiting` without a readable request.
  final Set<String> waitingOnly = {};
  bool answerFails = false;
  Completer<void>? answerGate;

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, params));
    switch (method) {
      case 'session.active_list':
        return {
          'sessions': [
            for (final entry in runtimeByStored.entries)
              {
                'id': entry.value,
                'session_key': entry.key,
                'current': false,
                'status':
                    (open[entry.value]?.isNotEmpty ?? false) ||
                        waitingOnly.contains(entry.value)
                    ? 'waiting'
                    : 'working',
              },
          ],
        };
      case 'session.list':
        final stored = storedByProfile[params['profile']];
        if (params['title'] != 'Group: $roomId' || stored == null) {
          return {'sessions': const []};
        }
        return {
          'sessions': [
            {'id': stored, 'title': 'Group: $roomId'},
          ],
        };
      case 'session.events.since':
        final runtime = params['session_id'] as String;
        if (replayFails.contains(runtime)) {
          throw StateError('replay unavailable');
        }
        return {
          'events': const [],
          'latest_seq': 4,
          'truncated': false,
          'count': 0,
          'epoch': 'e1',
          'open_requests': [...?open[runtime]],
        };
      case 'request.answer':
      case 'clarify.lock':
      case 'approval.respond':
        await answerGate?.future;
        if (answerFails) throw StateError('rejected');
        final id = method == 'request.answer'
            ? params['id']
            : params['request_id'];
        for (final list in open.values) {
          list.removeWhere(
            (r) =>
                r['id'] == id ||
                (r['params'] as Map)['request_id'] == params['request_id'],
          );
        }
        return {'status': 'ok'};
      case 'session.interrupt':
        open.remove(params['session_id']);
        waitingOnly.remove(params['session_id']);
        return {'status': 'interrupted'};
    }
    throw StateError('unexpected $method');
  }

  List<String> get methods => [for (final c in calls) c.$1];
  Iterable<(String, Map<String, dynamic>)> writes() => calls.where(
    (c) => const {
      'request.answer',
      'clarify.lock',
      'approval.respond',
      'session.interrupt',
    }.contains(c.$1),
  );
}

final class _RoomGateway implements RoomGateway {
  HostedGroupRoom room;
  HostedGroupLogPage log;
  RoomDriverStatus? status;
  int reads = 0;
  Completer<void>? readGate;
  _RoomGateway(this.room, this.log, this.status);

  HostedGroupWorkspaceReadback get _rb => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    reads++;
    await readGate?.future;
    return _rb;
  }

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async => _rb;

  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async => _rb;

  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async => _rb;

  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async =>
      _rb;

  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {}

  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {}
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

const _caps = RoomCapabilities(
  canSend: true,
  canStop: true,
  canApprove: true,
  canAnswerPrompts: true,
);

Map<String, dynamic> clarifyRequest({
  String id = 'srq-1',
  String question = '¿Publico la release 1.2.11 ahora?',
  List<String> choices = const ['Sí', 'No, espera'],
}) => {
  'id': id,
  'method': 'clarify',
  'params': {
    'session_id': 'rt-review',
    'question': question,
    'choices': choices,
  },
};

Future<(FakePromptGateway, _RoomGateway, List<(HostedGroupMember, String)>)>
pumpRoom(
  WidgetTester tester, {
  required FakePromptGateway rpc,
  bool working = true,
  RoomCapabilities caps = _caps,
  ThemeData? theme,
  Locale locale = const Locale('es'),
  List<Map<String, dynamic>> pending = const [],
}) async {
  tester.view.physicalSize = const Size(412 * 3, 915 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final u = seq.user('@review revisa el PR y publica');
  final events = [u, seq.started('m-review', u['event_id'] as String)];
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  final status = driver(
    working: working,
    counts: working ? const {'running': 1} : const {},
    pending: pending,
  );
  final gateway = _RoomGateway(room, log, status);
  final opened = <(HostedGroupMember, String)>[];
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        locale: locale,
        theme: theme ?? AppTheme.hermesRedDark,
        home: RoomScreen(
          room: room,
          log: log,
          driverStatus: status,
          gateway: gateway,
          capabilities: caps,
          profileFor: (_) => null,
          prefs: MemoryRoomPrefs(),
          memberPrompts: GatewayRoomMemberPrompts(rpc.call),
          onOpenMemberChat: (member, stored) => opened.add((member, stored)),
          pollTimer: (_, _) => _NoTimer(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
  return (rpc, gateway, opened);
}

const _shotKey = ValueKey('rq1215-shot');

/// Writes `<name>.png` (412×915 logical) when `DESIGN_SHOTS_DIR` is set.
Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['DESIGN_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 300));
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void expectCall(
  (String, Map<String, dynamic>) call,
  String method,
  Map<String, Object?> params,
) {
  expect(call.$1, method);
  expect(call.$2, equals(params));
}

Future<void> refresh(WidgetTester tester) async {
  await tester.state<RoomScreenState>(find.byType(RoomScreen)).refresh();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> openRoundDetail(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('room-status-strip')));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadInterFont);

  group('GatewayRoomMemberPrompts', () {
    test('reads only, with the exact upstream methods and payloads', () async {
      final rpc = FakePromptGateway()..open['rt-review'] = [clarifyRequest()];
      final prompts = await GatewayRoomMemberPrompts(
        rpc.call,
      ).probe(buildRoom());
      expect(prompts, hasLength(1));
      final clarify = prompts.single as RoomMemberClarify;
      expect(clarify.memberId, 'm-review');
      expect(clarify.runtimeSessionId, 'rt-review');
      expect(clarify.storedSessionId, 'stored-review');
      expect(clarify.requestId, 'srq-1');
      expect(clarify.choices, ['Sí', 'No, espera']);
      expect(rpc.writes(), isEmpty);
      expectCall(rpc.calls.first, 'session.active_list', <String, dynamic>{});
      expect(rpc.calls.where((c) => c.$1 == 'session.list').first.$2, {
        'profile': 'builder',
        'title': 'Group: $roomId',
        'include_hidden': true,
      });
      final replays = rpc.calls
          .where((c) => c.$1 == 'session.events.since')
          .toList();
      expect(replays, hasLength(1));
      expectCall(replays.single, 'session.events.since', {
        'session_id': 'rt-review',
        'last_seen': roomPromptProbeLastSeen,
      });
    });

    test('nobody waiting: one active_list read and nothing else', () async {
      final rpc = FakePromptGateway();
      final prompts = await GatewayRoomMemberPrompts(
        rpc.call,
      ).probe(buildRoom());
      expect(prompts, isEmpty);
      expect(rpc.methods, ['session.active_list']);
    });

    test(
      'a waiting session that is not a member of this room is ignored',
      () async {
        final rpc = FakePromptGateway()
          ..runtimeByStored['stored-other'] = 'rt-other'
          ..open['rt-other'] = [clarifyRequest()];
        final prompts = await GatewayRoomMemberPrompts(
          rpc.call,
        ).probe(buildRoom());
        expect(prompts, isEmpty);
      },
    );

    test('batch clarify shows the first unlocked question', () async {
      final rpc = FakePromptGateway()
        ..open['rt-review'] = [
          {
            'id': 'srq-b',
            'method': 'clarify',
            'params': {
              'session_id': 'rt-review',
              'questions': [
                {
                  'qid': 'q1',
                  'question': 'Rama',
                  'choices': ['main'],
                },
                {'qid': 'q2', 'question': 'Versión', 'choices': null},
              ],
              'answers': {'q1': 'main'},
            },
          },
        ];
      final prompt =
          (await GatewayRoomMemberPrompts(rpc.call).probe(buildRoom())).single
              as RoomMemberClarify;
      expect(prompt.questionId, 'q2');
      expect(prompt.index, 2);
      expect(prompt.total, 2);
      await GatewayRoomMemberPrompts(rpc.call).answerClarify(prompt, '1.2.11');
      expectCall(rpc.calls.last, 'clarify.lock', {
        'request_id': 'srq-b',
        'question_id': 'q2',
        'answer': '1.2.11',
      });
    });

    test('an approval already in driver_status is not duplicated', () async {
      final rpc = FakePromptGateway()
        ..open['rt-review'] = [
          {
            'id': 'srq-a',
            'method': 'approval',
            'params': {
              'session_id': 'rt-review',
              'request_id': 'apr-9',
              'command': 'git push',
            },
          },
        ];
      final prompts = await GatewayRoomMemberPrompts(
        rpc.call,
      ).probe(buildRoom(), skipApprovalIds: {'apr-9'});
      expect(prompts, isEmpty);
    });
  });

  testWidgets('clarify question appears with the bot name and choices', (
    tester,
  ) async {
    final rpc = FakePromptGateway()..open['rt-review'] = [clarifyRequest()];
    await pumpRoom(tester, rpc: rpc);
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsOneWidget,
    );
    expect(find.text('console-review te pregunta'), findsOneWidget);
    expect(find.text('¿Publico la release 1.2.11 ahora?'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1-choice-0')),
      findsOneWidget,
    );
    // The member row says it is waiting for you, not working.
    expect(find.text('console-review te necesita'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-typing-m-review')), findsNothing);
    await openRoundDetail(tester);
    expect(
      find.byKey(const ValueKey('room-round-chip-m-review-needsYou')),
      findsOneWidget,
    );
    expect(find.text('Esperando tu respuesta'), findsOneWidget);
    expect(rpc.writes(), isEmpty);
  });

  testWidgets('choosing an option answers with request.answer once', (
    tester,
  ) async {
    final rpc = FakePromptGateway()..open['rt-review'] = [clarifyRequest()];
    final (_, room, _) = await pumpRoom(tester, rpc: rpc);
    rpc.answerGate = Completer<void>();
    // Hold the room re-read: the card must leave on the answer itself.
    room.readGate = Completer<void>();
    final choice = find.byKey(
      const ValueKey('room-member-clarify-srq-1-choice-0'),
    );
    await tester.tap(choice);
    await tester.pump();
    await tester.tap(choice);
    await tester.pump();
    rpc.answerGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsNothing,
    );
    room.readGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final answers = rpc.writes().toList();
    expect(answers, hasLength(1));
    expectCall(answers.single, 'request.answer', {
      'id': 'srq-1',
      'result': {'answer': 'Sí'},
    });
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsNothing,
    );
    // The room resumes: the member is working again on the next read.
    await refresh(tester);
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('room-typing-m-review')), findsOneWidget);
  });

  testWidgets('free text answers the open question', (tester) async {
    final rpc = FakePromptGateway()
      ..open['rt-review'] = [clarifyRequest(choices: const [])];
    await pumpRoom(tester, rpc: rpc);
    await tester.enterText(
      find.byKey(const ValueKey('room-member-clarify-srq-1-text')),
      'Espera al QA',
    );
    await tester.tap(
      find.byKey(const ValueKey('room-member-clarify-srq-1-send')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectCall(rpc.writes().single, 'request.answer', {
      'id': 'srq-1',
      'result': {'answer': 'Espera al QA'},
    });
  });

  testWidgets('a rejected answer keeps the card and says so', (tester) async {
    final rpc = FakePromptGateway()..open['rt-review'] = [clarifyRequest()];
    await pumpRoom(tester, rpc: rpc);
    rpc.answerFails = true;
    await tester.tap(
      find.byKey(const ValueKey('room-member-clarify-srq-1-choice-1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsOneWidget,
    );
    expect(
      find.text('No se pudo enviar la respuesta. Inténtalo de nuevo.'),
      findsOneWidget,
    );
  });

  testWidgets('member approval answers with approval.respond', (tester) async {
    final rpc = FakePromptGateway()
      ..open['rt-review'] = [
        {
          'id': 'srq-a',
          'method': 'approval',
          'params': {
            'session_id': 'rt-review',
            'request_id': 'apr-7',
            'command': 'git push origin main',
            'choices': ['once', 'session', 'always', 'deny'],
          },
        },
      ];
    await pumpRoom(tester, rpc: rpc);
    expect(find.byKey(const ValueKey('room-approval-apr-7')), findsOneWidget);
    expect(find.text('git push origin main'), findsOneWidget);
    // Room approvals are once or deny, like the hosted room driver.
    expect(
      find.byKey(const ValueKey('room-approval-apr-7-always')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('room-approval-apr-7-deny')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectCall(rpc.writes().single, 'approval.respond', {
      'session_id': 'rt-review',
      'request_id': 'apr-7',
      'choice': 'deny',
    });
    expect(find.byKey(const ValueKey('room-approval-apr-7')), findsNothing);
  });

  testWidgets('unreachable wait shows an honest banner that opens the chat', (
    tester,
  ) async {
    final rpc = FakePromptGateway()..waitingOnly.add('rt-review');
    final (_, _, opened) = await pumpRoom(tester, rpc: rpc);
    expect(
      find.byKey(const ValueKey('room-member-waiting-m-review')),
      findsOneWidget,
    );
    expect(
      find.text(
        'console-review está esperando una respuesta que la sala no puede mostrar',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('room-member-waiting-m-review-open')),
    );
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single.$1.memberId, 'm-review');
    expect(opened.single.$2, 'stored-review');
    expect(rpc.writes(), isEmpty);
  });

  testWidgets('a replay failure degrades to the banner, never a guess', (
    tester,
  ) async {
    final rpc = FakePromptGateway()
      ..open['rt-review'] = [clarifyRequest()]
      ..replayFails.add('rt-review');
    await pumpRoom(tester, rpc: rpc);
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('room-member-waiting-m-review')),
      findsOneWidget,
    );
  });

  testWidgets('cancel wait asks first and interrupts only that runtime', (
    tester,
  ) async {
    final rpc = FakePromptGateway()..waitingOnly.add('rt-review');
    await pumpRoom(tester, rpc: rpc);
    final cancel = find.byKey(
      const ValueKey('room-member-waiting-m-review-cancel'),
    );
    await tester.tap(cancel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsOneWidget);
    // Backing out sends nothing.
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(rpc.writes(), isEmpty);

    await tester.tap(cancel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final writes = rpc.writes().toList();
    expect(writes, hasLength(1));
    expect(writes.single.$1, 'session.interrupt');
    expect(writes.single.$2['session_id'], 'rt-review');
    expect(writes.single.$2['expected_hosted_task_id'], 'task-m-review-0');
    expect(rpc.methods, isNot(contains('session.close')));
    expect(
      find.byKey(const ValueKey('room-member-waiting-m-review')),
      findsNothing,
    );
  });

  testWidgets('idle room: no prompt reads, no card, no banner', (tester) async {
    final rpc = FakePromptGateway();
    await pumpRoom(tester, rpc: rpc, working: false);
    expect(rpc.calls, isEmpty);
    expect(find.textContaining('te pregunta'), findsNothing);
    expect(find.textContaining('Esperando tu respuesta'), findsNothing);
  });

  testWidgets('working room with nobody waiting shows nothing extra', (
    tester,
  ) async {
    final rpc = FakePromptGateway();
    await pumpRoom(tester, rpc: rpc);
    expect(rpc.methods, ['session.active_list']);
    expect(find.textContaining('te pregunta'), findsNothing);
    expect(find.textContaining('no puede mostrar'), findsNothing);
    expect(find.byKey(const ValueKey('room-typing-m-review')), findsOneWidget);
  });

  testWidgets('read-only rooms show the question without answer controls', (
    tester,
  ) async {
    final rpc = FakePromptGateway()..open['rt-review'] = [clarifyRequest()];
    await pumpRoom(
      tester,
      rpc: rpc,
      caps: const RoomCapabilities(canSend: true),
    );
    expect(
      find.byKey(const ValueKey('room-member-clarify-srq-1')),
      findsOneWidget,
    );
    final button = tester.widget<TextButton>(
      find.descendant(
        of: find.byKey(const ValueKey('room-member-clarify-srq-1-choice-0')),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  group('captures 412x915 es', () {
    setUpAll(loadDesignFonts);
    for (final (mode, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      testWidgets('clarify card · $mode', (tester) async {
        final rpc = FakePromptGateway()..open['rt-review'] = [clarifyRequest()];
        await pumpRoom(tester, rpc: rpc, theme: theme);
        await _shot(tester, 'room_clarify_$mode');
        await openRoundDetail(tester);
        await _shot(tester, 'room_clarify_detail_$mode');
      });

      testWidgets('approval card · $mode', (tester) async {
        final rpc = FakePromptGateway()
          ..open['rt-review'] = [
            {
              'id': 'srq-a',
              'method': 'approval',
              'params': {
                'session_id': 'rt-review',
                'request_id': 'apr-7',
                'command': 'gh release create v1.2.11 --draft',
              },
            },
          ];
        await pumpRoom(tester, rpc: rpc, theme: theme);
        await _shot(tester, 'room_approval_$mode');
      });

      testWidgets('unreachable banner · $mode', (tester) async {
        final rpc = FakePromptGateway()..waitingOnly.add('rt-review');
        await pumpRoom(tester, rpc: rpc, theme: theme);
        await _shot(tester, 'room_waiting_banner_$mode');
        await tester.tap(
          find.byKey(const ValueKey('room-member-waiting-m-review-cancel')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await _shot(tester, 'room_cancel_wait_confirm_$mode');
      });
    }
  });
}
