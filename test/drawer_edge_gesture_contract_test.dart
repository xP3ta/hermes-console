import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';

void main() {
  // 1.4.1: the edge drag follows «Abrir el menú deslizando» (off by
  // default, 2026-11-14), so the literal `true` this test pinned became
  // the one helper every screen with the menu must read.
  test('las superficies globales leen el ajuste del gesto lateral del drawer', () {
    const paths = <String>[
      'lib/core/screens/home_dashboard_screen.dart',
      'lib/core/screens/session_list_screen.dart',
      'lib/core/screens/chat_screen.dart',
      'lib/core/screens/mission_control_screen.dart',
    ];

    for (final path in paths) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        contains(
          'drawerEnableOpenDragGesture: HermesDrawer.openDragEnabled(context),',
        ),
        reason: path,
      );
      expect(
        source,
        isNot(contains('drawerEnableOpenDragGesture: true')),
        reason: path,
      );
      expect(
        source,
        contains('drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),'),
        reason: path,
      );
    }
  });

  test('ningún Scaffold con drawer en lib/ se salta el ajuste', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Code only: a comment may say «drawer:» too.
      final source = entity
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      if (!RegExp(r'\bdrawer:\s').hasMatch(source)) continue;
      for (final match in RegExp(
        r'drawerEnableOpenDragGesture:\s*([^,\n]+)',
      ).allMatches(source)) {
        final value = match.group(1)!.trim();
        if (value != 'HermesDrawer.openDragEnabled(context)' &&
            value != 'page.drawerEnableOpenDragGesture') {
          offenders.add('${entity.path}: $value');
        }
      }
      final drawers = RegExp(r'\bdrawer:\s').allMatches(source).length;
      final reads = RegExp(r'drawerEnableOpenDragGesture:')
          .allMatches(source)
          .length;
      // Flutter's default is true: a drawer without the flag would open from
      // the edge whatever the setting says.
      if (reads < drawers) offenders.add('${entity.path}: drawer sin el flag');
    }
    expect(offenders, isEmpty);
  });

  testWidgets('la banda suma el borde reservado por Android y 48 dp', (
    tester,
  ) async {
    late double width;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          systemGestureInsets: EdgeInsets.only(left: 24),
        ),
        child: Builder(
          builder: (context) {
            width = HermesDrawer.edgeDragWidth(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(width, 72);
  });

  test(
    'la exclusión nativa es acotada y solo la gobiernan rutas con drawer',
    () {
      final native = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt',
      ).readAsStringSync();
      expect(native, contains('systemGestureExclusionRects'));
      expect(native, contains('200 * density'));
      expect(native, contains('Rect(0, top, width, top + height)'));

      for (final path in const <String>[
        'lib/core/screens/home_dashboard_screen.dart',
        'lib/core/screens/session_list_screen.dart',
        'lib/core/screens/chat_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('DrawerGestureExclusion.setEnabled'),
          reason: path,
        );
      }
    },
  );
}
