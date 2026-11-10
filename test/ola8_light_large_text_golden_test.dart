import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/code_view_prefs.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/inter_font.dart';

/// Ola 8 (AUDITORIA-PULIDO §5, T2-E): what wave 8 touches, dark and light,
/// at normal and 200 % text, on a phone width: the settings pieces (section
/// heading, rows, badges), the attachment kind badges and the code viewer.
///
/// Regenerate on the reference engine, never on a developer machine:
///   flutter test --update-goldens test/ola8_light_large_text_golden_test.dart
void main() {
  setUpAll(loadInterFont);

  Widget host(Widget child, {required bool dark, double scale = 1}) {
    return MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.fromId(dark ? 'console' : 'console-light'),
      home: Builder(
        builder: (context) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 392,
                  child: RepaintBoundary(
                    key: const ValueKey('golden'),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  final settings = Builder(
    builder: (context) {
      final colors = Theme.of(context).hermes;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HermesSectionHeader('Notificaciones'),
          HermesGroup(
            children: [
              HermesNavRow(
                icon: Icons.notifications_none_rounded,
                title: 'Avisos del agente',
                subtitle: 'Cuando termina un turno o necesita tu respuesta',
                onTap: () {},
              ),
              HermesNavRow(
                icon: Icons.lock_outline_rounded,
                title: 'Bloqueo de la app',
                subtitle: 'Huella',
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HermesBadge('Inicio', color: colors.accent, dot: false),
              HermesBadge('Activa', color: colors.success),
              HermesBadge('Bloqueada', color: colors.warning),
              HermesBadge('Error', color: colors.error),
              HermesBadge('Nota', color: colors.textSecondary, dot: false),
            ],
          ),
        ],
      );
    },
  );

  const files = Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AttachmentCard(
        name: 'copia.zip',
        mimeType: 'application/zip',
        sizeLabel: '2 MB',
      ),
      SizedBox(height: 8),
      AttachmentCard(
        name: 'factura.pdf',
        mimeType: 'application/pdf',
        sizeLabel: '180 KB',
      ),
      SizedBox(height: 8),
      AttachmentCard(
        name: 'gastos.csv',
        mimeType: 'text/csv',
        sizeLabel: '4 KB',
      ),
      SizedBox(height: 8),
      AttachmentCard(
        name: 'main.dart',
        mimeType: 'text/plain',
        sizeLabel: '12 KB',
      ),
    ],
  );

  for (final dark in [true, false]) {
    final mode = dark ? 'dark' : 'light';
    for (final scale in const [1.0, 2.0]) {
      final size = scale == 1 ? '1x' : '2x';

      testWidgets('settings pieces, $mode, $size', (tester) async {
        await tester.pumpWidget(host(settings, dark: dark, scale: scale));
        await tester.pump();
        await expectLater(
          find.byKey(const ValueKey('golden')),
          matchesGoldenFile('goldens/ola8_settings_${mode}_$size.png'),
        );
      });

      testWidgets('attachment badges, $mode, $size', (tester) async {
        await tester.pumpWidget(host(files, dark: dark, scale: scale));
        await tester.pump();
        await expectLater(
          find.byKey(const ValueKey('golden')),
          matchesGoldenFile('goldens/ola8_attachments_${mode}_$size.png'),
        );
      });
    }

    testWidgets('code viewer, $mode', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await CodeViewPrefs.load(await SharedPreferences.getInstance());
      addTearDown(() => CodeViewPrefs.debugUse(null));
      tester.view.physicalSize = const Size(392, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const code =
          '// Reintenta la copia nocturna.\n'
          "import 'dart:io';\n"
          '\n'
          'Future<bool> retry(String host, {int tries = 3}) async {\n'
          '  for (var i = 0; i < tries; i++) {\n'
          "    final ok = await ping(host, label: 'nas-1');\n"
          '    if (ok) return true;\n'
          '  }\n'
          '  return false;\n'
          '}\n';
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          locale: const Locale('es'),
          debugShowCheckedModeBanner: false,
          theme: AppTheme.fromId(dark ? 'console' : 'console-light'),
          home: ArtifactViewerScreen(
            name: 'retry.dart',
            mimeType: 'text/plain',
            highlightLanguage: 'dart',
            loadBytes: () async => Uint8List.fromList(utf8.encode(code)),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      await expectLater(
        find.byType(ArtifactViewerScreen),
        matchesGoldenFile('goldens/ola8_code_viewer_$mode.png'),
      );
    });
  }
}
