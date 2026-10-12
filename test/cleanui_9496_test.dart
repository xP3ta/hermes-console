import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'no_ai_suggestions_9496_test.dart' show openProjectForm;
import 'support/pj1215_fake_projects_gateway.dart';

void main() {
  for (final locale in [const Locale('en'), const Locale('es')]) {
    testWidgets(
      'project form keeps labels but no permanent introduction (${locale.languageCode})',
      (tester) async {
        await openProjectForm(
          tester,
          Pc1215CreatingProjectsGateway.sample(),
          locale: locale,
        );
        final strings = Strings.of(
          tester.element(find.byKey(const ValueKey('pc1215-create-sheet'))),
        );
        expect(find.text(strings.pc1215CreateDesc), findsNothing);
        expect(find.text(strings.pc1215NewProject), findsOneWidget);
        // The shared full-screen scaffold renders section labels uppercase.
        expect(
          find.text(strings.pc1215FoldersLabel.toUpperCase()),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('pc1215-create-idea')),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.pc1215IdeaLabel), findsOneWidget);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('pc1215-create-name')),
              )
              .maxLength,
          120,
        );
      },
    );

    testWidgets(
      'projects keeps on-demand help without a repeated introduction (${locale.languageCode})',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        final gateway = Pj1215FakeProjectsGateway.sample();
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('dark'),
            home: ProjectsCenterScreen(
              connection: SavedConnection(
                id: 'quiet-projects',
                label: 'Test',
                host: '127.0.0.1',
                port: 8642,
                apiKey: 'fixture',
              ),
              connectionManager: manager,
              gateway: gateway,
              chatLauncher: (_, _) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        final strings = Strings.of(
          tester.element(find.byType(ProjectsCenterScreen)),
        );
        expect(find.textContaining(strings.pj1215Intro), findsNothing);
        expect(find.byKey(const ValueKey('pj1215-intro-more')), findsNothing);
        expect(find.byKey(const ValueKey('pj1215-explainer')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('pj1215-help')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pj1215-explainer')), findsOneWidget);
        expect(gateway.writes, isEmpty);
      },
    );
  }
}
