// The overlap sweep (1.4.0, header-glass): every main screen, mounted with
// fake data at 360, 600 and 840 dp and at 1x and 2x text, in a dark and a
// light theme. At rest the body starts under the header's foot and its fade;
// no two sibling boxes intersect or stand closer than 4 dp; nothing
// overflows. One test per screen, so a screen that cannot be mounted is
// reported by itself; each prints ONE table with all of its violations.
//
// To cover a screen add a SweepScreen in support/header_sweep_screens.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart' show HermesCard;

import 'support/a11y_main_screen_harness.dart';
import 'support/header_sweep.dart';
import 'support/header_sweep_screens.dart';

const _themes = ['classic-dark', 'classic'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(clearA11yPlatformMocks);

  for (final screen in sweepScreens) {
    testWidgets('sweep: ${screen.id}', (tester) async {
      addTearDown(tester.view.reset);
      final violations = <String>[];
      for (final width in sweepWidths) {
        for (final scale in sweepScales) {
          // The dark theme at every size; the light one at the smallest and
          // the widest, where the layouts differ most.
          for (final theme in _themes) {
            if (theme == 'classic' && width == 600) continue;
            violations.addAll(
              await sweepOnce(
                tester,
                screen,
                width: width,
                scale: scale,
                themeId: theme,
              ),
            );
          }
        }
      }
      if (violations.isNotEmpty) {
        // ignore: avoid_print
        print(
          'SWEEP ${screen.id}: ${violations.length}\n${violations.join('\n')}',
        );
      }
      expect(
        violations,
        isEmpty,
        reason:
            'SWEEP ${screen.id} (${screen.note}):\n${violations.join('\n')}',
      );
    });
  }

  // The sweep must see what it is for: a page that starts under its header,
  // with two cards touching and a row that overflows, is reported.
  testWidgets('the sweep catches a broken page', (tester) async {
    addTearDown(tester.view.reset);
    final broken = SweepScreen(
      'roto',
      (tester) async => Scaffold(
        appBar: const HermesAppBar(title: Text('Cabecera')),
        extendBodyBehindAppBar: true,
        body: Column(
          children: [
            const Text('Texto bajo la cabecera'),
            const HermesCard(child: Text('Primera')),
            const HermesCard(child: Text('Segunda')),
            Row(
              children: [
                for (var i = 0; i < 4; i++)
                  const SizedBox(width: 120, child: Text('ancho')),
              ],
            ),
          ],
        ),
      ),
    );
    final found = await sweepOnce(
      tester,
      broken,
      width: 360,
      scale: 1,
      themeId: 'classic-dark',
    );
    final all = found.join('\n');
    expect(all, contains('(a) texto'));
    expect(all, contains('(b)'));
    expect(all, contains('(c) desbordamiento'));
  });
}
