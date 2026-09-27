// Spec 080 step A: install-source notice (Settings → About) and the About
// page on the design primitives. Screenshots: DESIGN_SHOTS_DIR.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/services/install_source.dart';
import 'package:hermes_android/core/widgets/install_source_section.dart';

import '../support/design_shots.dart';
import 'detail_single_scroll_contract_test.dart' show nestedVerticalScrollables;

void main() {
  test('installer package → channel', () {
    expect(
      InstallSourceInfo.classify('com.android.vending'),
      InstallSource.googlePlay,
    );
    expect(
      InstallSourceInfo.classify('dev.imranr.obtainium.fdroid'),
      InstallSource.githubObtainium,
    );
    expect(
      InstallSourceInfo.classify('dev.imranr.obtainium'),
      InstallSource.githubObtainium,
    );
    expect(InstallSourceInfo.classify(null), InstallSource.manual);
    expect(
      InstallSourceInfo.classify('com.google.android.packageinstaller'),
      InstallSource.manual,
    );
    expect(
      InstallSourceInfo.updateUrl(InstallSource.googlePlay),
      contains('id=dev.xpetalab.hermesconsole'),
    );
    expect(
      InstallSourceInfo.updateUrl(InstallSource.manual),
      'https://github.com/xP3ta/hermes-console/releases',
    );
  });

  for (final (source, label, button) in const [
    (InstallSource.googlePlay, 'Google Play', 'Abrir en Google Play'),
    (
      InstallSource.githubObtainium,
      'GitHub / Obtainium',
      'Abrir versiones en GitHub',
    ),
    (InstallSource.manual, 'Instalación manual', 'Abrir versiones en GitHub'),
  ]) {
    testWidgets('install source $source', (tester) async {
      await pumpDesignScreen(
        tester,
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [InstallSourceSection(initialSource: source)],
          ),
        ),
      );
      expect(find.text('Actualizaciones'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      expect(find.text(button), findsOneWidget);
      expect(find.textContaining('desinstala primero'), findsOneWidget);
    });
  }

  testWidgets('install source detected through the platform channel', (
    tester,
  ) async {
    InstallSourceInfo.installerOverride = () async => 'com.android.vending';
    addTearDown(() => InstallSourceInfo.installerOverride = null);
    await pumpDesignScreen(
      tester,
      const Scaffold(body: InstallSourceSection()),
    );
    await tester.pump();
    expect(find.text('Google Play'), findsOneWidget);
  });

  testWidgets('About page: groups, one scroll', (tester) async {
    InstallSourceInfo.installerOverride = () async => null;
    addTearDown(() => InstallSourceInfo.installerOverride = null);
    await pumpDesignScreen(tester, const AboutScreen());
    expect(nestedVerticalScrollables(tester), isEmpty);
    expect(tester.takeException(), isNull);
    await saveDesignShot(tester, 'about');
  });
}
