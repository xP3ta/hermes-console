import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';

/// `m:ss` (y `h:mm:ss` pasada la hora): el cronómetro vivo de la pastilla.
String formatTurnElapsed(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return '$minutes:$seconds';
  return '${minutes ~/ 60}:'
      '${(minutes % 60).toString().padLeft(2, '0')}:'
      '$seconds';
}

/// Duración de un paso terminado: `0.7 s`, `23 s`, `1:05`. Coma decimal en
/// español.
String formatStepDuration(Duration value, {String languageCode = 'en'}) {
  final ms = value.inMilliseconds;
  if (ms < 10000) {
    final text = (ms / 1000).toStringAsFixed(1);
    return '${languageCode == 'es' ? text.replaceAll('.', ',') : text} s';
  }
  if (ms < 60000) return '${value.inSeconds} s';
  return formatTurnElapsed(value);
}

/// Qué glifo encabeza la pastilla.
enum ActivityGlyph {
  connecting,
  thinking,
  tool,
  skill,
  waiting,
  tasks,
  background,
  subagents,
}

IconData _glyphIcon(ActivityGlyph glyph) => switch (glyph) {
  ActivityGlyph.connecting => Icons.cloud_queue_rounded,
  ActivityGlyph.thinking => Icons.psychology_alt_rounded,
  ActivityGlyph.tool => Icons.terminal_rounded,
  ActivityGlyph.skill => Icons.auto_awesome_rounded,
  ActivityGlyph.waiting => Icons.help_outline_rounded,
  ActivityGlyph.tasks => Icons.check_circle_outline_rounded,
  ActivityGlyph.background => Icons.layers_outlined,
  ActivityGlyph.subagents => Icons.account_tree_outlined,
};

/// Lo que la pastilla enseña en UNA línea. Se calcula solo desde el
/// [ActivitySnapshot]; no hay estado propio.
final class ActivityPillModel {
  const ActivityPillModel({
    required this.glyph,
    required this.action,
    required this.semanticsLabel,
    this.detail,
    this.tasksDone,
    this.tasksTotal,
    this.tasksFraction,
    this.extras,
    this.timerStart,
    this.live = true,
  });

  final ActivityGlyph glyph;

  /// Acción actual («terminal», «Pensando…», «Compactando conversación»…).
  final String action;

  /// Detalle seguro de la acción (`date`, `config.yaml`…), ya acotado.
  final String? detail;
  final int? tasksDone;
  final int? tasksTotal;
  final double? tasksFraction;

  /// Resumen de lo demás que sigue vivo («+1 en segundo plano · +2 subagentes»).
  final String? extras;

  /// Origen del cronómetro; `null` = sin cronómetro.
  final DateTime? timerStart;

  /// `false` cuando no hay nada corriendo (resultado de compactación, revisión
  /// de subagentes terminados): glifo estático, sin cronómetro.
  final bool live;

  final String semanticsLabel;

  bool get hasTasks => tasksDone != null && tasksTotal != null;
}

