import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/turn_activity_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Reloj controlado: el cronómetro tiene que leer el tiempo simulado del test,
/// no el del reloj de pared, o las aserciones dependerían de lo que tarde el
/// propio `pump`.
class _FakeClock {
  DateTime now;

  _FakeClock(this.now);

  void advance(Duration delta) => now = now.add(delta);
}

Future<void> _pumpPill(
  WidgetTester tester, {
  required bool active,
  required DateTime? startedAt,
  required _FakeClock clock,
  String? statusLabel = 'Ejecutando…',
  Locale locale = const Locale('es'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: TurnActivityPill(
            active: active,
            startedAt: startedAt,
            statusLabel: statusLabel,
            clock: () => clock.now,
          ),
        ),
      ),
    ),
  );
}

Finder get _pill => find.byKey(const ValueKey('turn-activity-pill'));
Finder get _elapsed => find.byKey(const ValueKey('turn-activity-elapsed'));

String _elapsedText(WidgetTester tester) =>
    tester.widget<Text>(_elapsed).data ?? '';

void main() {
  testWidgets('elapsed timer pauses in background and catches up on resume', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final clock = _FakeClock(DateTime(2026, 9, 17, 3));
    await _pumpPill(tester, active: true, startedAt: clock.now, clock: clock);
    clock.advance(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    expect(_elapsedText(tester), '0:04');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    clock.advance(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(_elapsedText(tester), '0:04');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_elapsedText(tester), '0:09');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('un turno corto no llega a pintar la pastilla', (tester) async {
    // El antiparpadeo es el punto: la mayoría de los turnos responden en un par
    // de segundos y no deben hacer aparecer y desaparecer una pastilla.
    final clock = _FakeClock(DateTime(2026, 9, 17, 3));
    await _pumpPill(tester, active: true, startedAt: clock.now, clock: clock);

    expect(_pill, findsNothing);

    clock.advance(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(_pill, findsNothing);
  });

  testWidgets('pasado el umbral aparece con el estado y el tiempo vivo', (
    tester,
  ) async {
    final clock = _FakeClock(DateTime(2026, 9, 17, 3));
    await _pumpPill(
      tester,
      active: true,
      startedAt: clock.now,
      clock: clock,
      statusLabel: 'Ejecutando…',
    );

    clock.advance(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));

    expect(_pill, findsOne);
    expect(find.text('Ejecutando…'), findsOne);
    expect(_elapsedText(tester), '0:04');

    // La cifra tiene que SUBIR sola: un número congelado no distingue
    // «sigue trabajando» de «se ha colgado», que es todo el punto del widget.
    clock.advance(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 8));

    expect(_elapsedText(tester), '0:12');
  });

  testWidgets(
    'sin statusLabel se ve el cronómetro solo, sin hueco de la palabra',
    (tester) async {
      // El llamador pasa null cuando la misma palabra ya está a la vista en
      // la ThinkingTraceCard del transcript — la pastilla no debe repetirla,
      // pero el cronómetro (la señal que no existe en ningún otro sitio)
      // tiene que seguir ahí.
      final clock = _FakeClock(DateTime(2026, 9, 17, 3));
      await _pumpPill(
        tester,
        active: true,
        startedAt: clock.now,
        clock: clock,
        statusLabel: null,
      );

      clock.advance(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));

      expect(_pill, findsOne);
      expect(_elapsedText(tester), '0:04');
      expect(find.text('Ejecutando…'), findsNothing);
    },
  );

  testWidgets('una espera larga cambia a la frase de tranquilidad', (
    tester,
  ) async {
    final clock = _FakeClock(DateTime(2026, 9, 17, 3));
    await _pumpPill(
      tester,
      active: true,
      startedAt: clock.now,
      clock: clock,
      statusLabel: 'Ejecutando…',
      locale: const Locale('en'),
    );

    clock.advance(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Ejecutando…'), findsOne);

    clock.advance(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));

    expect(find.text('Ejecutando…'), findsNothing);
    expect(find.text("Still working"), findsOne);
    expect(_elapsedText(tester), '0:25');
  });

  testWidgets(
    'la frase de tranquilidad aparece aunque el llamador pida silencio',
    (tester) async {
      // Pasado `reassureAfter` la espera ya se hizo larga y merece su propio
      // aviso — eso no es la misma narración que la palabra que se calló.
      final clock = _FakeClock(DateTime(2026, 9, 17, 3));
      await _pumpPill(
        tester,
        active: true,
        startedAt: clock.now,
        clock: clock,
        statusLabel: null,
        locale: const Locale('en'),
      );

      clock.advance(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 25));

      expect(find.text("Still working"), findsOne);
      expect(_elapsedText(tester), '0:25');
    },
  );

  testWidgets('el turno termina y la pastilla se va con su cronómetro', (
    tester,
  ) async {
    final clock = _FakeClock(DateTime(2026, 9, 17, 3));
    final startedAt = clock.now;
    await _pumpPill(tester, active: true, startedAt: startedAt, clock: clock);
    clock.advance(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    expect(_pill, findsOne);

    // Sin parar el `Timer.periodic` la pantalla de chat se repintaría una vez
    // por segundo para siempre; el test lo caza porque un timer pendiente hace
    // fallar el binding al terminar.
    await _pumpPill(tester, active: false, startedAt: null, clock: clock);

    expect(_pill, findsNothing);
  });

  testWidgets('el minuto sube a m:ss y la hora a h:mm:ss', (tester) async {
    final clock = _FakeClock(DateTime(2026, 9, 17, 3));
    await _pumpPill(tester, active: true, startedAt: clock.now, clock: clock);

    clock.advance(const Duration(minutes: 1, seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(_elapsedText(tester), '1:05');

    clock.advance(const Duration(hours: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(_elapsedText(tester), '1:01:05');
  });

  test('formatTurnElapsed usa el mismo escalón que Desktop', () {
    expect(formatTurnElapsed(Duration.zero), '0:00');
    expect(formatTurnElapsed(const Duration(seconds: 9)), '0:09');
    expect(formatTurnElapsed(const Duration(seconds: 59)), '0:59');
    expect(formatTurnElapsed(const Duration(seconds: 83)), '1:23');
    expect(
      formatTurnElapsed(const Duration(minutes: 59, seconds: 59)),
      '59:59',
    );
    expect(formatTurnElapsed(const Duration(hours: 2, seconds: 5)), '2:00:05');
  });
}
