import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/projects/project_create_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/pj1215_fake_projects_gateway.dart';

Future<void> openProjectForm(
  WidgetTester tester,
  Pc1215CreatingProjectsGateway gateway, {
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showProjectCreateSheet(
              context,
              creation: gateway,
              pickFolder: () async => '/srv/manual',
              ownerOf: (_) async => null,
              failureText: (_) => 'Failed',
              ideaWriter: gateway,
              ideaFolderReader: gateway,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in [const Locale('en'), const Locale('es')]) {
    testWidgets(
      'project form has no AI or suggestion controls (${locale.languageCode})',
      (tester) async {
        final gateway = Pc1215CreatingProjectsGateway.sample();
        await openProjectForm(tester, gateway, locale: locale);
        expect(
          find.byKey(const ValueKey('pc1215-create-generate')),
          findsNothing,
        );
        expect(find.byType(ActionChip), findsNothing);
        expect(
          find.byKey(const ValueKey('pc1215-create-shuffle')),
          findsNothing,
        );
        expect(gateway.writes, isEmpty);
      },
    );
  }

  testWidgets('opening, typing and scrolling never request generation', (
    tester,
  ) async {
    final gateway = Pc1215CreatingProjectsGateway.sample();
    await openProjectForm(tester, gateway);
    expect(gateway.writes, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('pc1215-create-name')),
      'Manual',
    );
    await tester.enterText(
      find.byKey(const ValueKey('pc1215-create-idea')),
      'My own idea',
    );
    await tester.drag(
      find.byKey(const ValueKey('pc1215-create-sheet')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    expect(gateway.writes, isEmpty);
    expect(gateway.calls, isEmpty);
    final add = find.byKey(const ValueKey('pc1215-create-add-folder'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final submit = find.byKey(const ValueKey('pc1215-create-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(gateway.writes.map((call) => call.$1), [
      'projects.create',
      'POST /api/fs/write-text',
    ]);
    expect(gateway.writes.last.$2['content'], 'My own idea\n');
  });
}
