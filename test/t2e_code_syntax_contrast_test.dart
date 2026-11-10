// Wave 8 (audit 1.4.0 §2.11): the viewer's syntax colours were fixed values
// that a light theme could not read (#DCB67A on #F7F7F7 is 1.78:1). They
// now come from the theme and reach 4.5:1 on the page in every preset.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/code_syntax_palette.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/code_view_prefs.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('every role reads at 4.5:1 on every surface of every preset', () {
    final fails = <String>[];
    for (final preset in AppTheme.presets) {
      final c = preset.colors;
      for (final (name, surface) in [
        ('background', c.background),
        ('surface', c.surface),
        ('surfaceVariant', c.surfaceVariant),
      ]) {
        final palette = CodeSyntaxPalette(c, surface);
        for (final role in CodeSyntaxRole.values) {
          final ratio = ThemeContrast.ratio(palette.colorOf(role), surface);
          if (ratio < CodeSyntaxPalette.minimumContrast) {
            fails.add('${preset.id} ${role.name}/$name $ratio');
          }
        }
      }
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  test('highlighter classes fall into three roles; the rest keeps the ink', () {
    expect(CodeSyntaxPalette.roleOf('keyword'), CodeSyntaxRole.keyword);
    expect(CodeSyntaxPalette.roleOf('tag'), CodeSyntaxRole.keyword);
    expect(CodeSyntaxPalette.roleOf('string'), CodeSyntaxRole.literal);
    expect(CodeSyntaxPalette.roleOf('number'), CodeSyntaxRole.literal);
    expect(CodeSyntaxPalette.roleOf('comment'), CodeSyntaxRole.comment);
    expect(CodeSyntaxPalette.roleOf('title'), isNull);
    expect(CodeSyntaxPalette.roleOf(null), isNull);
  });

  group('the viewer paints code in the theme', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await CodeViewPrefs.load(await SharedPreferences.getInstance());
    });
    tearDown(() => CodeViewPrefs.debugUse(null));

    for (final id in const ['console-light', 'console', 'gruvbox-light']) {
      testWidgets('$id: every coloured run reads at 4.5:1', (tester) async {
        final theme = AppTheme.fromId(id);
        const body = "// a note\nconst answer = 'yes';\nfinal n = 42;\n";
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: ArtifactViewerScreen(
              name: 'main.dart',
              mimeType: 'text/plain',
              highlightLanguage: 'dart',
              loadBytes: () async => Uint8List.fromList(utf8.encode(body)),
            ),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
        }

        final page = theme.hermes.background;
        final coloured = <Color>[];
        for (var line = 0; line < 3; line++) {
          final text = tester.widget<Text>(
            find.byKey(ValueKey('artifact-viewer-line-$line')),
          );
          text.textSpan!.visitChildren((span) {
            final color = span.style?.color;
            if (color != null) coloured.add(color);
            return true;
          });
        }
        expect(coloured, isNotEmpty, reason: 'nothing was highlighted');
        for (final color in coloured) {
          expect(
            ThemeContrast.ratio(color, page),
            greaterThanOrEqualTo(CodeSyntaxPalette.minimumContrast),
            reason: '$color on $page',
          );
        }
      });
    }
  });
}
