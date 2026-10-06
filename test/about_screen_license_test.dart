import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/animated_hermes_logo.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('Acerca de registra GPLv3 y conserva la atribucion upstream', (
    tester,
  ) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    PackageInfo.setMockInitialValues(
      appName: 'Hermes Console',
      packageName: 'dev.xpetalab.hermes',
      version: '1.2.7-qa',
      buildNumber: '914',
      buildSignature: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const AboutScreen(),
      ),
    );
    await tester.pump();

    final entries = await LicenseRegistry.licenses.toList();
    final project = entries.singleWhere(
      (entry) => entry.packages.contains('Hermes Console'),
    );
    final projectNotice = project.paragraphs
        .map((paragraph) => paragraph.text)
        .join('\n');
    expect(projectNotice, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(projectNotice, contains('Version 3, 29 June 2007'));

    final upstream = entries.singleWhere(
      (entry) => entry.packages.contains('hermes-android (upstream)'),
    );
    final notice = upstream.paragraphs
        .map((paragraph) => paragraph.text)
        .join('\n');

    expect(notice, contains('rusty4444'));
    expect(notice, contains('MIT License'));
    expect(
      entries.any((entry) => entry.packages.contains('Thinking Orbs 0.3.1')),
      isFalse,
    );
  });

  testWidgets('Acerca de muestra el icono de Console', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Console',
      packageName: 'dev.xpetalab.hermes',
      version: '1.2.15-qa',
      buildNumber: '1',
      buildSignature: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const AboutScreen(),
      ),
    );
    await tester.pump();

    final icon = tester.widget<Image>(
      find.byKey(const Key('about-console-icon')),
    );
    final provider = icon.image;
    final asset = provider is ResizeImage ? provider.imageProvider : provider;
    expect((asset as AssetImage).assetName, kConsoleIconAsset);
    expect(kConsoleIconAsset, 'assets/branding/console_icon.png');
  });
}
