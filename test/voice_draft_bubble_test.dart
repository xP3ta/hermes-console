// SPDX-License-Identifier: MIT
// Voz inline (§5): what the user is saying, as a draft of their message.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/voice_draft_bubble.dart';

Widget _host(Widget child, {TextDirection direction = TextDirection.ltr}) {
  return MaterialApp(
    theme: AppTheme.fromId('dark'),
    home: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );
}

void main() {
  group('VoiceDraft.textFor', () {
    test('a partial while listening is the draft', () {
      expect(
        VoiceDraft.textFor(phase: VoicePhase.listening, partial: ' hola '),
        'hola',
      );
    });

    test('listening with nothing heard shows no draft', () {
      expect(
        VoiceDraft.textFor(phase: VoicePhase.listening, partial: ''),
        isNull,
      );
    });

    test('a capture being transcribed shows the draft, even empty', () {
      // Hosts that do not stream partials: «Escuchando…» until the final.
      expect(
        VoiceDraft.textFor(phase: VoicePhase.transcribing, partial: ''),
        '',
      );
    });

    test('once sent, or while Hermes answers, there is no draft', () {
      for (final phase in const [
        VoicePhase.idle,
        VoicePhase.thinking,
        VoicePhase.speaking,
        VoicePhase.toolCall,
        VoicePhase.waitingPermission,
      ]) {
        expect(
          VoiceDraft.textFor(phase: phase, partial: 'hola'),
          isNull,
          reason: phase.name,
        );
      }
    });

    test('paused, there is no draft', () {
      expect(
        VoiceDraft.textFor(
          phase: VoicePhase.listening,
          partial: 'hola',
          userPaused: true,
        ),
        isNull,
      );
    });
  });

  group('VoiceDraftBubble', () {
    testWidgets('says «Hablando…» with the words heard so far', (tester) async {
      await tester.pumpWidget(
        _host(
          const VoiceDraftBubble(
            text: 'hola mundo',
            speakingLabel: 'Hablando…',
            listeningLabel: 'Escuchando…',
          ),
        ),
      );
      final bubble = find.byKey(const ValueKey('voice-draft-bubble'));
      expect(
        find.descendant(of: bubble, matching: find.text('hola mundo')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bubble, matching: find.text('Hablando…')),
        findsOneWidget,
      );
      expect(find.text('Escuchando…'), findsNothing);
    });

    testWidgets('with no words yet it says «Escuchando…» only', (tester) async {
      await tester.pumpWidget(
        _host(
          const VoiceDraftBubble(
            text: '',
            speakingLabel: 'Hablando…',
            listeningLabel: 'Escuchando…',
          ),
        ),
      );
      expect(find.text('Escuchando…'), findsOneWidget);
      expect(find.text('Hablando…'), findsNothing);
    });

    testWidgets('TalkBack reads the tag and the words, not per word', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const VoiceDraftBubble(
            text: 'hola mundo',
            speakingLabel: 'Hablando…',
            listeningLabel: 'Escuchando…',
          ),
        ),
      );
      final node = tester.getSemantics(
        find.byKey(const ValueKey('voice-draft-bubble')),
      );
      expect(node.label, contains('Hablando…'));
      expect(node.label, contains('hola mundo'));
      // A live region would read every partial out loud.
      expect(node.flagsCollection.isLiveRegion, isFalse);
      semantics.dispose();
    });

    testWidgets('sits on the user side, also right to left', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const bubble = VoiceDraftBubble(
        text: 'hola',
        speakingLabel: 'Hablando…',
        listeningLabel: 'Escuchando…',
      );
      final key = find.byKey(const ValueKey('voice-draft-bubble'));
      await tester.pumpWidget(_host(bubble));
      final ltr = tester.getRect(key);
      expect(ltr.center.dx, greaterThan(206), reason: 'end side in LTR');

      await tester.pumpWidget(_host(bubble, direction: TextDirection.rtl));
      final rtl = tester.getRect(key);
      expect(rtl.center.dx, lessThan(206), reason: 'end side in RTL');
      expect(tester.takeException(), isNull);
    });
  });
}
