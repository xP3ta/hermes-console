import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Pill ambiente del turno principal: «sigue trabajando, y llevo esto».
///
/// Cierra la diferencia de *sensación* con Desktop. Allí un turno ocupado nunca
/// está mudo: `ResponseLoadingIndicator` y `TurnActivityIndicator`
/// (`components/assistant-ui/thread/status.tsx`) pintan una fila de estado con
/// un punto latiendo, el nombre de la espera y —la pieza que Console no
/// tenía— un **cronómetro vivo** (`ActivityTimerText` sobre
/// `useElapsedSeconds`, `components/chat/activity-timer.ts`), que sigue
/// contando en los huecos en los que el modelo trabaja sin emitir texto. Esa
/// cifra subiendo es lo que distingue «sigue en marcha» de «se ha colgado».
///
/// Console ya mostraba una palabra de estado rotatoria (`ThinkingTraceCard`),
/// pero sin ninguna señal temporal: una llamada a herramienta de 40 s se veía
/// igual que una de 2 s, y ahí es donde aparecía la duda.
///
/// Decisiones propias de aquí, no copiadas:
///
///  * Es una pastilla flotante (mismo lenguaje que `SubagentActivityCard`), no
///    una fila del transcript, porque en móvil el transcript se va hacia arriba
///    mientras el turno trabaja y la señal tiene que quedarse a la vista.
///  * Desktop cuenta los huecos desde la última señal visible; aquí se cuenta
///    el turno **completo**. En móvil no hay borde-arco del composer ni fila
///    por herramienta que acumulen la espera, así que el total es el número que
///    de verdad responde «¿cuánto llevas?».
///  * Pasado [reassureAfter] la etiqueta cambia de la palabra de estado a una
///    frase explícita de «te respondo al terminar». La duda no llega en el
///    segundo 3, llega cuando la espera ya se hizo larga.
class TurnActivityPill extends StatefulWidget {
  /// El turno trabaja de verdad y todavía no hay texto visible que lo cuente.
  final bool active;

  /// Origen del cronómetro: el momento en que arrancó el turno.
  final DateTime? startedAt;

  /// Palabra de estado del pipeline (conectando / pensando / ejecutando), o
  /// `null` para omitirla y dejar solo el spinner + cronómetro — el llamador
  /// la calla cuando esa misma palabra ya está a la vista en otro sitio más
  /// específico (la `ThinkingTraceCard` en vivo), para no repetirla. El
  /// cronómetro nunca se omite: es la única señal de este widget que no
  /// existe en ningún otro sitio. Pasado [reassureAfter] esto se ignora y
  /// siempre se muestra la frase de tranquilidad, aunque el llamador haya
  /// pedido silencio — una espera ya larga merece su propio aviso.
  final String? statusLabel;

  /// Nada antes de esto: un turno rápido no debe hacer parpadear la pastilla.
  /// Desktop usa `TURN_QUIET_S = 2` para el mismo antiparpadeo; aquí se sube un
  /// poco porque la pastilla es más pesada visualmente que su fila de texto.
  final Duration revealAfter;

  /// A partir de aquí la etiqueta pasa a la frase de tranquilidad.
  final Duration reassureAfter;

  /// Reloj inyectable (tests). Por defecto [DateTime.now].
  final DateTime Function()? clock;

  const TurnActivityPill({
    required this.active,
    required this.startedAt,
    required this.statusLabel,
    this.revealAfter = const Duration(seconds: 3),
    this.reassureAfter = const Duration(seconds: 20),
    this.clock,
    super.key,
  });

  @override
  State<TurnActivityPill> createState() => _TurnActivityPillState();
}

class _TurnActivityPillState extends State<TurnActivityPill>
    with WidgetsBindingObserver {
  Timer? _ticker;
  bool _viewEnabled = false;
  bool _foreground = true;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewEnabled = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTicker();
    if (_foreground && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(TurnActivityPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  /// El cronómetro solo late mientras hay turno: un `Timer.periodic` corriendo
  /// en reposo repintaría la pantalla de chat una vez por segundo para siempre.
  void _syncTicker() {
    final shouldTick =
        widget.active &&
        widget.startedAt != null &&
        _foreground &&
        _viewEnabled;
    if (shouldTick == (_ticker != null)) return;
    if (!shouldTick) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Duration? get _elapsed {
    final startedAt = widget.startedAt;
    if (!widget.active || startedAt == null) return null;
    final elapsed = _now.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _elapsed;
    if (elapsed == null || elapsed < widget.revealAfter) {
      return const SizedBox.shrink(key: ValueKey('turn-activity-idle'));
    }
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final label = elapsed >= widget.reassureAfter
        ? strings.chaTurnStillWorking
        : widget.statusLabel;
    final timer = formatTurnElapsed(elapsed);

    return Semantics(
      liveRegion: true,
      label: label == null ? timer : '$label · $timer',
      child: Material(
        key: const ValueKey('turn-activity-pill'),
        color: colors.surface,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 16, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: 8),
              if (label != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // `tabular-nums` en Desktop: sin anchura fija de dígito el
              // contador baila de ancho en cada tic y arrastra la etiqueta.
              Text(
                timer,
                key: const ValueKey('turn-activity-elapsed'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `m:ss`, y `h:mm:ss` una vez pasada la hora. Mismo escalón que
/// `formatElapsed` en Desktop, que sube de `12s` a `1:23` en el minuto.
String formatTurnElapsed(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return '$minutes:$seconds';
  return '${minutes ~/ 60}:'
      '${(minutes % 60).toString().padLeft(2, '0')}:'
      '$seconds';
}
