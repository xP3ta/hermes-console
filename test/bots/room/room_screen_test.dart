import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_selection_area.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/clipboard_image_fake.dart';
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

const _compressCaps = RoomCapabilities(
  canSend: true,
  canRename: true,
  canStop: true,
  canDisband: true,
  canApprove: true,
  canRetry: true,
  canCompressMembers: true,
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
  GatewayRoomMemberCompressor? memberCompressor,
  Widget Function(Widget app)? wrap,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final log = buildLog(events);
  final resolvedRoom = room ?? buildRoom(latestSeq: log.latestSeq);
  final gateway = FakeRoomGateway(room: resolvedRoom, log: log, status: status);
  final app = _host(
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
      memberCompressor: memberCompressor,
      pollTimer: (_, _) => _FakeTimer(),
      clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
    ),
  );
  await tester.pumpWidget(wrap == null ? app : wrap(app));
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

final class _RecordingUploader implements RoomAttachmentUploader {
  final List<AttachmentDraft> uploaded = [];
  @override
  Future<String?> upload(draft) async {
    uploaded.add(draft);
    return '/srv/uploads/${draft.name}';
  }
}

final _pastedPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
  'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

/// Private app-support dir for the materialized draft copy.
void _mockPathProvider() {
  final temp = Directory.systemTemp.createTempSync('room-ime-paste-');
  addTearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => temp.path);
  addTearDown(
    () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

TextField _roomField(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(
    of: find.byType(ConsoleComposer),
    matching: find.byType(TextField),
  ),
);

List<AttachmentCard> _roomComposerCards(WidgetTester tester) => tester
    .widgetList<AttachmentCard>(find.byType(AttachmentCard))
    .where((card) => card.onRemove != null)
    .toList();

/// Lets the real file I/O behind the paste finish, then paints it.
Future<void> _settlePaste(WidgetTester tester, {bool Function()? until}) async {
  for (var i = 0; i < 100 && !(until?.call() ?? false); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _insertFromKeyboard(
  WidgetTester tester, {
  String mimeType = 'image/png',
  Uint8List? data,
}) async {
  final config = _roomField(tester).contentInsertionConfiguration;
  expect(config, isNotNull, reason: 'room composer must accept IME content');
  config!.onContentInserted(
    KeyboardInsertedContent(
      mimeType: mimeType,
      uri: 'content://keyboard/pasted',
      data: data ?? _pastedPng,
    ),
  );
  await _settlePaste(tester);
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

  testWidgets('rpl1215 room selections never offer "Ask about this"', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('Roomquestion');
    final m = seq.member(
      'm-builder',
      'builder',
      'Roomanswer ready',
      u['event_id'] as String,
    );
    final asked = <String>[];
    // Even under an ask scope (as if a chat screen were above), room
    // messages do not opt in: the room has no composer quote path.
    await _pump(
      tester,
      events: [u, m],
      wrap: (app) => ChatAskAboutScope(
        label: 'Ask about this',
        onAsk: asked.add,
        child: app,
      ),
    );
    for (final word in ['Roomanswer', 'Roomquestion']) {
      final target = find.textContaining(word, findRichText: true).first;
      await tester.longPressAt(tester.getTopLeft(target) + const Offset(8, 8));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Copy'), findsOneWidget, reason: word);
      expect(find.text('Ask about this'), findsNothing, reason: word);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(asked, isEmpty);
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

  testWidgets('a MEDIA line renders as a preview and the raw line is hidden', (
    tester,
  ) async {
    final seq = EventSeq();
    final u = seq.user('Look at this:\nMEDIA:/srv/out/cat.png\nDone.');
    final actions = FakeActions();
    await _pump(tester, events: [u], actions: actions);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('MEDIA:'), findsNothing);
    expect(find.textContaining('/srv/out'), findsNothing);
    expect(find.textContaining('Look at this:'), findsOneWidget);
    expect(find.textContaining('Done.'), findsOneWidget);
    expect(actions.calls, contains('fetch:cat.png'));
    expect(
      find.byKey(const ValueKey('room-attachment-media-/srv/out/cat.png')),
      findsOneWidget,
    );
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

  testWidgets('reply to a member seeds its handle once and focuses', (
    tester,
  ) async {
    final seq = EventSeq();
    final user = seq.user('status?');
    final member = seq.member(
      'm-builder',
      'builder',
      'ready',
      user['event_id'] as String,
    );
    final gateway = await _pump(tester, events: [user, member]);
    final field = find.descendant(
      of: find.byType(ConsoleComposer),
      matching: find.byType(TextField),
    );

    final memberReply = find.byKey(
      ValueKey('room-reply-${member['event_id']}'),
    );
    await tester.tap(memberReply);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '@builder ');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('room-thread-banner')), findsOneWidget);
    await tester.tap(memberReply);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '@builder ');
    expect(gateway.calls.where((call) => call.$1 == 'send'), isEmpty);

    await tester.enterText(field, '');
    await tester.tap(find.byKey(ValueKey('room-reply-${user['event_id']}')));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('unknown mention note follows local composer text', (
    tester,
  ) async {
    await _pump(tester, events: const []);
    final field = find.descendant(
      of: find.byType(ConsoleComposer),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '@nobody hi');
    await tester.pump();
    expect(find.byKey(const ValueKey('room-unknown-mention')), findsOneWidget);
    expect(
      find.text('No member is called @nobody — everyone will answer.'),
      findsOneWidget,
    );
    await tester.enterText(field, '@builder hi');
    await tester.pump();
    expect(find.byKey(const ValueKey('room-unknown-mention')), findsNothing);
    await tester.enterText(field, '@all hi');
    await tester.pump();
    expect(find.byKey(const ValueKey('room-unknown-mention')), findsNothing);
  });

  testWidgets('slash guard keeps text and attachments but paths still send', (
    tester,
  ) async {
    final gateway = await _pump(
      tester,
      events: const [],
      uploader: _Uploader(),
    );
    final field = find.descendant(
      of: find.byType(ConsoleComposer),
      matching: find.byType(TextField),
    );
    const attachment = AttachmentDraft(
      localId: 'draft-1',
      type: AttachmentType.document,
      name: 'notes.txt',
      mimeType: 'text/plain',
      sizeBytes: 5,
      localPath: '/tmp/notes.txt',
    );
    await tester.enterText(field, '/compress');
    tester.widget<ConsoleComposer>(find.byType(ConsoleComposer)).onSend(
      '/compress',
      const [attachment],
    );
    await tester.pump();
    expect(gateway.calls.where((call) => call.$1 == 'send'), isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, '/compress');
    expect(
      find.text("Rooms don't run commands. Remove the leading /…"),
      findsOneWidget,
    );

    await tester.enterText(field, '/model x');
    await tester.tap(
      find.byKey(const ValueKey('composer-primary-action-switcher')),
    );
    await tester.pumpAndSettle();
    expect(gateway.calls.where((call) => call.$1 == 'send'), isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, '/model x');

    await tester.enterText(field, '/etc/hosts is broken');
    await tester.tap(
      find.byKey(const ValueKey('composer-primary-action-switcher')),
    );
    await tester.pumpAndSettle();
    expect(
      gateway.calls.where((call) => call.$1 == 'send').single.$2['text'],
      '/etc/hosts is broken',
    );
  });

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

  testWidgets('settings compresses only a picked local member', (tester) async {
    final calls = <(String, Map<String, dynamic>)>[];
    final compressor = GatewayRoomMemberCompressor((method, params) async {
      calls.add((method, params));
      return switch (method) {
        'session.list' => {
          'sessions': [
            {'resolved_id': 'stored-builder'},
          ],
        },
        'session.resume' => {'session_id': 'runtime-builder'},
        'session.compress' => {
          'status': 'compressed',
          'summary': {'headline': 'Short room history'},
        },
        _ => <String, dynamic>{},
      };
    });
    await _pump(
      tester,
      events: const [],
      caps: _compressCaps,
      memberCompressor: compressor,
    );
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-settings')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('room-settings-compress')),
      findsOneWidget,
    );
    expect(calls, isEmpty);

    await tester.tap(find.byKey(const ValueKey('room-settings-compress')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('room-compress-member-m-builder')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('room-compress-member-m-builder')),
    );
    await tester.pumpAndSettle();
    expect(find.text("Compress @builder's room history?"), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
    );
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.$1), [
      'session.list',
      'session.resume',
      'session.compress',
    ]);
    expect(find.text('Compressed: Short room history'), findsOneWidget);
  });

  testWidgets('compress row is disabled while working and hidden read-only', (
    tester,
  ) async {
    final compressor = GatewayRoomMemberCompressor(
      (method, params) async => const {},
    );
    await _pump(
      tester,
      events: const [],
      status: driver(working: true),
      caps: _compressCaps,
      memberCompressor: compressor,
    );
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-settings-compress')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('room-compress-member-sheet')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _pump(
      tester,
      events: const [],
      caps: const RoomCapabilities(canRename: true),
    );
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-settings-compress')), findsNothing);
  });

  testWidgets('opening a room never probes session.compress', (tester) async {
    final calls = <(String, Map<String, dynamic>)>[];
    final compressor = GatewayRoomMemberCompressor((method, params) async {
      calls.add((method, params));
      return const <String, dynamic>{};
    });
    await _pump(tester, events: const [], memberCompressor: compressor);
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('room-settings-compress')), findsNothing);
    expect(
      calls.where((call) => call.$1 == 'session.compress'),
      isEmpty,
      reason: 'session.compress mutates a session and is never a probe',
    );
    expect(calls, isEmpty);
  });

  testWidgets('declared compress capability shows the row without a probe', (
    tester,
  ) async {
    final calls = <(String, Map<String, dynamic>)>[];
    final compressor = GatewayRoomMemberCompressor((method, params) async {
      calls.add((method, params));
      return const <String, dynamic>{};
    });
    await _pump(
      tester,
      events: const [],
      caps: _compressCaps,
      memberCompressor: compressor,
    );
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-settings')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('room-settings-compress')),
      findsOneWidget,
    );
    expect(calls, isEmpty);
  });

  testWidgets('compression is single-flight and drops a result after dispose', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    var calls = 0;
    final compressor = GatewayRoomMemberCompressor((method, params) {
      calls++;
      return gate.future;
    });
    await _pump(
      tester,
      events: const [],
      caps: _compressCaps,
      memberCompressor: compressor,
    );
    await tester.tap(find.byKey(const ValueKey('room-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-menu-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-settings-compress')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('room-compress-member-m-builder')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, 1);
    expect(find.text('Compressing…'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('room-settings-compress')));
    await tester.pump();
    expect(calls, 1);
    expect(
      find.byKey(const ValueKey('room-compress-member-sheet')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete({'sessions': const []});
    await tester.pump();
    expect(tester.takeException(), isNull);
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

    // Each published terminal kind is the server's verdict on the task: the
    // retry is a failure card again, never "Checking an interrupted reply…",
    // even while the indeterminate count still covers it.
    for (final kind in terminalKinds.keys) {
      testWidgets('a published $kind shows the failure card, not checking', (
        tester,
      ) async {
        final seq = EventSeq();
        final u = seq.user('@builder look');
        await _pump(
          tester,
          events: [
            u,
            terminalKinds[kind]!(
              seq,
              'm-builder',
              u['event_id'] as String,
              'dtask-done',
            ),
          ],
          status: driver(
            blocked: true,
            counts: {'indeterminate': 1},
            pending: [
              {'kind': 'retry', 'task_id': 'dtask-done'},
            ],
          ),
        );
        expect(
          find.byKey(const ValueKey('room-retry-dtask-done')),
          findsOneWidget,
        );
        expect(find.text('console-builder could not reply'), findsOneWidget);
        expect(find.text('Checking an interrupted reply…'), findsNothing);
      });
    }

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

  group('keyboard paste into the room composer', () {
    testWidgets('long-press "Paste image" adds the clipboard image as a chip', (
      tester,
    ) async {
      _mockPathProvider();
      final clipboard = FakeNativeClipboard(
        read: {
          'mimeType': 'image/png',
          'name': 'shot.png',
          'bytes': _pastedPng,
        },
      )..install();
      await _pump(tester, events: const [], uploader: _RecordingUploader());
      await openComposerTextMenu(
        tester,
        find.descendant(
          of: find.byType(ConsoleComposer),
          matching: find.byType(TextField),
        ),
      );
      expect(find.text('Paste image'), findsOneWidget);
      await tester.tap(find.text('Paste image'));
      await _settlePaste(
        tester,
        until: () => _roomComposerCards(tester).isNotEmpty,
      );

      expect(clipboard.calls, containsAllInOrder(['hasImage', 'readImage']));
      expect(_roomComposerCards(tester).single.name, 'pasted-image.png');
    });

    testWidgets('a pasted image becomes a chip and is uploaded on send', (
      tester,
    ) async {
      _mockPathProvider();
      final uploader = _RecordingUploader();
      final gateway = await _pump(tester, events: const [], uploader: uploader);
      await _insertFromKeyboard(tester);
      await _settlePaste(
        tester,
        until: () => _roomComposerCards(tester).isNotEmpty,
      );

      final cards = _roomComposerCards(tester);
      expect(cards, hasLength(1));
      expect(cards.single.name, 'pasted-image.png');

      await tester.enterText(
        find.descendant(
          of: find.byType(ConsoleComposer),
          matching: find.byType(TextField),
        ),
        'look at this chart',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('composer-primary-action-switcher')),
      );
      await _settlePaste(tester, until: () => uploader.uploaded.isNotEmpty);
      await tester.pumpAndSettle();

      expect(uploader.uploaded, hasLength(1));
      expect(uploader.uploaded.single.type, AttachmentType.image);
      expect(uploader.uploaded.single.mimeType, 'image/png');
      expect(uploader.uploaded.single.sizeBytes, _pastedPng.length);
      final sent = gateway.calls.where((c) => c.$1 == 'send').single.$2;
      expect(sent['text'], contains('look at this chart'));
      expect(sent['text'], contains('/srv/uploads/pasted-image.png'));
      expect(_roomComposerCards(tester), isEmpty);
    });

    testWidgets('a non-image payload is refused with the attach notice', (
      tester,
    ) async {
      _mockPathProvider();
      final uploader = _RecordingUploader();
      await _pump(tester, events: const [], uploader: uploader);
      await _insertFromKeyboard(
        tester,
        mimeType: 'application/x-msdownload',
        data: Uint8List.fromList([0x4d, 0x5a, 0x90, 0x00]),
      );
      expect(_roomComposerCards(tester), isEmpty);
      expect(
        find.text(
          "One of the attachments couldn't be prepared. Select it again.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('cross-gateway rooms explain why the paste was not attached', (
      tester,
    ) async {
      _mockPathProvider();
      final uploader = _RecordingUploader();
      await _pump(
        tester,
        events: const [],
        uploader: uploader,
        room: buildRoom(
          members: [
            memberJson('m-builder', 'builder'),
            memberJson('m-peer', 'peerbot', peer: 'peer-1'),
          ],
        ),
      );
      await _insertFromKeyboard(tester);
      expect(_roomComposerCards(tester), isEmpty);
      expect(uploader.uploaded, isEmpty);
      // The persistent reason under the composer plus the paste notice.
      expect(find.textContaining('another connection'), findsNWidgets(2));
    });

    testWidgets('without an uploader the paste says uploads are unavailable', (
      tester,
    ) async {
      _mockPathProvider();
      await _pump(tester, events: const []);
      await _insertFromKeyboard(tester);
      expect(_roomComposerCards(tester), isEmpty);
      expect(
        find.text('This connection cannot upload files to the server.'),
        findsNWidgets(2),
      );
    });
  });
}
