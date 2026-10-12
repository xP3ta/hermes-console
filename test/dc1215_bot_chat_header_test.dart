import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/bot_chat_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

// dc1215: the canonical Bot Chat header in the Dots style. The bot's face
// sits centred over a pill with its name in bold and ONE grey line of live
// status: what it is doing now, «Te espera…» in amber when it waits for an
// approval or an answer, or its last activity when idle.

final DateTime _t0 = DateTime(2026, 9, 21, 12);

ActivityStep _step(
  String label, {
  String? detail,
  ActivityStepStatus status = ActivityStepStatus.running,
  ActivityStepKind kind = ActivityStepKind.tool,
}) => ActivityStep(
  id: 'id-$label',
  kind: kind,
  label: label,
  status: status,
  detail: detail,
  startedAt: _t0,
);

final Strings _es = StringsEs();
final Strings _en = StringsEn();

BotChatHeaderStatus _status({
  Strings? s,
  bool approval = false,
  bool question = false,
  ActivitySnapshot snapshot = ActivitySnapshot.idle,
  String? idle = 'Última actividad · 10:12',
}) => botChatHeaderStatus(
  strings: s ?? _es,
  approvalPending: approval,
  questionPending: question,
  snapshot: snapshot,
  idleText: idle,
);

Widget _app(Widget child, {double textScale = 1, bool reduceMotion = true}) =>
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: home!,
      ),
      home: child,
    );

/// A static stand-in for the living face: these tests are about layout and
/// status, the face itself belongs to the roster work.
Widget _face(double size) => SizedBox(
  key: const ValueKey('test-face'),
  width: size,
  height: size,
  child: const ColoredBox(color: Colors.orange),
);

Widget _scaffold({
  required BotChatHeaderStatus status,
  String name = 'Hermes',
  bool compact = false,
}) => Builder(
  builder: (context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        toolbarHeight: BotChatDotsHeader.heightFor(scaler, compact: compact),
        title: BotChatDotsHeader(
          key: const ValueKey('bot-chat-header'),
          faceBuilder: _face,
          name: name,
          status: status,
          compact: compact,
        ),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
        ],
      ),
      body: const SizedBox.expand(),
    );
  },
);

Finder get _statusText =>
    find.byKey(const ValueKey('bot-chat-header-subtitle'));
Finder get _pill => find.byKey(const ValueKey('bot-chat-header-pill'));

