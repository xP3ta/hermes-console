import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/compaction_progress.dart';
import 'package:hermes_android/core/services/compaction_tracker.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/compaction_dock.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/inter_font.dart';

final DateTime _t0 = DateTime(2026, 9, 21, 12);

class _Clock {
  _Clock(this.now);
  DateTime now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('CompactionProgress: solo hechos', () {
    test(
      'sin progreso publicado no hay fracción, porcentaje ni estimación',
      () {
        final progress = CompactionProgress(startedAt: _t0, manual: false);
        expect(progress.fraction, isNull);
        expect(
          progress.elapsed(_t0.add(const Duration(seconds: 23))),
          const Duration(seconds: 23),
        );
      },
    );

    test('el progreso determinado sale solo de chunk_index / chunk_count', () {
      expect(parseCompactionChunks({'chunk_index': 2, 'chunk_count': 4}), (
        index: 2,
        count: 4,
      ));
      final progress = CompactionProgress(
        startedAt: _t0,
        manual: false,
        chunkIndex: 1,
        chunkCount: 4,
      );
      expect(progress.fraction, 0.25);
      // Datos incoherentes no rellenan nada.
      expect(
        parseCompactionChunks({'chunk_index': 5, 'chunk_count': 4}),
        isNull,
      );
      expect(
        parseCompactionChunks({'chunk_index': 1, 'chunk_count': 0}),
        isNull,
      );
      expect(
        parseCompactionChunks({'chunk_index': 'x', 'chunk_count': 2}),
        isNull,
      );
      // Un campo inventado NO cuenta, aunque parezca un porcentaje.
      for (final made in [
        {'progress': 0.5},
        {'percent': 50},
        {'pct': 50, 'total': 100},
        {'chunks': 4, 'done': 2},
        {'chunk': 2, 'chunk_total': 4},
      ]) {
        expect(parseCompactionChunks(made), isNull, reason: '$made');
      }
    });

    test('terminada: duración fija y sin fracción', () {
      final done = CompactionProgress(
        startedAt: _t0,
        manual: true,
        chunkIndex: 1,
        chunkCount: 2,
        finishedAt: _t0.add(const Duration(seconds: 71)),
      );
      expect(done.duration, const Duration(seconds: 71));
      expect(done.fraction, isNull);
      expect(formatCompactTokens(180000), '180k');
      expect(formatCompactTokens(21500), '21.5k');
      expect(formatCompactTokens(842), '842');
      expect(formatCompactTokens(1200000), '1.2M');
    });

    test('dock y contexto comparten formato en los límites k/M', () {
      const expected = {
        999500: '999.5k',
        999999: '1M',
        1000000: '1M',
        1500000: '1.5M',
      };

      for (final MapEntry(key: tokens, value: label) in expected.entries) {
        expect(formatCompactTokens(tokens), label, reason: '$tokens dock');
        expect(
          compactSessionContextTokens(tokens),
          label,
          reason: '$tokens contexto',
        );
        expect(
          label,
          isNot(contains('1000k')),
          reason: '$tokens fuera de rango',
        );
      }
    });
  });

