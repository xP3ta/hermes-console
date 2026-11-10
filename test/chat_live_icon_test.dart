import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_live_icon.dart';
import 'package:hermes_android/core/widgets/chat/chat_queue_chip.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The live chat's ten icons (Generative Icons, MIT): frame strips with a
// pure frame function, a theme tint, a settled pose, a still pose for
// «reduce motion», and the icon each live piece picks.

final _start = DateTime(2026, 11, 7);

Widget _host(
  Widget child, {
  bool reduced = false,
  double scale = 1,
  bool light = false,
}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.fromMode(light ? AppThemeMode.light : AppThemeMode.dark),
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(scale),
    ),
    child: body!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// A strip of the right size, painted opaque, so a loader can hand it back.
Future<ui.Image> _strip(ChatLiveGlyph glyph) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(
      0,
      0,
      (glyph.frames * kChatLiveIconFramePx).toDouble(),
      kChatLiveIconFramePx.toDouble(),
    ),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(
    glyph.frames * kChatLiveIconFramePx,
    kChatLiveIconFramePx,
  );
}

/// Strips decoded up front (real async), handed back by the loader at once so
/// the widget tree settles under the test clock.
Future<void> _preload(WidgetTester tester) async {
  final images = <ChatLiveGlyph, ui.Image>{};
  await tester.runAsync(() async {
    for (final glyph in ChatLiveGlyph.values) {
      images[glyph] = await _strip(glyph);
    }
  });
  ChatLiveIconCache.loader = (glyph) async => images[glyph];
}

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(ChatLiveIcon).first);

Color _tint(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(ChatLiveIcon),
          matching: find.byType(CustomPaint),
        ),
      )
      .firstWhere((p) => p.painter != null);
  return (paint.painter! as dynamic).color as Color;
}

ChatLiveGlyph _glyphOf(WidgetTester tester, Finder within) => tester
    .widget<ChatLiveIcon>(
      find.descendant(of: within, matching: find.byType(ChatLiveIcon)).first,
    )
    .glyph;

