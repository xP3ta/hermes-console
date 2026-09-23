import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/theme_contrast.dart';

/// Severidad de un aviso. El color sale siempre de los tokens del tema
/// (`accent`, `success`, `warning`, `error`), asi funciona en los 26 temas.
enum HermesNoticeKind { info, success, warning, error }

/// Prioridad dentro del carril unico de avisos.
///
/// [high] es para avisos que llegan de otra parte de la app y piden atencion
/// (aprobaciones, respuesta lista en otro chat). Un aviso [normal] (feedback de
/// una accion) puede tomar el carril un momento, pero el [high] vuelve despues.
enum HermesNoticePriority { normal, high }

/// Boton unico de un aviso ("Deshacer", "Ir", "Reintentar").
@immutable
class HermesNoticeAction {
  const HermesNoticeAction({
    required this.label,
    required this.onPressed,
    this.closesNotice = true,
  });

  final String label;
  final VoidCallback onPressed;

  /// Si pulsar la accion tambien retira el aviso (por defecto si). Un aviso
  /// cuyo destino puede fallar al abrirse (cross-chat) lo cierra su propietario.
  final bool closesNotice;
}

/// Duraciones por defecto (mas largas cuando hay que actuar o algo fallo).
/// Un `SnackBar` explicito con `duration` propia la conserva.
abstract final class HermesNoticeDurations {
  /// Confirmaciones ("Copiado", "Guardado"): se leen de un vistazo.
  static const Duration success = Duration(seconds: 3);
  static const Duration info = Duration(seconds: 4);
  static const Duration alert = Duration(seconds: 6);
  static const Duration action = Duration(seconds: 8);

  /// Tiempo minimo de lectura de un aviso cuando otros esperan su turno.
  static const Duration minWhenQueued = Duration(milliseconds: 2500);
}

/// Asa de un aviso ya mostrado: permite retirarlo antes de tiempo.
class HermesNoticeHandle {
  HermesNoticeHandle._(this._slot, this._notice);

  final _NoticeSlot _slot;
  final _Notice _notice;

  /// Retira el aviso (con salida animada). No hace nada si ya se cerro.
  void dismiss() => _slot.close(_notice);

  /// True mientras el aviso esta en pantalla (o aparcado esperando su turno).
  bool get isActive => !_notice.closed;
}

/// API unica de avisos transitorios de la app.
///
/// Sustituye a `ScaffoldMessenger...showSnackBar`. Los avisos flotan ARRIBA,
/// bajo la barra de estado (nunca abajo, donde viven el composer, el teclado,
/// el dock y las pastillas de actividad), en un carril unico: como mucho uno
/// visible, duplicados fusionados (mismo `id`), una cola FIFO corta para los
/// avisos distintos y un aviso importante que nunca queda tapado por feedback. Se apoyan en el `Overlay` raiz, asi que funcionan en cualquier
/// pantalla y por encima de hojas y dialogos ya abiertos.
///
/// ```dart
/// HermesNotice.show(context, message: s.copied, kind: HermesNoticeKind.success);
/// final notices = HermesNotice.of(context); // capturable antes de un await
/// ```
abstract final class HermesNotice {
  /// Controlador ligado al `Overlay` raiz de [context]. Se puede capturar antes
  /// de un `await` (igual que `ScaffoldMessenger.of`). Si no hay `Overlay`
  /// (por ejemplo un contexto por encima del Navigator) degrada a un
  /// `SnackBar` del `ScaffoldMessenger` mas cercano.
  static HermesNoticeController of(BuildContext context) =>
      maybeOf(context) ?? const HermesNoticeController._detached();

