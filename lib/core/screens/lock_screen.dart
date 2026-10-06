import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/app_lock.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// Pantalla de desbloqueo: PIN propio + biometría opcional.
///
/// Dos usos, ambos como RUTA del Navigator (nunca dentro de un Overlay casero):
///  - Gate de arranque/reanudación: presentada por [AppLockGate] como ruta
///    opaca; al verificar, desbloquea y hace pop de su propia ruta.
///  - Verificación puntual ([LockScreen.verify]): se presenta como ruta y
///    devuelve true/false vía Navigator.pop.
class LockScreen extends StatefulWidget {
  final AppLockService lock;
  final bool verifyMode;
  final String reason;

  const LockScreen({
    required this.lock,
    this.verifyMode = false,
    this.reason = '',
    super.key,
  });

  /// Pide verificación (biometría o PIN) para una acción sensible.
  /// Devuelve true si el usuario verificó. Si el bloqueo no está activo,
  /// devuelve true sin pedir nada.
  static Future<bool> verify(BuildContext context, AppLockService lock,
      {required String reason}) async {
    if (!lock.enabled) return true;
    final ok = await Navigator.push<bool>(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black54,
        fullscreenDialog: true,
        pageBuilder: (_, _, _) => CoveredRouteMediaQueryFreeze(
          child: LockScreen(lock: lock, verifyMode: true, reason: reason),
        ),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
    return ok ?? false;
  }

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pinCtrl = TextEditingController();
  String? _error;
  bool _biometricsAvailable = false;
  bool _checking = false;
  Timer? _cooldownTicker;

  @override
  void initState() {
    super.initState();
    _initBiometrics();
  }

  Future<void> _initBiometrics() async {
    final available =
        widget.lock.biometricEnabled && await widget.lock.canUseBiometrics();
    if (!mounted) return;
    setState(() => _biometricsAvailable = available);
    // Prompt biométrico directo al entrar — el PIN queda como fallback visible.
    if (available) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final ok =
        await widget.lock.authenticateBiometric(reason: widget.reason);
    if (!mounted) return;
    if (ok) _succeed();
  }

  Future<void> _submitPin() async {
    final pin = _pinCtrl.text;
    if (pin.isEmpty || _checking) return;
    setState(() => _checking = true);
    final ok = await widget.lock.verifyPin(pin);
    if (!mounted) return;
    setState(() => _checking = false);
    if (ok) {
      _succeed();
      return;
    }
    _pinCtrl.clear();
    HapticFeedback.mediumImpact();
    final wait = widget.lock.cooldownRemaining;
    setState(() {
      _error = wait > 0
          ? Strings.of(context).lockTooManyAttempts(wait.toString())
          : Strings.of(context).lockWrongPin;
    });
    if (wait > 0) _startCooldownTicker();
  }

  void _startCooldownTicker() {
    _cooldownTicker?.cancel();
    _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final left = widget.lock.cooldownRemaining;
      setState(() {
        _error = left > 0 ? Strings.of(context).lockTooManyAttempts(left.toString()) : null;
      });
      if (left <= 0) t.cancel();
    });
  }

  /// Suelta el foco del campo PIN antes de que este subárbol se desmonte.
  ///
  /// Suelta el foco/teclado antes de hacer pop (higiene; la robustez real
  /// viene de presentar siempre la LockScreen como ruta del Navigator).
  void _releaseFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.hasFocus) focus.unfocus();
  }

  void _succeed() {
    _releaseFocus();
    if (widget.verifyMode) {
      Navigator.of(context).pop(true);
    } else {
      // Gate: solo desbloquear. El AppLockGate observa `locked` y retira su
      // propia ruta — un único dueño del ciclo de vida de la ruta.
      widget.lock.unlock();
    }
  }

  void _cancel() {
    _releaseFocus();
    Navigator.of(context).pop(false);
  }

  @override
  void deactivate() {
    // Red de seguridad: pase lo que pase (back del sistema, pop programático),
    // el foco se suelta antes de desmontar. Idempotente con _releaseFocus.
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _cooldownTicker?.cancel();
    _pinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return PopScope(
      // En modo gate no se puede salir hacia atrás; en verify, volver = cancelar.
      canPop: widget.verifyMode,
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 40, color: colors.accent),
                    const SizedBox(height: 16),
                    Text(
                      'HERMES',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.reason.isEmpty
                          ? Strings.of(context).lockUnlock
                          : widget.reason,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _pinCtrl,
                      autofocus: !_biometricsAvailable,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(8),
                      ],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        letterSpacing: 8,
                      ),
                      decoration: InputDecoration(
                        hintText: 'PIN',
                        hintStyle: TextStyle(
                          fontSize: 14,
                          letterSpacing: 2,
                          color: colors.textTertiary,
                        ),
                        errorText: _error,
                      ),
                      onSubmitted: (_) => _submitPin(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _checking ? null : _submitPin,
                        child: _checking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : Text(Strings.of(context).lockUnlockShort),
                      ),
                    ),
                    if (_biometricsAvailable) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _tryBiometric,
                        icon: const Icon(Icons.fingerprint, size: 20),
                        label: Text(Strings.of(context).lockUseBiometrics),
                      ),
                    ],
                    if (widget.verifyMode) ...[
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _cancel,
                        child: Text(
                          Strings.of(context).commonCancel,
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Envuelve la app: observa el ciclo de vida y superpone [LockScreen]
/// mientras el servicio esté bloqueado.
/// Gate de bloqueo: presenta la [LockScreen] como una RUTA del Navigator raíz
/// cuando el servicio está bloqueado.
///
/// Arquitectura (corrección del crash `_dependents.isEmpty`): NO se usa un
/// `Overlay` casero. El bug venía de montar la LockScreen (con su `TextField`)
/// en un `Overlay` anidado que se desmontaba mientras el `EditableText` seguía
/// registrado como dependiente de ese Overlay vía `Overlay.of` (selección de
/// texto). Al presentarla como ruta normal, el campo usa el Overlay estable del
/// Navigator, que nunca se desmonta — solo se hace pop de la ruta, y el
/// Navigator desactiva el subárbol en el orden correcto (hijos antes que sus
/// inherited widgets). Por eso esta arquitectura no puede disparar el assert.
class AppLockGate extends StatefulWidget {
  final AppLockService lock;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const AppLockGate({
    required this.lock,
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  /// Ruta de bloqueo activa, o null si la app está desbloqueada. El gate es el
  /// ÚNICO dueño del ciclo de vida de esta ruta: la empuja al bloquear y la
  /// retira al desbloquear (incluido el desbloqueo programático vía
  /// `unlock()`/`disable()`), nunca la propia LockScreen.
  Route<void>? _lockRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.lock.locked.addListener(_sync);
    // Si la app arranca bloqueada, presentar tras el primer frame (cuando el
    // Navigator ya existe).
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        widget.lock.onAppPaused();
      case AppLifecycleState.resumed:
        widget.lock.onAppResumed();
      default:
        break;
    }
  }

  /// Reconcilia el estado de bloqueo con la presencia de la ruta de bloqueo.
  void _sync() {
    if (!mounted) return;
    final nav = widget.navigatorKey.currentState;
    if (nav == null) {
      // El Navigator aún no está montado: reintentar en el siguiente frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
      return;
    }
    final locked = widget.lock.locked.value;
    if (locked && _lockRoute == null) {
      final route = PageRouteBuilder<void>(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) =>
            CoveredRouteMediaQueryFreeze(child: LockScreen(lock: widget.lock)),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      );
      _lockRoute = route;
      // Al cerrarse (por cualquier vía) limpiamos la referencia y resincronizamos.
      nav.push(route).then((_) {
        if (_lockRoute == route) _lockRoute = null;
        _sync();
      });
    } else if (!locked && _lockRoute != null) {
      nav.removeRoute(_lockRoute!);
      _lockRoute = null;
    }
  }

  @override
  void dispose() {
    widget.lock.locked.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // El gate ya no dibuja nada propio: solo orquesta la ruta de bloqueo.
    return widget.child;
  }
}