void main() {
  final bundleLoader = ChatLiveIconCache.loader;
  tearDown(() {
    ChatLiveIconCache.reset();
    ChatLiveIconCache.loader = bundleLoader;
  });

  group('the shipped strips', () {
    final atlas = jsonDecode(
      File('assets/chat_icons/atlas.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final sources = jsonDecode(
      File('assets/chat_icons/SOURCES.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    test('are exactly the ten chat icons', () {
      expect(ChatLiveGlyph.values.map((g) => g.id).toSet(), atlas.keys.toSet());
      expect(ChatLiveGlyph.values, hasLength(10));
    });

    for (final glyph in ChatLiveGlyph.values) {
      test('${glyph.id}: frames, size and sha-256 match the records', () async {
        final file = File(glyph.asset);
        expect(file.existsSync(), isTrue, reason: glyph.asset);
        final bytes = file.readAsBytesSync();
        final entry = atlas[glyph.id] as Map<String, dynamic>;
        expect(entry['frames'], glyph.frames);
        expect(entry['size'], kChatLiveIconFramePx);
        expect(entry['frameMs'], kChatLiveIconFrame.inMilliseconds);
        final recorded =
            (sources['icons'] as Map<String, dynamic>)[glyph.id]
                as Map<String, dynamic>;
        expect(sha256.convert(bytes).toString(), recorded['atlasSha256']);
        expect(recorded['license'], 'MIT');
        expect(recorded['sourceSha256'], hasLength(64));
      });
    }

    testWidgets('decode to a strip of frames x 64 by 64', (tester) async {
      await tester.runAsync(() async {
        for (final glyph in ChatLiveGlyph.values) {
          final codec = await ui.instantiateImageCodec(
            File(glyph.asset).readAsBytesSync(),
          );
          final image = (await codec.getNextFrame()).image;
          expect(
            image.width,
            glyph.frames * kChatLiveIconFramePx,
            reason: glyph.id,
          );
          expect(image.height, kChatLiveIconFramePx, reason: glyph.id);
          codec.dispose();
        }
      });
    });
  });

  group('frame function', () {
    const glyph = ChatLiveGlyph.terminalAgent;
    final play = kChatLiveIconFrame * (glyph.frames - 1);

    test('starts on the first frame and runs forward', () {
      expect(chatLiveIconFrameAt(glyph, Duration.zero), 0);
      expect(chatLiveIconFrameAt(glyph, kChatLiveIconFrame * 5), 5);
    });

    test('holds the last pose, plays back, holds the first and wraps', () {
      expect(
        chatLiveIconFrameAt(glyph, play + const Duration(milliseconds: 10)),
        glyph.frames - 1,
      );
      expect(
        chatLiveIconFrameAt(
          glyph,
          play + kChatLiveIconHold + kChatLiveIconFrame * 3,
        ),
        glyph.frames - 1 - 3,
      );
      final cycle = (play + kChatLiveIconHold) * 2;
      expect(chatLiveIconFrameAt(glyph, cycle), 0);
      expect(chatLiveIconFrameAt(glyph, cycle + kChatLiveIconFrame * 2), 2);
    });

    test('never leaves the strip', () {
      for (final g in ChatLiveGlyph.values) {
        for (var ms = 0; ms < 20000; ms += 37) {
          final f = chatLiveIconFrameAt(g, Duration(milliseconds: ms));
          expect(f, inInclusiveRange(0, g.frames - 1), reason: '${g.id} @$ms');
        }
      }
    });

    test('the settled pose is the last frame', () {
      for (final g in ChatLiveGlyph.values) {
        expect(chatLiveIconRestFrame(g), g.frames - 1);
      }
    });
  });

  group('tools', () {
    test('command-like tools get the prompt, the rest the wrench', () {
      for (final tool in [
        'terminal',
        'execute_code',
        'process_manage',
        ' Terminal ',
      ]) {
        expect(
          chatLiveGlyphForTool(tool),
          ChatLiveGlyph.terminalAgent,
          reason: tool,
        );
      }
      for (final tool in [
        'read_file',
        'web_search',
        'delegate_task',
        '',
        null,
      ]) {
        expect(
          chatLiveGlyphForTool(tool),
          ChatLiveGlyph.toolCall,
          reason: '$tool',
        );
      }
    });
  });

  group('the widget', () {
    testWidgets('paints the fallback while the strip is not there', (
      tester,
    ) async {
      ChatLiveIconCache.loader = (_) async => null;
      await tester.pumpWidget(
        _host(
          const ChatLiveIcon(
            ChatLiveGlyph.check,
            color: Colors.teal,
            live: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('settled it rests on its last frame and does not animate', (
      tester,
    ) async {
      const glyph = ChatLiveGlyph.check;
      await _preload(tester);
      await tester.pumpWidget(
        _host(const ChatLiveIcon(glyph, color: Colors.teal)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(_state(tester).debugFrame, glyph.frames - 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('live it loops, and stops when it settles', (tester) async {
      const glyph = ChatLiveGlyph.reasoning;
      await _preload(tester);
      Widget icon({required bool live}) =>
          _host(ChatLiveIcon(glyph, color: Colors.teal, live: live));
      await tester.pumpWidget(icon(live: true));
      await tester.pump();
      // Let the app's own route transition finish: only the icon may tick.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.hasRunningAnimations, isTrue);
      // Over one full cycle (forward, hold, back, hold) it visits many frames.
      final seen = <int>{};
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        seen.add(_state(tester).debugFrame as int);
      }
      expect(seen.length, greaterThan(5));
      expect(seen, contains(0));
      expect(seen, contains(glyph.frames - 1));
      await tester.pumpWidget(icon(live: false));
      await tester.pump();
      // A rebuilt MaterialApp animates its theme for a moment: let that end.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.hasRunningAnimations, isFalse);
      expect(_state(tester).debugFrame, glyph.frames - 1);
    });

    testWidgets('reduce motion keeps it still even while live', (tester) async {
      await _preload(tester);
      await tester.pumpWidget(
        _host(
          const ChatLiveIcon(
            ChatLiveGlyph.responseStream,
            color: Colors.teal,
            live: true,
          ),
          reduced: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(
        _state(tester).debugFrame,
        ChatLiveGlyph.responseStream.frames - 1,
      );
    });

    for (final light in [false, true]) {
      testWidgets(
        'is tinted with the colour it is given (${light ? 'light' : 'dark'})',
        (tester) async {
          await _preload(tester);
          final color = light
              ? const Color(0xFF0B6B5F)
              : const Color(0xFF63D6C6);
          await tester.pumpWidget(
            _host(
              ChatLiveIcon(ChatLiveGlyph.queued, color: color),
              light: light,
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(_tint(tester), color);
        },
      );
    }

    testWidgets('is decorative and isolated for repaint', (tester) async {
      await _preload(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const ChatLiveIcon(ChatLiveGlyph.error, color: Colors.red)),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(ChatLiveIcon),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
      expect(find.bySemanticsLabel(RegExp('.+')), findsNothing);
      handle.dispose();
    });
  });

  group('where the live chat uses them', () {
    Widget row({bool live = true, bool failed = false, ChatLiveGlyph? glyph}) =>
        TurnInlineActivity(
          label: 'Ejecutando date',
          live: live,
          failed: failed,
          glyph: glyph,
          steps: 2,
          open: false,
          startedAt: _start,
          clock: () => _start,
          onTap: () {},
        );

    // The live look (9 nov 2026): the live card carries a turning ring (the
    // action in hand is a row of the window under it), and the settled line
    // a green ring with its check inside, or the error sign if it failed.
    testWidgets('the live row shows the turning ring, whatever the glyph', (
      tester,
    ) async {
      for (final glyph in [
        ChatLiveGlyph.reasoning,
        ChatLiveGlyph.terminalAgent,
        ChatLiveGlyph.toolCall,
        ChatLiveGlyph.delegateTask,
        ChatLiveGlyph.parallelTools,
        ChatLiveGlyph.responseStream,
        null,
      ]) {
        await tester.pumpWidget(_host(row(glyph: glyph), reduced: true));
        expect(
          find.descendant(
            of: find.byType(TurnInlineActivity),
            matching: find.byKey(const ValueKey('live-ring-spinner')),
          ),
          findsOneWidget,
          reason: '${glyph?.id}',
        );
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a settled row shows the outcome, whatever glyph it was', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          row(live: false, glyph: ChatLiveGlyph.terminalAgent),
          reduced: true,
        ),
      );
      expect(
        find.descendant(
          of: find.byType(TurnInlineActivity),
          matching: find.byKey(const ValueKey('live-ring-check')),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(
        _host(
          row(live: false, failed: true, glyph: ChatLiveGlyph.terminalAgent),
          reduced: true,
        ),
      );
      expect(
        _glyphOf(tester, find.byType(TurnInlineActivity)),
        ChatLiveGlyph.error,
      );
      await tester.pumpWidget(const SizedBox());
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('the row does not overflow at 320 dp, text x$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _host(
            row(glyph: ChatLiveGlyph.terminalAgent),
            reduced: true,
            scale: scale,
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('the queue chip shows the queued icon', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatQueueChip(
            text: 'Y después resúmelo',
            onOpen: () {},
            onRemove: () {},
          ),
          reduced: true,
        ),
      );
      expect(
        _glyphOf(tester, find.byType(ChatQueueChip)),
        ChatLiveGlyph.queued,
      );
      await tester.pumpWidget(const SizedBox());
    });

    SubagentActivity agent(String id, SubagentActivityPhase phase) {
      final scope = SubagentActivityScope(
        connectionId: 'test',
        parentSessionId: 'parent',
        runtimeSessionId: 'runtime',
        turnEpoch: 1,
      );
      return SubagentActivity(
        key: SubagentActivityKey(
          scope: scope,
          identityKind: SubagentIdentityKind.subagent,
          stableId: id,
        ),
        source: SubagentActivitySource.native,
        phase: phase,
        subagentId: id,
        details: SubagentActivityDetails(
          goalPreview: 'Revisar $id',
          startedAt: _start,
          durationSeconds: phase == SubagentActivityPhase.running ? null : 4,
          completedAt: phase == SubagentActivityPhase.running
              ? null
              : _start.add(const Duration(seconds: 4)),
        ),
      );
    }

    Widget capsule(List<SubagentActivity> agents) => Align(
      alignment: Alignment.bottomCenter,
      child: SubagentActivityCard(
        capsule: true,
        capsulePadding: const EdgeInsets.symmetric(horizontal: 16),
        activities: agents,
        now: _start.add(const Duration(seconds: 5)),
        turnSnapshot: ActivitySnapshot(turnActive: true, turnStartedAt: _start),
        onStop: () {},
        canSteer: (_) => false,
      ),
    );

    testWidgets('the capsule: team while it works, error when one failed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cap = find.byKey(const ValueKey('delegates-capsule'));
      await tester.pumpWidget(
        _host(
          capsule([
            agent('a', SubagentActivityPhase.running),
            agent('b', SubagentActivityPhase.running),
          ]),
          reduced: true,
        ),
      );
      await tester.pump();
      expect(_glyphOf(tester, cap), ChatLiveGlyph.agentTeam);
      await tester.pumpWidget(
        _host(
          capsule([
            agent('a', SubagentActivityPhase.failed),
            agent('b', SubagentActivityPhase.failed),
          ]),
          reduced: true,
        ),
      );
      await tester.pump();
      expect(_glyphOf(tester, cap), ChatLiveGlyph.error);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sheet header says failed when every child failed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          capsule([
            agent('a', SubagentActivityPhase.failed),
            agent('b', SubagentActivityPhase.failed),
          ]),
          reduced: true,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pump(const Duration(seconds: 1));
      final glyphs = tester
          .widgetList<ChatLiveIcon>(
            find.descendant(
              of: find.byKey(const ValueKey('subagent-panel')),
              matching: find.byType(ChatLiveIcon),
            ),
          )
          .map((i) => i.glyph);
      expect(glyphs, everyElement(ChatLiveGlyph.error));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sheet: header and one icon per child', (tester) async {
      tester.view.physicalSize = const Size(412, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          capsule([
            agent('a', SubagentActivityPhase.running),
            agent('b', SubagentActivityPhase.completed),
          ]),
          reduced: true,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pump(const Duration(seconds: 1));
      final panel = find.byKey(const ValueKey('subagent-panel'));
      expect(panel, findsOneWidget);
      expect(
        _glyphOf(tester, find.byKey(const ValueKey('subagent-row-a'))),
        ChatLiveGlyph.delegateTask,
      );
      expect(
        _glyphOf(tester, find.byKey(const ValueKey('subagent-row-b'))),
        ChatLiveGlyph.check,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.byType(ChatLiveIcon),
        ),
        findsNWidgets(3),
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}
