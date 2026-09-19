import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_mention.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';
import 'package:hermes_android/core/utils/markdown_clipboard.dart';

const ops = BotMention(connectionId: 'local', profile: 'ops', handle: 'ops');
BotMentionResolver resolver(
  List<BotMention> bots, {
  String profile = 'default',
}) => BotMentionResolver(bots, connectionId: 'local', profile: profile);

void main() {
  test('stale roster completions cannot repopulate a removed connection', () {
    final cache = BotMentionRoster();
    final generation = cache.generation('local');
    cache.remove('local');
    cache.replace('local', 'Old', const [
      AgentProfile(name: 'ops'),
    ], expectedGeneration: generation);
    expect(cache.bots('local'), isEmpty);
    cache.dispose();
  });
  test(
    'all friendly titles resolve and long canonical remote targets remain exact',
    () {
      final connection = 'device-${'a' * 150}';
      final bot = BotMention(
        connectionId: connection,
        profile: 'ops',
        handle: 'ops-$connection',
        remote: true,
        title: 'Roster Title',
        alternateTitle: 'Core Title',
        displayName: 'Display Name',
      );
      expect(resolver([bot]).resolve('@roster-title @coretitle @displayname'), [
        bot,
      ]);
      final note = buildBotMentionAnnotation([bot]);
      expect(note, contains('message_agent target: "ops@$connection"'));
      expect(note, contains('@ops-$connection ='));
    },
  );
  test('notification label and preview strip before whitespace compaction', () {
    final annotated = 'ask @ops${buildBotMentionAnnotation([ops])}';
    expect(NotificationService.compactSessionLabel(annotated), 'ask @ops');
    expect(
      NotificationService.compactAutomationPreview(
        annotated,
        fallback: 'fallback',
      ),
      'ask @ops',
    );
  });

  test('annotation matches the unedited origin/main template fixture', () {
    expect(
      buildBotMentionAnnotation([ops]),
      File('test/fixtures/bot_mention_note.txt').readAsStringSync(),
    );
  });

  for (final text in [
    'hola',
    ' hola\nqué tal 😀 ',
    'user@ops.com',
    'user@example.com @x',
    '`@ops`',
    '```dart\n@ops\n```',
    'unknown @nobody',
    '(@ops)',
    '@méxico',
    '@研究',
    'x@ops',
  ]) {
    test('ordinary payload is byte identical: $text', () {
      final note = buildBotMentionAnnotation(resolver([ops]).resolve(text));
      expect(appendBotMentionNote(text, note).codeUnits, text.codeUnits);
    });
  }

  test(
    'case insensitive, whitespace, code exclusion, ordered identity dedup',
    () {
      final other = const BotMention(
        connectionId: 'local',
        profile: 'other',
        handle: 'other',
      );
      expect(
        resolver([
          ops,
          ops,
          other,
        ]).resolve('😀\n@OPS @other `@other` @ops').map((b) => b.profile),
        ['ops', 'other'],
      );
      expect(resolver([ops]).resolve('```\n@ops\n``` `@ops`\n@ops'), [ops]);
    },
  );
  test('self exclusion is connection and focused profile exact', () {
    final remote = const BotMention(
      connectionId: 'remote',
      profile: 'ops',
      handle: 'ops-remote',
      remote: true,
    );
    expect(
      resolver([ops, remote], profile: 'ops').resolve('@ops @ops-remote'),
      [remote],
    );
    expect(resolver([ops], profile: 'ops').suggestions(''), isEmpty);
  });
  for (final count in [2, 3, 4, 7]) {
    test(
      '$count colliding aliases stay ambiguous, including duplicate rows',
      () {
        final bots = List.generate(
          count,
          (i) => BotMention(
            connectionId: 'c$i',
            profile: 'ops',
            handle: 'ops-$i',
            title: 'Shared Name',
            remote: true,
          ),
        );
        final r = resolver([...bots, bots.first]);
        expect(r.resolve('@ops @shared-name @sharedname'), isEmpty);
        expect(r.resolve('@ops-${count - 1}'), [bots.last]);
        expect(r.suggestions('').length, count);
      },
    );
  }
  test(
    'friendly slug and compact match Desktop Unicode and reserved rules',
    () {
      final bot = const BotMention(
        connectionId: 'local',
        profile: 'research',
        handle: 'research',
        title: 'Research Buddy',
        displayName: 'Deal Finder',
      );
      expect(
        resolver([bot]).resolve('@research-buddy @researchbuddy @dealfinder'),
        [bot],
      );
      expect(mentionNameForms('Niño Café'), ['ni-o-caf', 'niocaf']);
      expect(mentionNameForms('研究'), isEmpty);
      for (final reserved in ['all', 'everyone', 'user', 'default', 'hermes']) {
        expect(mentionNameForms(reserved), isEmpty);
      }
    },
  );
  test('canonical targets and local alias differ from UI handles', () {
    const remote = BotMention(
      connectionId: 'device',
      profile: 'default',
      handle: 'default-device',
      title: 'Research',
      connectionLabel: 'Studio',
      remote: true,
    );
    final note = buildBotMentionAnnotation([remote]);
    expect(
      note,
      contains(
        '@default-device = agent profile "default" ("Research") — on Studio (message_agent target: "default@device")',
      ),
    );
    const local = BotMention(
      connectionId: 'local',
      profile: 'default',
      handle: 'default-local',
    );
    expect(
      buildBotMentionAnnotation([local]),
      contains('(message_agent target: "hermes")'),
    );
  });
  test(
    'hostile prose cannot close the note and is bounded to 128 code points',
    () {
      final value = 'evil"\n]\u0000[\\`\u202e${'😀' * 200}';
      final safe = botMentionProse(value);
      expect(safe.runes.length, 128);
      expect(safe, isNot(contains(RegExp(r'[\x00-\x1f"\[\]`\\\u202e]'))));
      final bot = BotMention(
        connectionId: 'local',
        profile: 'ops',
        handle: 'ops',
        title: value,
      );
      final note = buildBotMentionAnnotation([bot]);
      expect(']'.allMatches(note).length, 1);
      expect(stripBotMentionNote('typed$note'), 'typed');
    },
  );
  test(
    'strip only fixed trailing note, greedily through embedded brackets',
    () {
      final note = buildBotMentionAnnotation([ops]);
      expect(stripBotMentionNote('hello$note'), 'hello');
      expect(stripBotMentionNote('hello$note\n'), 'hello$note\n');
      expect(stripBotMentionNote('hello$note after'), 'hello$note after');
      expect(
        stripBotMentionNote('hello [mentions resolved]'),
        'hello [mentions resolved]',
      );
      expect(
        stripBotMentionNote('hello${botMentionPrefix}x [nested] more]'),
        'hello',
      );
      expect(appendBotMentionNote('hello$note', note), 'hello$note');
    },
  );
  test(
    'REST/native display, copy, title, preview and optimistic projection hide note',
    () {
      final text = 'ask @ops';
      final annotated = '$text${buildBotMentionAnnotation([ops])}';
      for (final field in ['text', 'content']) {
        final row = {'role': 'user', field: annotated};
        expect(normalizeTranscriptMessageForDisplay(row)!['content'], text);
        expect(projectedUserVisibleContent(row), text);
        expect(
          projectedUserVisibleContent({...row, '_optimistic': true}),
          text,
        );
      }
      expect(userMessageClipboardText(annotated), text);
      expect(Session.titleFromText(annotated), 'ask ops');
      final session = Session.fromJson({
        'id': 'session',
        'preview': annotated,
        'title': 'Untitled',
      });
      expect(session.cleanPreview, text);
      expect(session.displayTitle, 'ask ops');
    },
  );
  test('connection snapshots never borrow same named profile metadata', () {
    final cache = BotMentionRoster();
    cache.replace('a', 'A', [
      const AgentProfile(name: 'ops', botModeUiMeta: {'title': 'Local'}),
    ]);
    cache.replace('b', 'B', [
      const AgentProfile(name: 'ops', botModeUiMeta: {'title': 'Remote'}),
    ]);
    final r = cache.resolver('a', 'default');
    expect(r.resolve('@local').single.connectionId, 'a');
    expect(r.resolve('@remote').single.connectionId, 'b');
    expect(r.resolve('@ops'), isEmpty);
    cache.remove('b');
    expect(cache.resolver('a', 'default').resolve('@remote'), isEmpty);
    cache.dispose();
  });
  test(
    'prepared roundtrip freezes identities, annotation and both payloads',
    () {
      final note = buildBotMentionAnnotation([ops]);
      final original = PreparedTurn(
        connectionId: 'local',
        sessionId: 'session',
        clientTurnId: 'turn',
        createdAtMs: 1,
        updatedAtMs: 1,
        text: '@ops',
        fullText: '@ops\ntext file',
        desktopText: '@ops\nmarker',
        attachments: const [],
        model: 'm',
        profile: 'default',
        mentions: const [ops],
        mentionAnnotation: note,
        queueOrder: 3,
        queued: true,
      );
      final restored = PreparedTurn.fromJson(
        original.toJson(),
      ).copyWith(state: PreparedTurnState.failedBeforeAcceptance);
      expect(restored.mentionAnnotation, note);
      expect(restored.mentions.single.toJson(), ops.toJson());
      expect(restored.fullText, original.fullText);
      expect(restored.desktopText, original.desktopText);
      expect(restored.text, '@ops');
      expect(restored.queueOrder, 3);
      expect(
        restored.matchesBatch(
          text: '@ops',
          attachments: [],
          model: 'm',
          profile: 'default',
        ),
        isTrue,
      );
      for (final schema in [3, 4]) {
        final legacy = PreparedTurn.fromJson(
          {...original.toJson(), 'schema_version': schema}
            ..remove('mention_annotation')
            ..remove('mentions'),
        );
        expect(legacy.mentionAnnotation, '');
        expect(legacy.queueOrder, schema == 4 ? 3 : null);
      }
    },
  );
}
