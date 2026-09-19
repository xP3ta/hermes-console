// Desinstalación del agente Hermes local con seguimiento en vivo.
//
// Flujo: confirmación → progreso con log en tiempo real → éxito o restos.
// El script de desinstalación sirve su propio log por localhost (:8643),
// igual que el instalador, así que el polling funciona sin cambios.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/agent_runtime/agent_runtime.dart';
import '../../services/agent_runtime/local_termux_agent_provider.dart';
import 'local_install_screen.dart';
import '../../services/connection_manager.dart';
import '../../services/notifications/notification_service.dart';
import '../../services/platform/android_apps.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_spark_mascot.dart';
import '../../widgets/hermes_status_indicator.dart';
import '../../widgets/hermes_ui.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../../main.dart';

class _Stage {
  final String label;
  final List<String> keys;
  const _Stage(this.label, this.keys);
}

// Identificadores del protocolo del script (no traducir).
const List<List<String>> _kStageKeys = [
  ['@@stage parando', 'proceso hermes'],
  ['@@stage borrando', 'borrado:', 'no encontrado:'],
  ['@@stage verificando', '@@warn', 'completa'],
  ['@@done'],
];

List<_Stage> _buildStages(Strings s) => [
  _Stage(s.lunStage1, _kStageKeys[0]),
  _Stage(s.lunStage2, _kStageKeys[1]),
  _Stage(s.lunStage3, _kStageKeys[2]),
  _Stage(s.lunStage4, _kStageKeys[3]),
];

// `notStarted`: el RUN_COMMAND nunca llegó a ejecutarse (Termux lo rechazó,
// típicamente por allow-external-apps desactivado) — distinto de `canceled`
// (acción del usuario): con causa probable y acción de recuperación.
enum _Phase { confirming, uninstalling, done, partial, canceled, notStarted }

class LocalUninstallScreen extends StatefulWidget {
  final ConnectionManager connManager;
  const LocalUninstallScreen({required this.connManager, super.key});

  @override
  State<LocalUninstallScreen> createState() => _LocalUninstallScreenState();
}

