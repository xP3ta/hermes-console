// Review findings M3 and m4 (console-reddit-independent-review.md) on the
// room attachment display added for the Reddit report:
//  * M3: a `message.member` whose manifest Console rejects lost its files
//    silently (`attachments = const []`), with no sign on screen.
//  * m4: attachment names may carry bidi controls (upstream
//    hosted_room_attachments.py::_name accepts them), and Console painted
//    them as they came in the chip, the room card and the reply quote, so
//    `invoice<U+202E>fdp.exe` could read as `invoiceexe.pdf`.
//
// Names are neutralised at render time, never rejected by the parser:
// rejecting a name upstream accepts would make the whole room unreadable,
// which is the reported symptom again.
//
// New API is read dynamically in the [RED] tests so the run against the code
// without it fails per test, not at compile time.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'bots/room/room_fixtures.dart';
import 'support/inter_font.dart';

const _attId = 'att_0123456789abcdef0123456789abcdef';

/// Every bidi control the review lists.
const _bidiControls = <String>[
  '\u202A', '\u202B', '\u202C', '\u202D', '\u202E', // embeddings/overrides
  '\u2066', '\u2067', '\u2068', '\u2069', // isolates
  '\u200E', '\u200F', '\u061C', // marks
];

Map<String, dynamic> _att(String name) => {
  'attachment_id': _attId,
  'kind': 'file',
  'name': name,
  'size': 10,
  'mime': 'application/octet-stream',
};

bool _hasBidi(String text) => _bidiControls.any(text.contains);

Map<String, dynamic> _withPayload(
  Map<String, dynamic> event,
  Map<String, Object?> extra,
) => {
  ...event,
  'payload': {...(event['payload'] as Map<String, dynamic>), ...extra},
};

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// The plain text of every paragraph painted under [root].
List<String> _paintedTexts(WidgetTester tester) => [
  for (final p in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  ))
    p.text.toPlainText(),
];

