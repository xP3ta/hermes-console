// Estilo propio de la piel nueva del Kanban (solo presentación).
//
// Aquí vive lo que las tarjetas, las cabeceras de columna y la barra de
// acciones comparten: el ajuste que activa la piel, el tono y el texto de
// ayuda de cada estado, el glifo de prioridad y el formato del cronómetro.
// Nada de esto toca el cliente ni los modelos: se calcula desde los campos
// que el tablero ya trae.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Clave del ajuste interno "Nuevo diseño del Kanban". Por defecto activado.
const String kKanbanNewSkinPrefKey = 'kanban_new_skin';

/// Lectura/escritura del ajuste. Sin valor guardado la piel nueva está activa.
abstract final class KanbanSkinSetting {
  static bool read(SharedPreferences prefs) =>
      prefs.getBool(kKanbanNewSkinPrefKey) ?? true;

  static Future<void> write(SharedPreferences prefs, bool value) =>
      prefs.setBool(kKanbanNewSkinPrefKey, value);
}

/// Aspecto de una columna: el tono de su marca y su texto de ayuda. Una
/// columna que el cliente no conoce (el backend añadió un estado) recibe el
/// aspecto por defecto y ningún texto de ayuda.
class KanbanColumnStyle {
  final Color tone;
  final String? help;

  const KanbanColumnStyle({required this.tone, this.help});
}

KanbanColumnStyle kanbanColumnStyle(
  HermesThemeColors colors,
  Strings s,
  String status,
) {
  switch (status) {
    case 'triage':
      return KanbanColumnStyle(
        tone: colors.textSecondary,
        help: s.kanbanSkinHelpTriage,
      );
    case 'todo':
      return KanbanColumnStyle(
        tone: colors.textSecondary,
        help: s.kanbanSkinHelpTodo,
      );
    case 'scheduled':
      return KanbanColumnStyle(
        tone: colors.secondary,
        help: s.kanbanSkinHelpScheduled,
      );
    case 'ready':
      return KanbanColumnStyle(
        tone: colors.accent,
        help: s.kanbanSkinHelpReady,
      );
    case 'running':
      return KanbanColumnStyle(
        tone: colors.success,
        help: s.kanbanSkinHelpRunning,
      );
    case 'blocked':
      return KanbanColumnStyle(
        tone: colors.error,
        help: s.kanbanSkinHelpBlocked,
      );
    case 'review':
      return KanbanColumnStyle(
        tone: colors.warning,
        help: s.kanbanSkinHelpReview,
      );
    case 'done':
      return KanbanColumnStyle(
        tone: colors.textDisabled,
        help: s.kanbanSkinHelpDone,
      );
    case 'archived':
      return KanbanColumnStyle(
        tone: colors.textDisabled,
        help: s.kanbanSkinHelpArchived,
      );
  }
  return KanbanColumnStyle(tone: colors.textSecondary);
}

const String _glyphHigh = '▲';
const String _glyphNormal = '●';
const String _glyphLow = '▽';

/// Glifo de texto de una prioridad (`high`/`normal`/`low`); null si la tarea
/// no tiene prioridad (el valor por defecto no se pinta).
String? kanbanPriorityGlyph(String? priority) {
  switch (priority) {
    case 'high':
      return _glyphHigh;
    case 'normal':
      return _glyphNormal;
    case 'low':
      return _glyphLow;
  }
  return null;
}

String? kanbanPriorityName(Strings s, String? priority) {
  switch (priority) {
    case 'high':
      return s.kanbanPriorityHigh;
    case 'normal':
      return s.kanbanPriorityNormal;
    case 'low':
      return s.kanbanPriorityLow;
  }
  return null;
}

/// Color del glifo: solo la prioridad alta llama la atención.
Color kanbanPriorityColor(HermesThemeColors colors, String? priority) =>
    priority == 'high' ? colors.error : colors.textSecondary;

/// Color estable del avatar de quien lleva la tarea, derivado de su nombre
/// (siempre el mismo perfil, siempre el mismo tono).
Color kanbanAvatarTone(HermesThemeColors colors, String assignee) {
  final palette = <Color>[
    colors.accent,
    colors.success,
    colors.warning,
    colors.secondary,
    colors.error,
  ];
  var hash = 0;
  for (final unit in assignee.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}

/// Tiempo transcurrido como `m:ss` o `h:mm:ss`.
String kanbanElapsedLabel(Duration elapsed) {
  final total = elapsed.isNegative ? 0 : elapsed.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = total % 60;
  final ss = sec.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}
