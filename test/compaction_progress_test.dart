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

    testWidgets(
      'manual vencida termina como no confirmada sin afirmar éxito',
      (tester) async {
        final clock = _Clock(_t0);
        final tracker = CompactionTracker(clock: () => clock.now);
        addTearDown(tracker.dispose);
        tracker.sync(active: true, manual: true);
        clock.advance(const Duration(minutes: 12));
        tracker.reportUnconfirmed();

        expect(tracker.running, isFalse);
        expect(tracker.current?.isUnconfirmed, isTrue);
        expect(tracker.current?.duration, const Duration(minutes: 12));
        await tester.pump(const Duration(seconds: 7));
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

  group('CompactionDock', () {
    Widget app(CompactionProgress progress, _Clock clock, {String? note}) =>
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: false),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CompactionDock(
                compaction: progress,
                note: note,
                clock: () => clock.now,
              ),
            ),
          ),
        );

    testWidgets('sin progreso: línea que se mueve, hechos reales y cronómetro', (
      tester,
    ) async {
      final clock = _Clock(_t0.add(const Duration(seconds: 23)));
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: true,
            messagesBefore: 22,
            tokensBefore: 21500,
          ),
          clock,
        ),
      );
      expect(find.textContaining('Compactando'), findsOneWidget);
      expect(find.textContaining('22 msj · ~21.5k tok'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('compaction-elapsed')))
            .data,
        '0:23',
      );
      // Ni relleno determinado, ni porcentaje, ni tiempo restante, ni spinner.
      expect(
        find.byKey(const ValueKey('compaction-line-moving')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('compaction-line-fill')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('≈'), findsNothing);
      // El segmento avanza de verdad.
      dynamic painter() => tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('compaction-line-moving')),
          )
          .painter;
      final first = painter().t as double?;
      await tester.pump(const Duration(milliseconds: 600));
      expect(painter().t as double?, isNot(first));
    });

    testWidgets('a ancho de móvil el título y los recuentos van en UNA línea', (
      tester,
    ) async {
      await loadInterFont();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final progress = CompactionProgress(
        startedAt: _t0,
        manual: true,
        messagesBefore: 12,
        tokensBefore: 21600,
      );
      await tester.pumpWidget(
        app(progress, _Clock(_t0.add(const Duration(seconds: 30)))),
      );
      expect(find.textContaining('Compactando conversación'), findsNothing);
      final title = tester.getRect(find.text('Compactando'));
      final facts = tester.getRect(
        find.byKey(const ValueKey('compaction-facts')),
      );
      final timer = tester.getRect(
        find.byKey(const ValueKey('compaction-elapsed')),
      );
      expect(find.textContaining('12 msj · ~21.6k tok'), findsOneWidget);
      // Misma línea: alturas de un solo renglón y alineados en horizontal.
      expect(facts.height, lessThan(20));
      expect((facts.center.dy - title.center.dy).abs(), lessThan(4));
      expect(timer.left, greaterThan(facts.right));

      // Si no cabe, se recortan los recuentos ANTES que el título.
      tester.view.physicalSize = const Size(200, 800);
      await tester.pump();
      final narrowTitle = tester.widget<Text>(find.text('Compactando'));
      expect(narrowTitle.softWrap, isFalse);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('compaction-facts')))
            .overflow,
        TextOverflow.ellipsis,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('con texto grande sí puede partirse en dos líneas', (
      tester,
    ) async {
      await loadInterFont();
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: CompactionDock(
                compaction: CompactionProgress(
                  startedAt: _t0,
                  manual: true,
                  messagesBefore: 12,
                  tokensBefore: 21600,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('compaction-facts')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('con movimiento reducido la línea queda quieta', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: CompactionDock(
                compaction: CompactionProgress(startedAt: _t0, manual: false),
              ),
            ),
          ),
        ),
      );
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('compaction-line-moving')),
                  )
                  .painter!
              as dynamic;
      expect(painter.t, isNull);
    });

    testWidgets('con trozos reales: relleno determinado desde esos números', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: false,
            chunkIndex: 2,
            chunkCount: 4,
          ),
          _Clock(_t0),
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('compaction-line-fill')),
            )
            .value,
        0.5,
      );
      expect(find.textContaining('parte 2 de 4'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('compaction-line-moving')),
        findsNothing,
      );
    });

    testWidgets('un campo inventado no rellena la barra', (tester) async {
      // El backend actual solo dice «empezó / latido / terminó»: aunque llegue
      // algo con pinta de porcentaje, el parser lo ignora y la línea sigue
      // indeterminada.
      final chunks = parseCompactionChunks({'progress': 0.9, 'percent': 90});
      expect(chunks, isNull);
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: false,
            chunkIndex: chunks?.index,
            chunkCount: chunks?.count,
          ),
          _Clock(_t0),
        ),
      );
      expect(find.byKey(const ValueKey('compaction-line-fill')), findsNothing);
      expect(
        find.byKey(const ValueKey('compaction-line-moving')),
        findsOneWidget,
      );
    });

    testWidgets('resultado real: solo lo que el backend dio', (tester) async {
      final finished = _t0.add(const Duration(seconds: 71));
      Future<void> pump(CompactionProgress p) =>
          tester.pumpWidget(app(p, _Clock(finished)));
      await pump(
        CompactionProgress(
          startedAt: _t0,
          manual: true,
          messagesBefore: 22,
          messagesAfter: 12,
          finishedAt: finished,
        ),
      );
      expect(
        find.text('Compactado · 22 → 12 mensajes · 71 s', findRichText: true),
        findsOneWidget,
      );
      // Con tokens reportados se añaden; sin ellos no se muestran.
      await pump(
        CompactionProgress(
          startedAt: _t0,
          manual: true,
          messagesBefore: 22,
          messagesAfter: 12,
          tokensBefore: 96000,
          tokensAfter: 4800,
          finishedAt: finished,
        ),
      );
      expect(
        find.text(
          'Compactado · 22 → 12 mensajes · 96k → 4.8k tokens · 71 s',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // Automática sin cifras: solo la duración medida.
      await pump(
        CompactionProgress(startedAt: _t0, manual: false, finishedAt: finished),
      );
      expect(
        find.text('Compactado · 71 s', findRichText: true),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('compaction-elapsed')), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('compaction-line-fill')),
            )
            .value,
        1,
      );
    });

    testWidgets('resultado no confirmado es terminal y conserva el aviso', (
      tester,
    ) async {
      const warning = 'No se pudo confirmar la compresión.';
      await tester.pumpWidget(
        app(
          CompactionProgress(
            startedAt: _t0,
            manual: true,
            finishedAt: _t0.add(const Duration(minutes: 12)),
            resultConfirmed: false,
          ),
          _Clock(_t0.add(const Duration(minutes: 12))),
          note: warning,
        ),
      );

      expect(find.text(warning), findsOneWidget);
      expect(find.byKey(const ValueKey('compaction-result')), findsOneWidget);
      expect(find.byKey(const ValueKey('compaction-elapsed')), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('compaction-line-fill')),
            )
            .color,
        Theme.of(tester.element(find.byType(CompactionDock))).hermes.warning,
      );
    });

    testWidgets('aviso de estado que exige atención ocupa una sola fila', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          CompactionProgress(startedAt: _t0, manual: true),
          _Clock(_t0),
          note: 'La compresión sigue en curso.',
        ),
      );
      expect(find.text('La compresión sigue en curso.'), findsOneWidget);
    });

    testWidgets('320 dp a escala 2 sin desbordes', (tester) async {
      await loadInterFont();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: CompactionDock(
                compaction: CompactionProgress(
                  startedAt: _t0,
                  manual: true,
                  messagesBefore: 22,
                  tokensBefore: 21500,
                  chunkIndex: 1,
                  chunkCount: 3,
                ),
                note:
                    'La compresión sigue en curso. Hermes actualizará esta conversación.',
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('CompressionUnconfirmedNotice', () {
    Widget host(Widget child, {double width = 360}) => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

    testWidgets(
      'REGRESSION_COMP_UNCONFIRMED readable text, reload and dismiss actions',
      (tester) async {
        var retried = 0;
        var dismissed = 0;
        await tester.pumpWidget(
          host(
            CompressionUnconfirmedNotice(
              onRetry: () => retried++,
              onDismiss: () => dismissed++,
            ),
          ),
        );
        final title = tester.widget<Text>(
          find.byKey(const ValueKey('compression-unconfirmed-title')),
        );
        expect(title.data, 'No se pudo confirmar la compresión');
        // The explanation is never cut to one ellipsized line.
        final body = tester.widget<Text>(
          find.byKey(const ValueKey('compression-unconfirmed-body')),
        );
        expect(body.maxLines, isNot(1));
        expect(body.overflow, isNot(TextOverflow.ellipsis));
        // No running timer on a state that is not running anymore.
        expect(find.byKey(const ValueKey('compaction-elapsed')), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('compression-unconfirmed-retry')),
        );
        await tester.tap(
          find.byKey(const ValueKey('compression-unconfirmed-dismiss')),
        );
        expect(retried, 1);
        expect(dismissed, 1);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('compressionOutcomeText', () {
    testWidgets('no-op and success carry the before -> after facts', (
      tester,
    ) async {
      late Strings strings;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Builder(
            builder: (context) {
              strings = Strings.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        compressionOutcomeText(
          strings,
          noop: true,
          beforeMessages: 6,
          afterMessages: 6,
          beforeTokens: 20379,
          afterTokens: 20379,
        ),
        'Nada que compactar · 6 mensajes · ~20.4k tokens',
      );
      expect(
        compressionOutcomeText(
          strings,
          noop: false,
          beforeMessages: 34,
          afterMessages: 12,
          beforeTokens: 30275,
          afterTokens: 25668,
        ),
        'Compactado · 34 → 12 mensajes · 30.3k → 25.7k tokens',
      );
      expect(
        compressionOutcomeText(strings, noop: false),
        'Compactado',
      );
    });
  });
}
