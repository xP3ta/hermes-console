import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_turn_recovery_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'aviso sin confirmar muestra reintentar y detener sin tono de error',
    (tester) async {
      var retries = 0;
      var stops = 0;
      final event = chatTurnRecoveryUnconfirmedEvent(
        str: lookupStrings(const Locale('es')),
        onRetry: () => retries++,
        onStop: () => stops++,
      );
      expect(event.tone, IslandTone.warning);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedLight,
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: Center(child: IslandEventTile(event: event)),
          ),
        ),
      );
      expect(find.text('Sin confirmar'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      await tester.tap(find.text('Sin confirmar'));
      await tester.pumpAndSettle();
      expect(find.text('Detener turno'), findsOneWidget);
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detener turno'));
      expect(retries, 1);
      expect(stops, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
