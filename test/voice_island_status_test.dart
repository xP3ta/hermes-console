// SPDX-License-Identifier: MIT
// Voz inline (§9): the island's voice state is read by TalkBack once per
// change, never per clock tick, and it fits right to left as well.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/voice_capsule.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart'
    show VoiceStripState;

Widget _host(
  VoiceStripState state,
  String label, {
  TextDirection direction = TextDirection.ltr,
}) {
  return MaterialApp(
    theme: AppTheme.fromId('dark'),
    home: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Center(
          child: VoiceIslandStatus(
            name: 'Hermes',
            state: state,
            statusLabel: label,
            actionLabel: 'Pausar',
            onTap: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('TalkBack hears the state once per change, never the clock', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final status = find.byKey(const ValueKey('voice-island-status'));
    await tester.pumpWidget(_host(VoiceStripState.listening, 'Escuchando…'));
    final first = tester.getSemantics(status);
    expect(first.flagsCollection.isLiveRegion, isTrue);
    expect(first.label, 'Hermes, Escuchando…');
    expect(first.label, isNot(contains('0:')));

    // The clock ticks on screen; what TalkBack hears does not change.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('0:03'), findsOneWidget);
    expect(tester.getSemantics(status).label, 'Hermes, Escuchando…');

    // A new state is a new label: one announcement.
    await tester.pumpWidget(_host(VoiceStripState.thinking, 'Pensando…'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSemantics(status).label, 'Hermes, Pensando…');
    semantics.dispose();
  });

  testWidgets('right to left, the state fits on its line', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        VoiceStripState.toolCall,
        'Usando una herramienta con un nombre muy largo…',
        direction: TextDirection.rtl,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    final status = tester.getRect(
      find.byKey(const ValueKey('voice-island-status')),
    );
    expect(status.width, lessThanOrEqualTo(VoiceIslandStatus.maxWidth));
    expect(status.left, greaterThanOrEqualTo(0));
    expect(status.right, lessThanOrEqualTo(320));
  });
}
