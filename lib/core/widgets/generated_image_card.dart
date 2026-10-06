import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/media_dimensions.dart';
import '../theme/app_theme.dart';
import 'attachment_card.dart';
import 'stacked_image_cards.dart';

/// Estado de una imagen generada dentro de la burbuja del asistente (spec 030).
enum GeneratedImageStatus {
  /// Descarga en curso.
  downloading,

  /// Archivo local listo: se muestra la miniatura.
  ready,

  /// Descarga fallida (red/token) — reintentable manualmente.
  error,

  /// El servidor respondió que ya no existe (caché rotada) — sin reintento.
  gone,

  /// El bridge no soporta la descarga (versión < 1.12.0 o sin bridge):
  /// pista de degradación, el texto del mensaje queda intacto (US2).
  unsupported,
}

/// Tarjeta de imagen generada por el agente: miniatura + visor a pantalla
/// completa, o el estado que toque (descargando / error con Reintentar /
/// no disponible / pista de bridge desactualizado). Sin reintentos
/// automáticos: el único disparador de red tras un fallo es el usuario.
class GeneratedImageCard extends StatelessWidget {
  final GeneratedImageStatus status;

  /// Archivo local descargado (requerido cuando [status] es [GeneratedImageStatus.ready]).
  final File? file;

  /// Reintentar la descarga (solo estado [GeneratedImageStatus.error]).
  final VoidCallback? onRetry;

  /// Pixel size when the caller already knows it; otherwise the header of
  /// [file] is probed (memoized), so the box is final on the first layout.
  final Size? intrinsicSize;