void main() {
  setUpAll(loadInterFont);

  // Independent audit (scratch-fa, 2026-11-14), verified on upstream main
  // 491f984 gateway/hosted_room_discussion.py:398-399: «Lowering the
  // scheduling budget must not invalidate already-published higher rounds»
  // — round_index is any non-negative integer. Console capped it at 2, so a
  // room continued on Desktop with a deferred turn in round 3+ was
  // unreadable in Console (another candidate cause of the Reddit report).
  group('turn.deferred round_index (upstream: non-negative, unbounded)', () {
    for (final round in [3, 7]) {
      test('[RED] a deferred turn in round $round parses', () {
        final seq = EventSeq();
        final root = seq.user('go');
        final event = HostedGroupEvent.fromJson(
          seq.deferred('m-builder', root['event_id'] as String, round: round),
          roomId: roomId,
        );
        expect(event.kind, 'turn.deferred');
      });
    }

    for (final bad in <Object>[-1, 1.5, '3']) {
      test('[CONTROL] round_index $bad stays rejected', () {
        final seq = EventSeq();
        final root = seq.user('go');
        final raw = seq.deferred('m-builder', root['event_id'] as String);
        expect(
          () => HostedGroupEvent.fromJson(
            _withPayload(raw, {'round_index': bad}),
            roomId: roomId,
          ),
          throwsFormatException,
        );
      });
    }
  });

  group('M2 (review): a single backslash in a name', () {
    test('[CONTROL] r"a\\b.txt" is rejected, as upstream _name does', () {
      // The review read `name.contains(r'\')` as two backslashes; in a Dart
      // raw string it is one. This pins the behaviour.
      expect(r'a\b.txt'.codeUnits.where((c) => c == 0x5C).length, 1);
      expect(
        () => HostedGroupAttachment.fromJson(_att(r'a\b.txt')),
        throwsFormatException,
      );
    });
  });

  group('M3: member files Console rejects are announced', () {
    Map<String, dynamic> memberEvent(Object? attachments) {
      final seq = EventSeq();
      final root = seq.user('hello');
      return _withPayload(
        seq.member('m-builder', 'builder', 'done', root['event_id'] as String),
        {'attachments': attachments},
      );
    }

    test('[RED] an invalid member manifest keeps the text and is flagged', () {
      final event = HostedGroupEvent.fromJson(
        memberEvent([
          {..._att('a.txt'), 'attachment_id': 'bad'},
        ]),
        roomId: roomId,
      );
      expect(event.publicText, 'done');
      expect(event.attachments, isEmpty);
      expect((event as dynamic).attachmentsRejected, isTrue);
    });

    test('[CONTROL] a valid member manifest is not flagged', () {
      final event = HostedGroupEvent.fromJson(
        memberEvent([_att('a.txt')]),
        roomId: roomId,
      );
      expect(event.attachments.single.name, 'a.txt');
      expect((event as dynamic).attachmentsRejected, isFalse);
    });

    test('[CONTROL] a member message without attachments is not flagged', () {
      final seq = EventSeq();
      final root = seq.user('hello');
      final event = HostedGroupEvent.fromJson(
        seq.member('m-builder', 'builder', 'ok', root['event_id'] as String),
        roomId: roomId,
      );
      expect((event as dynamic).attachmentsRejected, isFalse);
    });

    testWidgets('[RED] the room shows that the message had files it could '
        'not show', (tester) async {
      final seq = EventSeq();
      final root = seq.user('hello');
      final reply = _withPayload(
        seq.member('m-builder', 'builder', 'done', root['event_id'] as String),
        {
          'attachments': [
            {..._att('a.txt'), 'attachment_id': 'bad'},
          ],
        },
      );
      final entry = buildRoomTranscript(
        events: buildLog([root, reply]).events,
        members: buildRoom().members,
      ).whereType<RoomMessageEntry>().last;
      await tester.pumpWidget(
        _host(
          RoomMessageTile(
            entry: entry,
            profile: null,
            avatarCache: null,
            mentionHandles: const [],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('done'), findsWidgets);
      expect(
        find.text("Files in this message can't be shown in Console"),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('m4: attachment names never paint bidi controls', () {
    for (final control in _bidiControls) {
      final code = control.codeUnitAt(0).toRadixString(16).toUpperCase();
      final name = 'invoice${control}fdp.exe';

      testWidgets('[RED] chip: U+$code', (tester) async {
        await tester.pumpWidget(
          _host(
            RoomServerAttachmentChip(
              attachment: HostedGroupAttachment.fromJson(_att(name)),
            ),
          ),
        );
        final texts = _paintedTexts(tester);
        expect(texts, contains('invoicefdp.exe'));
        expect(texts.where(_hasBidi), isEmpty, reason: '$texts');
      });

      test('[RED] room card preview: U+$code', () {
        final seq = EventSeq();
        final only = _withPayload(seq.user(''), {
          'attachments': [_att(name)],
        });
        final hosted = HostedGroupsSnapshot(
          rooms: [buildRoom(latestSeq: 1)],
          logs: [buildLog([only])],
        );
        final entry = RoomRosterEntry.build(
          hosted: hosted,
          attention: AttentionSummary.fromSnapshot(hosted),
        ).single;
        expect(entry.preview, 'invoicefdp.exe');
        expect(_hasBidi(entry.preview), isFalse);
      });

      test('[RED] reply quote: U+$code', () {
        final seq = EventSeq();
        final only = _withPayload(seq.user(''), {
          'attachments': [_att(name)],
        });
        final reply = seq.member(
          'm-builder',
          'builder',
          'got it',
          only['event_id'] as String,
        );
        final entries = buildRoomTranscript(
          events: buildLog([only, reply]).events,
          members: buildRoom().members,
        ).whereType<RoomMessageEntry>().toList();
        final quote = entries.last.quote;
        expect(quote?.preview, 'invoicefdp.exe');
        expect(_hasBidi(quote!.preview), isFalse);
      });
    }

    test('[CONTROL] the parsed name itself is kept as the server sent it '
        '(never rejected: that would make the room unreadable)', () {
      final parsed = HostedGroupAttachment.fromJson(_att('a\u202Eb.txt'));
      expect(parsed.name, 'a\u202Eb.txt');
    });
  });
}