  /// Como [of], pero null si no hay ni `Overlay` ni `ScaffoldMessenger`.
  static HermesNoticeController? maybeOf(BuildContext context) {
    final overlay = _rootOverlay(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (overlay == null && messenger == null) return null;
    return HermesNoticeController._(overlay, messenger);
  }

  /// Controlador ligado a un `Overlay` concreto (p. ej. el del Navigator raiz
  /// cuando el llamador no tiene `BuildContext` propio).
  static HermesNoticeController? ofOverlay(OverlayState? overlay) =>
      overlay == null ? null : HermesNoticeController._(overlay, null);

  /// Atajo para el Navigator raiz de la app.
  static HermesNoticeController? ofNavigator(NavigatorState? navigator) =>
      ofOverlay(navigator?.overlay);

  /// Muestra un aviso. Ver [HermesNoticeController.show].
  static HermesNoticeHandle? show(
    BuildContext context, {
    required String message,
    String? title,
    HermesNoticeKind kind = HermesNoticeKind.info,
    HermesNoticeAction? action,
    Duration? duration,
  }) => of(context).show(
    message: message,
    title: title,
    kind: kind,
    action: action,
    duration: duration,
  );

  static OverlayState? _rootOverlay(BuildContext context) {
    // El contexto del propio Navigator (p. ej. `navigatorKey.currentContext`)
    // queda POR ENCIMA de su Overlay: se resuelve por su estado.
    if (context is StatefulElement) {
      final state = context.state;
      if (state is NavigatorState) return state.overlay;
    }
    return Overlay.maybeOf(context, rootOverlay: true);
  }
}

/// Controlador de avisos ligado a un `Overlay` (o al `ScaffoldMessenger` de
/// respaldo). Los metodos `showSnackBar`/`hide*`/`clearSnackBars` existen para
/// migrar llamadas antiguas sin tocar su forma.
class HermesNoticeController {
  const HermesNoticeController._(this._overlay, this._fallback);

  const HermesNoticeController._detached() : _overlay = null, _fallback = null;

  final OverlayState? _overlay;
  final ScaffoldMessengerState? _fallback;

  /// Muestra un aviso en el carril superior.
  ///
  /// - [message] es el texto; con [title] pasa a segunda linea (<= 2 lineas).
  /// - [kind] fija icono y color (tokens del tema); [icon]/[tint] lo sustituyen
  ///   para avisos con identidad propia (aprobacion, run...).
  /// - [action] es el unico boton; [onTap] es el gesto de toda la tarjeta (por
  ///   defecto cierra el aviso).
  /// - [duration] null = por defecto segun severidad/accion; [sticky] = no se
  ///   cierra solo (se retira deslizando, con la X o al abrirlo).
  /// - [id] fusiona duplicados: mismo id visible = se refresca sin reanimar.
  HermesNoticeHandle? show({
    required String message,
    String? title,
    HermesNoticeKind kind = HermesNoticeKind.info,
    IconData? icon,
    Color? tint,
    HermesNoticeAction? action,
    VoidCallback? onTap,
    Duration? duration,
    bool sticky = false,
    HermesNoticePriority priority = HermesNoticePriority.normal,
    String? id,
    Key? noticeKey,
    bool showDismiss = false,
    String? dismissLabel,
    VoidCallback? onClosed,
  }) {
    final overlay = _overlay;
    if (overlay == null) {
      // Sin Overlay (contexto por encima del Navigator): respaldo nativo.
      _fallback?.showSnackBar(
        SnackBar(
          content: Text(title == null ? message : '$title. $message'),
          duration: duration ?? const Duration(seconds: 4),
          action: action == null
              ? null
              : SnackBarAction(
                  label: action.label,
                  onPressed: action.onPressed,
                ),
        ),
      );
      return null;
    }
    if (!overlay.mounted) return null;
    final notice = _Notice(
      id: id ?? '${kind.name}|${title ?? ''}|$message',
      kind: kind,
      icon: icon,
      tint: tint,
      title: title,
      message: message,
      action: action,
      onTap: onTap,
      duration: duration,
      sticky: sticky,
      priority: priority,
      noticeKey: noticeKey,
      showDismiss: showDismiss,
      dismissLabel: dismissLabel,
      onClosed: onClosed,
    );
    return _NoticeSlot.of(overlay).present(notice);
  }

