// Wave 8, round 3 (after voice v2, the PiP and the tool pills): the labels
// painted on a tint read at 4.5:1 on what they really sit on, in light and
// dark, and the new pieces hold 200 % text without overflowing.
//
// Measured before the fix (values of app_theme.dart): the voice line's
// chip label in the raw accent was 2.09:1 on Console's capsule, 3.86:1 on
// console-light; warning and error chips fell under 4.5 too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesChrome;
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/voice_capsule.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _themes = ['console', 'console-light', 'amber', 'gruvbox-light'];

const _labels = VoiceStripLabels(
  finishListening: 'Terminar de hablar',
  pause: 'Pausar',
  resume: 'Reanudar',
  stopAndTalk: 'Parar y hablar',
  cancel: 'Cancelar tarea',
  stop: 'Detener',
  retry: 'Reintentar',
  review: 'Ver aprobación',
  close: 'Terminar modo voz',
  end: 'Terminar',
);

Widget _host(ThemeData theme, Widget child, {double scale = 1}) {
  return MaterialApp(
    theme: theme,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    builder: (context, home) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(textScaler: TextScaler.linear(scale)),
        child: home!,
      );
    },
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: 480, child: child),
      ),
    ),
  );
}

/// Every explicit text colour drawn under [of]. Icons are left out: a
/// glyph needs 3:1, not 4.5:1.
List<Color> _inks(WidgetTester tester, Finder of) {
  final inks = <Color>[];
  final texts = tester.widgetList<RichText>(
    find.descendant(of: of, matching: find.byType(RichText)),
  );
  for (final text in texts) {
    if (text.text.style?.fontFamily == Icons.done_rounded.fontFamily) {
      continue;
    }
    text.text.visitChildren((span) {
      if (span.style?.color case final color?) inks.add(color);
      return true;
    });
    if (text.text.style?.color case final color?) inks.add(color);
  }
  return inks;
}

ActivityStep _done() => const ActivityStep(
  id: 't',
  kind: ActivityStepKind.tool,
  label: 'terminal',
  status: ActivityStepStatus.done,
  detail: 'df -h',
  duration: Duration(milliseconds: 700),
);

void main() {
  for (final id in _themes) {
    testWidgets('$id: the voice line chip label reads at 4.5:1', (
      tester,
    ) async {
      final theme = AppTheme.fromId(id);
      final colors = theme.hermes;
      for (final (state, key) in [
        (VoiceStripState.waiting, 'voice-strip-review'),
        (VoiceStripState.listening, 'voice-strip-finish-listening'),
      ]) {
        await tester.pumpWidget(
          _host(
            theme,
            VoiceStatusLine(
              state: state,
              statusLabel: 'Hola',
              labels: _labels,
              onReview: () {},
              onFinishListening: () {},
            ),
          ),
        );
        final tone = state == VoiceStripState.waiting
            ? colors.warning
            : colors.accent;
        final chip = ThemeContrast.composite(
          tone.withValues(alpha: 0.2),
          HermesChrome.of(colors).opaque,
        );
        final inks = _inks(tester, find.byKey(ValueKey(key)));
        expect(inks, isNotEmpty, reason: '$key draws its label');
        for (final ink in inks) {
          expect(
            ThemeContrast.ratio(ink, chip),
            greaterThanOrEqualTo(4.5),
            reason: '$id $key $ink',
          );
        }
      }
    });

    testWidgets('$id: a done tool pill keeps its quiet ink at 4.5:1', (
      tester,
    ) async {
      final theme = AppTheme.fromId(id);
      final colors = theme.hermes;
      await tester.pumpWidget(_host(theme, TurnToolRow(step: _done())));
      final pill = ThemeContrast.composite(
        colors.success.withValues(alpha: 0.12),
        colors.background,
      );
      final inks = _inks(tester, find.byType(TurnToolRow));
      expect(inks, isNotEmpty);
      for (final ink in inks) {
        expect(
          ThemeContrast.ratio(ink, pill),
          greaterThanOrEqualTo(4.5),
          reason: '$id $ink',
        );
      }
    });
  }

  testWidgets('200 %: a tool pill grows instead of overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppTheme.fromId('console-light'),
        TurnToolRow(step: _done()),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('turn-tool-pill'))).height,
      greaterThanOrEqualTo(TurnToolRow.pillHeight),
    );
  });

  testWidgets('200 %: the minimized voice pill does not overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppTheme.fromId('console-light'),
        VoiceCapsulePill(
          name: 'Hermes',
          state: VoiceStripState.listening,
          statusLabel: 'Escuchando…',
          openLabel: 'Abrir modo voz',
          onOpen: () {},
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
