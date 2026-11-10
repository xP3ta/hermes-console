import 'package:flutter/material.dart';

import '../services/motion_prefs.dart';
import '../theme/app_theme.dart';

/// Cursor opcional bajo la respuesta que está llegando (línea, bloque o guion
/// bajo). Es un widget aparte, hermano del texto: nunca se inyecta en él ni
/// lo retrasa, así que el texto real aparece igual con el cursor o sin él.
///
/// Con el ajuste apagado no dibuja nada. Con «reducir movimiento» se queda
/// fijo, sin parpadeo.
class HermesStreamingCursor extends StatelessWidget {
  const HermesStreamingCursor({this.prefs, super.key});

  /// Solo para pruebas; por defecto, [MotionPrefs.shared].
  final MotionPrefs? prefs;

  @override
  Widget build(BuildContext context) {
    final store = prefs ?? MotionPrefs.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final style = store.cursor;
        if (style == StreamingCursorStyle.off) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: ExcludeSemantics(
            child: _BlinkingCursor(
              key: ValueKey('streaming-cursor-${style.name}'),
              style: style,
            ),
          ),
        );
      },
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor({required this.style, super.key});

  final StreamingCursorStyle style;

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final (double width, double height) = switch (widget.style) {
      StreamingCursorStyle.block => (9.0, 16.0),
      StreamingCursorStyle.underscore => (10.0, 2.0),
      _ => (2.0, 16.0),
    };
    final bar = SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.textPrimary,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        height: 16,
        child: Align(
          alignment: AlignmentDirectional.bottomStart,
          child: FadeTransition(
            opacity: CurvedAnimation(
              parent: _controller,
              curve: Curves.easeInOut,
            ),
            child: bar,
          ),
        ),
      ),
    );
  }
}