/// Construye el modelo de la pastilla, o `null` si no hay nada vivo que enseñar.
///
/// [revealAfter] evita el parpadeo en turnos rápidos: mientras lo único vivo es
/// el propio turno «pensando» y lleva menos que eso, la pastilla no aparece (el
/// avatar de la burbuja ya late). Una herramienta en curso, una lista de tareas
/// o una espera por el usuario son trabajo real y la revelan de inmediato.
ActivityPillModel? buildActivityPillModel(
  ActivitySnapshot snapshot,
  Strings strings, {
  required DateTime now,
  String languageCode = 'en',
  Duration revealAfter = const Duration(seconds: 2),
}) {
  if (!snapshot.isLive) return null;
  final realWork =
      snapshot.current != null ||
      snapshot.showTasks ||
      snapshot.waitingForUser ||
      snapshot.noActivityHint;
  if (!snapshot.hasNonTurnActivity && !realWork) {
    final startedAt = snapshot.turnStartedAt;
    if (startedAt != null && now.difference(startedAt) < revealAfter) {
      return null;
    }
  }

  ActivityGlyph glyph;
  String action;
  String? detail;
  DateTime? timerStart;
  var live = true;
  var primary = 'turn';

  if (snapshot.turnActive) {
    timerStart = snapshot.turnStartedAt;
    final current = snapshot.current;
    if (snapshot.noActivityHint) {
      glyph = ActivityGlyph.thinking;
      action = strings.chaTurnStillWorking;
    } else if (snapshot.waitingForUser) {
      glyph = ActivityGlyph.waiting;
      action = strings.liveWaitingForUser;
    } else if (current != null) {
      switch (current.kind) {
        case ActivityStepKind.reasoning:
          glyph = ActivityGlyph.thinking;
          action = strings.chatActivityThinking;
        case ActivityStepKind.skill:
          glyph = ActivityGlyph.skill;
          action = current.label;
          detail = current.detail;
        case ActivityStepKind.tool:
          glyph = ActivityGlyph.tool;
          action = current.label;
          detail = current.detail;
      }
    } else {
      glyph = snapshot.headline == strings.chaPipelineConnecting
          ? ActivityGlyph.connecting
          : ActivityGlyph.thinking;
      action = snapshot.headline ?? strings.chaPipelineThinking;
    }
  } else if (snapshot.showTasks && snapshot.tasks!.isFinished) {
    primary = 'tasks';
    glyph = ActivityGlyph.tasks;
    action = strings.agentTasksAllDone;
    live = false;
  } else if (snapshot.subagentsRunning) {
    primary = 'subagents';
    glyph = ActivityGlyph.subagents;
    action = snapshot.subagentCount == 0
        ? strings.chaBackgroundWorkTitle
        : strings.liveSubagentsWorking(snapshot.subagentCount);
  } else if (snapshot.backgroundCount > 0) {
    primary = 'background';
    glyph = ActivityGlyph.background;
    timerStart = snapshot.backgroundStartedAt;
    final single =
        snapshot.backgroundCount == 1 && snapshot.processes.length == 1;
    final command = snapshot.processes.isEmpty
        ? null
        : snapshot.processes.first.command.trim();
    action = single && command != null && command.isNotEmpty
        ? strings.chaBackgroundProcessCommand(command)
        : strings.chaBackgroundActivityCount(snapshot.backgroundCount);
  } else {
    primary = 'subagents';
    glyph = ActivityGlyph.subagents;
    action = strings.liveSubagentsEnded(snapshot.subagentCount);
    live = false;
  }

  final tasks = snapshot.showTasks ? snapshot.tasks : null;
  final extras = <String>[
    if (primary != 'background' && snapshot.backgroundCount > 0)
      strings.liveMoreBackground(snapshot.backgroundCount),
    if (primary != 'subagents' &&
        snapshot.hasSubagents &&
        snapshot.subagentCount > 0)
      strings.liveMoreSubagents(snapshot.subagentCount),
    // El estado de segundo plano puede estar desfasado: se avisa en la línea.
    if (snapshot.processesStale && snapshot.backgroundCount > 0)
      strings.chaBackgroundActivityStale,
  ];

  final semantics = <String>[
    action,
    ?detail,
    if (tasks != null) strings.liveTasksShort(tasks.done, tasks.total),
    ...extras,
  ].join(', ');

  return ActivityPillModel(
    glyph: glyph,
    action: action,
    detail: detail,
    tasksDone: tasks?.done,
    tasksTotal: tasks?.total,
    tasksFraction: tasks?.progress,
    extras: extras.isEmpty ? null : extras.join(' · '),
    timerStart: timerStart,
    live: live,
    semanticsLabel: semantics,
  );
}

/// Reconstruye [builder] cada segundo mientras [active], con reloj inyectable.
///
/// Es el único ticker de la pastilla: cronómetro, porcentaje estimado de la
/// compactación y anti-parpadeo salen del mismo `now`. Se para en segundo plano
/// y en rutas ocultas para no repintar el chat en reposo.
class ActivityTicker extends StatefulWidget {
  const ActivityTicker({
    required this.active,
    required this.builder,
    this.clock,
    super.key,
  });

  final bool active;
  final Widget Function(BuildContext context, DateTime now) builder;
  final DateTime Function()? clock;

  @override
  State<ActivityTicker> createState() => _ActivityTickerState();
}

class _ActivityTickerState extends State<ActivityTicker>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  bool _viewEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewEnabled = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(ActivityTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
    if (_foreground && mounted) setState(() {});
  }

  void _sync() {
    final shouldTick = widget.active && _foreground && _viewEnabled;
    if (shouldTick == (_timer != null)) return;
    if (!shouldTick) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, (widget.clock ?? DateTime.now)());
}

