import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/desktop_projection_rooms.dart';
import 'package:hermes_android/core/bots/ui/room/desktop_projection_room_screen.dart';
import 'package:hermes_android/core/bots/ui/room/room_dictation.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_selection_area.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

final class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

final class FakeRoomGateway implements RoomGateway {
  HostedGroupRoom room;
  HostedGroupLogPage log;
  RoomDriverStatus? status;
  final List<(String, Map<String, Object?>)> calls = [];
  Completer<void>? approveGate;

  /// When true, a successful approve leaves [status] as it was (the server
  /// acknowledged the answer but still lists the approval).
  bool approveKeepsStatus = false;

  FakeRoomGateway({required this.room, required this.log, this.status});

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    calls.add(('read', {}));
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async {
    calls.add(('send', {'text': text, 'thread': attempt.threadId}));
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async {
    calls.add(('rename', {'name': name}));
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async {
    calls.add(('stop', {}));
    status = driver();
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async {
    calls.add(('disband', {}));
    this.room = buildRoom(disbanded: true, revision: 2);
    return _readback;
  }

  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {
    calls.add(('approve', {'choice': choice, 'request': action.requestId}));
    await approveGate?.future;
    if (!approveKeepsStatus) status = driver();
  }

  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {
    calls.add(('retry', {'task': taskId}));
    status = driver();
  }

  List<String> get methods => [for (final c in calls) c.$1];
}

final class FakeActions implements RoomAttachmentActions {
  final List<String> calls = [];
  @override
  bool canFetch(RoomAttachmentRef ref) => true;
  @override
  Future<File> fetch(RoomAttachmentRef ref) async {
    calls.add('fetch:${ref.name}');
    return File('/tmp/${ref.name}');
  }

  @override
  Future<void> open(RoomAttachmentRef ref, File file) async =>
      calls.add('open:${ref.name}');
  @override
  Future<void> share(RoomAttachmentRef ref, File file) async =>
      calls.add('share:${ref.name}');
  @override
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) async {
    calls.add('save:${ref.name}');
    return ArtifactSaveResult.saved;
  }
}

final class _FakeDictation extends RoomDictation {
  bool _recording = false;
  @override
  bool get recording => _recording;
  set recording(bool value) {
    _recording = value;
    notifyListeners();
  }

  @override
  bool get transcribing => false;
  @override
  ValueListenable<double>? get level => null;
  @override
  Future<void> start({
    required String currentText,
    required ValueChanged<String> onText,
    required ValueChanged<RoomDictationFailure> onFailure,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

final class _Uploader implements RoomAttachmentUploader {
  @override
  Future<String?> upload(draft) async => '/srv/uploads/${draft.name}';
}

const _allCaps = RoomCapabilities(
  canSend: true,
  canRename: true,
  canStop: true,
  canDisband: true,
  canApprove: true,
  canRetry: true,
);

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('en'),
  theme: AppTheme.hermesRedDark,
  home: child,
);

Future<FakeRoomGateway> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  RoomDriverStatus? status,
  HostedGroupRoom? room,
  RoomCapabilities caps = _allCaps,
  RoomAttachmentActions? actions,
  RoomAttachmentUploader? uploader,
  RoomLocalPrefs? prefs,
  AgentProfile? Function(HostedGroupMember member)? profileFor,
  void Function(HostedGroupMember member)? onOpenMember,
  RoomDictation? dictation,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final log = buildLog(events);
  final resolvedRoom = room ?? buildRoom(latestSeq: log.latestSeq);
  final gateway = FakeRoomGateway(room: resolvedRoom, log: log, status: status);
  await tester.pumpWidget(
    _host(
      RoomScreen(
        room: resolvedRoom,
        log: log,
        driverStatus: status,
        gateway: gateway,
        capabilities: caps,
        profileFor: profileFor ?? (_) => null,
        onOpenMember: onOpenMember,
        prefs: prefs ?? MemoryRoomPrefs(),
        attachmentActions: actions,
        uploader: uploader,
        dictation: dictation,
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

const _richMarkdown = '''
## Suite complete

- 6607 pass
- analyze **clean**

```bash
flutter test --no-pub
```

| Severity | N |
| --- | --- |
| P0/P1 | 0 |
''';

/// Texts of the tappable spans (links) currently rendered.
Set<String> _linkTexts(WidgetTester tester) {
  final out = <String>{};
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        out.add(span.text ?? span.toPlainText());
      }
      return true;
    });
  }
  return out;
}

void main() {
  setUpAll(loadInterFont);

  testWidgets('group layout: one header per run, user bubble, no side rail', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('status? @builder');
    final disc = u['event_id'] as String;
    final first = seq.member('m-builder', 'builder', 'first', disc);
    final second = seq.member('m-builder', 'builder', 'second', disc);
    final third = seq.member('m-review', 'review', 'third', disc);
    await _pump(tester, events: [u, first, second, third]);

    expect(
      find.byKey(ValueKey('room-run-header-${first['event_id']}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('room-run-header-${second['event_id']}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('room-run-header-${third['event_id']}')),
      findsOneWidget,
    );
    expect(find.text('console-builder'), findsOneWidget);
    expect(
      find.byKey(ValueKey('room-user-bubble-${u['event_id']}')),
      findsOneWidget,
    );
    // The user bubble hugs the right edge.
    final bubble = tester.getRect(
      find.byKey(ValueKey('room-user-bubble-${u['event_id']}')),
    );
    expect(bubble.right, greaterThan(340));
    // Member cards carry no coloured side rail (no left border accent).
    final card = tester.widget<Container>(
      find.byKey(ValueKey('room-member-card-${first['event_id']}')),
    );
    final border = (card.decoration! as BoxDecoration).border! as Border;
    expect(border.left.color, border.top.color);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets(
    'room Markdown uses the chat renderer: no raw marks, table and code',
    (tester) async {
      final seq = EventSeq();
      final u = seq.user('report');
      final m = seq.member(
        'm-builder',
        'builder',
        _richMarkdown,
        u['event_id'] as String,
      );
      await _pump(tester, events: [u, m]);

      expect(find.byType(MarkdownTable), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
      expect(find.textContaining('## '), findsNothing);
      expect(find.textContaining('```'), findsNothing);
      // Message prose is never SelectableText (only the shared table cells,
      // exactly like the main chat renderer).
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SelectableText &&
              (w.data ?? w.textSpan?.toPlainText() ?? '').contains('6607'),
        ),
        findsNothing,
      );
      expect(find.byType(ChatMessageSelectionArea), findsWidgets);
    },
  );

  testWidgets(
    'tapping a long message never scrolls the transcript or the message',
    (tester) async {
      final seq = EventSeq();
      final u = seq.user('long');
      final long = List.generate(
        40,
        (i) => 'Line $i of a long answer.',
      ).join('\n\n');
      final m = seq.member(
        'm-builder',
        'builder',
        long,
        u['event_id'] as String,
      );
      await _pump(tester, events: [u, m]);
      final transcript = find.byKey(const ValueKey('room-transcript'));
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      final before = position.pixels;
      await tester.tap(find.text('Line 38 of a long answer.'));
      await tester.pumpAndSettle();
      expect(position.pixels, before);
      // No vertical scrollable inside the message card.
      final card = find.byKey(ValueKey('room-member-card-${m['event_id']}'));
      final inner = tester
          .widgetList<Scrollable>(
            find.descendant(of: card, matching: find.byType(Scrollable)),
          )
          .where(
            (s) =>
                s.axisDirection == AxisDirection.down ||
                s.axisDirection == AxisDirection.up,
          );
      expect(inner, isEmpty);
    },
  );

  testWidgets(
    'status strip: summary, floating per-member detail with chips, stop all',
    (tester) async {
      final seq = EventSeq();
      final u = seq.user('@builder @review @lead @radar ship it');
      final disc = u['event_id'] as String;
      final gateway = await _pump(
        tester,
        events: [
          u,
          seq.started('m-builder', disc),
          seq.started('m-lead', disc),
          seq.settled('m-radar', disc, passed: true),
        ],
        status: driver(
          working: true,
          counts: {'running': 2, 'queued': 1},
          pending: [approvalAction()],
        ),
      );
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey('room-strip-summary')),
      );
      // Someone needing you wins the one line.
      expect(summary.data, 'console-lead needs you');
      expect(
        find.byKey(const ValueKey('room-round-row-m-builder')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('room-status-strip')));
      // A working face animates forever: pump frames instead of settling.
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('room-round-chip-m-builder-working')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-round-chip-m-review-queued')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-round-chip-m-lead-needsYou')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-round-chip-m-radar-passed')),
        findsOneWidget,
      );
      expect(find.text('Wants to run gh pr ready 51'), findsOneWidget);
      expect(
        find.textContaining('Replying to your message · '),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('room-stop-all')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('hermes-confirm-dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(gateway.methods, contains('stop'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('approval card offers only server choices and answers once', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('@lead merge');
    final gateway = await _pump(
      tester,
      events: [u, seq.started('m-lead', u['event_id'] as String)],
      status: driver(working: true, pending: [approvalAction()]),
    );
    expect(
      find.byKey(const ValueKey('room-approval-apr-1-once')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-approval-apr-1-deny')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-approval-apr-1-always')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('room-approval-apr-1-session')),
      findsNothing,
    );

    gateway.approveGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('room-approval-apr-1-once')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('room-approval-apr-1-once')));
    await tester.tap(find.byKey(const ValueKey('room-approval-apr-1-deny')));
    await tester.pump();
    gateway.approveGate!.complete();
    await tester.pumpAndSettle();
    final approvals = gateway.calls.where((c) => c.$1 == 'approve').toList();
    expect(approvals, hasLength(1));
    expect(approvals.single.$2, {'choice': 'once', 'request': 'apr-1'});
    expect(find.byKey(const ValueKey('room-approval-apr-1')), findsNothing);
  });

  testWidgets(
    'approval card re-enables when the server still lists it after a successful answer',
    (tester) async {
      final seq = EventSeq();
      final u = seq.user('@lead merge');
      final gateway = await _pump(
        tester,
        events: [u, seq.started('m-lead', u['event_id'] as String)],
        status: driver(working: true, pending: [approvalAction()]),
      );
      gateway.approveKeepsStatus = true;
      final once = find.byKey(const ValueKey('room-approval-apr-1-once'));
      await tester.tap(once);
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        final state = tester.state<RoomScreenState>(find.byType(RoomScreen));
        await state.refresh();
        await tester.pumpAndSettle();
      }
      expect(gateway.calls.where((c) => c.$1 == 'approve'), hasLength(1));
      final button = tester.widget<TextButton>(
        find.descendant(of: once, matching: find.byType(TextButton)),
      );
      expect(button.onPressed, isNotNull);
    },
  );

  testWidgets('retry card calls groups.retry for the server-listed task', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('@radar check');
    final disc = u['event_id'] as String;
    final gateway = await _pump(
      tester,
      events: [
        u,
        seq.started('m-radar', disc, task: 'task-r'),
        seq.failed('m-radar', disc, task: 'task-r'),
      ],
      status: driver(
        blocked: true,
        pending: [
          {'kind': 'retry', 'task_id': 'task-r'},
        ],
      ),
    );
    expect(find.text('console-radar could not reply'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('room-retry-task-r-action')));
    await tester.pumpAndSettle();
    expect(gateway.calls.where((c) => c.$1 == 'retry').single.$2, {
      'task': 'task-r',
    });
  });

  testWidgets('failure card uses the same speaker name as the strip', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('@radar check');
    final disc = u['event_id'] as String;
    await _pump(
      tester,
      events: [
        u,
        seq.started('m-radar', disc, task: 'task-r'),
        seq.failed('m-radar', disc, task: 'task-r'),
      ],
      status: driver(
        blocked: true,
        pending: [
          {'kind': 'retry', 'task_id': 'task-r'},
        ],
      ),
      profileFor: (m) => m.handle == 'radar'
          ? AgentProfile(name: 'radar', botModeUiMeta: {'title': 'Radar'})
          : null,
    );
    expect(find.text('Radar could not reply'), findsOneWidget);
    expect(find.text('console-radar could not reply'), findsNothing);
  });

  testWidgets('mentions that cannot open anything are not rendered as links', (
    tester,
  ) async {
    final opened = <String>[];
    final seq = EventSeq();
    final u = seq.user('@builder @radar @all look');
    await _pump(
      tester,
      events: [u, seq.member('m-lead', 'lead', 'On it @builder @radar', 'd1')],
      // Only builder has a local profile Mission Control can open.
      profileFor: (m) =>
          m.handle == 'builder' ? AgentProfile(name: 'builder') : null,
      onOpenMember: (m) => opened.add(m.handle),
    );
    expect(_linkTexts(tester), {'@builder'});
    await tester.tapOnText(find.textRange.ofSubstring('@builder').first);
    await tester.pumpAndSettle();
    expect(opened, ['builder']);

    // The thread page offers the same working links.
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-threads')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-thread-thread-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-thread-page')), findsOneWidget);
    expect(_linkTexts(tester), {'@builder'});
    await tester.tapOnText(find.textRange.ofSubstring('@builder').first);
    await tester.pumpAndSettle();
    expect(opened, ['builder', 'builder']);
  });

  testWidgets('attachment suffix renders as a card with download/open/share', (
    tester,
  ) async {
    final seq = EventSeq();
    final text = appendRoomAttachmentSuffix('Here', const [
      RoomAttachmentRef(name: 'report.pdf', path: '/srv/uploads/report.pdf'),
    ]);
    final u = seq.user(text);
    final actions = FakeActions();
    await _pump(tester, events: [u], actions: actions);
    expect(find.textContaining('Attached files staged'), findsNothing);
    expect(find.textContaining('@file:'), findsNothing);
    expect(find.text('report.pdf'), findsOneWidget);
    const path = '/srv/uploads/report.pdf';
    await tester.tap(
      find.byKey(const ValueKey('room-attachment-download-$path')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-attachment-open-$path')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-attachment-share-$path')));
    await tester.pumpAndSettle();
    expect(actions.calls, [
      'fetch:report.pdf',
      'save:report.pdf',
      'open:report.pdf',
      'share:report.pdf',
    ]);
  });

  testWidgets(
    'shared composer: @ palette inserts a member and send carries it',
    (tester) async {
      final gateway = await _pump(
        tester,
        events: const [],
        uploader: _Uploader(),
      );
      expect(find.byType(ConsoleComposer), findsOneWidget);
      // No Bot Mode toggle / voice-mode pill in rooms.
      expect(find.byKey(const ValueKey('voice')), findsNothing);
      final field = find.descendant(
        of: find.byType(ConsoleComposer),
        matching: find.byType(TextField),
      );
      await tester.tap(field);
      await tester.enterText(field, 'hey @bu');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('room-mention-palette')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('room-mention-builder')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'hey @builder ');
      await tester.tap(
        find.byKey(const ValueKey('composer-primary-action-switcher')),
      );
      await tester.pumpAndSettle();
      expect(
        gateway.calls.where((c) => c.$1 == 'send').single.$2['text'],
        'hey @builder',
      );
      expect(
        find.byKey(const ValueKey('room-attach-disabled-reason')),
        findsNothing,
      );
    },
  );

  // Every keystroke and focus change rebuilt the whole RoomScreen (app
  // bar, status strip, transcript lookup); only the composer depends on
  // the text, the focus and the dictation state.
  testWidgets('typing and focus rebuild only the composer, not the screen', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('status? @builder');
    final reply = seq.member(
      'm-builder',
      'builder',
      'hello',
      u['event_id'] as String,
    );
    await _pump(tester, events: [u, reply], uploader: _Uploader());
    final strip = tester.widget(find.byType(RoomStatusStrip));
    final field = find.descendant(
      of: find.byType(ConsoleComposer),
      matching: find.byType(TextField),
    );
    await tester.tap(field);
    await tester.pump();
    for (final text in ['h', 'he', 'hey', 'hey ', 'hey @']) {
      await tester.enterText(field, text);
      await tester.pump();
    }
    expect(
      identical(tester.widget(find.byType(RoomStatusStrip)), strip),
      isTrue,
      reason: 'the screen above the composer was not rebuilt',
    );
    // The composer itself still follows the text: send enabled, palette.
    final composer = tester.widget<ConsoleComposer>(
      find.byType(ConsoleComposer),
    );
    expect(composer.sendEnabled, isTrue);
    expect(find.byKey(const ValueKey('room-mention-palette')), findsOneWidget);
    // Losing focus hides the palette without rebuilding the screen.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('room-mention-palette')), findsNothing);
    await tester.enterText(field, '');
    await tester.pump();
    expect(
      tester.widget<ConsoleComposer>(find.byType(ConsoleComposer)).sendEnabled,
      isFalse,
    );
    expect(
      identical(tester.widget(find.byType(RoomStatusStrip)), strip),
      isTrue,
    );
  });

  testWidgets('dictation state reaches the composer without a screen build', (
    tester,
  ) async {
    final dictation = _FakeDictation();
    addTearDown(dictation.dispose);
    await _pump(tester, events: const [], dictation: dictation);
    final strip = tester.widget(find.byType(RoomStatusStrip));
    expect(find.byKey(const ValueKey('dictation-stop')), findsNothing);
    dictation.recording = true;
    await tester.pump();
    expect(find.byKey(const ValueKey('dictation-stop')), findsOneWidget);
    expect(
      identical(tester.widget(find.byType(RoomStatusStrip)), strip),
      isTrue,
    );
    dictation.recording = false;
    await tester.pump();
    expect(find.byKey(const ValueKey('dictation-stop')), findsNothing);
  });

  testWidgets('attach is disabled with a reason in cross-gateway rooms', (
    tester,
  ) async {
    await _pump(
      tester,
      events: const [],
      uploader: _Uploader(),
      room: buildRoom(
        members: [
          memberJson('m-builder', 'builder'),
          memberJson('m-peer', 'peerbot', peer: 'peer-1'),
        ],
      ),
    );
    expect(
      find.byKey(const ValueKey('room-attach-disabled-reason')),
      findsOneWidget,
    );
    expect(find.textContaining('another connection'), findsOneWidget);
  });

  testWidgets('overflow menu uses the floating surface; disband is confirmed', (
    tester,
  ) async {
    final seq = EventSeq();
    final gateway = await _pump(tester, events: [seq.user('hi')]);
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-overflow-menu')), findsOneWidget);
    for (final item in [
      'members',
      'threads',
      'files',
      'activity',
      'notifications',
      'settings',
      'disband',
    ]) {
      expect(find.byKey(ValueKey('room-menu-$item')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('room-menu-disband')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
    );
    await tester.pumpAndSettle();
    expect(gateway.methods, contains('disband'));
  });

  testWidgets('notifications level persists per room', (tester) async {
    final prefs = MemoryRoomPrefs();
    await _pump(tester, events: const [], prefs: prefs);
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-notifications')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-notify-mentions')));
    await tester.pumpAndSettle();
    expect(prefs.levels.values.single, RoomNotificationLevel.mentions);
  });

  testWidgets('read-only room still offers the notification level', (
    tester,
  ) async {
    // The level is a device-local pref and read-only connections still get
    // room notifications, so they must be able to mute a noisy room.
    final prefs = MemoryRoomPrefs();
    await _pump(
      tester,
      events: const [],
      caps: RoomCapabilities.none,
      prefs: prefs,
    );
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-menu-settings')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('room-menu-notifications')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-notify-muted')));
    await tester.pumpAndSettle();
    expect(prefs.levels.values.single, RoomNotificationLevel.muted);
  });

  testWidgets('passes are one quiet line that opens the Activity sheet', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('go');
    final disc = u['event_id'] as String;
    await _pump(
      tester,
      events: [
        u,
        seq.member('m-builder', 'builder', 'done', disc),
        seq.settled('m-radar', disc, passed: true),
      ],
    );
    expect(find.text('console-radar passed · Activity ›'), findsOneWidget);
    await tester.tap(find.text('console-radar passed · Activity ›'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-activity-sheet')), findsOneWidget);
    expect(find.text('console-radar passed'), findsOneWidget);
  });

  testWidgets(
    'Desktop projection room is read-only with a banner and no composer',
    (tester) async {
      final projection = DesktopProjectionRooms.parse({
        'version': 3,
        'rooms': {
          'name:Desk': {
            'name': 'Desk',
            'members': [
              {'name': 'astra'},
            ],
            'log': [
              {
                'from': {'kind': 'user', 'name': 'You'},
                'text': 'hi @astra',
                'at': 1790000100000,
              },
              {
                'from': {'kind': 'member', 'name': 'astra'},
                'text': '**bold** reply',
                'at': 1790000160000,
              },
            ],
          },
        },
      });
      expect(projection.rooms, isNotEmpty);
      await tester.pumpWidget(
        _host(DesktopProjectionRoomScreen(room: projection.rooms.single)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('projection-readonly-banner')),
        findsOneWidget,
      );
      expect(find.text('Desktop room · read-only'), findsOneWidget);
      expect(find.byType(ConsoleComposer), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('**'), findsNothing);
    },
  );

  // Field report (hosted room, 4/4 bots up): "? could not reply" plus "A reply
  // failed" while the server was only re-checking an interrupted attempt.
  // Server shape: `pending_actions` lists a retry for every `indeterminate`
  // task, and an indeterminate task has no room event at all until the
  // driver settles or defers it (no `turn.started` is ever published).
  group('interrupted reply the server is still checking', () {
    testWidgets('is not a failure card and never names a bot "?"', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder look');
      await _pump(
        tester,
        events: [u],
        status: driver(
          blocked: true,
          counts: {'indeterminate': 1},
          pending: [
            {'kind': 'retry', 'task_id': 'dtask-int'},
          ],
        ),
      );
      expect(find.byKey(const ValueKey('room-retry-dtask-int')), findsNothing);
      expect(find.textContaining('could not reply'), findsNothing);
      expect(find.text('A reply failed'), findsNothing);
      expect(find.text('Blocked — retry'), findsNothing);
      expect(find.text('Checking an interrupted reply…'), findsOneWidget);
    });

    testWidgets('a deferral the server published names the real bot', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder look');
      final disc = u['event_id'] as String;
      await _pump(
        tester,
        events: [
          u,
          seq.deferred('m-builder', disc, task: 'dtask-def'),
        ],
        status: driver(
          counts: {'deferred': 1},
          pending: [
            {'kind': 'retry', 'task_id': 'dtask-def'},
          ],
        ),
      );
      expect(
        find.byKey(const ValueKey('room-retry-dtask-def')),
        findsOneWidget,
      );
      expect(find.text('console-builder could not reply'), findsOneWidget);
      expect(find.text('Checking an interrupted reply…'), findsNothing);
    });

    testWidgets('stays a failure when the driver is not running', (
      tester,
    ) async {
      final seq = EventSeq();
      await _pump(
        tester,
        events: [seq.user('@builder look')],
        status: driver(
          running: false,
          counts: {'indeterminate': 1},
          pending: [
            {'kind': 'retry', 'task_id': 'dtask-int'},
          ],
        ),
      );
      expect(find.text('A bot could not reply'), findsOneWidget);
      expect(find.textContaining('?'), findsNothing);
      expect(find.text('Blocked — retry'), findsOneWidget);
    });

    testWidgets('an unexplained retry beyond the indeterminate count stays', (
      tester,
    ) async {
      final seq = EventSeq();
      await _pump(
        tester,
        events: [seq.user('@builder look')],
        status: driver(
          blocked: true,
          counts: {'indeterminate': 1, 'deferred': 1},
          pending: [
            {'kind': 'retry', 'task_id': 'dtask-a'},
            {'kind': 'retry', 'task_id': 'dtask-b'},
          ],
        ),
      );
      expect(find.text('A bot could not reply'), findsNWidgets(2));
      expect(find.text('Checking an interrupted reply…'), findsNothing);
    });

    testWidgets('a deferral alongside an indeterminate retry shows only it', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder @review look');
      final disc = u['event_id'] as String;
      await _pump(
        tester,
        events: [
          u,
          seq.deferred('m-review', disc, task: 'dtask-def'),
        ],
        status: driver(
          blocked: true,
          counts: {'indeterminate': 1, 'deferred': 1},
          pending: [
            {'kind': 'retry', 'task_id': 'dtask-int'},
            {'kind': 'retry', 'task_id': 'dtask-def'},
          ],
        ),
      );
      expect(find.text('console-review could not reply'), findsOneWidget);
      expect(find.byKey(const ValueKey('room-retry-dtask-int')), findsNothing);
      expect(find.text('Checking an interrupted reply…'), findsNothing);
    });
  });

  // A retry whose task maps to no roster member (no room event names it)
  // must read as a sentence, not as "? could not reply".
  group('failure card for a task with no known member', () {
    for (final (locale, title) in [
      (const Locale('en'), 'A bot could not reply'),
      (const Locale('es'), 'Un bot no pudo responder'),
    ]) {
      testWidgets('names the bot neutrally (${locale.languageCode})', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            locale: locale,
            theme: AppTheme.hermesRedDark,
            home: Scaffold(
              body: RoomRetryCard(
                taskId: 'dtask-unknown',
                member: null,
                busy: false,
                onRetry: () {},
                onDismiss: () {},
              ),
            ),
          ),
        );
        expect(find.text(title), findsOneWidget);
        expect(find.textContaining('?'), findsNothing);
      });
    }
  });
}
