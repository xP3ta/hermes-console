import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_status_tone.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Conversation-list status lines ("usando herramientas", "compactando")
/// used to share the title's colour. Each state now has its own semantic
/// tone, readable (WCAG AA) and distinct from the title in every theme.
void main() {
  test('each activity maps to its semantic state', () {
    expect(
      sessionStatusToneFor(SessionActivityKind.usingTools),
      SessionStatusTone.working,
    );
    expect(
      sessionStatusToneFor(SessionActivityKind.generating),
      SessionStatusTone.working,
    );
    expect(
      sessionStatusToneFor(SessionActivityKind.compacting),
      SessionStatusTone.compacting,
    );
    expect(
      sessionStatusToneFor(SessionActivityKind.waitingForUser),
      SessionStatusTone.attention,
    );
    expect(
      sessionStatusToneFor(SessionActivityKind.idle),
      SessionStatusTone.muted,
    );
    expect(
      sessionStatusToneFor(SessionActivityKind.usingTools, stale: true),
      SessionStatusTone.muted,
    );
  });

  test('every theme: tones follow their tokens, read AA and never look like '
      'the title', () {
    for (final preset in AppTheme.presets) {
      for (final theme in [
        AppTheme.fromId(preset.id),
        AppTheme.hermesRedLight,
        AppTheme.hermesRedDark,
      ]) {
        final colors = theme.hermes;
        final tones = {
          for (final tone in SessionStatusTone.values)
            tone: sessionStatusColor(colors, tone),
        };
        for (final entry in tones.entries) {
          expect(
            _contrast(entry.value, colors.background),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.id} ${entry.key}',
          );
          expect(entry.value, isNot(colors.textPrimary));
          if (entry.key != SessionStatusTone.muted) {
            expect(
              _contrast(entry.value, colors.textPrimary),
              greaterThanOrEqualTo(1.3),
              reason: '${preset.id} ${entry.key} vs title',
            );
          }
        }
        expect(
          tones[SessionStatusTone.compacting],
          isNot(tones[SessionStatusTone.working]),
          reason: preset.id,
        );
        expect(
          tones[SessionStatusTone.attention],
          isNot(tones[SessionStatusTone.working]),
          reason: preset.id,
        );
      }
    }
  });

  test('the base palette uses its own tokens when they already read well', () {
    final colors = AppTheme.hermesRedDark.hermes;
    expect(
      sessionStatusColor(colors, SessionStatusTone.working),
      colors.success,
    );
    expect(
      sessionStatusColor(colors, SessionStatusTone.attention),
      colors.warning,
    );
    expect(sessionStatusColor(colors, SessionStatusTone.error), colors.error);
    expect(
      sessionStatusColor(colors, SessionStatusTone.muted),
      colors.textSecondary,
    );
  });
}