/// Texto escalado (1.0 = normal): a escala alta la pastilla suelta lo accesorio.
double activityTextScale(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(13) / 13;

Color _glyphColor(HermesThemeColors colors, ActivityGlyph glyph) =>
    switch (glyph) {
      ActivityGlyph.waiting => colors.warning,
      ActivityGlyph.tasks => colors.success,
      _ => colors.accent,
    };

/// Glifo de estado: icono dentro de un disco suave con un anillo fino que gira
/// mientras hay trabajo vivo. Es lo que da identidad a la pastilla sin texto.
class ActivityGlyphBadge extends StatelessWidget {
  const ActivityGlyphBadge({
    required this.glyph,
    required this.live,
    super.key,
  });

  final ActivityGlyph glyph;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = _glyphColor(colors, glyph);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return SizedBox(
      key: const ValueKey('activity-glyph'),
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
            ),
            child: const SizedBox.expand(),
          ),
          if (live)
            SizedBox(
              width: 24,
              height: 24,
              child: reduceMotion
                  ? CircularProgressIndicator(
                      value: 0.28,
                      strokeWidth: 1.8,
                      color: color,
                    )
                  : CircularProgressIndicator(strokeWidth: 1.8, color: color),
            ),
          Icon(_glyphIcon(glyph), size: 13, color: color),
        ],
      ),
    );
  }
}

/// Anillo diminuto + «2/4»: el progreso de las tareas dentro de la pastilla.
class ActivityTaskChip extends StatelessWidget {
  const ActivityTaskChip({
    required this.done,
    required this.total,
    required this.fraction,
    super.key,
  });

  final int done;
  final int total;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Row(
      key: const ValueKey('activity-task-chip'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            value: fraction,
            strokeWidth: 2.2,
            backgroundColor: colors.divider,
            color: done >= total ? colors.success : colors.accent,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '$done/$total',
          maxLines: 1,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// La línea de la pastilla: la misma en la pastilla plegada y en la cabecera
/// del panel desplegado, para que la ventana «salga» de la pastilla sin que
/// nada salte.
class ActivityPillRow extends StatelessWidget {
  const ActivityPillRow({
    required this.model,
    required this.now,
    this.expanded = false,
    this.fill = false,
    super.key,
  });

  final ActivityPillModel model;
  final DateTime now;

  /// Chevron hacia abajo (panel abierto) frente a hacia arriba.
  final bool expanded;

  /// Ocupa todo el ancho disponible (cabecera del panel) en vez de ajustarse.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final bigText = activityTextScale(context) >= 1.6;
    final timerStart = model.timerStart;
    final timer = timerStart == null || !model.live
        ? null
        : formatTurnElapsed(
            now.difference(timerStart).isNegative
                ? Duration.zero
                : now.difference(timerStart),
          );

    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: model.action,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          if (model.detail != null)
            TextSpan(
              text: ' · ${model.detail}',
              style: TextStyle(color: colors.textSecondary),
            ),
        ],
      ),
      key: const ValueKey('activity-pill-text'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13),
    );

    final children = <Widget>[
      ActivityGlyphBadge(glyph: model.glyph, live: model.live),
      const SizedBox(width: 9),
      fill ? Expanded(child: text) : Flexible(child: text),
      if (model.hasTasks && !bigText) ...[
        const SizedBox(width: 9),
        ActivityTaskChip(
          done: model.tasksDone!,
          total: model.tasksTotal!,
          fraction: model.tasksFraction ?? 0,
        ),
      ],
      if (model.extras != null && !bigText) ...[
        const SizedBox(width: 9),
        Flexible(
          flex: 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              model.extras!,
              key: const ValueKey('activity-pill-extras'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
        ),
      ],
      if (timer != null) ...[
        const SizedBox(width: 9),
        // El cronómetro no entra en la etiqueta semántica: se anunciaría cada
        // segundo. La acción sí, y solo cuando cambia.
        ExcludeSemantics(
          child: Text(
            timer,
            key: const ValueKey('activity-pill-elapsed'),
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
      const SizedBox(width: 4),
      AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 200),
        child: Icon(
          Icons.keyboard_arrow_up_rounded,
          size: 20,
          color: colors.textSecondary,
        ),
      ),
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(
          mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// La pastilla plegada: UNA superficie flotante para todo lo vivo.
class ActivityPill extends StatelessWidget {
  const ActivityPill({
    required this.model,
    required this.now,
    required this.onTap,
    super.key,
  });

  final ActivityPillModel model;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Semantics(
      liveRegion: true,
      button: onTap != null,
      container: true,
      label: model.semanticsLabel,
      hint: strings.liveShowActivity,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('activity-pill'),
        color: colors.surface,
        shape: StadiumBorder(
          side: BorderSide(color: colors.divider, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        child: InkWell(
          onTap: onTap,
          child: ActivityPillRow(model: model, now: now),
        ),
      ),
    );
  }
}
