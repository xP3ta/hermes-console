// The turn's summary opened: the turn's calls organised. Every step is a
// plain line (icon, words, time, state mark; nothing drawn around it, in the
// receipt rows' size and ink) hanging from the connector down the side, one
// tick per line, as if it grew out of it (the owner, 22 nov: no outlined
// pills, only the tree). A run of consecutive calls of one kind is ONE
// line, «Verb ×N», with what they acted on and how long they took together,
// and opens to the calls themselves one level in, on a connector of their
// own. The closed live window keeps its outlined pills.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hicons.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart'
    show activityToolDetail;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/live_turn_window.dart';
import 'package:hermes_android/core/design/gel_surface.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat/turn_receipt_pill.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

import 'support/inter_font.dart';

/// A skill name of 40 characters: on a foldable it must show whole.
const _longSkill = 'grounded-citations-for-current-news-feed';

TurnStepCardEntry _call(
  String id,
  String tool, {
  String? detail,
  String? title,
  int? seconds,
  bool running = false,
  bool failed = false,
  DateTime? startedAt,
  Widget? opened,
  Widget? attachment,
  TurnStepCardKind kind = TurnStepCardKind.tool,
}) => TurnStepCardEntry(
  id: id,
  kind: kind,
  title: title ?? 'Paso $id',
  detail: detail,
  toolName: tool,
  running: running,
  failed: failed,
  startedAt: startedAt,
  duration: seconds == null ? null : Duration(seconds: seconds),
  semanticsLabel: [title ?? 'Paso $id', ?detail].join(', '),
  opened: opened,
  attachment: attachment,
);

TurnStepCardEntry _thought(String id) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.thought,
  title: 'Pensó',
  semanticsLabel: 'Pensó',
  opened: Text('idea $id'),
);

TurnStepCardEntry _skill(String id, String name, int seconds) => _call(
  id,
  'skill_view',
  title: 'Skill cargada',
  detail: name,
  seconds: seconds,
);

/// The turn of the owner's screenshot: five skill loads, a command, one
/// more skill (its name 40 characters), three web searches (their queries
/// are never shown) and three calls of a plugin's memory tool.
List<TurnStepCardEntry> _screenshot({bool running = false, DateTime? at}) => [
  _skill('s1', 'current-news-research', 3),
  _skill('s2', 'grounded-citations', 2),
  _skill('s3', 'omh-web-research', 2),
  _skill('s4', 'omh-memory-system', 2),
  _skill('s5', 'hermes-tools', 2),
  _call(
    't1',
    'terminal',
    title: 'Ejecutó',
    detail: 'canary',
    seconds: 1,
    opened: const Text('salida t1', key: ValueKey('out-t1')),
  ),
  _skill('s6', _longSkill, 2),
  _call('w1', 'web_search', title: 'Búsqueda web completada', seconds: 6),
  _call('w2', 'web_search', title: 'Búsqueda web completada', seconds: 6),
  _call(
    'w3',
    'web_search',
    title: running ? 'Buscando en la web' : 'Búsqueda web completada',
    seconds: running ? null : 6,
    running: running,
    startedAt: running ? at : null,
  ),
  if (!running) ...[
    _call('m1', 'omh_memory', title: 'Omh Memory', seconds: 3),
    _call('m2', 'omh_memory', title: 'Omh Memory', seconds: 3),
    _call('m3', 'omh_memory', title: 'Omh Memory', seconds: 3),
  ],
];

List<int> _shape(List<TurnStepCardEntry> entries) => [
  for (final group in turnFeedGroups(entries)) group.length,
];

final _now = DateTime(2026, 11, 20, 12);

Widget _host(
  List<TurnStepCardEntry> entries, {
  double scale = 1,
  bool reduced = true,
  ThemeData? theme,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduced,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LiveTurnScope(
          status: const LiveTurnStatus(active: true),
          clock: () => _now,
          child: TurnStepCards(entries: entries, detailsOnly: true),
        ),
      ),
    ),
  ),
);

Future<void> _screen(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _group(String id) => find.byKey(ValueKey('turn-feed-group-$id'));
Finder _row(String id) => find.byKey(ValueKey('turn-step-card-$id'));

/// The words of a pill: its one rich line, «Verb ×N  detail» (its first
/// `Text`; the icon is a glyph of its own).
RenderParagraph _line(WidgetTester tester, Finder pill) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: pill, matching: find.byType(Text)).first,
    );