  /// Compatibilidad con `ScaffoldMessenger.showSnackBar`: traduce un
  /// [SnackBar] de texto simple (con accion y duracion opcionales) al aviso.
  /// [kind] fija la severidad (por defecto informativo); el fondo del SnackBar
  /// original se ignora: el color sale de los tokens del tema.
  HermesNoticeHandle? showSnackBar(SnackBar snackBar, {HermesNoticeKind? kind}) {
    final content = snackBar.content;
    final text = content is Text
        ? (content.data ?? content.textSpan?.toPlainText())
        : null;
    if (text == null) {
      // Contenido que no es texto: los avisos son texto; se deja al SnackBar
      // nativo para no perder el mensaje (no queda ningun uso en la app).
      _fallback?.showSnackBar(snackBar);
      return null;
    }
    final action = snackBar.action;
    final explicitDuration =
        snackBar.duration == const Duration(milliseconds: 4000)
        ? null
        : snackBar.duration;
    final handle = show(
      message: text,
      kind: kind ?? HermesNoticeKind.info,
      action: action == null
          ? null
          : HermesNoticeAction(
              label: action.label,
              onPressed: action.onPressed,
            ),
      duration: explicitDuration,
      noticeKey: snackBar.key,
      showDismiss: snackBar.showCloseIcon ?? false,
    );
    if (handle != null) snackBar.onVisible?.call();
    return handle;
  }

  /// Retira el aviso visible (solo prioridad normal; nunca una aprobacion); el
  /// siguiente de la cola, si lo hay, ocupa su lugar.
  void hideCurrentSnackBar() => _overlay == null
      ? _fallback?.hideCurrentSnackBar()
      : _NoticeSlot.of(_overlay).closeNormal(animated: true);

  /// Retira el aviso visible sin animacion.
  void removeCurrentSnackBar() => _overlay == null
      ? _fallback?.removeCurrentSnackBar()
      : _NoticeSlot.of(_overlay).closeNormal(animated: false);

  /// Retira el aviso normal visible y toda la cola de espera.
  void clearSnackBars() => _overlay == null
      ? _fallback?.clearSnackBars()
      : _NoticeSlot.of(_overlay).closeNormal(animated: false, clearQueue: true);
}

// ── Estado del carril ────────────────────────────────────────────────────────

class _Notice {
  _Notice({
    required this.id,
    required this.kind,
    required this.message,
    required this.priority,
    required this.sticky,
    this.icon,
    this.tint,
    this.title,
    this.action,
    this.onTap,
    this.duration,
    this.noticeKey,
    this.showDismiss = false,
    this.dismissLabel,
    this.onClosed,
  });

  final String id;
  HermesNoticeKind kind;
  IconData? icon;
  Color? tint;
  String? title;
  String message;
  HermesNoticeAction? action;
  VoidCallback? onTap;
  Duration? duration;
  bool sticky;
  final HermesNoticePriority priority;
  Key? noticeKey;
  bool showDismiss;
  String? dismissLabel;
  VoidCallback? onClosed;

  /// Sube cada vez que un duplicado refresca este aviso (reinicia el temporizador).
  int revision = 0;
  bool closing = false;
  bool closed = false;

  void refreshFrom(_Notice other) {
    kind = other.kind;
    icon = other.icon;
    tint = other.tint;
    title = other.title;
    message = other.message;
    action = other.action;
    onTap = other.onTap;
    duration = other.duration;
    sticky = other.sticky;
    noticeKey = other.noticeKey;
    showDismiss = other.showDismiss;
    dismissLabel = other.dismissLabel;
    onClosed = other.onClosed;
    revision++;
  }

  void fireClosed() {
    if (closed) return;
    closed = true;
    final callback = onClosed;
    onClosed = null;
    callback?.call();
  }
}

/// Carril unico de un `Overlay`: un aviso visible, una cola corta de normales
/// y, como maximo, un aviso importante aparcado.
class _NoticeSlot extends ChangeNotifier {
  _NoticeSlot(this.overlay);

  final OverlayState overlay;
  static final Expando<_NoticeSlot> _slots = Expando<_NoticeSlot>(
    'HermesNotice',
  );

  /// Avisos normales en espera; si se desborda se descartan los mas antiguos.
  static const int maxPending = 3;

  static _NoticeSlot of(OverlayState overlay) =>
      _slots[overlay] ??= _NoticeSlot(overlay);

  _Notice? current;
  final List<_Notice> _pending = <_Notice>[];

  /// Aviso de prioridad alta desplazado por un feedback normal; vuelve despues.
  _Notice? _parked;
  OverlayEntry? _entry;

