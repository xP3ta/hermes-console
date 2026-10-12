import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/voice_guide_screen.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets('la pantalla principal no muestra un asistente redundante', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const VoiceSettingsScreen(),
      ),
    );
    await tester.pump();

    expect(find.text('Guía paso a paso'), findsNothing);
    expect(find.text('Modo de voz'), findsNothing);
    // The main screen is a short list; routing and engines are one tap away.
    for (final key in const [
      'voice_main_dictation',
      'voice_main_reply_voice',
      'voice_auto_speak',
      'voice_continue_when_locked',
      'voice_main_advanced',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    for (final key in const [
      'voice_mode_phone_option',
      'voice_mode_server_option',
      'voice_dictation_phone_option',
      'voice_dictation_server_option',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    await tester.tap(find.byKey(const ValueKey('voice_main_reply_voice')));
    await tester.pumpAndSettle();
    final conversation = find.byKey(const ValueKey('voice_reading_section'));
    for (final key in const [
      'voice_mode_server_option',
      'voice_mode_phone_option',
    ]) {
      expect(
        find.descendant(of: conversation, matching: find.byKey(ValueKey(key))),
        findsOneWidget,
        reason: key,
      );
    }
    expect(find.textContaining('JSON'), findsNothing);
  });

  testWidgets('la guía local también está completa en inglés', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const VoiceGuideScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Two settings, with no hidden steps'), findsOneWidget);
    expect(find.text('Speech to text'), findsOneWidget);
    expect(find.text('Text to speech'), findsOneWidget);
    expect(find.text('3. Test before saving'), findsNothing);
  });
}