  group('CompactionTracker', () {
    testWidgets('automática: solo el borde real `compacted` la da por buena', (
      tester,
    ) async {
      final clock = _Clock(_t0);
      final tracker = CompactionTracker(clock: () => clock.now);
      addTearDown(tracker.dispose);
      tracker.sync(active: true, manual: false, startedAt: _t0);
      expect(tracker.running, isTrue);
      expect(tracker.current!.manual, isFalse);
      clock.advance(const Duration(seconds: 38));
      // La bandera se apaga y llega el `compacted`.
      tracker.sync(active: false, manual: false);
      expect(tracker.running, isTrue, reason: 'margen para el final real');
      tracker.reportResult();
      expect(tracker.running, isFalse);
      expect(tracker.current!.duration, const Duration(seconds: 38));
      // Sin cifras del backend no se inventa ninguna.
      expect(tracker.current!.tokensAfter, isNull);
      expect(tracker.current!.messagesAfter, isNull);
      await tester.pump(const Duration(seconds: 7));
      expect(tracker.current, isNull);
    });

    testWidgets(
      'automática que acaba sin `compacted` (ready, idle, atascada): se retira '
      'en silencio, sin resultado inventado',
      (tester) async {
        final tracker = CompactionTracker(clock: () => _t0);
        addTearDown(tracker.dispose);
        tracker.sync(active: true, manual: false);
        tracker.sync(active: false, manual: false);
        await tester.pump(const Duration(seconds: 4));
        expect(tracker.current, isNull);
      },
    );

    testWidgets('manual: espera el resultado del RPC y lo publica exacto', (
      tester,
    ) async {
      final clock = _Clock(_t0);
      final tracker = CompactionTracker(clock: () => clock.now);
      addTearDown(tracker.dispose);
      tracker.sync(
        active: true,
        manual: true,
        startedAt: _t0,
        tokensBefore: 21500,
        messagesBefore: 22,
      );
      clock.advance(const Duration(seconds: 70));
      tracker.sync(active: false, manual: true);
      expect(tracker.running, isTrue, reason: 'aún se espera el resultado');
      tracker.reportResult(
        tokensBefore: 21234,
        tokensAfter: 5000,
        messagesBefore: 22,
        messagesAfter: 12,
      );
      final done = tracker.current!;
      expect(done.isFinished, isTrue);
      expect(done.tokensAfter, 5000);
      expect(done.messagesAfter, 12);
      expect(done.duration, const Duration(seconds: 70));
      await tester.pump(const Duration(seconds: 7));
      expect(tracker.current, isNull);
    });

    testWidgets(
      'manual sin resultado (abortada, lock…): la barra se retira sola',
      (tester) async {
        final tracker = CompactionTracker(clock: () => _t0);
        addTearDown(tracker.dispose);
        tracker.sync(active: true, manual: true);
        tracker.sync(active: false, manual: true);
        expect(tracker.running, isTrue);
        await tester.pump(const Duration(seconds: 4));
        expect(tracker.current, isNull, reason: 'sin barra colgada');
        tracker.reportResult(tokensBefore: 1, tokensAfter: 1);
        expect(tracker.current, isNull);
      },
    );

    test('los hechos nuevos actualizan la medición sin reiniciarla', () {
      final tracker = CompactionTracker(clock: () => _t0);
      addTearDown(tracker.dispose);
      tracker.sync(active: true, manual: true, startedAt: _t0);
      tracker.sync(
        active: true,
        manual: true,
        messagesBefore: 22,
        tokensBefore: 21500,
        chunkIndex: 1,
        chunkCount: 3,
      );
      final current = tracker.current!;
      expect(current.startedAt, _t0);
      expect(current.messagesBefore, 22);
      expect(current.tokensBefore, 21500);
      expect(current.fraction, closeTo(1 / 3, 1e-9));
      tracker.reset();
      expect(tracker.current, isNull);
    });
  });

  group('CompactionTracker: outcomes learned late', () {
    testWidgets('a no-op finishes as "nothing to compact"', (tester) async {
      final tracker = CompactionTracker(clock: () => _t0);
      addTearDown(tracker.dispose);
      tracker.sync(active: true, manual: true, startedAt: _t0);
      tracker.reportResult(messagesBefore: 6, tokensBefore: 20379, noop: true);
      expect(tracker.current?.noop, isTrue);
      expect(tracker.current?.isFinished, isTrue);
      await tester.pump(const Duration(seconds: 4));
      expect(tracker.current, isNull);
    });

    testWidgets('a restored outcome gets one result frame', (tester) async {
      final tracker = CompactionTracker(clock: () => _t0);
      addTearDown(tracker.dispose);
      tracker.reportResult(messagesBefore: 35, messagesAfter: 31);
      expect(tracker.current, isNull, reason: 'no start, nothing to show');
      tracker.reportResult(
        messagesBefore: 35,
        messagesAfter: 31,
        startedAt: _t0,
      );
      expect(tracker.current?.isFinished, isTrue);
      expect(tracker.current?.messagesAfter, 31);
      await tester.pump(const Duration(seconds: 4));
      expect(tracker.current, isNull);
    });
  });