  /// Cada entrada nueva del Overlay lleva una generacion: un carril que ya fue
  /// retirado (pero sigue montado hasta el proximo frame) ignora el estado.
  int _generation = 0;
  int _attachedGeneration = -1;

  bool get hasPending => _pending.isNotEmpty;

  HermesNoticeHandle? present(_Notice incoming) {
    if (!overlay.mounted) return null;
    final shown = current;
    final live = shown != null && !shown.closing ? shown : null;
    // 1. Duplicados: se refrescan en su sitio (texto, accion, temporizador).
    if (live != null && live.id == incoming.id) {
      live.refreshFrom(incoming);
      notifyListeners();
      return HermesNoticeHandle._(this, live);
    }
    for (final queued in _pending) {
      if (queued.id == incoming.id) {
        queued.refreshFrom(incoming);
        return HermesNoticeHandle._(this, queued);
      }
    }
    // 2. Un aviso importante toma el carril: lo pendiente ya no es actual.
    if (incoming.priority == HermesNoticePriority.high) {
      for (final stale in _pending) {
        stale.fireClosed();
      }
      _pending.clear();
      _parked?.fireClosed();
      _parked = null;
      shown?.fireClosed();
      return _show(incoming);
    }
    // 3. Feedback normal.
    if (shown == null) return _show(incoming);
    if (live != null && live.priority == HermesNoticePriority.high) {
      // Sobre un aviso importante: este se aparca y vuelve al terminar.
      _parked?.fireClosed();
      _parked = live;
      return _show(incoming);
    }
    // Sobre otro normal: cola FIFO corta (como los SnackBar), sin perder el
    // orden de lo que una misma accion quiso decir.
    _pending.add(incoming);
    while (_pending.length > maxPending) {
      _pending.removeAt(0).fireClosed();
    }
    notifyListeners();
    return HermesNoticeHandle._(this, incoming);
  }

  HermesNoticeHandle _show(_Notice notice) {
    current = notice;
    if (_entry == null) {
      final generation = ++_generation;
      final entry = OverlayEntry(
        builder: (_) => _NoticeLane(slot: this, generation: generation),
      );
      _entry = entry;
      overlay.insert(entry);
    }
    notifyListeners();
    return HermesNoticeHandle._(this, notice);
  }

  void close(_Notice notice) {
    if (notice.closed) return;
    if (_pending.remove(notice)) {
      notice.fireClosed();
      return;
    }
    if (identical(_parked, notice)) {
      _parked = null;
      notice.fireClosed();
      return;
    }
    if (!identical(current, notice) || notice.closing) return;
    notice.closing = true;
    notifyListeners();
    if (!_laneAttached) finishClose(notice);
  }

  /// Retira el aviso normal visible (nunca uno de prioridad alta). Con
  /// [clearQueue] tambien vacia la cola de espera.
  void closeNormal({required bool animated, bool clearQueue = false}) {
    if (clearQueue) {
      final queued = List<_Notice>.of(_pending);
      _pending.clear();
      for (final notice in queued) {
        notice.fireClosed();
      }
    }
    final shown = current;
    if (shown == null || shown.priority != HermesNoticePriority.normal) return;
    if (animated) {
      close(shown);
    } else {
      finishClose(shown);
    }
  }

  bool get _laneAttached => _attachedGeneration == _generation;

  /// El carril termino la animacion de salida: el aviso ya no esta.
  void finishClose(_Notice notice) {
    if (!identical(current, notice)) return;
    notice.fireClosed();
    final _Notice? next;
    if (_pending.isNotEmpty) {
      next = _pending.removeAt(0);
    } else {
      next = _parked;
      _parked = null;
      if (next != null) {
        // Vuelve el aviso importante con temporizador nuevo.
        next.closing = false;
        next.revision++;
      }
    }
    current = next;
    notifyListeners();
    if (next != null) return;
    final entry = _entry;
    _entry = null;
    if (entry != null && overlay.mounted) {
      entry.remove();
      entry.dispose();
    }
  }
}

/// Entrada del `Overlay`: coloca el aviso actual arriba, bajo la barra de
/// estado, con entrada/salida cortas y temporizador propio (se cancela al
/// desmontar el arbol, sin dejar timers colgando).
class _NoticeLane extends StatefulWidget {
  const _NoticeLane({required this.slot, required this.generation});

