// rt1215: secondary text (onSurfaceVariant = textSecondary) and links
// (accentText) reach WCAG AA 4.5:1 on every surface of every theme, and the
// agent-text surfaces really paint their prose in those tokens — rendered in
// every theme, not only read from the palette.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/content.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/activity_sections.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const double _aa = 4.5;

const String _reasoning =
    '**Checking the backup host**\n\n'
    'The nightly job on `nas-1` failed; see the [log](https://example.com) '
    'before retrying.';

final DateTime _t0 = DateTime(2026, 10, 6, 12);

void main() {
  test('secondary ink and links reach 4.5:1 on every surface', () {
    final fails = <String>[];
    for (final p in AppTheme.presets) {
      final c = p.colors;
      final surfaces = {
        'background': c.background,
        'surface': c.surface,
        'surfaceVariant': c.surfaceVariant,
      };
      surfaces.forEach((name, bg) {
        for (final (token, ink) in [
          ('textSecondary', c.textSecondary),
          ('accentText', c.accentText),
        ]) {
          final r = ThemeContrast.ratio(ink, bg);
          if (r < _aa) {
            fails.add('${p.id} $token/$name ${r.toStringAsFixed(2)}');
          }
        }
      });
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  testWidgets('agent-text surfaces paint readable ink in every theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fails = <String>[];
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      final c = theme.hermes;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(preset.id),
          locale: const Locale('en'),
          localizationsDelegates: const [
            Strings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: Strings.supportedLocales,
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  ActivityNowSection(
                    snapshot: ActivitySnapshot(
                      turnActive: true,
                      turnStartedAt: _t0,
                      headline: 'Thinking…',
                      liveReasoning: _reasoning,
                    ),
                    now: _t0,
                  ),
                  ActivityDoneSection(
                    now: _t0,
                    steps: const [
                      ActivityStep(
                        id: 'tool',
                        kind: ActivityStepKind.tool,
                        label: 'terminal',
                        status: ActivityStepStatus.done,
                        text: 'ls -la /srv/backup',
                      ),
                      ActivityStep(
                        id: 'r',
                        kind: ActivityStepKind.reasoning,
                        label: 'reasoning',
                        status: ActivityStepStatus.done,
                        text: _reasoning,
                      ),
                    ],
                  ),
                  const HermesTextBlock(text: _reasoning),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final worstBackground = [c.background, c.surface, c.surfaceVariant];
      var checked = 0;
      for (final element in find.byType(RichText).evaluate()) {
        final widget = element.widget as RichText;
        void visit(InlineSpan span, TextStyle inherited) {
          if (span is! TextSpan) return;
          final style = inherited.merge(span.style);
          final text = span.text ?? '';
          final isIcon = (style.fontFamily ?? '').contains('MaterialIcons');
          if (text.trim().isNotEmpty && !isIcon && style.color != null) {
            final ink = ThemeContrast.composite(style.color!, c.background);
            checked++;
            for (final bg in worstBackground) {
              final r = ThemeContrast.ratio(ink, bg);
              if (r < _aa) {
                fails.add(
                  '${preset.id} "${text.trim().split('\n').first}" '
                  '${r.toStringAsFixed(2)}',
                );
                break;
              }
            }
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            visit(child, style);
          }
        }

        visit(widget.text, const TextStyle());
      }
      expect(checked, greaterThan(5), reason: preset.id);
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });
}
