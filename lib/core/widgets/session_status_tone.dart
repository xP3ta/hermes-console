import 'package:flutter/material.dart';

import '../services/global_activity_aggregate.dart';
import '../models/session_activity.dart';
import '../theme/app_theme.dart';

/// Semantic state of a conversation's live status line (Conversaciones rows,
/// Inicio recents). Each state owns a colour from the theme tokens so the
/// status never reads like the title: working = the live dot's green,
/// compacting = the theme's calm contrast tint, attention = amber, error =
/// the error token, anything stale or idle = muted.
enum SessionStatusTone { working, compacting, attention, error, muted }

SessionStatusTone sessionStatusToneFor(
  SessionActivityKind kind, {
  bool stale = false,
}) {
  if (stale) return SessionStatusTone.muted;
  return switch (kind) {
    SessionActivityKind.preparing ||
    SessionActivityKind.generating ||
    SessionActivityKind.usingTools ||
    SessionActivityKind.responding ||
    SessionActivityKind.delegated ||
    SessionActivityKind.backgroundProcess => SessionStatusTone.working,
    SessionActivityKind.compacting => SessionStatusTone.compacting,
    SessionActivityKind.waitingForUser => SessionStatusTone.attention,
    SessionActivityKind.idle => SessionStatusTone.muted,
  };
}

SessionStatusTone globalStatusToneFor(GlobalActivity activity) {
  if (activity.stale) return SessionStatusTone.muted;
  if (activity.requiresAction) return SessionStatusTone.attention;
  return switch (activity.phase) {
    GlobalActivityPhase.preparing ||
    GlobalActivityPhase.generating ||
    GlobalActivityPhase.usingTools ||
    GlobalActivityPhase.delegated ||
    GlobalActivityPhase.backgroundWork ||
    GlobalActivityPhase.completing => SessionStatusTone.working,
    GlobalActivityPhase.compacting => SessionStatusTone.compacting,
    GlobalActivityPhase.waitingForUser => SessionStatusTone.attention,
    GlobalActivityPhase.failed => SessionStatusTone.error,
    GlobalActivityPhase.completed ||
    GlobalActivityPhase.interrupted ||
    GlobalActivityPhase.unknown => SessionStatusTone.muted,
  };
}

/// The state's colour for this theme: its token, adjusted only as far as
/// needed to read at WCAG AA on the background and to stay apart from the
/// title colour.
Color sessionStatusColor(HermesThemeColors colors, SessionStatusTone tone) =>
    switch (tone) {
      SessionStatusTone.working => _separatedTone(colors, [colors.success]),
      SessionStatusTone.compacting => resolveActivityTone(colors),
      SessionStatusTone.attention => _separatedTone(colors, [colors.warning]),
      SessionStatusTone.error => _separatedTone(colors, [colors.error]),
      SessionStatusTone.muted => readableActivityTone(
        colors.textSecondary,
        colors.background,
      ),
    };

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// WCAG AA for normal-size text.
const double _kMinActivityContrast = 4.5;

/// Minimum contrast for a tone to read as different from the title.
const double _kMinTitleSeparation = 1.3;

/// Tono legible para la línea de "actividad en curso" sobre [background].
///
/// `colors.secondary` cambia radicalmente entre los ~8 temas del catálogo
/// (de `#1540B1` en Nous claro a `#FFE600` en alto contraste, pasando por
/// `#606060` en Mono): en varios queda por debajo de 4.5:1 sobre la
/// superficie y el usuario lo veía "en blanco", indistinguible del título de
/// la conversación. En vez de fijar un color que solo funciona en un tema, el
/// tono del tema se aclara —u oscurece, en temas claros— hasta cruzar el
/// umbral, conservando su identidad.
@visibleForTesting
Color readableActivityTone(Color tone, Color background) {
  if (_contrastRatio(tone, background) >= _kMinActivityContrast) return tone;
  final target = background.computeLuminance() < 0.5
      ? Colors.white
      : Colors.black;
  var candidate = tone;
  for (var step = 1; step <= 10; step++) {
    candidate = Color.lerp(tone, target, step / 10)!;
    if (_contrastRatio(candidate, background) >= _kMinActivityContrast) {
      return candidate;
    }
  }
  return candidate;
}

/// Tono de "compactando"/actividad calma para un tema concreto: el
/// `secondary` del tema (o su `accent`), legible y separado del título.
///
/// Dos trampas reales del catálogo, las dos con el mismo síntoma (la
/// actividad acaba con el color del título):
///  - Mono: `secondary` ya es el gris claro del título (`#EAEAEA`), y
///    aclararlo para cumplir AA lo deja idéntico. Su `accent` gris medio sí
///    se separa.
///  - Cyberpunk: ni `secondary` ni `accent` se separan del `textPrimary`
///    neón. Ahí se atenúa el tono hacia el fondo hasta separarlo, sin bajar
///    nunca del umbral AA.
@visibleForTesting
Color resolveActivityTone(HermesThemeColors colors) =>
    _separatedTone(colors, [colors.secondary, colors.accent]);

Color _separatedTone(HermesThemeColors colors, List<Color> candidates) {
  bool separated(Color tone) =>
      _contrastRatio(tone, colors.textPrimary) >= _kMinTitleSeparation;

  Color? fallback;
  for (final candidate in candidates) {
    final tone = readableActivityTone(candidate, colors.background);
    if (separated(tone)) return tone;
    fallback ??= tone;
  }
  var tone = fallback!;
  for (var step = 1; step <= 12; step++) {
    final dimmed = Color.lerp(fallback, colors.background, step / 20)!;
    if (_contrastRatio(dimmed, colors.background) < _kMinActivityContrast) {
      break;
    }
    tone = dimmed;
    if (separated(dimmed)) return dimmed;
  }
  return tone;
}