  const GeneratedImageCard({
    required this.status,
    this.file,
    this.onRetry,
    this.intrinsicSize,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final readyFile = file;
    if (status == GeneratedImageStatus.ready && readyFile != null) {
      return GeneratedImageFrame(
        intrinsicSize:
            intrinsicSize ?? MediaDimensionsCache.ofFileSync(readyFile),
        builder: (box) => _thumbnail(context, s, readyFile, box),
      );
    }
    final child = switch (status) {
      GeneratedImageStatus.ready => const SizedBox.shrink(),
      GeneratedImageStatus.downloading => _statusCard(
        context,
        colors,
        leading: SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: colors.accent,
          ),
        ),
        text: s.genImgDownloading,
      ),
      GeneratedImageStatus.error => _statusCard(
        context,
        colors,
        leading: Icon(
          Icons.broken_image_outlined,
          size: 17,
          color: colors.warning,
        ),
        text: s.genImgError,
        trailing: TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          child: Text(
            s.commonRetry,
            style: TextStyle(fontSize: 12, color: colors.accentText),
          ),
        ),
      ),
      GeneratedImageStatus.gone => _statusCard(
        context,
        colors,
        leading: Icon(
          Icons.hide_image_outlined,
          size: 17,
          color: colors.textSecondary,
        ),
        text: s.genImgGone,
      ),
      GeneratedImageStatus.unsupported => _statusCard(
        context,
        colors,
        leading: Icon(
          Icons.image_outlined,
          size: 17,
          color: colors.textSecondary,
        ),
        text: s.genImgHint,
      ),
    };
    // Inside a stack of images the card is the stack's top card: centred.
    if (ImageStackScope.maybeOf(context) != null) return Center(child: child);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }

  Widget _thumbnail(BuildContext context, Strings s, File f, Size box) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final radius = theme.hermesComponents.profile.shape.cardRadius;
    final fade = MediaQuery.maybeDisableAnimationsOf(context) ?? false
        ? Duration.zero
        : const Duration(milliseconds: 150);
    // In a stack the card fills it (cover) and a tap opens the gallery of
    // the whole stack at this image.
    final stack = ImageStackScope.maybeOf(context);
    stack?.controller.report(stack.index, f);
    return Semantics(
      label: s.genImgSemanticLabel,
      image: true,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => stack == null
            ? showImageViewer(context, f)
            : stack.controller.open(stack.index),
        child: Material(
          key: const ValueKey('generated-image-thumbnail'),
          color: colors.surfaceVariant.withValues(alpha: 0.28),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
          ),
          child: SizedBox.fromSize(
            size: box,
            child: ColoredBox(
              // Garantiza que toda la miniatura, incluidas zonas transparentes
              // del bitmap, sea una superficie táctil y no solo decorativa.
              color: Colors.transparent,
              child: Stack(
                children: [
                  Image(
                    // Decodifica a tamaño de miniatura (misma clave que la
                    // precarga): una imagen ya precargada pinta en el primer
                    // frame; si no, aparece con un fundido corto.
                    image: generatedImageThumbnailProvider(f),
                    fit: stack == null ? BoxFit.contain : BoxFit.cover,
                    width: box.width,
                    height: box.height,
                    frameBuilder: (_, child, frame, synchronous) => synchronous
                        ? child
                        : AnimatedOpacity(
                            opacity: frame == null ? 0 : 1,
                            duration: fade,
                            curve: Curves.easeOut,
                            child: child,
                          ),
                    errorBuilder: (ctx, _, _) => _statusCard(
                      ctx,
                      Theme.of(ctx).hermes,
                      leading: Icon(
                        Icons.broken_image_outlined,
                        size: 17,
                        color: Theme.of(ctx).hermes.warning,
                      ),
                      text: Strings.of(ctx).genImgError,
                    ),
                  ),
                  if (stack == null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IgnorePointer(
                        child: Container(
                          key: const ValueKey('generated-image-expand'),
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.58),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.open_in_full_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusCard(
    BuildContext context,
    HermesThemeColors colors, {
    required Widget leading,
    required String text,
    Widget? trailing,
  }) {
    final radius = Theme.of(context).hermesComponents.profile.shape.cardRadius;
    return Container(
      key: const ValueKey('generated-image-status'),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: EdgeInsets.fromLTRB(
        10,
        trailing == null ? 8 : 4,
        8,
        trailing == null ? 8 : 4,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: colors.divider.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 8),
          Flexible(
            child: Padding(
              padding: EdgeInsets.only(
                top: trailing == null ? 0 : 6,
                bottom: trailing == null ? 0 : 6,
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Outer layout shared by a generated image's skeleton and its thumbnail, so
/// the row has the same height before and after the bytes arrive.
class GeneratedImageFrame extends StatelessWidget {
  final Size? intrinsicSize;
  final Widget Function(Size box) builder;

  const GeneratedImageFrame({
    super.key,
    required this.intrinsicSize,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    // The top card of a stack of images: fill the card.
    if (ImageStackScope.maybeOf(context) != null) {
      return LayoutBuilder(
        builder: (context, constraints) => builder(constraints.biggest),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) => builder(
            generatedImageBoxSize(
              intrinsicSize,
              maxWidth: constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : generatedImageMaxExtent,
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder of a generated image whose bytes are not here yet: the final
/// box, no file name. It shimmers only while a download really runs, and is
/// static under reduced motion.
class GeneratedImageSkeleton extends StatefulWidget {
  final Size? intrinsicSize;
  final bool loading;

  /// Download progress in 0..1 when the total is known.
  final double? progress;

  const GeneratedImageSkeleton({
    super.key,
    required this.intrinsicSize,
    required this.loading,
    this.progress,
  });

  @override
  State<GeneratedImageSkeleton> createState() => _GeneratedImageSkeletonState();
}

class _GeneratedImageSkeletonState extends State<GeneratedImageSkeleton>
    with SingleTickerProviderStateMixin {
  AnimationController? _shimmer;

  bool _animate(BuildContext context) =>
      widget.loading &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false) &&
      TickerMode.valuesOf(context).enabled;

  void _syncShimmer(bool animate) {
    if (animate) {
      final controller = _shimmer ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      );
      if (!controller.isAnimating) controller.repeat();
    } else {
      _shimmer?.stop();
    }
  }

  @override
  void dispose() {
    _shimmer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final radius = theme.hermesComponents.profile.shape.cardRadius;
    final animate = _animate(context);
    _syncShimmer(animate);
    final base = colors.surfaceVariant.withValues(alpha: 0.28);
    final highlight = colors.surfaceVariant.withValues(alpha: 0.55);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final progress = widget.progress;
    return GeneratedImageFrame(
      intrinsicSize: widget.intrinsicSize,
      builder: (box) => Container(
        key: const ValueKey('generated-image-skeleton'),
        width: box.width,
        height: box.height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: colors.divider.withValues(alpha: 0.45)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (animate && _shimmer != null)
              AnimatedBuilder(
                animation: _shimmer!,
                builder: (_, _) {
                  final t = _shimmer!.value * 2 - 0.5;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(-1 + t * 2, 0),
                        end: Alignment(t * 2, 0),
                        colors: [base, highlight, base],
                      ),
                    ),
                  );
                },
              ),
            if (widget.loading && (progress != null || !reduced))
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  color: colors.accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
