// Onboarding premium de primera ejecución: bienvenida animada e interactiva.
//
// PageView de 4 pasos con entrada animada por página (fade + slide + scale en
// paralaje), fondo con glow pulsante sutil del acento, indicador de progreso
// animado y botón final que marca el flag y entra a la app. Se muestra una
// sola vez (flag `onboarding_done` en prefs); siempre se puede saltar.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_hermes_logo.dart';
import '../widgets/hermes_ui.dart';
import 'onboarding/welcome_mode_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final ConnectionManager connManager;
  final VoidCallback onDone;
  const OnboardingScreen({
    required this.connManager,
    required this.onDone,
    super.key,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final _pager = PageController();
  late final AnimationController _glow;
  double _page = 0;

  static const _kPages = <_OnbPage>[
    _OnbPage(kind: _Illu.brand, title: '', subtitle: ''),
    _OnbPage(kind: _Illu.control, title: '', subtitle: ''),
    _OnbPage(kind: _Illu.profiles, title: '', subtitle: ''),
    _OnbPage(kind: _Illu.secure, title: '', subtitle: ''),
  ];

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
    _pager.addListener(() {
      setState(() => _page = _pager.page ?? 0);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _glow
        ..stop()
        ..value = 0.5;
    } else if (!_glow.isAnimating) {
      _glow.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _glow.dispose();
    _pager.dispose();
    super.dispose();
  }

  static const _pageCount = 4;
  bool get _isLast => _page.round() >= _pageCount - 1;

  void _next() {
    if (_isLast) {
      _openModeChoice();
    } else {
      _pager.nextPage(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  /// Tras la intro, el usuario elige modo de uso (agente local / cliente
  /// remoto). Al llegar aquí la intro YA se da por vista: persistimos el flag
  /// inmediatamente para que NO vuelva a mostrarse aunque el usuario abandone
  /// la configuración sin llegar a crear una conexión (p. ej. el agente local
  /// aún no arranca). Bajo las rutas empujadas, `home` ya es HomeDashboard, así
  /// que al retroceder se cae en el panel —no en la intro—.
  void _openModeChoice() {
    final nav = Navigator.of(context);
    widget.onDone(); // persiste onboarding_done + swap a HomeDashboard en main
    nav.push(
      MaterialPageRoute(
        builder: (_) => WelcomeModeScreen(
          connManager: widget.connManager,
          onDone: () {
            nav.popUntil((r) => r.isFirst); // descarta rutas del onboarding
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    const pages = _kPages;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          // Glow pulsante de fondo, sigue al acento del tema activo.
          AnimatedBuilder(
            animation: _glow,
            builder: (_, _) =>
                _GlowBackground(t: _glow.value, accent: colors.accent),
          ),
          SafeArea(
            child: Column(
              children: [
                // Saltar.
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
                    child: TextButton(
                      onPressed: widget.onDone,
                      child: Text(
                        Strings.of(context).obSkip,
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pager,
                    itemCount: pages.length,
                    itemBuilder: (_, i) {
                      // Paralaje: desplazamiento relativo de esta página.
                      final delta = (i - _page);
                      return _OnbPageView(
                        page: pages[i],
                        delta: delta,
                        glow: _glow,
                      );
                    },
                  ),
                ),
                _Dots(count: pages.length, page: _page, colors: colors),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                  child: SizedBox(
                    width: double.infinity,
                    child: HermesPrimaryButton(
                      label: _isLast
                          ? Strings.of(context).obStart
                          : Strings.of(context).commonNext,
                      icon: _isLast
                          ? Icons.arrow_forward_rounded
                          : Icons.chevron_right_rounded,
                      onTap: _next,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _Illu { brand, control, profiles, secure }

/// Título localizado de una página de onboarding (brand = nombre propio).
String _obTitle(Strings s, _Illu k) => switch (k) {
  _Illu.brand => 'Hermes Console',
  _Illu.control => s.obTitleControl,
  _Illu.profiles => s.obTitleProfiles,
  _Illu.secure => s.obTitleSecure,
};

String _obSubtitle(Strings s, _Illu k) => switch (k) {
  _Illu.brand => s.obSubtitleBrand,
  _Illu.control => s.obSubtitleControl,
  _Illu.profiles => s.obSubtitleProfiles,
  _Illu.secure => s.obSubtitleSecure,
};

class _OnbPage {
  final _Illu kind;
  final String title;
  final String subtitle;
  const _OnbPage({
    required this.kind,
    required this.title,
    required this.subtitle,
  });
}

/// Contenido de una página con entrada animada (fade + slide + scale) según su
/// distancia a la página activa (paralaje).
class _OnbPageView extends StatelessWidget {
  final _OnbPage page;
  final double delta; // 0 = activa; ±1 = adyacente
  final AnimationController glow;
  const _OnbPageView({
    required this.page,
    required this.delta,
    required this.glow,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final d = delta.clamp(-1.0, 1.0);
    final opacity = (1 - d.abs()).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Ilustración con paralaje y leve escala.
              Transform.translate(
                offset: Offset(-d * 60, 0),
                child: Transform.scale(
                  scale: 0.85 + 0.15 * opacity,
                  child: Opacity(
                    opacity: opacity,
                    child: _Illustration(kind: page.kind, glow: glow),
                  ),
                ),
              ),
              const SizedBox(height: 44),
              Transform.translate(
                offset: Offset(0, 24 * (1 - opacity)),
                child: Opacity(
                  opacity: opacity,
                  child: Column(
                    children: [
                      Text(
                        _obTitle(Strings.of(context), page.kind),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _obSubtitle(Strings.of(context), page.kind),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ilustraciones por paso. La de marca dibuja el monograma H (igual que el
/// icono de la app); las demás son clústeres de iconos temáticos.
class _Illustration extends StatelessWidget {
  final _Illu kind;
  final AnimationController glow;
  const _Illustration({required this.kind, required this.glow});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return AnimatedBuilder(
      animation: glow,
      builder: (_, _) {
        final pulse = 0.5 + 0.5 * math.sin(glow.value * math.pi * 2);
        // La marca muestra la mascota Hermes (el muñequito ámbar animado), no el
        // logo H+alas: es la identidad viva de la app. Va sobre un halo con glow
        // pulsante del acento; el resto de pasos van en tarjeta con iconos.
        if (kind == _Illu.brand) {
          return Container(
            width: 248,
            height: 248,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.18 + 0.16 * pulse),
                  blurRadius: 48,
                  spreadRadius: 4,
                ),
              ],
            ),
            // Más grande y con el anillo orbitando (efecto loader) en la
            // bienvenida, que es la primera impresión.
            child: const AnimatedHermesLogo(size: 196, orbit: true),
          );
        }
        return Container(
          width: 168,
          height: 168,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
            boxShadow: [
              BoxShadow(
                color: colors.accent.withValues(alpha: 0.12 + 0.12 * pulse),
                blurRadius: 36,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Center(child: _inner(colors)),
        );
      },
    );
  }

  Widget _inner(HermesThemeColors colors) {
    switch (kind) {
      case _Illu.brand:
        return const SizedBox.shrink(); // gestionado arriba
      case _Illu.control:
        return _IconCluster(
          colors: colors,
          icons: const [
            Icons.chat_bubble_outline,
            Icons.memory_outlined,
            Icons.extension_outlined,
            Icons.schedule_outlined,
          ],
        );
      case _Illu.profiles:
        return _IconCluster(
          colors: colors,
          icons: const [
            Icons.account_tree_outlined,
            Icons.auto_awesome_outlined,
            Icons.tune_rounded,
            Icons.badge_outlined,
          ],
        );
      case _Illu.secure:
        return Icon(Icons.shield_outlined, size: 76, color: colors.accent);
    }
  }
}

class _IconCluster extends StatelessWidget {
  final HermesThemeColors colors;
  final List<IconData> icons;
  const _IconCluster({required this.colors, required this.icons});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      padding: const EdgeInsets.all(28),
      children: [
        for (final ic in icons) Icon(ic, size: 34, color: colors.accentHover),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final double page;
  final HermesThemeColors colors;
  const _Dots({required this.count, required this.page, required this.colors});

  @override
  Widget build(BuildContext context) {
    final active = page.round();
    // Los puntos son solo decorativos: TalkBack anuncia la posición en el
    // flujo con un label ("Paso N de M") que se refresca al cambiar de página.
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Paso ${active + 1} de $count',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (int i = 0; i < count; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: i == active ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i == active ? colors.accent : colors.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Fondo con dos glows radiales suaves que laten y se desplazan ligeramente.
class _GlowBackground extends StatelessWidget {
  final double t; // 0..1
  final Color accent;
  const _GlowBackground({required this.t, required this.accent});

  @override
  Widget build(BuildContext context) {
    final dy = math.sin(t * math.pi * 2);
    return Stack(
      children: [
        Positioned(
          top: 80 + dy * 30,
          left: -120,
          child: _blob(accent.withValues(alpha: 0.10), 320),
        ),
        Positioned(
          bottom: 120 - dy * 30,
          right: -140,
          child: _blob(accent.withValues(alpha: 0.08), 360),
        ),
      ],
    );
  }

  Widget _blob(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}