void main() {
  group('status', () {
    test('working: the current step, as the working line names it', () {
      final status = _status(
        snapshot: ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          current: _step('terminal', detail: 'flutter'),
        ),
      );
      expect(status.text, 'terminal · flutter');
      expect(status.tone, BotChatHeaderTone.working);
    });

    test('working with a skill: the skill name without its category', () {
      final status = _status(
        snapshot: ActivitySnapshot(
          turnActive: true,
          current: _step('skill_view', detail: 'creative/hyperframes → api.md'),
        ),
      );
      expect(status.text, 'hyperframes');
    });

    test('working with no running step: the latest finished one', () {
      final status = _status(
        snapshot: ActivitySnapshot(
          turnActive: true,
          done: [
            _step('patch', detail: 'b.dart', status: ActivityStepStatus.done),
            _step('read_file', status: ActivityStepStatus.done),
          ],
        ),
      );
      expect(status.text, 'patch · b.dart');
      expect(status.tone, BotChatHeaderTone.working);
    });

    test('working with nothing known yet: «Pensando…»', () {
      for (final s in [_es, _en]) {
        final status = _status(
          s: s,
          snapshot: const ActivitySnapshot(turnActive: true),
        );
        expect(status.text, s.chatActivityThinking);
        expect(status.tone, BotChatHeaderTone.working);
      }
    });

    test('an approval wins over the current step, in amber', () {
      final status = _status(
        approval: true,
        snapshot: ActivitySnapshot(
          turnActive: true,
          current: _step('terminal'),
        ),
      );
      expect(status.text, 'Te espera: aprobación');
      expect(status.tone, BotChatHeaderTone.waiting);
      expect(_status(s: _en, approval: true).text, 'Waiting for you: approval');
    });

    test(
      'a question or a turn waiting for the user: «Te espera: respuesta»',
      () {
        expect(_status(question: true).text, 'Te espera: respuesta');
        expect(_status(question: true).tone, BotChatHeaderTone.waiting);
        final waiting = _status(
          snapshot: const ActivitySnapshot(
            turnActive: true,
            waitingForUser: true,
          ),
        );
        expect(waiting.text, 'Te espera: respuesta');
        expect(waiting.tone, BotChatHeaderTone.waiting);
      },
    );

    test('idle: the last activity, or nothing invented', () {
      final idle = _status();
      expect(idle.text, 'Última actividad · 10:12');
      expect(idle.tone, BotChatHeaderTone.idle);
      expect(_status(idle: null).text, isNull);
    });

    test('background work alone is not the bot thinking', () {
      final status = _status(
        snapshot: const ActivitySnapshot(subagentGenericCount: 2),
      );
      expect(status.tone, BotChatHeaderTone.idle);
    });
  });

  group('header', () {
    testWidgets('face centred over a pill with the name and one status line', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          _scaffold(
            status: _status(
              snapshot: ActivitySnapshot(
                turnActive: true,
                current: _step('terminal', detail: 'flutter'),
              ),
            ),
          ),
        ),
      );
      final face = tester.getRect(find.byKey(const ValueKey('test-face')));
      final pill = tester.getRect(_pill);
      expect((face.center.dx - pill.center.dx).abs(), lessThan(1));
      expect((pill.center.dx - 195).abs(), lessThan(1), reason: 'centred');
      expect(face.top, lessThan(pill.top));
      expect(face.bottom, greaterThan(pill.top), reason: 'rides on the pill');
      final name = tester.widget<Text>(
        find.descendant(of: _pill, matching: find.text('Hermes')),
      );
      expect(name.style!.fontWeight, FontWeight.w700);
      final status = tester.widget<Text>(_statusText);
      expect(status.data, 'terminal · flutter');
      expect(status.maxLines, 1);
      expect(status.overflow, TextOverflow.ellipsis);
      final colors = AppTheme.hermesRedDark.hermes;
      expect(status.style!.color, colors.textSecondary);
      // The whole header fits its bar.
      final bar = tester.getRect(find.byType(AppBar));
      expect(face.top, greaterThanOrEqualTo(bar.top));
      expect(pill.bottom, lessThanOrEqualTo(bar.bottom));
    });

    testWidgets('waiting reads in amber', (tester) async {
      await tester.pumpWidget(_app(_scaffold(status: _status(approval: true))));
      final status = tester.widget<Text>(_statusText);
      expect(status.data, 'Te espera: aprobación');
      expect(status.style!.color, AppTheme.hermesRedDark.hermes.warning);
    });

    testWidgets('no status line when idle with nothing to say', (tester) async {
      await tester.pumpWidget(_app(_scaffold(status: _status(idle: null))));
      expect(_statusText, findsNothing);
      expect(find.text('Hermes'), findsOneWidget);
    });

    testWidgets('compact on scroll: smaller bar, face beside the pill', (
      tester,
    ) async {
      const scaler = TextScaler.noScaling;
      expect(
        BotChatDotsHeader.heightFor(scaler, compact: true),
        lessThan(BotChatDotsHeader.heightFor(scaler, compact: false)),
      );
      expect(
        BotChatDotsHeader.heightFor(scaler, compact: true),
        lessThanOrEqualTo(kToolbarHeight),
      );
      await tester.pumpWidget(
        _app(_scaffold(status: _status(), compact: true)),
      );
      final face = tester.getRect(find.byKey(const ValueKey('test-face')));
      final pill = tester.getRect(_pill);
      expect(face.right, lessThanOrEqualTo(pill.left + 1));
      expect((face.center.dy - pill.center.dy).abs(), lessThan(2));
      expect(_statusText, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final compact in [false, true]) {
      testWidgets('text scale 2.0 at 360dp fits (compact: $compact)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            _scaffold(
              name: 'Un bot con un nombre larguísimo que no cabe',
              compact: compact,
              status: _status(
                snapshot: ActivitySnapshot(
                  turnActive: true,
                  current: _step(
                    'una_herramienta_con_nombre_larguisimo',
                    detail: 'archivo_con_nombre_larguisimo.dart',
                  ),
                ),
              ),
            ),
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(AppBar));
        final pill = tester.getRect(_pill);
        expect(pill.bottom, lessThanOrEqualTo(bar.bottom));
        expect(pill.left, greaterThanOrEqualTo(0));
        expect(pill.right, lessThanOrEqualTo(360));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: _statusText, matching: find.byType(RichText)),
        );
        // The status follows the reader's text size up to the app bar
        // title clamp Material applies (1.34), and the bar is sized for it.
        expect(paragraph.textScaler.scale(14) / 14, closeTo(1.34, 0.01));
        expect(
          bar.height,
          BotChatDotsHeader.heightFor(
            const TextScaler.linear(2),
            compact: compact,
          ),
        );
        // Past the clamp the bar does not grow: it is sized for what the
        // title really paints.
        expect(
          BotChatDotsHeader.heightFor(
            const TextScaler.linear(2),
            compact: compact,
          ),
          BotChatDotsHeader.heightFor(
            const TextScaler.linear(BotChatDotsHeader.maxTitleTextScale),
            compact: compact,
          ),
        );
      });
    }

    testWidgets('idle header settles: nothing ticks', (tester) async {
      await tester.pumpWidget(
        _app(_scaffold(status: _status()), reduceMotion: false),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('one semantics node says who and what', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(_scaffold(status: _status(approval: true))));
      expect(
        find.bySemanticsLabel('Hermes, Te espera: aprobación'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
