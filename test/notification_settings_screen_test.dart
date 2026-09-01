import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

void main() {
  testWidgets('el diagnóstico apila estado a 320 px con texto al 200%', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: HermesNotificationDiagnosticRow(
              label: 'Notification permission',
              value: 'Not granted',
              good: false,
            ),
          ),
        ),
      ),
    );

    final label = tester.getRect(find.text('Notification permission'));
    final value = tester.getRect(find.text('Not granted'));
    expect(value.top, greaterThanOrEqualTo(label.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('el estado background refleja activación y error persistente', (
    tester,
  ) async {
    Future<void> pump(BackgroundNotificationUiState state) {
      return tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('dark'),
          home: Scaffold(
            body: HermesBackgroundNotificationStatus(
              state: state,
              activatingLabel: 'Activando…',
              activeLabel: 'Activo',
              pausedLabel: 'En pausa',
              errorLabel: 'Error al iniciar',
            ),
          ),
        ),
      );
    }

    await pump(BackgroundNotificationUiState.activating);
    expect(find.text('Activando…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await pump(BackgroundNotificationUiState.error);
    expect(find.text('Error al iniciar'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

    await pump(BackgroundNotificationUiState.active);
    expect(find.text('Activo'), findsOneWidget);
    expect(find.byIcon(Icons.circle), findsOneWidget);

    await pump(BackgroundNotificationUiState.paused);
    expect(find.text('En pausa'), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
  });
}
