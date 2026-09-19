// Splash animado al abrir la app: el muñequito Hermes entra con escala+fade, la
// marca "HERMES / console" se revela y tres barras respiran de forma escalonada.
// Tras ~3.4 s llama a [onDone]. Es una "intro" ligera (sin vídeo).
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import '../widgets/animated_hermes_logo.dart';
import '../../l10n/app_localizations.dart';

class SplashScreen extends StatefulWidget {
  final VoidCallback onDone;
  final bool ready;
  final ValueListenable<double>? progress;

  const SplashScreen({
    required this.onDone,
    this.ready = true,
    this.progress,
    super.key,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _pop; // escala del muñequito
  late final Animation<double> _fade; // opacidad general
  late final Animation<double> _word; // revelado de la marca
  late final Animation<double> _loaderReveal;
  bool _leaving = false;
  bool _minimumDurationElapsed = false;
  Timer? _minimumDurationTimer;
  Timer? _leaveTimer;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    );
    _pop = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    _fade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.42, curve: Curves.easeOutCubic),
    );
    _word = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.28, 0.82, curve: Curves.easeOutCubic),
    );
    _loaderReveal = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.64, 1, curve: Curves.easeOutCubic),
    );
    // El primer frame de una apertura fría incluye la inicialización del
    // engine, plugins y decodificación de la marca. Si los controladores
    // arrancan en initState, su reloj avanza durante ese trabajo y la intro
    // aparece ya a mitad de movimiento. Comenzar tras pintar el primer frame
    // conserva la trayectoria completa y evita el salto perceptible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.forward();
      _minimumDurationTimer = Timer(const Duration(milliseconds: 3000), () {
        if (!mounted) return;
        _minimumDurationElapsed = true;
        _leaveIfReady();
      });
    });
  }

  @override
  void didUpdateWidget(covariant SplashScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.ready && widget.ready) _leaveIfReady();
  }

  void _leaveIfReady() {
    if (!_minimumDurationElapsed || !widget.ready || _leaving || !mounted) {
      return;
    }
    setState(() => _leaving = true);
    _leaveTimer = Timer(const Duration(milliseconds: 460), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _minimumDurationTimer?.cancel();
    _leaveTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final brandColor =
        ThemeContrast.meets(colors.accent, colors.background, minimum: 3)
        ? colors.accent
        : colors.accentText;
    return Scaffold(
      backgroundColor: colors.background,
      // El fondo permanece opaco durante la salida. Desvanecer el Scaffold
      // entero revelaba la ventana nativa negra cuando Android estaba en modo
      // oscuro aunque el perfil de Hermes fuera claro.
      body: AnimatedSlide(
        offset: _leaving ? const Offset(0, -0.018) : Offset.zero,
        duration: const Duration(milliseconds: 460),
        curve: Curves.easeInOutCubic,
        child: AnimatedScale(
          scale: _leaving ? 0.985 : 1,
          duration: const Duration(milliseconds: 460),
          curve: Curves.easeInOutCubic,
          child: AnimatedOpacity(
            key: const Key('splash-content-opacity'),
            opacity: _leaving ? 0 : 1,
            duration: const Duration(milliseconds: 460),
            curve: Curves.easeInOutCubic,
            child: Center(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: _fade.value,
                        child: Transform.translate(
                          offset: Offset(0, (1 - _pop.value) * 18),
                          child: Transform.scale(
                            scale: 0.86 + _pop.value * 0.14,
                            // Logo grande y nítido (sin halo iluminado), con la
                            // esfera exterior girando alrededor.
                            child: AnimatedHermesLogo(
                              size: 200,
                              orbit: true,
                              glow: false,
                              color: brandColor,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Opacity(
                        opacity: _word.value,
                        child: Transform.translate(
                          offset: Offset(0, (1 - _word.value) * 12),
                          child: Column(
                            children: [
                              Text(
                                'HERMES',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 12 - 4 * _word.value,
                                  fontSize: 26,
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'console',
                                style: TextStyle(
                                  letterSpacing: 9 - 3 * _word.value,
                                  fontSize: 12,
                                  color: brandColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                      Opacity(
                        opacity: _loaderReveal.value,
                        child: Transform.translate(
                          offset: Offset(0, (1 - _loaderReveal.value) * 6),
                          child: _StartupProgressBar(
                            progress: widget.progress,
                            intro: _c,
                            color: brandColor,
                            reduceMotion:
                                MediaQuery.maybeDisableAnimationsOf(context) ??
                                false,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Progreso real del arranque. Con Home configurado observa hitos publicados
/// por la raíz; durante onboarding deriva el avance de la propia introducción.
class _StartupProgressBar extends StatelessWidget {
  const _StartupProgressBar({
    required this.progress,
    required this.intro,
    required this.color,
    required this.reduceMotion,
  });

  final ValueListenable<double>? progress;
  final Animation<double> intro;
  final Color color;
  final bool reduceMotion;

  Widget _bar(BuildContext context, double rawProgress) {
    final value = rawProgress.clamp(0.0, 1.0);
    final percent = (value * 100).round();
    final colors = Theme.of(context).hermes;
    return Semantics(
      label: Localizations.of<Strings>(context, Strings)?.splashLoadingProgress ?? 'Progreso de carga',
      value: '$percent%',
      child: SizedBox(
        key: const ValueKey('splash-progress-bar'),
        width: 168,
        height: 18,
        child: Row(
          children: [
            SizedBox(
              width: 120,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: value),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (context, animatedValue, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    key: const ValueKey('splash-progress-track'),
                    height: 3,
                    color: colors.divider.withValues(alpha: 0.48),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: animatedValue.clamp(0.0, 1.0),
                      child: Container(
                        key: const ValueKey('splash-progress-fill'),
                        color: color,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              key: const ValueKey('splash-progress-percent-slot'),
              width: 40,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$percent%',
                  key: const ValueKey('splash-progress-percent'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 10.5,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final external = progress;
    if (external != null) {
      return ValueListenableBuilder<double>(
        valueListenable: external,
        builder: (context, value, _) => _bar(context, value),
      );
    }
    return AnimatedBuilder(
      animation: intro,
      builder: (context, _) => _bar(
        context,
        0.08 + Curves.easeOutCubic.transform(intro.value) * 0.92,
      ),
    );
  }
}
