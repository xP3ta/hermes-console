import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';
import 'activity_pill.dart';
import 'activity_sections.dart';

export 'activity_sections.dart'
    show ActivityPanelActions, ActivityScheduleAction;

/// Lo que el panel abierto necesita para repintarse en vivo.
final class ActivityPanelState {
  const ActivityPanelState(this.snapshot, this.actions);

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;
}

/// Cuerpo del panel: las secciones que tengan contenido, en orden fijo.
///
/// 1 Tareas · 2 Ahora · 3 Hecho · 4 Segundo plano / Subagentes / Bucles /
/// Objetivo. Lo que no tiene contenido se omite.
class ActivityPanelBody extends StatelessWidget {
  const ActivityPanelBody({
    required this.snapshot,
    required this.actions,
    required this.now,
    this.nowKey,
    super.key,
  });

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;
  final DateTime now;
  final Key? nowKey;

  @override
  Widget build(BuildContext context) {
    final tasks = snapshot.showTasks ? snapshot.tasks : null;
    final children = <Widget>[
      if (tasks != null) ActivityTasksSection(tasks: tasks),
      if (snapshot.turnActive)
        ActivityNowSection(snapshot: snapshot, now: now, sectionKey: nowKey),
      if (snapshot.turnActive && snapshot.done.isNotEmpty)
        ActivityDoneSection(steps: snapshot.done, now: now),
      if (snapshot.processes.isNotEmpty)
        ActivityBackgroundSection(
          snapshot: snapshot,
          actions: actions,
          now: now,
        ),
      if (snapshot.hasSubagents)
        ActivitySubagentsSection(
          snapshot: snapshot,
          actions: actions,
          now: now,
        ),
      if (snapshot.schedules.isNotEmpty)
        ActivityLoopsSection(snapshot: snapshot, actions: actions),
      if (snapshot.goal != null)
        ActivityGoalSection(goal: snapshot.goal!, actions: actions),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// La superficie del panel: crece desde el rect de la pastilla (ancho, radio y
/// alto interpolados con la animación de la ruta) y su cabecera ES la línea de
/// la pastilla, así que nada salta al abrir.
class ActivityPanelSurface extends StatefulWidget {
  const ActivityPanelSurface({
    required this.animation,
    required this.link,
    required this.pillSize,
    required this.state,
    required this.onClose,
    this.clock,
    super.key,
  });

  final Animation<double> animation;
  final LayerLink link;
  final Size pillSize;
  final ValueListenable<ActivityPanelState> state;
  final VoidCallback onClose;
  final DateTime Function()? clock;

  @override
  State<ActivityPanelSurface> createState() => _ActivityPanelSurfaceState();
}

class _ActivityPanelSurfaceState extends State<ActivityPanelSurface> {
  static const double maxWidth = 560;
  static const double heightFactor = 0.55;

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final ScrollController _scroll = ScrollController();
  final GlobalKey _scrollKey = GlobalKey();
  final GlobalKey _nowKey = GlobalKey();
  bool _userScrolled = false;
  bool _closing = false;
  double _dragDown = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_followCurrentStep);
    WidgetsBinding.instance.addPostFrameCallback((_) => _followCurrentStep());
  }

  @override
  void dispose() {
    widget.state.removeListener(_followCurrentStep);
    _curve.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _nowFullyVisible() {
    final nowBox = _nowKey.currentContext?.findRenderObject();
    final viewBox = _scrollKey.currentContext?.findRenderObject();
    if (nowBox is! RenderBox || viewBox is! RenderBox) return true;
    if (!nowBox.attached || !viewBox.attached) return true;
    final top = nowBox.localToGlobal(Offset.zero).dy;
    final viewTop = viewBox.localToGlobal(Offset.zero).dy;
    return top >= viewTop - 1 &&
        top + nowBox.size.height <= viewTop + viewBox.size.height + 1;
  }

  /// Mantiene a la vista el paso en curso mientras el usuario no haya tomado el
  /// control del scroll.
  void _followCurrentStep() {
    if (_userScrolled || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userScrolled || !_scroll.hasClients) return;
      final ctx = _nowKey.currentContext;
      if (ctx == null || _nowFullyVisible()) return;
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: reduce ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      _userScrolled = true;
    } else if (notification is ScrollEndNotification &&
        _userScrolled &&
        _nowFullyVisible()) {
      // Volvió a dejar el paso en curso a la vista: se reanuda el seguimiento.
      _userScrolled = false;
    }
    return false;
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    widget.onClose();
  }

  void _dragEnd(DragEndDetails details) {
    if (_dragDown > 40 || (details.primaryVelocity ?? 0) > 300) _close();
    _dragDown = 0;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final media = MediaQuery.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    return ActivityTicker(
      active: true,
      clock: widget.clock,
      builder: (context, now) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final snapshot = widget.state.value.snapshot;
          final actions = widget.state.value.actions;
          final model = buildActivityPillModel(
            snapshot,
            strings,
            now: now,
            languageCode: lang,
            revealAfter: Duration.zero,
          );
          if (model == null) {
            // Nada vivo: el panel se retira solo.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _close();
            });
            return const SizedBox.shrink();
          }
          final available = media.size.height - media.viewInsets.bottom;
          final maxHeight = math.max(160.0, available * heightFactor);
          final targetWidth = math.max(
            widget.pillSize.width,
            math.min(media.size.width - 24, maxWidth),
          );
          return Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: CompositedTransformFollower(
                  link: widget.link,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomCenter,
                  followerAnchor: Alignment.bottomCenter,
                  child: AnimatedBuilder(
                    animation: _curve,
                    builder: (context, _) {
                      final t = _curve.value.clamp(0.0, 1.0);
                      final width = lerpDouble(
                        widget.pillSize.width,
                        targetWidth,
                        t,
                      )!;
                      final radius = lerpDouble(
                        widget.pillSize.height / 2,
                        24,
                        t,
                      )!;
                      return SizedBox(
                        key: const ValueKey('activity-panel-frame'),
                        width: width,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxHeight),
                          child: Semantics(
                            container: true,
                            explicitChildNodes: true,
                            label: strings.liveActivityTitle,
                            child: Material(
                              key: const ValueKey('activity-panel'),
                              color: colors.surface,
                              elevation: 14,
                              shadowColor: Colors.black.withValues(alpha: 0.5),
                              clipBehavior: Clip.antiAlias,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(radius),
                                side: BorderSide(
                                  color: colors.divider,
                                  width: 0.8,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Flexible(
                                    child: ClipRect(
                                      child: SizeTransition(
                                        sizeFactor: _curve,
                                        alignment: Alignment.bottomCenter,
                                        child: Opacity(
                                          opacity: Curves.easeIn.transform(t),
                                          child:
                                              NotificationListener<
                                                ScrollNotification
                                              >(
                                                onNotification: _onScroll,
                                                child: SingleChildScrollView(
                                                  key: _scrollKey,
                                                  controller: _scroll,
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                        16,
                                                        4,
                                                        16,
                                                        8,
                                                      ),
                                                  child: ActivityPanelBody(
                                                    snapshot: snapshot,
                                                    actions: actions,
                                                    now: now,
                                                    nowKey: _nowKey,
                                                  ),
                                                ),
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onVerticalDragUpdate: (d) {
                                      if (d.delta.dy > 0) {
                                        _dragDown += d.delta.dy;
                                      }
                                    },
                                    onVerticalDragEnd: _dragEnd,
                                    child: Semantics(
                                      button: true,
                                      label: model.semanticsLabel,
                                      hint: strings.liveHideActivity,
                                      onTap: _close,
                                      liveRegion: true,
                                      excludeSemantics: true,
                                      child: InkWell(
                                        key: const ValueKey(
                                          'activity-panel-header',
                                        ),
                                        onTap: _close,
                                        child: ActivityPillRow(
                                          model: model,
                                          now: now,
                                          expanded: true,
                                          fill: true,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Ruta modal ligera: velo casi transparente, cierre al tocar fuera, con el
/// botón atrás o deslizando hacia abajo. Vive en el overlay del navegador, por
/// encima del compositor, pero el panel se ancla a la pastilla (que está POR
/// ENCIMA del compositor), así que nunca lo tapa.
class ActivityPanelRoute extends PopupRoute<void> {
  ActivityPanelRoute({
    required this.pageBuilder,
    required this.reduceMotion,
    required this.dismissLabel,
  });

  final Widget Function(BuildContext context, Animation<double> animation)
  pageBuilder;
  final bool reduceMotion;
  final String dismissLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.14);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => dismissLabel;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => pageBuilder(context, animation);
}

/// La pastilla de actividad del chat + el panel que sale de ella.
///
/// Una sola pastilla, un solo hueco de layout y un solo `ActivityTicker`: el
/// cronómetro, el porcentaje de compactación y el resto del texto salen del
/// mismo reloj, y no existen otras pastillas con las que solaparse.
class ActivityPillHost extends StatefulWidget {
  const ActivityPillHost({
    required this.snapshot,
    this.actions = ActivityPanelActions.none,
    this.clock,
    this.revealAfter = const Duration(seconds: 2),
    this.suspended = false,
    super.key,
  });

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;
  final DateTime Function()? clock;
  final Duration revealAfter;

  /// Otra superficie flotante (la paleta de comandos) ocupa ahora el hueco
  /// sobre el compositor: la pastilla conserva su sitio pero no se pinta ni
  /// recibe toques, para no solaparse con ella.
  final bool suspended;

  @override
  State<ActivityPillHost> createState() => _ActivityPillHostState();
}

class _ActivityPillHostState extends State<ActivityPillHost> {
  final LayerLink _link = LayerLink();
  final GlobalKey _pillKey = GlobalKey();
  late final ValueNotifier<ActivityPanelState> _live = ValueNotifier(
    ActivityPanelState(widget.snapshot, widget.actions),
  );
  bool _open = false;
  ActivityPanelRoute? _route;

  @override
  void didUpdateWidget(ActivityPillHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot ||
        !identical(oldWidget.actions, widget.actions)) {
      // Los oyentes del panel viven en otro subárbol: se les avisa tras el frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _live.value = ActivityPanelState(widget.snapshot, widget.actions);
        }
      });
    }
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = route.navigator;
        if (navigator != null && navigator.mounted && route.isActive) {
          navigator.removeRoute(route);
        }
      });
    }
    _live.dispose();
    super.dispose();
  }

  void _openPanel() {
    if (_open) return;
    final box = _pillKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final size = box.size;
    final navigator = Navigator.of(context);
    final strings = Strings.of(context);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _live.value = ActivityPanelState(widget.snapshot, widget.actions);
    final route = ActivityPanelRoute(
      reduceMotion: reduce,
      dismissLabel: strings.liveHideActivity,
      pageBuilder: (routeContext, animation) => ActivityPanelSurface(
        animation: animation,
        link: _link,
        pillSize: size,
        state: _live,
        clock: widget.clock,
        onClose: () {
          if (routeContext.mounted) Navigator.of(routeContext).maybePop();
        },
      ),
    );
    _route = route;
    setState(() => _open = true);
    unawaited(
      navigator.push<void>(route).whenComplete(() {
        _route = null;
        if (mounted) setState(() => _open = false);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    return ActivityTicker(
      active: widget.snapshot.isLive,
      clock: widget.clock,
      builder: (context, now) {
        final model = buildActivityPillModel(
          widget.snapshot,
          strings,
          now: now,
          languageCode: lang,
          revealAfter: widget.revealAfter,
        );
        if (model == null) {
          return const SizedBox.shrink(key: ValueKey('activity-pill-idle'));
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: CompositedTransformTarget(
              link: _link,
              child: ExcludeSemantics(
                excluding: _open || widget.suspended,
                child: Opacity(
                  opacity: _open || widget.suspended ? 0 : 1,
                  child: IgnorePointer(
                    ignoring: _open || widget.suspended,
                    child: KeyedSubtree(
                      key: _pillKey,
                      child: ActivityPill(
                        model: model,
                        now: now,
                        onTap: _openPanel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
