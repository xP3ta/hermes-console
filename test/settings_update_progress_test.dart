import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// "Actualizar Hermes" (Ajustes › Sistema): confirmación honesta + indicador
/// de progreso real.
///
/// Bug reportado en dispositivo: "cuando le doy a actualizar Hermes no se
/// suele aplicar al momento y no funciona bien". La causa era que un POST con
/// respuesta 2xx (`responseConfirmed`) hacía que la PRIMERA lectura de
/// `/api/status` —a los 3 s, con el gateway aún en la versión vieja— se diese
/// por confirmada, y además se saltaba por completo el `checkUpdate` de
/// verificación. La app anunciaba "Hermes actualizado a vX" con la versión
/// anterior.
void main() {
  group('classifyHermesUpdatePoll', () {
    test('el gateway caído nunca confirma', () {
      expect(
        classifyHermesUpdatePoll(
          gatewayRunning: false,
          previousVersion: '0.20.1',
          observedVersion: '',
          updateStillAvailable: null,
          responseConfirmed: true,
          elapsed: const Duration(minutes: 2),
        ),
        HermesUpdateVerdict.keepWaiting,
      );
    });

    test(
      'REGRESIÓN: un POST 2xx no confirma por sí solo con la versión vieja viva',
      () {
        expect(
          classifyHermesUpdatePoll(
            gatewayRunning: true,
            previousVersion: '0.20.1',
            observedVersion: '0.20.1',
            updateStillAvailable: true,
            responseConfirmed: true,
            elapsed: const Duration(seconds: 3),
          ),
          HermesUpdateVerdict.keepWaiting,
        );
      },
    );

    test('la versión nueva viva confirma', () {
      expect(
        classifyHermesUpdatePoll(
          gatewayRunning: true,
          previousVersion: '0.20.1',
          observedVersion: '0.20.2',
          updateStillAvailable: null,
          responseConfirmed: false,
          elapsed: const Duration(seconds: 3),
        ),
        HermesUpdateVerdict.confirmed,
      );
    });

    test('que el servidor deje de ofrecer la actualización confirma', () {
      expect(
        classifyHermesUpdatePoll(
          gatewayRunning: true,
          // Sin línea base de versión: la única evidencia disponible.
          previousVersion: '',
          observedVersion: '0.20.2',
          updateStillAvailable: false,
          responseConfirmed: false,
          elapsed: const Duration(seconds: 3),
        ),
        HermesUpdateVerdict.confirmed,
      );
    });

    test(
      'sin evidencia y con POST confirmado, la espera acaba como no verificada',
      () {
        expect(
          classifyHermesUpdatePoll(
            gatewayRunning: true,
            previousVersion: '0.20.1',
            observedVersion: '0.20.1',
            updateStillAvailable: null,
            responseConfirmed: true,
            elapsed: hermesUpdateVerifyGrace,
          ),
          HermesUpdateVerdict.unverified,
        );
      },
    );

    test('sin evidencia y sin POST confirmado se sigue esperando', () {
      expect(
        classifyHermesUpdatePoll(
          gatewayRunning: true,
          previousVersion: '0.20.1',
          observedVersion: '0.20.1',
          updateStillAvailable: null,
          responseConfirmed: false,
          elapsed: hermesUpdateVerifyGrace * 2,
        ),
        HermesUpdateVerdict.keepWaiting,
      );
    });
  });

  group('HermesUpdateProgress', () {
    test('la barra avanza paso a paso y nunca retrocede', () {
      var previous = 0.0;
      for (final step in HermesUpdateProgress.track) {
        final progress = HermesUpdateProgress(step: step);
        expect(progress.fraction, greaterThan(previous));
        expect(progress.fraction, lessThanOrEqualTo(1.0));
        expect(progress.stepNumber, lessThanOrEqualTo(progress.totalSteps));
        previous = progress.fraction;
      }
    });

    test('los estados terminales se marcan como acabados', () {
      for (final step in [HermesUpdateStep.done, HermesUpdateStep.unverified]) {
        final progress = HermesUpdateProgress(step: step);
        expect(progress.finished, isTrue);
        expect(progress.fraction, 1.0);
      }
      expect(
        const HermesUpdateProgress(step: HermesUpdateStep.verifying).finished,
        isFalse,
      );
    });
  });

  testWidgets('el panel pinta una barra determinista y el paso n/N', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(
          body: HermesUpdateProgressPanel(
            progress: HermesUpdateProgress(
              step: HermesUpdateStep.restarting,
              elapsedSeconds: 12,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-update-progress-bar')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    // Determinista: un spinner indeterminado (value == null) era justo lo que
    // no dejaba ver si la actualización avanzaba.
    expect(bar.value, isNotNull);
    expect(bar.value, closeTo(0.75, 0.001));
    expect(find.text('3/4'), findsOneWidget);
    expect(find.text('12s'), findsOneWidget);
    final strings = Strings.of(
      tester.element(find.byType(HermesUpdateProgressPanel)),
    );
    expect(find.text(strings.setGatewayRestarting), findsOneWidget);
  });

  test(
    'el sondeo de la actualización verifica SIEMPRE, no solo sin POST confirmado',
    () {
      final source = File(
        'lib/core/screens/settings_screen.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<bool> _waitForGatewayBack(');
      final wait = source.substring(
        start,
        source.indexOf('  void _publishUpdateStep(', start),
      );

      expect(wait, contains('classifyHermesUpdatePoll('));
      expect(wait, contains('_client.checkUpdate(force: true)'));
      // La condición vieja se saltaba la verificación cuando el POST había
      // devuelto 2xx; eso es lo que dejaba pasar una actualización no aplicada.
      expect(
        wait,
        isNot(contains('waitForUpdate && !updateResponseConfirmed')),
      );
      expect(wait, contains('HermesUpdateStep.restarting'));
      expect(wait, contains('HermesUpdateStep.verifying'));
    },
  );
}