/// The spans of a pill's line that hold words: the verb, then the detail.
List<TextSpan> _spans(WidgetTester tester, Finder pill) {
  final spans = <TextSpan>[];
  _line(tester, pill).text.visitChildren((span) {
    if (span is TextSpan && span.text != null) spans.add(span);
    return true;
  });
  return spans;
}

String _words(WidgetTester tester, Finder pill) =>
    _line(tester, pill).text.toPlainText();

Finder _pill(String id) => find.byKey(ValueKey('turn-feed-pill-$id'));
Finder _groupPill(String id) =>
    find.byKey(ValueKey('turn-feed-group-pill-$id'));

/// Every pill on screen, the window's and the list's alike.
Finder _pills() => find.byType(LiveTurnRowPill);

/// One tick of the connector per row, whichever level it hangs from.
Finder _ticks() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      ((widget.key! as ValueKey<String>).value.startsWith('turn-feed-elbow-') ||
          (widget.key! as ValueKey<String>).value.startsWith(
            'turn-feed-group-elbow-',
          )),
);

Finder _checks(Finder of) => find.descendant(
  of: of,
  matching: find.byKey(const ValueKey('live-ring-check')),
);

void main() {
  setUpAll(loadInterFont);
  setUp(StepsBarMemory.reset);

  group('grouping', () {
    test('the screenshot: 5 skills · the command · the lone skill · 3 '
        'searches · 3 memory calls', () {
      expect(_shape(_screenshot()), [5, 1, 1, 3, 3]);
      expect(turnFeedGroups(const []), isEmpty);
      expect(_shape([_call('a', 'web_search')]), [1]);
      expect(_shape([_call('a', 'web_search'), _call('b', 'web_search')]), [
        2,
      ]);
    });

    test('a call still running stays in its run, in the middle too', () {
      expect(
        _shape([
          _call('a', 'web_search'),
          _call('b', 'web_search', running: true),
          _call('c', 'web_search'),
        ]),
        [3],
      );
      expect(
        _shape([
          _call('a', 'terminal'),
          _call('b', 'web_search', running: true),
          _call('c', 'terminal'),
        ]),
        [1, 1, 1],
      );
    });

    test('interleaved kinds and thoughts end a run', () {
      expect(
        _shape([
          _call('a', 'skill_view', detail: 'x'),
          _call('b', 'web_search'),
          _call('c', 'skill_view', detail: 'y'),
          _call('d', 'skill_view', detail: 'z'),
          _thought('e'),
          _call('f', 'skill_view', detail: 'w'),
        ]),
        [1, 1, 2, 1, 1],
      );
    });

    test('a family is Desktop\'s run category; any other tool by name', () {
      // list_files and read_file are both «explored» files; terminal and
      // execute_code both commands.
      expect(
        _shape([
          _call('a', 'list_files'),
          _call('b', 'read_file'),
          _call('c', 'terminal'),
          _call('d', 'execute_code'),
          _call('e', 'omh_memory'),
          _call('f', 'omh_memory'),
          _call('g', 'cronjob'),
          _call('h', 'mcp__github__create_issue'),
          _call('i', 'mcp__github__create_issue'),
        ]),
        [2, 2, 2, 1, 2],
      );
    });

    test('calls without a detail group with those that have one', () {
      final group = turnFeedGroups([
        _call('a', 'skill_view', detail: 'alpha'),
        _call('b', 'skill_view'),
        _call('c', 'skill_view', detail: 'beta'),
        _call('d', 'skill_view', detail: 'alpha'),
      ]).single;
      expect(group, hasLength(4));
      expect(turnFeedGroupDetail(group), 'alpha, beta');
      final searches = [_call('a', 'web_search'), _call('b', 'web_search')];
      expect(turnFeedGroupDetail(searches), isNull);
    });

    test('a skill load and a read of its resources are two kinds', () {
      expect(
        _shape([
          _call('a', 'skill_view', detail: 'alpha'),
          _call('b', 'skill_view', detail: 'alpha → notes.md'),
          _call('c', 'skill_view', detail: 'beta → refs.md'),
        ]),
        [1, 2],
      );
    });

    test('cards, file edits, connectors, outcomes and calls that left '
        'something to show never fold', () {
      for (final tool in const [
        'delegate_task',
        'clarify',
        'image_generate',
        'edit_file',
        'write_file',
        'patch',
        'connectors__github__GITHUB_CREATE_ISSUE',
      ]) {
        expect(_shape([_call('a', tool), _call('b', tool)]), [
          1,
          1,
        ], reason: tool);
      }
      expect(
        _shape([
          _call('a', 'terminal', kind: TurnStepCardKind.outcome),
          _call('b', 'terminal', kind: TurnStepCardKind.outcome),
        ]),
        [1, 1],
      );
      expect(
        _shape([
          _call('a', 'browser_navigate', attachment: const SizedBox()),
          _call('b', 'browser_navigate'),
          _call('c', 'browser_navigate'),
        ]),
        [1, 2],
      );
    });

    test('labels: Desktop\'s clause words, counted; another tool by its '
        'title', () {
      final es = StringsEs();
      final en = StringsEn();
      final groups = turnFeedGroups(_screenshot());
      expect(turnFeedGroupLabel(es, groups[0]), '5 skills cargadas');
      expect(turnFeedGroupLabel(en, groups[0]), '5 skills loaded');
      expect(turnFeedGroupLabel(es, groups[3]), '3 búsquedas');
      expect(turnFeedGroupLabel(en, groups[3]), '3 searches');
      expect(turnFeedGroupLabel(es, groups[4]), 'Omh Memory · 3 veces');
      expect(turnFeedGroupLabel(en, groups[4]), 'Omh Memory · 3 times');
      expect(
        turnFeedGroupDetail(groups[0]),
        'current-news-research, grounded-citations, omh-web-research, '
        'omh-memory-system, hermes-tools',
      );
      final commands = [_call('a', 'terminal'), _call('b', 'terminal')];
      expect(turnFeedGroupLabel(es, commands), '2 comandos');
      final resources = [
        _call('a', 'skill_view', detail: 'a → x.md'),
        _call('b', 'skill_view', detail: 'a → y.md'),
      ];
      expect(turnFeedGroupLabel(es, resources), '2 recursos de skill leídos');
    });
  });

  group('the opened pill', () {
    for (final width in const [360.0, 750.0]) {
      testWidgets('${width.toInt()} dp: each row a pill on the connector, '
          '«Verb ×N», the times on one column', (tester) async {
        await _screen(tester, width);
        await tester.pumpWidget(_host(_screenshot()));
        await tester.pump();

        // Five pills, not thirteen rows, each with its tick, each done one
        // with the ring and its check at the trailing end.
        expect(_pills(), findsNWidgets(5));
        expect(_ticks(), findsNWidgets(5));
        expect(_checks(_pills()), findsNWidgets(5));
        for (final id in ['s1', 'w1', 'm1']) {
          expect(_groupPill(id), findsOneWidget);
        }
        expect(_pill('t1'), findsOneWidget);
        expect(_pill('s6'), findsOneWidget);
        for (final id in ['s2', 's5', 'w2', 'm3']) {
          expect(_row(id), findsNothing);
        }
        expect(
          _words(tester, _groupPill('s1')),
          startsWith('Skill cargada ×5  current-news-research'),
        );
        expect(
          _words(tester, _groupPill('w1')),
          'Búsqueda web completada ×3',
        );
        expect(_words(tester, _groupPill('m1')), 'Omh Memory ×3');
        expect(_words(tester, _pill('t1')), 'Ejecutó  canary');

        // The pills sit one under another, the same width, inside the
        // connector's gutter.
        final lefts = {
          for (final pill in tester.widgetList(_pills()))
            tester.getTopLeft(find.byWidget(pill)).dx,
        };
        expect(lefts, hasLength(1));

        // Every time ends on the same x, just before the ring, whether or
        // not the pill has a caret.
        final edges = [
          for (final id in ['group-s1', 't1', 's6', 'group-w1', 'group-m1'])
            tester
                .getTopRight(find.byKey(ValueKey('live-turn-time-$id')))
                .dx,
        ];
        for (final edge in edges) {
          expect(edge, moreOrLessEquals(edges.first, epsilon: 0.01));
        }

        // A caret only where the pill opens.
        Finder caret(String id) =>
            find.byKey(ValueKey('live-turn-caret-$id'));
        expect(caret('group-s1'), findsOneWidget);
        expect(caret('t1'), findsOneWidget);
        expect(caret('s6'), findsNothing);

        // The full skill name fits on a foldable; a phone ellipsizes it at
        // the end of the pill.
        final line = _line(tester, _pill('s6'));
        expect(line.text.toPlainText(), 'Skill cargada  $_longSkill');
        expect(line.didExceedMaxLines, width < 700);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('each kind its icon; the words in the receipt rows\' size and '
        'ink, the detail fainter', (tester) async {
      await _screen(tester, 750);
      await tester.pumpWidget(_host(_screenshot()));
      await tester.pump();
      final colors = AppTheme.hermesRedDark.extension<HermesThemeColors>()!;
      IconData iconOf(Finder pill) => tester
          .widget<Icon>(
            find.descendant(of: pill, matching: find.byType(Icon)).first,
          )
          .icon!;
      expect(iconOf(_groupPill('s1')), HIcons.auto_awesome_rounded);
      expect(iconOf(_pill('t1')), HIcons.terminal_rounded);
      expect(iconOf(_groupPill('w1')), HIcons.search_rounded);
      expect(iconOf(_groupPill('m1')), HIcons.psychology_outlined);
      final spans = _spans(tester, _pill('t1'));
      final receipt = TurnReceiptPill.styleOf(tester.element(_pill('t1')));
      expect(spans.first.style!.fontSize, receipt.fontSize);
      expect(spans.first.style!.fontWeight, FontWeight.w400);
      expect(spans.first.style!.color, receipt.color);
      expect(spans.last.style!.fontSize, receipt.fontSize);
      expect(spans.last.style!.color!.a, lessThan(receipt.color!.a));
      expect(colors.error, isNot(receipt.color));
    });

    testWidgets('a group opens to its calls, one level in on a connector of '
        'their own, and remembers it', (tester) async {
      await _screen(tester, 750);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(_screenshot()));
      await tester.pump();

      final node = tester.getSemantics(_group('s1'));
      expect(
        node.label,
        'Skill cargada ×5, current-news-research, grounded-citations, '
        'omh-web-research, omh-memory-system, hermes-tools, 0:11',
      );
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isExpanded, Tristate.isFalse);
      expect(
        tester.getSemantics(_row('s6')).label,
        '0:02, Skill cargada, $_longSkill',
      );

      await tester.tap(_group('s1'));
      await tester.pump();
      for (final id in ['s1', 's2', 's3', 's4', 's5']) {
        expect(_pill(id), findsOneWidget);
      }
      expect(_pills(), findsNWidgets(10));
      expect(_ticks(), findsNWidgets(10));
      expect(_checks(_pills()), findsNWidgets(10));
      expect(
        tester.getSemantics(_group('s1')).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      // One level in: the calls' pills start further in than the group's,
      // and end on the same edge, their times on the same column.
      final group = tester.getRect(_groupPill('s1'));
      final member = tester.getRect(_pill('s2'));
      expect(member.left, greaterThan(group.left));
      expect(member.top, greaterThan(group.bottom));
      expect(member.right, moreOrLessEquals(group.right));
      expect(
        tester.getTopRight(find.byKey(const ValueKey('live-turn-time-s2'))).dx,
        moreOrLessEquals(
          tester
              .getTopRight(
                find.byKey(const ValueKey('live-turn-time-group-s1')),
              )
              .dx,
        ),
      );
      // The next row hangs from the same first-level connector.
      expect(tester.getRect(_pill('t1')).left, group.left);

      // Closing the pill and opening it again: still open.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(_screenshot()));
      await tester.pump();
      expect(_pill('s3'), findsOneWidget);

      await tester.tap(_group('s1'));
      await tester.pump();
      expect(_pill('s3'), findsNothing);
      semantics.dispose();
    });

    testWidgets('what a group unfolds reads as unfolded: its ring in the '
        'secondary ink, on a quieter connector; the open group keeps full '
        'strength', (tester) async {
      await _screen(tester, 750);
      await tester.pumpWidget(_host(_screenshot()));
      await tester.pump();
      await tester.tap(_group('s1'));
      await tester.pump();
      final colors = AppTheme.hermesRedDark.extension<HermesThemeColors>()!;
      final group = _groupPill('s1');
      final member = _pill('s2');
      final lone = _pill('t1');
      expect(tester.widget<LiveTurnRowPill>(group).quiet, isFalse);
      expect(tester.widget<LiveTurnRowPill>(lone).quiet, isFalse);
      expect(tester.widget<LiveTurnRowPill>(member).quiet, isTrue);
      // One height for every line, that of the receipt rows.
      for (final line in [group, member, lone]) {
        expect(tester.getSize(line).height, TurnReceiptPill.height);
      }
      // The unfolded level hangs from a quieter connector.
      expect(
        tester
            .widget<LiveTurnBranch>(
              find
                  .ancestor(of: member, matching: find.byType(LiveTurnBranch))
                  .first,
            )
            .quiet,
        isTrue,
      );
      expect(
        tester
            .widget<LiveTurnBranch>(
              find
                  .ancestor(of: group, matching: find.byType(LiveTurnBranch))
                  .first,
            )
            .quiet,
        isFalse,
      );
      LiveRingCheck ringOf(Finder pill) => tester.widget<LiveRingCheck>(
        find.descendant(of: pill, matching: find.byType(LiveRingCheck)),
      );
      expect(ringOf(member).color, colors.textSecondary);
      expect(ringOf(group).color, isNull, reason: 'the success ink');
      // Its caret turned down: it is open.
      expect(
        tester
            .widget<AnimatedRotation>(
              find.ancestor(
                of: find.byKey(const ValueKey('live-turn-caret-group-s1')),
                matching: find.byType(AnimatedRotation),
              ),
            )
            .turns,
        0,
      );
    });

    testWidgets('no step has a capsule: no outline, no fill, no glass; only '
        'the connector is drawn', (tester) async {
      await _screen(tester, 750);
      await tester.pumpWidget(_host(_screenshot()));
      await tester.pump();
      await tester.tap(_group('s1'));
      await tester.pump();
      expect(_pills(), findsNWidgets(10));
      for (final element in _pills().evaluate()) {
        final pill = find.byWidget(element.widget);
        expect((element.widget as LiveTurnRowPill).plain, isTrue);
        for (final type in [DecoratedBox, Container, HermesGelSurface, Card]) {
          expect(
            find.descendant(of: pill, matching: find.byType(type)),
            findsNothing,
            reason: '$type in ${element.widget.key}',
          );
        }
        expect(
          find.descendant(
            of: pill,
            matching: find.byWidgetPredicate(
              (widget) => widget is Material && widget.shape != null,
            ),
          ),
          findsNothing,
        );
      }
      // The tree is still there: one tick per line.
      expect(_ticks(), findsNWidgets(10));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap on a step opens what it left, and again closes it', (
      tester,
    ) async {
      await _screen(tester, 750);
      await tester.pumpWidget(_host(_screenshot()));
      await tester.pump();
      const out = ValueKey('out-t1');
      expect(find.byKey(out), findsNothing);
      await tester.tap(_pill('t1'));
      await tester.pump();
      expect(find.byKey(out), findsOneWidget);
      await tester.tap(_pill('t1'));
      await tester.pump();
      expect(find.byKey(out), findsNothing);
    });

    testWidgets('a failed step is told without a capsule: the error sign, '
        'the word and the error ink', (tester) async {
      await _screen(tester, 750);
      await tester.pumpWidget(
        _host([
          _call('ok', 'terminal', title: 'Ejecutó', detail: 'ls', seconds: 1),
          _call(
            'bad',
            'read_file',
            title: 'No pudo leer',
            detail: 'notes.md',
            seconds: 2,
            failed: true,
          ),
        ]),
      );
      await tester.pump();
      final colors = AppTheme.hermesRedDark.extension<HermesThemeColors>()!;
      final bad = _pill('bad');
      final good = _pill('ok');
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: bad,
                matching: find.byIcon(HIcons.error_outline_rounded),
              ),
            )
            .color,
        colors.error,
      );
      expect(_checks(bad), findsNothing);
      expect(_checks(good), findsOneWidget);
      final word = tester.widget<Text>(
        find.descendant(
          of: bad,
          matching: find.text(StringsEs().stepsBarStatusFailed),
        ),
      );
      expect(word.style!.color, colors.error);
      expect(_spans(tester, bad).first.style!.color, colors.error);
      expect(_spans(tester, good).first.style!.color, isNot(colors.error));
      expect(
        find.descendant(of: bad, matching: find.byType(DecoratedBox)),
        findsNothing,
      );
    });

    testWidgets('the live window keeps its outlined pill', (tester) async {
      await _screen(tester, 750);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: LiveTurnRowPill(
              row: LiveTurnRow.of(
                _call('w', 'terminal', title: 'Ejecutó', seconds: 1),
              ),
            ),
          ),
        ),
      );
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(LiveTurnRowPill),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect((box.decoration as BoxDecoration).border, isNotNull);
      expect(tester.widget<LiveTurnRowPill>(find.byType(LiveTurnRowPill)).plain, isFalse);
    });

    testWidgets('a run with the call in hand: the ring turning and its '
        'clock', (tester) async {
      await _screen(tester, 750);
      final started = _now.subtract(const Duration(seconds: 4));
      await tester.pumpWidget(_host(_screenshot(running: true, at: started)));
      await tester.pump();
      final pill = _groupPill('w1');
      expect(
        find.descendant(of: pill, matching: find.byType(LiveSpinnerRing)),
        findsOneWidget,
      );
      expect(_checks(pill), findsNothing);
      expect(
        find.descendant(of: pill, matching: find.text('0:04')),
        findsOneWidget,
      );
      expect(_words(tester, pill), 'Búsqueda web completada ×3');
      expect(_checks(_groupPill('s1')), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(_group('w1')).label,
        'Búsqueda web completada ×3, En curso',
      );
      semantics.dispose();
    });

    testWidgets('live updates: a new call never re-enters the rows before it, '
        'a growing group keeps its place, an open row stays open', (
      tester,
    ) async {
      await _screen(tester, 750);
      TurnStepCardEntry search(String id) => _call(
        id,
        'web_search',
        title: 'Búsqueda web completada',
        seconds: 6,
      );
      final first = [
        _call(
          'a',
          'terminal',
          title: 'Ejecutó',
          detail: 'git',
          seconds: 2,
          opened: const Text('salida a', key: ValueKey('out-a')),
        ),
        search('b'),
      ];
      await tester.pumpWidget(_host(first, reduced: false));
      await tester.pumpAndSettle();
      await tester.tap(_row('a'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('out-a')), findsOneWidget);
      final rowB = tester.element(find.byKey(const ValueKey('turn-row-b')));

      Finder entering(String id) => find.descendant(
        of: find.byKey(ValueKey('turn-row-$id')),
        matching: find.byType(TweenAnimationBuilder<double>),
      );
      Element rowOf(String id) => tester.element(find.byKey(ValueKey(id)));

      // b is joined by a second search: the lone pill becomes the group's,
      // in the same element, and does not come in again.
      final second = [...first, search('c')];
      await tester.pumpWidget(_host(second, reduced: false));
      await tester.pump();
      expect(rowOf('turn-row-b'), same(rowB));
      expect(_words(tester, _groupPill('b')), 'Búsqueda web completada ×2');
      expect(entering('a'), findsNothing);
      expect(entering('b'), findsNothing);

      final third = [...second, search('d')];
      await tester.pumpWidget(_host(third, reduced: false));
      await tester.pump();
      expect(rowOf('turn-row-b'), same(rowB));
      expect(_words(tester, _groupPill('b')), 'Búsqueda web completada ×3');
      expect(entering('b'), findsNothing);

      // Another kind: a new pill that comes in; the ones before it stay.
      await tester.pumpWidget(
        _host([...third, _call('e', 'terminal', seconds: 1)], reduced: false),
      );
      await tester.pump();
      expect(entering('e'), findsOneWidget);
      expect(entering('a'), findsNothing);
      expect(entering('b'), findsNothing);
      expect(find.byKey(const ValueKey('out-a')), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('a call being read stays open when the next call of its '
        'kind joins it', (tester) async {
      await _screen(tester, 750);
      TurnStepCardEntry command(String id) => _call(
        id,
        'terminal',
        title: 'Ejecutó',
        detail: 'git',
        seconds: 2,
        opened: Text('salida $id', key: ValueKey('out-$id')),
      );
      await tester.pumpWidget(_host([command('a')]));
      await tester.pump();
      await tester.tap(_row('a'));
      await tester.pump();
      expect(find.byKey(const ValueKey('out-a')), findsOneWidget);

      await tester.pumpWidget(_host([command('a'), command('b')]));
      await tester.pump();
      // One pill now, open on the call being read (Desktop's `ToolRun`:
      // open while one of its calls is).
      expect(_group('a'), findsOneWidget);
      expect(_words(tester, _groupPill('a')), 'Ejecutó ×2  git');
      expect(find.byKey(const ValueKey('out-a')), findsOneWidget);
      await tester.tap(_row('b'));
      await tester.pump();
      expect(find.byKey(const ValueKey('out-b')), findsOneWidget);
      await tester.tap(_group('a'));
      await tester.pump();
      expect(find.byKey(const ValueKey('out-a')), findsNothing);
      expect(_row('b'), findsNothing);
      await tester.pumpWidget(_host([command('a'), command('b')]));
      await tester.pump();
      expect(_row('b'), findsNothing);
    });

    testWidgets('thoughts and outcomes keep their look, on the connector', (
      tester,
    ) async {
      await _screen(tester, 750);
      await tester.pumpWidget(
        _host([
          _call('a', 'terminal', title: 'Ejecutó', seconds: 2),
          _thought('p'),
          _call('b', 'terminal', title: 'Ejecutó', seconds: 2),
          const TurnStepCardEntry(
            id: 'outcome',
            kind: TurnStepCardKind.outcome,
            title: 'Detenido',
            icon: HIcons.stop_circle_outlined,
            semanticsLabel: 'Detenido',
          ),
        ]),
      );
      await tester.pump();
      // The thought between the two commands ends the run.
      expect(_pill('a'), findsOneWidget);
      expect(_pill('b'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('turn-inner-thought-p')),
        findsOneWidget,
      );
      expect(find.text('Detenido'), findsOneWidget);
      // All four hang from one connector at the same gutter.
      final x = tester.getTopLeft(_pill('a')).dx;
      expect(tester.getTopLeft(_pill('b')).dx, x);
      final outcome = find.byKey(const ValueKey('turn-step-card-outcome'));
      expect(tester.getTopLeft(outcome).dx, x);
      expect(tester.takeException(), isNull);
    });

    for (final (width, scale) in const [
      (360.0, 1.3),
      (360.0, 2.0),
      (750.0, 1.3),
      (750.0, 2.0),
    ]) {
      testWidgets('${width.toInt()} dp, text $scale: no overflow, closed or '
          'open', (tester) async {
        await _screen(tester, width);
        await tester.pumpWidget(_host(_screenshot(), scale: scale));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(_group('s1'));
        await tester.pump();
        await tester.tap(_row('t1'));
        await tester.pump();
        expect(find.byKey(const ValueKey('out-t1')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          _host([
            ..._screenshot(running: true, at: _now),
            _call('x', 'terminal', failed: true, seconds: 3),
            _call('y', 'terminal', seconds: 3),
          ], scale: scale),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the light theme draws the same pills', (tester) async {
      await _screen(tester, 360);
      await tester.pumpWidget(
        _host(_screenshot(), theme: AppTheme.fromMode(AppThemeMode.light)),
      );
      await tester.pump();
      expect(_pills(), findsNWidgets(5));
      expect(_checks(_pills()), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('through the pill: the turn opened and the same turn settled '
      'show the same pills', (tester) async {
    await _screen(tester, 750);
    final start = _now.subtract(const Duration(seconds: 80));
    List<ChatTraceEvent> events() => [
      for (final (i, name) in const [
        'current-news-research',
        'grounded-citations',
        'omh-web-research',
      ].indexed)
        ChatTraceEvent(
          id: 's$i',
          label: 'skill_view',
          status: 'completed',
          detail: name,
          duration: const Duration(seconds: 2),
        ),
      for (var i = 0; i < 2; i++)
        ChatTraceEvent(
          id: 'w$i',
          label: 'web_search',
          status: 'completed',
          detail: 'una consulta privada',
          duration: const Duration(seconds: 6),
        ),
    ];
    Widget turn({required bool active}) => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: LiveTurnScope(
            inlineActivity: true,
            status: LiveTurnStatus(active: active, startedAt: start),
            clock: () => _now,
            child: ThinkingTraceCard(
              active: active,
              stepCards: true,
              events: events(),
              duration: const Duration(seconds: 80),
              headerBuilder: (_, summary, details) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [summary, details],
              ),
            ),
          ),
        ),
      ),
    );
    for (final active in [true, false]) {
      await tester.pumpWidget(turn(active: active));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('chat-inline-activity')));
      await tester.pump(const Duration(seconds: 1));
      expect(
        _words(tester, _groupPill('s0')),
        'Skill cargada ×3  current-news-research, grounded-citations, '
        'omh-web-research',
        reason: '$active',
      );
      expect(
        _words(tester, _groupPill('w0')),
        'Búsqueda web completada ×2',
        reason: '$active',
      );
      expect(_ticks(), findsNWidgets(2), reason: '$active');
      // A search's query is never on screen.
      expect(
        find.textContaining('consulta privada', findRichText: true),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the closed window and the opened list draw a call with the '
      'same pill: its icon, its words, its ring', (tester) async {
    await _screen(tester, 750);
    final start = _now.subtract(const Duration(seconds: 30));
    // As the chat builds them from `tool.start`/`tool.complete`
    // (`active_chat_service.dart`): the detail is the client's projection of
    // the call's arguments. A plugin's skill is named `namespace:name`.
    final events = [
      ChatTraceEvent(
        id: 't',
        label: 'terminal',
        status: 'completed',
        detail: activityToolDetail('terminal', {'command': 'git status'}),
        duration: const Duration(seconds: 2),
      ),
      ChatTraceEvent(
        id: 'k',
        label: 'skill_view',
        status: 'completed',
        detail: activityToolDetail('skill_view', {'name': 'omh:web-research'}),
        duration: const Duration(seconds: 3),
      ),
      ChatTraceEvent(
        id: 'k2',
        label: 'skill_view',
        status: 'completed',
        detail: activityToolDetail('skill_view', {
          'name': 'research:grounded-citations',
        }),
        duration: const Duration(seconds: 2),
      ),
      ChatTraceEvent(
        id: 'w',
        label: 'web_search',
        status: 'running',
        detail: activityToolDetail('web_search', {'query': 'algo privado'}),
        startedAt: _now.subtract(const Duration(seconds: 4)),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: LiveTurnScope(
              inlineActivity: true,
              status: LiveTurnStatus(active: true, startedAt: start),
              clock: () => _now,
              child: ThinkingTraceCard(
                active: true,
                stepCards: true,
                events: events,
                headerBuilder: (_, summary, details) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [summary, details],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    IconData iconIn(Finder of) => tester
        .widget<Icon>(
          find.descendant(of: of, matching: find.byType(Icon)).first,
        )
        .icon!;
    Finder windowRow(String id) => find.byKey(ValueKey('live-turn-row-$id'));

    // Closed: the window, in its approved look.
    final window = find.byKey(const ValueKey('live-turn-window'));
    expect(window, findsOneWidget);
    expect(
      find.descendant(of: window, matching: find.byType(LiveTurnRowPill)),
      findsNWidgets(3),
    );
    expect(_checks(window), findsNWidgets(2));
    expect(
      find.descendant(of: window, matching: find.byType(LiveSpinnerRing)),
      findsOneWidget,
    );
    expect(_words(tester, windowRow('t')), 'Ejecutó  git');
    // The two skill loads: «×2», with the last one's name.
    expect(
      _words(tester, windowRow('k')),
      'Skill cargada ×2  research:grounded-citations',
    );
    final closed = (
      command: iconIn(windowRow('t')),
      skill: iconIn(windowRow('k')),
      search: iconIn(windowRow('w')),
    );
    expect(closed.command, HIcons.terminal_rounded);
    expect(closed.skill, HIcons.auto_awesome_rounded);

    // Opened: the same pills, the same icons, the same ring-checks.
    await tester.tap(find.byKey(const ValueKey('chat-inline-activity')));
    await tester.pump();
    expect(window, findsNothing);
    expect(iconIn(_pill('t')), closed.command);
    expect(iconIn(_groupPill('k')), closed.skill);
    expect(iconIn(_pill('w')), closed.search);
    expect(_checks(_pills()), findsNWidgets(2));
    expect(
      find.descendant(of: _pill('w'), matching: find.byType(LiveSpinnerRing)),
      findsOneWidget,
    );
    expect(
      _words(tester, _groupPill('k')),
      'Skill cargada ×2  omh:web-research, research:grounded-citations',
    );
    expect(
      find.descendant(of: _groupPill('k'), matching: find.text('0:05')),
      findsOneWidget,
    );
    expect(
      find.textContaining('algo privado', findRichText: true),
      findsNothing,
    );
  });
}