  group('CompactionDock pill', () {
    Widget app(
      CompactionProgress progress,
      _Clock clock, {
      ThemeData? theme,
      double width = 390,
      double textScale = 1,
      TextDirection? direction,
      Locale locale = const Locale('es'),
    }) => MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: false,
          textScaler: TextScaler.linear(textScale),
        ),
        child: direction == null
            ? child!
            : Directionality(textDirection: direction, child: child!),
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: CompactionDock(
                compaction: progress,
                clock: () => clock.now,
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('live: spinner, "Compactando", muted facts and real timer', (
      tester,
    ) async {
      await loadInterFont();
      final clock = _Clock(_t0.add(const Duration(seconds: 23)));
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: true,
            messagesBefore: 38,
            tokensBefore: 32200,
          ),
          clock,
        ),
      );
      expect(find.byKey(const ValueKey('compaction-spinner')), findsOneWidget);
      expect(find.textContaining('Compactando'), findsOneWidget);
      expect(find.textContaining('38 msj · ~32.2k tok'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('compaction-elapsed')))
            .data,
        '0:23',
      );
      // A compact pill sized to its content, not a full-width bar.
      final pill = tester.getSize(
        find.byKey(const ValueKey('compaction-dock')),
      );
      expect(pill.width, lessThan(390));
      expect(pill.height, lessThanOrEqualTo(48));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      clock.advance(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('compaction-elapsed')))
            .data,
        '0:25',
      );
    });

    testWidgets('done: check + before -> after, no timer', (tester) async {
      final clock = _Clock(_t0);
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: true,
            messagesBefore: 38,
            messagesAfter: 34,
            finishedAt: _t0.add(const Duration(seconds: 47)),
          ),
          clock,
        ),
      );
      expect(
        find.byKey(const ValueKey('compaction-done-icon')),
        findsOneWidget,
      );
      expect(find.text('Compactado · 38 → 34 mensajes'), findsOneWidget);
      expect(find.byKey(const ValueKey('compaction-elapsed')), findsNothing);
      expect(find.byKey(const ValueKey('compaction-spinner')), findsNothing);
    });

    testWidgets('no-op: "Nada que compactar" with the message count', (
      tester,
    ) async {
      final clock = _Clock(_t0);
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: true,
            messagesBefore: 6,
            finishedAt: _t0.add(const Duration(seconds: 1)),
            noop: true,
          ),
          clock,
        ),
      );
      expect(find.text('Nada que compactar · 6 mensajes'), findsOneWidget);
    });

    testWidgets('without facts the result falls back to the duration', (
      tester,
    ) async {
      final clock = _Clock(_t0);
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: true,
            finishedAt: _t0.add(const Duration(seconds: 71)),
          ),
          clock,
        ),
      );
      expect(find.text('Compactado · 71 s'), findsOneWidget);
    });

    testWidgets('determinate ring only from published chunks', (tester) async {
      final clock = _Clock(_t0);
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: false,
            chunkIndex: 1,
            chunkCount: 4,
          ),
          clock,
        ),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, 0.25);
    });

    for (final theme in [AppTheme.hermesRedDark, AppTheme.hermesRedLight]) {
      testWidgets(
        '320 dp at 200% text, ${theme.brightness.name}: no overflow',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final clock = _Clock(_t0.add(const Duration(minutes: 3)));
          for (final progress in [
            CompactionProgress(
              startedAt: _t0,
              manual: true,
              messagesBefore: 1234,
              tokensBefore: 1250000,
              chunkIndex: 2,
              chunkCount: 9,
            ),
            CompactionProgress(
              startedAt: _t0,
              manual: true,
              messagesBefore: 1234,
              messagesAfter: 12,
              tokensBefore: 1250000,
              tokensAfter: 48000,
              finishedAt: _t0.add(const Duration(minutes: 3)),
            ),
          ]) {
            await tester.pumpWidget(
              app(progress, clock, theme: theme, width: 320, textScale: 2),
            );
            expect(tester.takeException(), isNull);
            final pill = tester.getRect(
              find.byKey(const ValueKey('compaction-dock')),
            );
            expect(pill.width, lessThanOrEqualTo(320));
          }
        },
      );
    }

    testWidgets('RTL and English', (tester) async {
      final clock = _Clock(_t0.add(const Duration(seconds: 5)));
      await tester.pumpWidget(
        app(
          CompactionProgress(startedAt: _t0, manual: true, messagesBefore: 3),
          clock,
          locale: const Locale('en'),
          direction: TextDirection.rtl,
        ),
      );
      expect(find.textContaining('Compacting'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