class _LocalUninstallScreenState extends State<LocalUninstallScreen>
    with WidgetsBindingObserver {
  static const AppBridge _bridge = AndroidApps();
  late final LocalTermuxAgentProvider _termux;

  static const String _prefKeyInProgress = 'local_uninstall_in_progress';

  _Phase _phase = _Phase.confirming;
  Timer? _poll;
  Timer? _clock;
  DateTime? _startedAt;
  DateTime? _minDisplayUntil;
  int _stageIndex = 0;
  final List<String> _logTail = [];
  final List<String> _warnings = [];
  int _noProgressTicks = 0;
  bool _warnShown = false;
  bool _removedConnection = false;
  bool _finishNotified = false;
  // Bootstrap de allow-external-apps, mismo patrón que el instalador
  // (_maybeBootstrap de local_install_screen): si el log nunca responde,
  // Termux rechazó el RUN_COMMAND en silencio y hay que activar la propiedad
  // en primer plano antes de rendirse (spec 028 A-002).
  bool _progressSeen = false;
  bool _bootstrapTried = false;
  bool _bootstrapping = false;
  /// Servicio de notificaciones locales, cacheado del árbol mientras está
  /// montado para avisar del fin aunque el usuario haya salido de la pantalla.
  NotificationService? _notif;
  NotificationService? get _notifications {
    if (_notif != null) return _notif;
    if (!mounted) return null;
    return _notif =
        context.findAncestorStateOfType<HermesAppState>()?.notifications;
  }

  static const Duration _timeout = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _termux = LocalTermuxAgentProvider(apps: _bridge);
    // Observa el ciclo de vida para relanzar al volver del bootstrap de Termux.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Al volver de Termux tras el bootstrap de allow-external-apps: la
    // propiedad ya debería estar activa, así que se relanza el RUN_COMMAND
    // real de la desinstalación (igual que hace el instalador).
    if (_phase == _Phase.uninstalling && _bootstrapping && !_progressSeen) {
      setState(() {
        _bootstrapping = false;
        _noProgressTicks = 0;
      });
      _termux.runUninstall();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _clock?.cancel();
    _termux.dispose();
    super.dispose();
  }

  Future<void> _startUninstall() async {
    await widget.connManager.prefs.setBool(_prefKeyInProgress, true);
    setState(() {
      _phase = _Phase.uninstalling;
      _startedAt = DateTime.now();
      _minDisplayUntil = DateTime.now().add(const Duration(seconds: 2));
      _stageIndex = 0;
      _logTail.clear();
      _warnings.clear();
      _noProgressTicks = 0;
      _warnShown = false;
      _finishNotified = false;
      _progressSeen = false;
      _bootstrapping = false;
      // _bootstrapTried se conserva entre reintentos: el bootstrap solo se
      // intenta una vez por pantalla (evita el bucle Termux↔app).
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _phase == _Phase.uninstalling) setState(() {});
    });
    final launched = await _termux.runUninstall();
    if (!mounted) return;
    if (!launched) {
      _clock?.cancel();
      // Sin lanzamiento no hay operación en curso: limpiar el pref evita el
      // banner fantasma del home (spec 028 A-003) y el estado dice la verdad
      // ("no se pudo iniciar"), no "cancelada".
      await widget.connManager.prefs.remove(_prefKeyInProgress);
      if (!mounted) return;
      setState(() => _phase = _Phase.notStarted);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).lunLaunchError),
          duration: const Duration(seconds: 7),
        ),
      );
      return;
    }
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
  }

  Future<void> _tick() async {
    if (!mounted || _phase != _Phase.uninstalling) return;

    final start = _startedAt;
    if (start != null && DateTime.now().difference(start) > _timeout) {
      _poll?.cancel();
      _clock?.cancel();
      await _termux.cancelUninstall();
      // El pref de "operación en curso" también se limpia aquí: solo se
      // borraba en el camino @@exit y el banner del home quedaba huérfano
      // para siempre (spec 028 A-003).
      await widget.connManager.prefs.remove(_prefKeyInProgress);
      if (!mounted) return;
      // Sin señal alguna del log, la desinstalación nunca llegó a arrancar:
      // estado honesto con causa y acción, no "cancelada" (spec 028 A-002).
      setState(
        () => _phase = _progressSeen ? _Phase.canceled : _Phase.notStarted,
      );
      return;
    }

    final log = await _termux.fetchUninstallProgress();
    if (!mounted) return;

    if (log == null) {
      _noProgressTicks++;
      // ~10 s sin señal y sin bootstrap previo → Termux está rechazando el
      // RUN_COMMAND en silencio: activa allow-external-apps en primer plano
      // (mismo patrón que el instalador) antes de rendirse.
      if (_noProgressTicks >= 7 &&
          !_progressSeen &&
          !_bootstrapTried &&
          !_bootstrapping) {
        await _maybeBootstrap();
        return;
      }
      if (_noProgressTicks >= 7 && !_warnShown && !_bootstrapping) {
        _warnShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).lunTimeoutWarning),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    _noProgressTicks = 0;
    _progressSeen = true;
    await _parse(log);
  }

  /// Bootstrap de `allow-external-apps` reutilizando el mecanismo del
  /// instalador: doble comprobación del log y, si sigue mudo, abre Termux en
  /// primer plano con el comando que activa la propiedad. Al volver a la app
  /// (didChangeAppLifecycleState) se relanza la desinstalación.
  Future<void> _maybeBootstrap() async {
    if (_bootstrapTried || _bootstrapping || _progressSeen || !mounted) return;
    // Puede que el RUN_COMMAND sí funcione y el log responda aunque el tick
    // anterior no lo viera: si hay señal, no hay que tocar nada.
    final log = await _termux.fetchUninstallProgress(
      timeout: const Duration(seconds: 2),
    );
    if (!mounted || _progressSeen) return;
    if (log != null) {
      _progressSeen = true;
      return;
    }
    _bootstrapTried = true;
    setState(() => _bootstrapping = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).lisBootstrapSnack),
        duration: const Duration(seconds: 4),
      ),
    );
    final ok = await _termux.bootstrapExternalApps();
    if (!mounted) return;
    if (!ok) {
      // No se pudo abrir Termux en primer plano: deja el flujo normal, que
      // acabará en el estado "no se pudo iniciar" con acción de reintento.
      setState(() => _bootstrapping = false);
    }
  }

  Future<void> _parse(String log) async {
    final lower = log.toLowerCase();

    var idx = _stageIndex;
    for (var i = _kStageKeys.length - 1; i >= 0; i--) {
      if (_kStageKeys[i].any(lower.contains)) {
        idx = i > idx ? i : idx;
        break;
      }
    }

    final exitMatch = RegExp(r'@@exit\s+(\d+)').firstMatch(lower);
    final exit = exitMatch != null
        ? int.tryParse(exitMatch.group(1) ?? '')
        : null;

    final newWarns = log
        .split('\n')
        .where((l) => l.toLowerCase().startsWith('@@warn'))
        .map(
          (l) => l
              .replaceFirst(RegExp(r'@@warn\s*', caseSensitive: false), '')
              .trim(),
        )
        .where((l) => l.isNotEmpty)
        .toList();

    final lines = log
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.startsWith('@@'))
        .toList();

    if (!mounted) return;
    setState(() {
      _stageIndex = idx;
      _logTail
        ..clear()
        ..addAll(lines.length > 30 ? lines.sublist(lines.length - 30) : lines);
      for (final w in newWarns) {
        if (!_warnings.contains(w)) _warnings.add(w);
      }
      if (exit != null) {
        _poll?.cancel();
        _clock?.cancel();
        _stageIndex = _kStageKeys.length - 1;
      }
    });

    if (exit != null) {
      if (exit != 130) {
        _removeConnection();
        // El agente ya no existe: borra la marca de instalado para que el setup
        // vuelva a ofrecer SÓLO instalar (detección binaria).
        AgentRuntimeConsts.setAgentInstalled(false);
        // Y limpia cualquier flag de instalación obsoleto: sin esto, tras
        // desinstalar seguía apareciendo un «Retomar» fantasma en el home.
        widget.connManager.prefs.remove(LocalInstallScreen.prefKeyInProgress);
      }
      final finalPhase = switch (exit) {
        0 => _Phase.done,
        130 => _Phase.canceled,
        _ => _Phase.partial,
      };
      // Avisa por notificación (salvo cancelación del propio usuario): funciona
      // aunque la app esté en segundo plano durante la desinstalación.
      if (finalPhase != _Phase.canceled) {
        _notifyUninstallFinished(
          ok: finalPhase == _Phase.done,
          detail: _warnings.isNotEmpty
              ? 'Algunos elementos no se pudieron eliminar.'
              : null,
        );
      }
      // Garantiza al menos 2s en la vista de progreso para que el log sea visible.
      final minWait = _minDisplayUntil ?? DateTime.now();
      final remaining = minWait.difference(DateTime.now());
      if (remaining > Duration.zero) {
        await Future.delayed(remaining);
      }
      await widget.connManager.prefs.remove(_prefKeyInProgress);
      if (!mounted) return;
      setState(() => _phase = finalPhase);
    }
  }

  Future<void> _removeConnection() async {
    if (_removedConnection) return;
    _removedConnection = true;
    await _termux.removeLocalConnection(widget.connManager);
  }

  /// Notifica el desenlace de la desinstalación una sola vez por intento.
  void _notifyUninstallFinished({required bool ok, String? detail}) {
    if (_finishNotified) return;
    _finishNotified = true;
    _notifications?.localUninstallFinished(ok: ok, detail: detail);
  }

  Future<void> _cancel() async {
    _poll?.cancel();
    _clock?.cancel();
    await _termux.cancelUninstall();
    // Igual que el instalador: al cancelar se limpia el pref de "operación en
    // curso"; si no, el banner del home reaparecía en cada arranque
    // (spec 028 A-003).
    await widget.connManager.prefs.remove(_prefKeyInProgress);
    if (!mounted) return;
    setState(() => _phase = _Phase.canceled);
  }

  String get _elapsedLabel {
    final start = _startedAt;
    if (start == null) return '00:00';
    final s = DateTime.now().difference(start).inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(
          str.lunScreenTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
            color: colors.error,
          ),
        ),
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.confirming => _confirmView(colors),
          _Phase.uninstalling => _progressView(colors),
          _Phase.done => _doneView(colors),
          _Phase.partial => _partialView(colors),
          _Phase.canceled => _canceledView(colors),
          _Phase.notStarted => _notStartedView(colors),
        },
      ),
    );
  }

  Widget _confirmView(HermesThemeColors colors) {
    final str = Strings.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.error.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.delete_forever_rounded,
                    color: colors.error,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      str.lunConfirmTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                str.lunConfirmSubtitle,
                style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
              ),
              const SizedBox(height: 10),
              ...[
                str.lunItem1,
                str.lunItem2,
                str.lunItem3,
                str.lunItem4,
                str.lunItem5,
              ].map(
                (item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• ',
                        style: TextStyle(color: colors.error, fontSize: 13),
                      ),
                      Expanded(
                        child: Text(
                          item,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.textPrimary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.warning.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 15,
                      color: colors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        str.lunWarning,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HermesPrimaryButton(
          label: str.lunDoUninstall,
          icon: Icons.delete_forever_rounded,
          onTap: _startUninstall,
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(str.lunCancel),
          ),
        ),
      ],
    );
  }

  Widget _progressView(HermesThemeColors colors) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.error.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const HermesStatusIndicator(
                    mood: HermesSparkMood.connecting,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _buildStages(Strings.of(context))[_stageIndex].label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  if (_startedAt != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: colors.error.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: colors.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 13,
                            color: colors.error,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _elapsedLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: null,
                  minHeight: 7,
                  backgroundColor: colors.surfaceVariant,
                  color: colors.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                Strings.of(context).lunStageCount(_stageIndex + 1, _kStageKeys.length),
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ...List.generate(_kStageKeys.length, (i) {
          final stages = _buildStages(Strings.of(context));
          final state = i < _stageIndex
              ? 1
              : i == _stageIndex
              ? 0
              : -1;
          final Widget leading = state == 1
              ? Icon(Icons.check_circle, size: 18, color: colors.success)
              : state == 0
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.error,
                  ),
                )
              : Icon(
                  Icons.radio_button_unchecked,
                  size: 18,
                  color: colors.textDisabled,
                );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    stages[i].label,
                    style: TextStyle(
                      fontSize: 13,
                      color: state == -1
                          ? colors.textDisabled
                          : colors.textPrimary,
                      fontWeight: state == 0
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 16),
        _terminalCard(colors),
        const SizedBox(height: 18),
        Center(
          child: TextButton.icon(
            icon: Icon(
              Icons.close_rounded,
              size: 16,
              color: colors.textDisabled,
            ),
            label: Text(
              Strings.of(context).lunCancelProcess,
              style: TextStyle(color: colors.textDisabled),
            ),
            onPressed: _cancel,
          ),
        ),
      ],
    );
  }

  Widget _doneView(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HermesStatusIndicator(
              mood: HermesSparkMood.success,
              size: 60,
            ),
            const SizedBox(height: 18),
            Text(
              str.lunDoneTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              str.lunDoneBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            HermesPrimaryButton(
              label: str.lunGoHome,
              icon: Icons.home_rounded,
              onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
            ),
          ],
        ),
      ),
    );
  }

  Widget _partialView(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HermesStatusIndicator(
              mood: HermesSparkMood.error,
              size: 60,
            ),
            const SizedBox(height: 18),
            Text(
              str.lunPartialTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            if (_warnings.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.warning.withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _warnings
                      .map(
                        (w) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 14,
                                color: colors.warning,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  w,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textPrimary,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              str.lunPartialBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            HermesPrimaryButton(
              label: str.lunRetry,
              icon: Icons.cleaning_services_rounded,
              onTap: _startUninstall,
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(str.lunBack),
            ),
          ],
        ),
      ),
    );
  }

  /// La desinstalación nunca llegó a arrancar (Termux rechazó el comando y el
  /// bootstrap no lo resolvió): dice la causa probable y ofrece acciones en
  /// vez de un "cancelada" engañoso con solo "volver".
  Widget _notStartedView(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HermesStatusIndicator(
              mood: HermesSparkMood.error,
              size: 60,
            ),
            const SizedBox(height: 18),
            Text(
              Strings.of(context).lunStartFailedTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              Strings.of(context).lunStartFailedBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            HermesPrimaryButton(
              label: str.lunRetry,
              icon: Icons.refresh_rounded,
              onTap: _startUninstall,
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(Strings.of(context).uninstallOpenTermux),
              onPressed: _termux.bootstrapExternalApps,
            ),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(str.lunBack),
            ),
          ],
        ),
      ),
    );
  }

  Widget _canceledView(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HermesStatusIndicator(
              mood: HermesSparkMood.error,
              size: 60,
            ),
            const SizedBox(height: 18),
            Text(
              str.lunCanceledTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              str.lunCanceledBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            HermesPrimaryButton(
              label: str.lunBack,
              icon: Icons.arrow_back_rounded,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _terminalCard(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.terminal_rounded, size: 13, color: colors.textDisabled),
            const SizedBox(width: 6),
            Text(
              str.lunTerminalLabel,
              style: TextStyle(
                fontSize: 11,
                color: colors.textDisabled,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 260,
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
          ),
          child: _logTail.isEmpty
              ? Center(
                  child: Text(
                    str.lunTerminalWaiting,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textDisabled,
                      fontFamily: 'monospace',
                    ),
                  ),
                )
              : ListView(
                  reverse: true,
                  children: _logTail.reversed
                      .map(
                        (l) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Text(
                            l,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.35,
                              color: l.toLowerCase().contains('error') ||
                                      l.toLowerCase().contains('fail')
                                  ? colors.error.withValues(alpha: 0.9)
                                  : l.toLowerCase().contains('ok') ||
                                          l.toLowerCase().contains('done') ||
                                          l.toLowerCase().contains('eliminado')
                                      ? colors.success.withValues(alpha: 0.9)
                                      : colors.textSecondary,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }
}
