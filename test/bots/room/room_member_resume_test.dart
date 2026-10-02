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

/// Fake hosted gateway mirroring upstream for a member whose runtime is
/// gone: `session.active_list` lists only the runtimes that exist, the
/// exact-title `session.list` finds each member's durable room session, and
/// `session.resume` (`methods_session.py`) registers a live runtime for it.
final class _Rpc {
  final List<(String, Map<String, dynamic>)> calls = [];

  /// stored id -> (runtime id, status) of the live runtimes.
  final Map<String, (String, String)> live = {
    'stored-builder': ('rt-builder', 'idle'),
  };
  final Map<String, String> storedByProfile = {
    'review': 'stored-review',
    'builder': 'stored-builder',
  };
  bool resumeFails = false;
  Completer<void>? resumeGate;

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, params));
    switch (method) {
      case 'session.active_list':
        return {
          'sessions': [
            for (final e in live.entries)
              {
                'id': e.value.$1,
                'session_key': e.key,
                'status': e.value.$2,
                'title': 'Group: $roomId',
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
      case 'session.resume':
        await resumeGate?.future;
        if (resumeFails) throw StateError('resume failed');
        final stored = params['session_id'] as String;
        live[stored] = ('rt-new', 'idle');
        return {'session_id': 'rt-new', 'resumed': stored, 'status': 'idle'};
    }
    throw StateError('unexpected $method');
  }

  List<(String, Map<String, dynamic>)> get resumes => [
    for (final c in calls)
      if (c.$1 == 'session.resume') c,
  ];
  List<String> get methods => [for (final c in calls) c.$1];
}

final class _RoomGateway implements RoomGateway {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  final RoomDriverStatus status;
  int reads = 0;
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
const _shotKey = ValueKey('rr1215-shot');
const _banner = ValueKey('room-member-stall-m-review');
const _resume = ValueKey('room-member-stall-m-review-resume');

/// The owner's incident: `@review` is due, the driver works (one queued
/// task, re-deferred), the log has not moved for [quiet].
Future<_RoomGateway> _pump(
  WidgetTester tester,
  _Rpc rpc, {
  Duration quiet = const Duration(minutes: 5),
  bool working = true,
  bool settled = false,
  bool deferred = false,
  RoomCapabilities caps = _caps,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(412 * 3, 915 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final u = seq.user('@review revisa el PR y publica');
  final events = [u];
  if (settled) {
    final reply = seq.member(
      'm-review',
      'review',
      'Revisado.',
      u['event_id'] as String,
    );
    events
      ..add(reply)
      ..add(
        seq.settled(
          'm-review',
          u['event_id'] as String,
          messageId: reply['event_id'] as String,
        ),
      );
  }
  if (deferred) {
    // `turn.deferred` (reason member_unavailable) without a retry offer:
    // the round shows the member as queued.
    events.add({
      ...seq.started('m-review', u['event_id'] as String),
      'kind': 'turn.deferred',
      'event_id': 'turn.deferred-${seq.seq}',
    });
    final payload = Map<String, dynamic>.from(events.last['payload'] as Map)
      ..['seen_through_seq'] = 1
      ..['execution_generation'] = 1
      ..['reason'] = 'member_unavailable';
    events.last['payload'] = payload;
  }
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  final status = driver(
    working: working,
    counts: working ? const {'queued': 1} : const {},
  );
  final gateway = _RoomGateway(room, log, status);
  final last = (events.last['created_at'] as double) * 1000;
  final now = DateTime.fromMillisecondsSinceEpoch(last.round()).add(quiet);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        locale: const Locale('es'),
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
          pollTimer: (_, _) => _NoTimer(),
          clock: () => now,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
  return gateway;
}

Future<void> _tapResumeAndConfirm(WidgetTester tester) async {
  await tester.tap(find.byKey(_resume));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(find.byKey(const ValueKey('hermes-confirm-dialog-confirm')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

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

void main() {
  setUpAll(loadInterFont);

  testWidgets('due member without a live runtime: banner, nothing written', (
    tester,
  ) async {
    final rpc = _Rpc();
    await _pump(tester, rpc);
    expect(find.byKey(_banner), findsOneWidget);
    expect(
      find.text('console-review no puede retomar su turno'),
      findsOneWidget,
    );
    expect(find.byKey(_resume), findsOneWidget);
    expect(rpc.resumes, isEmpty);
    expect(rpc.calls.where((c) => c.$1 == 'session.list').last.$2, {
      'profile': 'review',
      'title': 'Group: $roomId',
      'include_hidden': true,
    });
  });

  testWidgets('a task younger than two minutes is not probed', (tester) async {
    final rpc = _Rpc();
    await _pump(tester, rpc, quiet: const Duration(seconds: 119));
    expect(find.byKey(_banner), findsNothing);
    expect(rpc.methods, isNot(contains('session.list')));
  });

  testWidgets('the member runtime is alive: no banner', (tester) async {
    final rpc = _Rpc()..live['stored-review'] = ('rt-review', 'idle');
    await _pump(tester, rpc);
    expect(find.byKey(_banner), findsNothing);
  });

  testWidgets('idle room: no banner and no reads', (tester) async {
    final rpc = _Rpc();
    await _pump(tester, rpc, working: false);
    expect(find.byKey(_banner), findsNothing);
    expect(rpc.calls, isEmpty);
  });

  testWidgets('a deferred turn in an idle room is never flagged', (
    tester,
  ) async {
    final rpc = _Rpc();
    await _pump(tester, rpc, working: false, deferred: true);
    expect(find.byKey(_banner), findsNothing);
    expect(rpc.methods, isNot(contains('session.list')));
  });

  testWidgets('a member whose turn is terminal is never flagged', (
    tester,
  ) async {
    final rpc = _Rpc();
    await _pump(tester, rpc, settled: true);
    expect(find.byKey(_banner), findsNothing);
    expect(rpc.methods, isNot(contains('session.list')));
  });

  testWidgets('another member of the room executing: no banner', (
    tester,
  ) async {
    final rpc = _Rpc()..live['stored-builder'] = ('rt-builder', 'working');
    await _pump(tester, rpc);
    expect(find.byKey(_banner), findsNothing);
  });

  testWidgets('backing out of the confirmation sends nothing', (tester) async {
    final rpc = _Rpc();
    await _pump(tester, rpc);
    await tester.tap(find.byKey(_resume));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsOneWidget);
    expect(find.text('¿Reanudar a console-review?'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(rpc.resumes, isEmpty);
    expect(find.byKey(_banner), findsOneWidget);
  });

  testWidgets('resume sends the exact session once and clears after re-read', (
    tester,
  ) async {
    final rpc = _Rpc();
    final gateway = await _pump(tester, rpc);
    final readsBefore = gateway.reads;
    await _tapResumeAndConfirm(tester);
    expect(rpc.resumes, hasLength(1));
    expect(rpc.resumes.single.$2, {
      'session_id': 'stored-review',
      'profile': 'review',
      'source': 'bot_room',
      'omit_messages': true,
    });
    expect(gateway.reads, greaterThan(readsBefore));
    expect(find.byKey(_banner), findsNothing);
    expect(
      find.text('console-review vuelve a tener su sesión abierta'),
      findsOneWidget,
    );
    // Only that member's session: nothing else is written.
    expect(
      rpc.methods.toSet().difference({
        'session.active_list',
        'session.list',
        'session.resume',
      }),
      isEmpty,
    );
  });

  testWidgets('a failed resume says so and keeps the button', (tester) async {
    final rpc = _Rpc()..resumeFails = true;
    await _pump(tester, rpc);
    await _tapResumeAndConfirm(tester);
    expect(
      find.text('No se pudo reanudar a console-review. Inténtalo de nuevo.'),
      findsOneWidget,
    );
    expect(find.byKey(_banner), findsOneWidget);
    final button = tester.widget<TextButton>(find.byKey(_resume));
    expect(button.onPressed, isNotNull);
    rpc.resumeFails = false;
    await _tapResumeAndConfirm(tester);
    expect(rpc.resumes, hasLength(2));
    expect(find.byKey(_banner), findsNothing);
  });

  testWidgets('one resume in flight at a time', (tester) async {
    final rpc = _Rpc()..resumeGate = Completer<void>();
    await _pump(tester, rpc);
    await _tapResumeAndConfirm(tester);
    expect(rpc.resumes, hasLength(1));
    final button = tester.widget<TextButton>(find.byKey(_resume));
    expect(button.onPressed, isNull);
    await tester.tap(find.byKey(_resume), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsNothing);
    rpc.resumeGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(rpc.resumes, hasLength(1));
    expect(find.byKey(_banner), findsNothing);
  });

  testWidgets('read-only rooms explain the stall without a button', (
    tester,
  ) async {
    final rpc = _Rpc();
    await _pump(tester, rpc, caps: const RoomCapabilities(canSend: true));
    expect(find.byKey(_banner), findsOneWidget);
    expect(find.byKey(_resume), findsNothing);
    expect(
      find.text(
        'Necesitas una conexión con permiso de escritura para reanudarlo.',
      ),
      findsOneWidget,
    );
    expect(rpc.resumes, isEmpty);
  });

  group('captures 412x915 es', () {
    setUpAll(loadDesignFonts);
    for (final (mode, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      testWidgets('stall banner · $mode', (tester) async {
        final rpc = _Rpc();
        await _pump(tester, rpc, theme: theme);
        await _shot(tester, 'room_stall_banner_$mode');
        await tester.tap(find.byKey(_resume));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await _shot(tester, 'room_stall_confirm_$mode');
      });

      testWidgets('stall banner read-only · $mode', (tester) async {
        final rpc = _Rpc();
        await _pump(
          tester,
          rpc,
          theme: theme,
          caps: const RoomCapabilities(canSend: true),
        );
        await _shot(tester, 'room_stall_readonly_$mode');
      });
    }
  });
}
