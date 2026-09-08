import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/server_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'el setup es manual y la ayuda no entrega secretos ni comandos al LLM',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);

      await tester.pumpWidget(_host(ServerSetupScreen(connManager: manager)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Linux / Termux'));
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final guidanceToggle = find.text(
        '¿Necesitas contexto? Copiar consulta de solo lectura',
      );
      await tester.scrollUntilVisible(
        guidanceToggle,
        180,
        scrollable: scrollable,
      );
      expect(find.text('Copia para una terminal de confianza'), findsOneWidget);

      await tester.ensureVisible(guidanceToggle);
      await tester.pumpAndSettle();
      await tester.tap(guidanceToggle.hitTestable());
      await tester.pumpAndSettle();

      final guidance = ServerSetupGenerator.agentPromptFor(
        ServerHostPlatform.linux,
      );
      expect(find.text(guidance), findsOneWidget);
      expect(guidance, isNot(contains(ServerSetupGenerator.curlCommand)));
      expect(guidance, isNot(contains('hermes://pair')));

      final secretWarning = find.byKey(
        const ValueKey('setup-pairing-secret-at-entry'),
      );
      await tester.scrollUntilVisible(
        secretWarning,
        180,
        scrollable: scrollable,
      );
      expect(secretWarning, findsOneWidget);
      expect(
        find.textContaining('salida de emparejado es una credencial'),
        findsOneWidget,
      );
      final pasteLabel = find.text('Pegar enlace secreto de emparejado');
      await tester.scrollUntilVisible(pasteLabel, 180, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(pasteLabel, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
