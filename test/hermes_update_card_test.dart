import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_update_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/design/hicons.dart';

void main() {
  group('HermesUpdatePresentation', () {
    test('Docker 0.18.2 se presenta como actualización externa, no actual', () {
      final presentation = HermesUpdatePresentation.fromPayload({
        'install_method': 'docker',
        'current_version': '0.18.2',
        'behind': null,
        'update_available': false,
        'can_apply': false,
        'update_command': 'docker pull nousresearch/hermes-agent:latest',
        'message': 'Pull the new image and recreate the container.',
      }, fallbackVersion: '0.18.2');

      expect(presentation.kind, HermesUpdateKind.external);
      expect(presentation.currentVersion, '0.18.2');
      expect(presentation.updateCommand, contains('docker pull'));
    });

    test('Git atrasado conserva la acción aplicable', () {
      final presentation = HermesUpdatePresentation.fromPayload({
        'install_method': 'git',
        'current_version': '0.18.2',
        'behind': 12,
        'update_available': true,
        'can_apply': true,
      }, fallbackVersion: '—');

      expect(presentation.kind, HermesUpdateKind.available);
      expect(presentation.hasUpdate, isTrue);
      expect(presentation.behind, 12);
    });

    test('behind null por fallo de red nunca se anuncia como al día', () {
      final presentation = HermesUpdatePresentation.fromPayload({
        'install_method': 'git',
        'current_version': '0.18.2',
        'behind': null,
        'update_available': false,
        'can_apply': true,
        'message': "Couldn't reach the update source",
      }, fallbackVersion: '—');

      expect(presentation.kind, HermesUpdateKind.checkFailed);
    });

    test('solo behind cero se presenta como versión actual', () {
      final presentation = HermesUpdatePresentation.fromPayload({
        'install_method': 'pip',
        'current_version': '0.19.0',
        'behind': 0,
        'update_available': false,
        'can_apply': true,
      }, fallbackVersion: '—');

      expect(presentation.kind, HermesUpdateKind.current);
    });

    test('un 401 se puede presentar como acceso al Dashboard requerido', () {
      final presentation = HermesUpdatePresentation.dashboardAccessRequired(
        fallbackVersion: '0.19.1',
      );

      expect(presentation.kind, HermesUpdateKind.dashboardAccessRequired);
      expect(presentation.currentVersion, '0.19.1');
      expect(presentation.hasUpdate, isFalse);
    });
  });

  testWidgets('Docker muestra guía y comando sin check verde ni al día', (
    tester,
  ) async {
    final presentation = HermesUpdatePresentation.fromPayload({
      'install_method': 'docker',
      'current_version': '0.18.2',
      'behind': null,
      'update_available': false,
      'can_apply': false,
      'update_command': 'docker pull nousresearch/hermes-agent:latest',
      'message': 'Pull the new image and recreate the container.',
    }, fallbackVersion: '—');

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: HermesUpdateCard(
            presentation: presentation,
            isLocal: false,
            busy: false,
            onApply: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('fuera de la app'), findsOneWidget);
    expect(find.textContaining('docker pull'), findsOneWidget);
    expect(find.textContaining('al día'), findsNothing);
    expect(find.byIcon(HIcons.check), findsNothing);
    expect(find.byKey(const Key('hermes_update_command')), findsOneWidget);
  });

  testWidgets('acceso requerido explica el 401 y abre su configuración', (
    tester,
  ) async {
    var configureTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: HermesUpdateCard(
            presentation: HermesUpdatePresentation.dashboardAccessRequired(
              fallbackVersion: '0.19.1',
            ),
            isLocal: false,
            busy: false,
            onApply: () {},
            onConfigureDashboard: () => configureTaps += 1,
          ),
        ),
      ),
    );

    expect(find.textContaining('requiere iniciar sesión'), findsOneWidget);
    expect(find.text('Configurar acceso al Dashboard'), findsOneWidget);
    expect(find.textContaining('no expone'), findsNothing);

    await tester.tap(
      find.byKey(const Key('hermes_update_configure_dashboard')),
    );
    expect(configureTaps, 1);
  });
}