  final _NoticeSlot slot;
  final int generation;

  @override
  State<_NoticeLane> createState() => _NoticeLaneState();
}

class _NoticeLaneState extends State<_NoticeLane>
    with SingleTickerProviderStateMixin {
  late final AnimationController _visibility = AnimationController(vsync: this);
  Timer? _timer;
  Timer? _dwell;
  bool _dwellDone = false;
  _Notice? _shown;
  int _shownRevision = -1;
  bool _presented = false;
  bool _exiting = false;
  bool _reduceMotion = false;
  bool _accessibleNavigation = false;
  bool _synced = false;

  @override
  void initState() {
    super.initState();
    widget.slot._attachedGeneration = widget.generation;
    widget.slot.addListener(_onSlotChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _accessibleNavigation =
        MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    if (!_synced) {
      _synced = true;
      _sync(rebuild: false);
    }
  }

  @override
  void dispose() {
    widget.slot.removeListener(_onSlotChanged);
    if (widget.slot._attachedGeneration == widget.generation) {
      widget.slot._attachedGeneration = -1;
    }
    _timer?.cancel();
    _dwell?.cancel();
    _visibility.dispose();
    super.dispose();
  }

  void _onSlotChanged() {
    if (!mounted || widget.generation != widget.slot._generation) return;
    _sync();
  }

  void _sync({bool rebuild = true}) {
    final notice = widget.slot.current;
    if (notice == null) return;
    if (!identical(notice, _shown)) {
      _shown = notice;
      _shownRevision = notice.revision;
      _exiting = false;
      _armTimer(notice);
      if (!_presented) {
        _presented = true;
        _visibility.duration = Motion.base;
        if (_reduceMotion) {
          _visibility.value = 1;
        } else {
          _visibility.forward(from: 0);
        }
      } else {
        _visibility.value = 1;
      }
    } else if (notice.revision != _shownRevision) {
      _shownRevision = notice.revision;
      _exiting = false;
      _visibility.value = 1;
      _armTimer(notice);
    }
    if (notice.closing && !_exiting) {
      _exiting = true;
      _timer?.cancel();
      _dwell?.cancel();
      _visibility.duration = _reduceMotion ? Duration.zero : Motion.fast;
      _visibility.reverse().whenComplete(() {
        if (!identical(_shown, notice)) return;
        _presented = false;
        _shown = null;
        if (!mounted || widget.generation != widget.slot._generation) return;
        widget.slot.finishClose(notice);
      });
    }
    _yieldToQueue(notice);
    if (rebuild && mounted) setState(() {});
  }

  /// Con avisos esperando, el visible cede el turno pasado su tiempo minimo de
  /// lectura, en vez de agotar su duracion completa.
  void _yieldToQueue(_Notice notice) {
    if (_dwellDone &&
        !notice.closing &&
        !notice.sticky &&
        notice.priority == HermesNoticePriority.normal &&
        widget.slot.hasPending) {
      widget.slot.close(notice);
    }
  }

  void _armTimer(_Notice notice) {
    _timer?.cancel();
    _dwell?.cancel();
    _timer = null;
    _dwellDone = false;
    _dwell = Timer(HermesNoticeDurations.minWhenQueued, () {
      _dwellDone = true;
      _yieldToQueue(notice);
    });
    if (notice.sticky) return;
    final duration = notice.duration ?? _defaultDuration(notice);
    // Con navegacion accesible una accion no debe caducar antes de poder usarla.
    if (notice.action != null &&
        notice.duration == null &&
        _accessibleNavigation) {
      return;
    }
    _timer = Timer(duration, () => widget.slot.close(notice));
  }

  static Duration _defaultDuration(_Notice notice) {
    if (notice.action != null) return HermesNoticeDurations.action;
    return switch (notice.kind) {
      HermesNoticeKind.warning ||
      HermesNoticeKind.error => HermesNoticeDurations.alert,
      HermesNoticeKind.success => HermesNoticeDurations.success,
      HermesNoticeKind.info => HermesNoticeDurations.info,
    };
  }

  @override
  Widget build(BuildContext context) {
    final notice = _shown;
    if (notice == null) return const SizedBox.shrink();
    final padding = MediaQuery.paddingOf(context);
    final strings = Localizations.of<Strings>(context, Strings);
    final card = HermesNoticeCard(
      noticeKey: notice.noticeKey ?? ValueKey('hermes-notice-${notice.id}'),
      kind: notice.kind,
      icon: notice.icon,
      tint: notice.tint,
      title: notice.title,
      message: notice.message,
      action: notice.action == null
          ? null
          : HermesNoticeAction(
              label: notice.action!.label,
              onPressed: () {
                notice.action!.onPressed();
                if (notice.action!.closesNotice) widget.slot.close(notice);
              },
            ),
      onTap: notice.onTap ?? () => widget.slot.close(notice),
      onDismissed: () => widget.slot.close(notice),
      showDismiss: notice.showDismiss,
      dismissLabel: notice.dismissLabel ?? strings?.inAppDismiss ?? 'Dismiss',
      kindLabel: switch (notice.kind) {
        HermesNoticeKind.success => strings?.noticeKindSuccess ?? 'Success',
        HermesNoticeKind.warning => strings?.noticeKindWarning ?? 'Warning',
        HermesNoticeKind.error => strings?.noticeKindError ?? 'Error',
        HermesNoticeKind.info => null,
      },
    );
    // Arriba, bajo la barra de estado: nunca sobre el composer, el teclado, el
    // dock ni las pastillas de actividad, que viven abajo.
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16 + padding.left,
          padding.top + 8,
          16 + padding.right,
          0,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: AnimatedBuilder(
              animation: _visibility,
              child: card,
              builder: (context, child) {
                final value = Curves.easeOutCubic.transform(_visibility.value);
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, -12 * (1 - value)),
                    child: child,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ── Tarjeta ──────────────────────────────────────────────────────────────────

/// Tarjeta visual de un aviso: insignia circular tintada + texto + una accion.
///
/// Superficie neutra del tema con filete y sombra suave; el estado lo llevan
/// solo el glifo y su circulo (nunca una barra lateral ni un relleno de color).
/// Es publica para poder probarla y reutilizarla; en la app se usa a traves de
/// [HermesNotice].
class HermesNoticeCard extends StatelessWidget {
  const HermesNoticeCard({
    required this.noticeKey,
    required this.message,
    required this.onDismissed,
    this.kind = HermesNoticeKind.info,
    this.icon,
    this.tint,
    this.title,
    this.action,
    this.onTap,
    this.showDismiss = false,
    this.dismissLabel = 'Dismiss',
    this.kindLabel,
    super.key,
  });

  /// Clave del `Dismissible` (los tests deslizan sobre ella).
  final Key noticeKey;
  final HermesNoticeKind kind;
  final IconData? icon;
  final Color? tint;
  final String? title;
  final String message;
  final HermesNoticeAction? action;
  final VoidCallback? onTap;
  final VoidCallback onDismissed;
  final bool showDismiss;
  final String dismissLabel;

  /// Prefijo solo para lectores de pantalla ("Error", "Aviso"...).
  final String? kindLabel;

  static IconData iconFor(HermesNoticeKind kind) => switch (kind) {
    HermesNoticeKind.info => Icons.info_outline_rounded,
    HermesNoticeKind.success => Icons.check_circle_outline_rounded,
    HermesNoticeKind.warning => Icons.warning_amber_rounded,
    HermesNoticeKind.error => Icons.error_outline_rounded,
  };

  static Color tintFor(HermesNoticeKind kind, ThemeData theme) {
    final colors = theme.hermes;
    return switch (kind) {
      HermesNoticeKind.info => colors.accent,
      HermesNoticeKind.success => colors.success,
      HermesNoticeKind.warning => colors.warning,
      HermesNoticeKind.error => colors.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    final radius = profile.shape.cardRadius.clamp(16.0, 22.0);
    final dark = theme.brightness == Brightness.dark;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // Con texto muy grande la accion baja a su propia fila: el texto conserva
    // el ancho y nada se desborda a 320 dp.
    final stackAction = textScale > 1.3;

    final baseTint = tint ?? tintFor(kind, theme);
    final circleFill = Color.alphaBlend(
      baseTint.withValues(alpha: 0.14),
      colors.surface,
    );
    // El glifo debe leerse (3:1) sobre su circulo en cualquier tema.
    final glyph = ThemeContrast.adjustForContrast(baseTint, [
      circleFill,
    ], minimum: 3.0);

    final hasTitle = title != null && title!.trim().isNotEmpty;
    final primary = hasTitle ? title! : message;
    final secondary = hasTitle && message.trim().isNotEmpty ? message : null;

    final badge = Container(
      key: const ValueKey('hermes-notice-badge'),
      width: 32,
      height: 32,
      decoration: BoxDecoration(shape: BoxShape.circle, color: circleFill),
      alignment: Alignment.center,
      child: Icon(
        icon ?? iconFor(kind),
        key: const ValueKey('hermes-notice-icon'),
        color: glyph,
        size: 18,
      ),
    );

    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          primary,
          maxLines: hasTitle ? (stackAction ? 2 : 1) : 5,
          overflow: TextOverflow.ellipsis,
          style: hasTitle
              ? theme.textTheme.titleSmall?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                )
              : theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w500,
                  fontSize: 13.5,
                  height: 1.35,
                ),
        ),
        if (secondary != null) ...[
          const SizedBox(height: 2),
          Text(
            secondary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.3,
            ),
          ),
        ],
      ],
    );

    final label = [
      ?kindLabel,
      primary,
      ?secondary,
    ].join('. ');

    // Texto + insignia: un unico nodo semantico anunciado como region viva.
    final content = Semantics(
      container: true,
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          badge,
          const SizedBox(width: 12),
          Expanded(child: texts),
        ],
      ),
    );

    final actionButton = action == null
        ? null
        : _NoticeActionButton(
            key: const ValueKey('hermes-notice-action'),
            action: action!,
          );
    final dismissButton = showDismiss
        ? IconButton(
            key: const ValueKey('hermes-notice-dismiss'),
            onPressed: onDismissed,
            tooltip: dismissLabel,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: Icon(
              Icons.close_rounded,
              color: colors.textSecondary,
              size: 18,
            ),
          )
        : null;

    final Widget body;
    if (stackAction && actionButton != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, 10, dismissButton == null ? 12 : 0, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: content),
                ?dismissButton,
              ],
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8, bottom: 2),
              child: actionButton,
            ),
          ),
        ],
      );
    } else {
      body = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            12,
            8,
            dismissButton != null ? 4 : (actionButton != null ? 10 : 14),
            8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: content),
              ?actionButton,
              ?dismissButton,
            ],
          ),
        ),
      );
    }

    final card = Semantics(
      container: true,
      button: onTap != null,
      onDismiss: onDismissed,
      child: Material(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.20),
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.divider.withValues(alpha: 0.78)),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: body,
          ),
        ),
      ),
    );

    return GestureDetector(
      // Deslizar hacia arriba (hacia donde nacio) tambien lo retira.
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -250) onDismissed();
      },
      child: Dismissible(
        key: noticeKey,
        // Horizontal solo hacia el borde final: no compite con el gesto Android
        // de volver, que nace en el borde inicial de la pantalla.
        direction: DismissDirection.endToStart,
        resizeDuration: Motion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 140),
        movementDuration: Motion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        confirmDismiss: (_) async {
          // El propietario retira el aviso de inmediato. Devolver false evita
          // que Dismissible intente reconstruirse ya marcado como borrado en el
          // mismo frame en que desaparece el overlay.
          onDismissed();
          return false;
        },
        child: card,
      ),
    );
  }
}

/// Accion unica de un aviso: pastilla compacta con objetivo tactil de 48 dp.
class _NoticeActionButton extends StatelessWidget {
  const _NoticeActionButton({required this.action, super.key});

  final HermesNoticeAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    return Semantics(
      button: true,
      label: action.label,
      excludeSemantics: true,
      onTap: action.onPressed,
      child: InkWell(
        onTap: action.onPressed,
        borderRadius: BorderRadius.circular(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
