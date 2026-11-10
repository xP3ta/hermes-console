// Wave 8 (audit 1.4.0 §2.11): the attachment kind colours were fixed values
// for a dark page; on a light one the label of an archive fell to 2.4:1.
// The ink now keeps the kind's hue and reads at 4.5:1 (label) or 3:1
// (icon) on whatever theme it is drawn in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  test('labels 4.5:1 and icons 3:1 for every kind in every preset', () {
    final fails = <String>[];
    void check(String what, Color ink, Color behind, double minimum) {
      final ratio = ThemeContrast.ratio(ink, behind);
      if (ratio + 1e-9 < minimum) fails.add('$what $ratio');
    }

    for (final preset in AppTheme.presets) {
      final c = preset.colors;
      for (final kind in AttachmentKind.values) {
        for (final (name, under) in [
          ('surfaceVariant', c.surfaceVariant),
          ('background', c.background),
        ]) {
          // The label sits on the badge's tint over [under].
          final tile = ThemeContrast.composite(
            attachmentBadgeTint(kind),
            under,
          );
          check(
            '${preset.id} ${kind.name} label/$name',
            attachmentBadgeInk(kind, under),
            tile,
            4.5,
          );
        }
        check(
          '${preset.id} ${kind.name} icon/surfaceVariant',
          attachmentBadgeInk(
            kind,
            c.surfaceVariant,
            minimum: 3,
            tinted: false,
          ),
          c.surfaceVariant,
          3,
        );
      }
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  testWidgets('a file card in a light theme paints its label readable', (
    tester,
  ) async {
    final theme = AppTheme.fromId('console-light');
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(
          body: Center(
            child: AttachmentCard(
              name: 'backup.zip',
              mimeType: 'application/zip',
              sizeLabel: '2 MB',
            ),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('ZIP'));
    final under = theme.hermes.surfaceVariant;
    final tile = ThemeContrast.composite(
      attachmentBadgeTint(AttachmentKind.archive),
      under,
    );
    expect(
      label.style?.color,
      attachmentBadgeInk(AttachmentKind.archive, under),
    );
    expect(
      ThemeContrast.ratio(label.style!.color!, tile),
      greaterThanOrEqualTo(4.5),
    );
  });
}
