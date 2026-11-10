// Wave 8 (audit 1.4.0 §2.12, §2.14): one-line labels were cut to a few
// letters at 200 % text. From 1.3× on they may take a second line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/text_scale.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

Widget _at(double scale, Widget child) => MaterialApp(
  theme: AppTheme.fromId('console'),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: child),
  ),
);

void main() {
  for (final (scale, lines) in [(1.0, 1), (1.29, 1), (1.3, 2), (2.0, 2)]) {
    testWidgets('at ×$scale a label takes $lines line(s)', (tester) async {
      late int got;
      await tester.pumpWidget(
        _at(
          scale,
          Builder(
            builder: (context) {
              got = labelMaxLines(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(got, lines);
    });
  }

  testWidgets('a settings row subtitle wraps at 200 % instead of cutting', (
    tester,
  ) async {
    const subtitle = 'A subtitle long enough to need two lines at 200 %';
    await tester.pumpWidget(
      _at(
        2,
        HermesNavRow(
          icon: Icons.info_outline,
          title: 'Title',
          subtitle: subtitle,
          onTap: () {},
        ),
      ),
    );
    // Two lines at 1x already (a subtitle is a sentence); three at 200 %.
    expect(tester.widget<Text>(find.text(subtitle)).maxLines, 3);
  });
}
