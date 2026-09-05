// Scroll machinery: the streaming viewport lock and physics that keep the
// live answer pinned, plus the scroll-to-bottom affordances.
part of 'chat_screen.dart';

class _ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ScrollToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) => _ChatScrollButton(
    onTap: onTap,
    label: Strings.of(context).chaScrollToBottom,
    icon: Icons.keyboard_arrow_down,
    iconSize: 20,
  );
}

class _ChatScrollButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  final IconData icon;
  final double iconSize;

  const _ChatScrollButton({
    required this.onTap,
    required this.label,
    required this.icon,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Nombre y rol para TalkBack + target táctil de 48dp; el círculo visual se
    // mantiene discreto para no tapar la respuesta.
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.55),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(icon, size: iconSize, color: colors.accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ancla visual de un mensaje del asistente. Al ser un RenderObject ligero no
/// mueve ni reutiliza el árbol Markdown cuando cambia el último turno.
@visibleForTesting
class ChatAnswerAnchor extends SingleChildRenderObjectWidget {
  final ValueChanged<RenderBox> onLayout;
  final ValueChanged<RenderBox>? onDetach;

  const ChatAnswerAnchor({
    super.key,
    required this.onLayout,
    this.onDetach,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      ChatAnswerAnchorRenderBox(onLayout, onDetach);

  @override
  void updateRenderObject(
    BuildContext context,
    ChatAnswerAnchorRenderBox renderObject,
  ) {
    renderObject
      ..onLayout = onLayout
      ..onDetach = onDetach;
  }
}

@visibleForTesting
class ChatAnswerAnchorRenderBox extends RenderProxyBox {
  ValueChanged<RenderBox> onLayout;
  ValueChanged<RenderBox>? onDetach;
  double? laidOutHeight;

  ChatAnswerAnchorRenderBox(this.onLayout, this.onDetach);

  @override
  void performLayout() {
    super.performLayout();
    laidOutHeight = size.height;
    onLayout(this);
  }

  @override
  void detach() {
    onDetach?.call(this);
    super.detach();
  }
}

/// Detecta la intención de leer antes de que Flutter determine la dirección del
/// scroll. Es pública solo para cubrir la regresión con un widget test.
@visibleForTesting
class ChatScrollInteractionGuard extends StatelessWidget {
  final Widget child;
  final PointerDownEventListener onPointerDown;
  final PointerMoveEventListener? onPointerMove;
  final PointerUpEventListener? onPointerUp;
  final PointerCancelEventListener? onPointerCancel;

  const ChatScrollInteractionGuard({
    super.key,
    required this.child,
    required this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onPointerCancel,
  });

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: onPointerDown,
    onPointerMove: onPointerMove,
    onPointerUp: onPointerUp,
    onPointerCancel: onPointerCancel,
    child: child,
  );
}

/// Mantiene el contenido visible anclado cuando el primer hijo de una lista
/// invertida aumenta de altura durante streaming.
///
/// Flutter conserva por defecto `pixels`; en un chat `reverse:true`, sin
/// embargo, el contenido nuevo se inserta entre ese offset y el fondo. Sumar el
/// crecimiento real del asistente conserva la misma coordenada visual. La
/// corrección ocurre en `adjustPositionForNewDimensions`, antes de pintar y sin
/// sustituir la actividad de scroll activa.
class _ChatStreamingViewportPhysics extends ScrollPhysics {
  final _ChatStreamingViewportLock lock;

  const _ChatStreamingViewportPhysics({required this.lock, super.parent});

  @override
  _ChatStreamingViewportPhysics applyTo(ScrollPhysics? ancestor) {
    return _ChatStreamingViewportPhysics(
      lock: lock,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final inherited = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (!lock.enabled) {
      lock.clear();
      return inherited;
    }
    final anchorCorrection = lock.consumeAnchorVisualCorrection();
    if (anchorCorrection != null) {
      lock.clear();
      return (newPosition.pixels + anchorCorrection)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    final metricsDelta =
        newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    if (lock.consumeStructuralChange(metricsDelta)) {
      lock.clear();
      return (newPosition.pixels + metricsDelta)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    final reportedDelta = lock.take();
    if (lock.consumeReportedStructuralChange(reportedDelta)) {
      return (newPosition.pixels + reportedDelta)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    if (!reportedDelta.isFinite || reportedDelta.abs() < 0.01) {
      return inherited;
    }
    // Padding, separadores y redondeo del sliver pueden añadir unos pocos px
    // fuera del RenderBox medido. Solo usa el delta global cuando coincide de
    // forma ESTRECHA con el crecimiento reportado; una tolerancia amplia (64)
    // dejaba pasar el ruido de ESTIMACIÓN del sliver con historial
    // virtualizado (~36 px al insertar las filas del turno) y el viewport
    // derivaba hacia el fondo mientras el lector leía.
    final extentDelta =
        metricsDelta.isFinite &&
            (metricsDelta - reportedDelta).abs() <= 8 &&
            metricsDelta.sign == reportedDelta.sign
        ? metricsDelta
        : reportedDelta;
    final corrected = newPosition.pixels + extentDelta;
    return corrected
        .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
        .toDouble();
  }
}

class _ChatStreamingViewportLock {
  double _pendingExtentDelta = 0;
  bool _structuralChangePending = false;
  bool _reportedStructuralChangePending = false;
  double? _anchorVisualOffset;
  RenderBox? Function()? _anchorVisualLookup;
  bool enabled = false;

  void enable() => enabled = true;

  void disable() {
    enabled = false;
    _structuralChangePending = false;
    _reportedStructuralChangePending = false;
    _clearAnchorVisualChange();
    clear();
  }

  void expectStructuralChange() {
    if (!enabled) return;
    _structuralChangePending = true;
    _reportedStructuralChangePending = false;
    _clearAnchorVisualChange();
    clear();
  }

  void expectReportedStructuralChange() {
    if (!enabled) return;
    _structuralChangePending = false;
    _reportedStructuralChangePending = true;
    _clearAnchorVisualChange();
    clear();
  }

  bool expectAnchorVisualChange(
    RenderBox anchor,
    RenderBox? Function() lookup,
  ) {
    if (!enabled) return false;
    final offset = _visualOffsetInViewport(anchor);
    if (offset == null) return false;
    _structuralChangePending = false;
    _reportedStructuralChangePending = false;
    _anchorVisualOffset = offset;
    _anchorVisualLookup = lookup;
    clear();
    return true;
  }

  bool consumeStructuralChange(double metricsDelta) {
    if (!_structuralChangePending ||
        !metricsDelta.isFinite ||
        metricsDelta.abs() < 0.01) {
      return false;
    }
    _structuralChangePending = false;
    return true;
  }

  void expireStructuralChange() => _structuralChangePending = false;

  bool consumeReportedStructuralChange(double reportedDelta) {
    if (!_reportedStructuralChangePending) return false;
    _reportedStructuralChangePending = false;
    return reportedDelta.isFinite && reportedDelta.abs() >= 0.01;
  }

  void expireReportedStructuralChange() {
    _reportedStructuralChangePending = false;
  }

  double? consumeAnchorVisualCorrection() {
    final previous = _anchorVisualOffset;
    final lookup = _anchorVisualLookup;
    if (previous == null || lookup == null) return null;
    final next = _visualOffsetInViewport(lookup());
    if (next == null) return null;
    _clearAnchorVisualChange();
    final correction = previous - next;
    return correction.isFinite && correction.abs() >= 0.01 ? correction : 0;
  }

  void expireAnchorVisualChange() => _clearAnchorVisualChange();

  static double? _visualOffsetInViewport(RenderBox? anchor) {
    if (anchor == null || !anchor.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(anchor);
    if (viewport == null || !viewport.attached) return null;

    // `getTransformTo` no es seguro aquí: en una lista invertida pide el
    // `size` del hijo directo del sliver mientras el viewport aún está dentro
    // de `performLayout`. El ancla ya guardó su propia altura al terminar su
    // layout, así que reconstruimos la traslación sin leer otro RenderBox.
    var current = anchor as RenderObject;
    var innerOffset = Offset.zero;
    RenderBox? sliverChild;
    RenderSliverMultiBoxAdaptor? sliver;
    while (true) {
      final parent = current.parent;
      if (parent == null) break;
      if (parent is RenderSliverMultiBoxAdaptor && current is RenderBox) {
        sliver = parent;
        sliverChild = current;
        break;
      }
      final parentData = current.parentData;
      if (parentData is BoxParentData) {
        innerOffset += parentData.offset;
      }
      current = parent;
    }
    if (sliver == null || sliverChild == null) return null;
    final geometry = sliver.geometry;
    final layoutOffset = sliver.childScrollOffset(sliverChild);
    final anchorHeight = anchor is ChatAnswerAnchorRenderBox
        ? anchor.laidOutHeight
        : null;
    if (geometry == null || layoutOffset == null || anchorHeight == null) {
      return null;
    }
    final mainAxisPosition = layoutOffset - sliver.constraints.scrollOffset;
    final childPaintOffset = switch (sliver.constraints.axisDirection) {
      AxisDirection.down => mainAxisPosition,
      AxisDirection.up =>
        geometry.paintExtent - anchorHeight - mainAxisPosition,
      _ => null,
    };
    if (childPaintOffset == null) return null;
    final offset = MatrixUtils.transformPoint(
      sliver.getTransformTo(viewport),
      Offset(innerOffset.dx, childPaintOffset + innerOffset.dy),
    ).dy;
    return offset.isFinite ? offset : null;
  }

  void _clearAnchorVisualChange() {
    _anchorVisualOffset = null;
    _anchorVisualLookup = null;
  }

  void record(double delta) {
    if (delta.isFinite) {
      _pendingExtentDelta += delta;
    }
  }

  double take() {
    final delta = _pendingExtentDelta;
    _pendingExtentDelta = 0;
    return delta;
  }

  void clear() => _pendingExtentDelta = 0;
}

class _LiveAssistantExtentReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onExtentDelta;

  const _LiveAssistantExtentReporter({
    required this.onExtentDelta,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _LiveAssistantExtentRenderBox(onExtentDelta);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _LiveAssistantExtentRenderBox renderObject,
  ) {
    renderObject.onExtentDelta = onExtentDelta;
  }
}

class _LiveAssistantExtentRenderBox extends RenderProxyBox {
  ValueChanged<double> onExtentDelta;
  double? _previousExtent;

  _LiveAssistantExtentRenderBox(this.onExtentDelta);

  @override
  void performLayout() {
    super.performLayout();
    final previous = _previousExtent;
    final next = size.height;
    _previousExtent = next;
    // La primera altura TAMBIÉN es un delta: un turno que materializa su host
    // vivo con el lector arriba (seguimiento congelado o turno en segundo
    // plano) crece el extent desde cero y sin ese reporte el texto leído
    // derivaría. Con el lock inactivo el delta se descarta en el propio
    // ajuste del viewport, así que el seguimiento normal no nota el cambio.
    onExtentDelta(next - (previous ?? 0));
  }
}

/// Mide una fila recién insertada una sola vez.
///
/// A diferencia del reporter del asistente vivo, aquí la primera altura sí es
/// un delta: la fila no existía en el frame anterior. Se usa únicamente al
/// encadenar un turno mientras el lector conserva un ancla terminal.
class _SurfaceTurnInitialExtentReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onInitialExtent;

  const _SurfaceTurnInitialExtentReporter({
    required this.onInitialExtent,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SurfaceTurnInitialExtentRenderBox(onInitialExtent);

  @override
  void updateRenderObject(
    BuildContext context,
    _SurfaceTurnInitialExtentRenderBox renderObject,
  ) {
    renderObject.onInitialExtent = onInitialExtent;
  }
}

class _SurfaceTurnInitialExtentRenderBox extends RenderProxyBox {
  ValueChanged<double> onInitialExtent;
  bool _reported = false;

  _SurfaceTurnInitialExtentRenderBox(this.onInitialExtent);

  @override
  void performLayout() {
    super.performLayout();
    if (_reported) return;
    _reported = true;
    onInitialExtent(size.height);
  }
}

/// Alinea el principio de una respuesta con la parte superior del historial,
/// incluso cuando la respuesta es más alta que toda la pantalla.
@visibleForTesting
Future<void> scrollChatAnswerToStart(
  RenderObject targetObject,
  ScrollPosition position, {
  Duration duration = chatNavigationDuration,
}) async {
  final target = chatAnswerStartOffset(targetObject, position);
  if (target == null) return;
  if (duration == Duration.zero) {
    position.jumpTo(target);
    return;
  }
  await position.animateTo(
    target,
    duration: duration,
    curve: chatNavigationCurve,
  );
}

@visibleForTesting
double? chatAnswerStartOffset(
  RenderObject targetObject,
  ScrollPosition position,
) {
  final viewport = RenderAbstractViewport.maybeOf(targetObject);
  if (viewport == null) return null;
  return viewport
      // El historial usa `reverse:true`: alignment 1 coloca el borde visual
      // superior del mensaje en la parte superior del viewport.
      .getOffsetToReveal(targetObject, 1)
      .offset
      .clamp(position.minScrollExtent, position.maxScrollExtent);
}

/// Los dos saltos del historial comparten ritmo para que subir y bajar se
/// sientan como la misma interacción, sin arranques o frenadas bruscas.
@visibleForTesting
const chatNavigationDuration = Duration(milliseconds: 320);

@visibleForTesting
const chatNavigationCurve = Curves.easeOutCubic;

MarkdownStyleSheet _userSheet(ThemeData theme, HermesThemeColors colors) {
  final fg = colors.textPrimary;
  return MarkdownStyleSheet(
    p: theme.textTheme.bodyMedium?.copyWith(color: fg, height: 1.4),
    code: TextStyle(
      backgroundColor: fg.withValues(alpha: 0.12),
      fontFamily: 'monospace',
      fontSize: 13,
      color: fg,
    ),
    codeblockDecoration: BoxDecoration(
      color: fg.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
    ),
    a: TextStyle(
      color: fg.withValues(alpha: 0.85),
      decoration: TextDecoration.underline,
      decorationColor: fg.withValues(alpha: 0.5),
    ),
    h1: theme.textTheme.headlineSmall?.copyWith(color: fg),
    h2: theme.textTheme.titleLarge?.copyWith(color: fg),
    h3: theme.textTheme.titleMedium?.copyWith(color: fg),
    blockquote: TextStyle(
      color: fg.withValues(alpha: 0.75),
      fontStyle: FontStyle.italic,
    ),
    blockquoteDecoration: BoxDecoration(
      color: fg.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
    ),
    em: theme.textTheme.bodyMedium?.copyWith(
      fontStyle: FontStyle.italic,
      color: fg,
    ),
    strong: theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.bold,
      color: fg,
    ),
  );
}

/// Keeps an existing transcript mounted while a manual refresh is in flight or
/// reports a failure. Initial loads without history still use the full states.
class ChatRefreshStatusOverlay extends StatelessWidget {
  const ChatRefreshStatusOverlay({
    required this.loading,
    required this.errorMessage,
    required this.child,
    super.key,
  });

  final bool loading;
  final String? errorMessage;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (loading)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Semantics(
              key: const ValueKey('chat-refresh-progress'),
              liveRegion: true,
              label: MaterialLocalizations.of(
                context,
              ).refreshIndicatorSemanticLabel,
              child: ExcludeSemantics(
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: colors.accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          ),
        if (errorMessage != null)
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: Center(
              child: Semantics(
                key: const ValueKey('chat-refresh-error'),
                liveRegion: true,
                label: errorMessage,
                child: ExcludeSemantics(
                  child: Material(
                    color: colors.error,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        errorMessage!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
