// Panel de control nativo para la instancia local de Hermes (Termux).
//
// Se abre desde GatewayManagerScreen cuando conn.kind == InstanceKind.localhost,
// en lugar del editor de instancias remotas (InstanceEditScreen). Ofrece:
//   A) Estado en vivo (polling cada 3 s) con uptime aproximado
//   B) Botones de arranque / parada
//   C) Formulario de reconfiguración (proveedor · modelo · API key)
//   D) Visor de logs colapsable
//   E) Información del sistema (host, dashboard, versión)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/agent_runtime/agent_runtime.dart';
import '../services/agent_runtime/local_termux_agent_provider.dart';
import '../services/bridge_manager.dart';
import '../services/connection_manager.dart';
import '../services/platform/android_apps.dart';
import '../theme/app_theme.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart';
import 'models_screen.dart';
import 'onboarding/local_install_screen.dart';
import 'onboarding/local_uninstall_screen.dart';

/// Estado del Mobile Bridge tal como lo presenta la UI del control local.
enum _BridgeUi {
  checking, // sondeando
  connected, // bridge activo y enlazado (token válido)
  unlinked, // bridge corriendo pero sin enlazar (token/clave no coincide)
  notDetected, // no responde / no desplegado
}

class LocalInstanceControlScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;

  const LocalInstanceControlScreen({
    required this.connection,
    required this.connManager,
    super.key,
  });

  @override
  State<LocalInstanceControlScreen> createState() =>
      _LocalInstanceControlScreenState();
}

class _LocalInstanceControlScreenState
    extends State<LocalInstanceControlScreen> with WidgetsBindingObserver {
  static const AppBridge _bridge = AndroidApps();

  late final LocalTermuxAgentProvider _termux;

  // ── Estado en vivo ────────────────────────────────────────────────────────
  bool _isRunning = false;
  bool _installRunning = false; // hay instalación/reparación en curso → reanudar
  DateTime? _runningSince;
  Timer? _poll;
  bool _acting = false;
  Timer? _actingTimer;
  // Evita que las sondas de estado se solapen: el poll dispara cada 3 s pero
  // isAgentRunning() puede tardar hasta 5 s, y bajo carga (descarga de un
  // modelo) se acumularían peticiones sobre el mismo cliente HTTP.
  bool _refreshing = false;
  // Fallos de sonda consecutivos. Un único fallo transitorio (resize de
  // ventana que suspende los Timer, o dispositivo saturado descargando) no debe
  // marcar el agente como caído; exigimos varios seguidos.
  int _failedProbes = 0;


  // Estado del Mobile Bridge (sección dedicada): sondeo + reparación.
  _BridgeUi _bridgeUi = _BridgeUi.checking;
  bool _bridgeBusy = false;
  String? _bridgeMsg;
  // Último estado completo del sondeo (URL probada + causa real del fallo), para
  // el diagnóstico en pantalla cuando el agente va pero el bridge no responde.
  BridgeState? _bridgeState;

  // ── Logs ─────────────────────────────────────────────────────────────────
  bool _logsExpanded = false;
  String? _logsContent;
  bool _fetchingLogs = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _termux = LocalTermuxAgentProvider(apps: _bridge);
    _refresh();
    _probeBridge();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  // ── Mobile Bridge: sondeo + reparación ────────────────────────────────────
  // El bridge se despliega y arranca DENTRO del arranque del agente. Por eso
  // tanto "no detectado" como "sin enlazar" se resuelven reiniciando el agente
  // (re-despliega el bridge con la clave canónica). "Reintentar enlace" prueba
  // la provisión sin reiniciar, por si las claves ya coinciden.

  BridgeManager? get _bridgeManager =>
      context.findAncestorStateOfType<HermesAppState>()?.bridgeManager;

  Future<void> _probeBridge() async {
    final mgr = _bridgeManager;
    if (mgr == null) {
      if (mounted) setState(() => _bridgeUi = _BridgeUi.notDetected);
      return;
    }
    final st = await mgr.probe(widget.connection.id);
    if (!mounted) return;
    setState(() {
      _bridgeState = st;
      _bridgeUi = switch (st.status) {
        BridgeStatus.connected => _BridgeUi.connected,
        BridgeStatus.needsToken ||
        BridgeStatus.authFailed =>
          _BridgeUi.unlinked,
        _ => _BridgeUi.notDetected,
      };
    });
  }

  /// Intenta enlazar (provisión) sin reiniciar el agente.
  Future<void> _retryLink() async {
    final mgr = _bridgeManager;
    if (mgr == null || _bridgeBusy) return;
    setState(() {
      _bridgeBusy = true;
      _bridgeMsg = null;
    });
    bool ok;
    try {
      ok = await mgr.tryProvision(widget.connection.id);
    } catch (e) {
      debugPrint('[instance-control] excepción silenciada (fallback: ok = false): $e');
      ok = false;
    }
    if (!mounted) return;
    await _probeBridge();
    if (!mounted) return;
    setState(() {
      _bridgeBusy = false;
      _bridgeMsg = ok ? null : Strings.of(context).licBridgeRetryFailed;
    });
  }

  /// Reinicia el agente: re-despliega el bridge con la clave canónica y vuelve
  /// a enlazar. Resuelve el desajuste de clave y el bridge no desplegado.
  /// Lee `~/.hermes/bridge.out` desde Termux y lo muestra en un diálogo, para
  /// ver el error real por el que el bridge no levanta (sin abrir Termux).
  Future<void> _showBridgeLog() async {
    setState(() => _bridgeBusy = true);
    String? log;
    try {
      log = await _termux.readBridgeLog();
    } catch (e) {
      log = 'Could not read the log: $e';
    }
    if (!mounted) return;
    setState(() => _bridgeBusy = false);
    final colors = Theme.of(context).hermes;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: const Text('Log del bridge'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              log ??
                  'No log yet (~/.hermes/bridge.out is empty, or Termux did not '
                      'respond). Tap "Install & start" and try again.',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: colors.textPrimary,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// Fila etiqueta/valor del bloque de diagnóstico del bridge (mono, copiable).
  Widget _diagRow(String label, String value, HermesThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: colors.textSecondary)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                color: colors.textPrimary,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _repairBridge() async {
    if (_bridgeBusy) return;
    setState(() {
      _bridgeBusy = true;
      _bridgeMsg = null;
    });
    try {
      // Reinicio DIRIGIDO del bridge (no de todo el agente): mata el bridge
      // viejo y lo arranca con el token actual. Más fiable y sin tumbar el
      // dashboard/gateway.
      final dispatched = await _termux.restartBridge();
      if (!dispatched) {
        // Termux ni aceptó el comando (no instalado / sin permiso): el bridge no
        // se va a instalar por mucho que esperemos. Avisamos al instante en vez
        // de fingir que está en marcha y dejar el panel en "Not detected".
        if (mounted) {
          setState(() => _bridgeBusy = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).licStartTermuxRejected)),
          );
        }
        return;
      }
      // El bridge tarda unos segundos en levantar y reenlazar el puerto.
      await Future.delayed(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[instance-control] excepción silenciada (se ignora sin más): $e');}
    if (!mounted) return;
    // Con el bridge ya arrancado con el token actual, enlaza.
    final mgr = _bridgeManager;
    if (mgr != null) {
      try {
        await mgr.tryProvision(widget.connection.id);
      } catch (e) {
        debugPrint('[instance-control] excepción silenciada (se ignora sin más): $e');}
    }
    if (!mounted) return;
    await _probeBridge();
    if (mounted) setState(() => _bridgeBusy = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // OJO: los Timer de Dart NO se suspenden en background (solo los Tickers
    // vsync): hay que parar la sonda a mano o sigue quemando CPU cada 3 s con
    // la app pausada (spec 028). Al volver (incluye el paso paused→resumed de
    // un resize multi-ventana/plegable/DeX), re-sincroniza de inmediato y
    // re-arma la sonda.
    if (state == AppLifecycleState.resumed) {
      _failedProbes = 0;
      _refresh();
      _poll ??= Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _actingTimer?.cancel();
    _termux.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    // Sondas no solapadas: si una anterior sigue en vuelo, dejamos que termine.
    if (_refreshing) return;
    _refreshing = true;
    bool running;
    bool installRunning = false;
    try {
      running = await _termux.isAgentRunning();
      // Si el agente no responde puede haber una instalación/reparación EN CURSO
      // (lanzada desde aquí y dejada en segundo plano al pulsar «atrás»). La
      // detectamos para ofrecer «Ver progreso» y poder volver a ella.
      if (!running) installRunning = await _termux.isInstallRunning();
    } finally {
      _refreshing = false;
    }
    if (!mounted) return;
    if (_installRunning != installRunning) {
      setState(() => _installRunning = installRunning);
    }
    if (running) {
      _failedProbes = 0;
    } else if (_isRunning) {
      // Estaba online y la sonda falló: probablemente transitorio (resize de
      // ventana o descarga saturando el dispositivo). Mantenemos "online" un
      // ciclo más y solo lo damos por caído tras 2 fallos consecutivos, para no
      // "desconectar" en falso ni bloquear la reconexión.
      if (++_failedProbes < 2) return;
    }
    setState(() {
      if (running && !_isRunning) _runningSince ??= DateTime.now();
      if (!running) _runningSince = null;
      _isRunning = running;
    });
  }

  // ── Controles ─────────────────────────────────────────────────────────────

  Future<void> _startAgent() async {
    setState(() => _acting = true);
    final dispatched = await _termux.startAgent();
    if (!dispatched) {
      // Termux ni siquiera aceptó el comando (no instalado / sin permiso): no
      // tiene sentido esperar 20 s a que suba el gateway. Avisamos al instante.
      if (mounted) {
        setState(() => _acting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).licStartTermuxRejected)),
        );
      }
      return;
    }
    _actingTimer?.cancel();
    // El gateway puede tardar 10-15 s en bind al puerto en Android. Reintentamos
    // cada 2 s durante 20 s antes de rendirnos y mostrar offline.
    int attempts = 0;
    _actingTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      attempts++;
      await _refresh();
      if (_isRunning || attempts >= 10) {
        t.cancel();
        if (mounted) setState(() => _acting = false);
        // Si tras los reintentos sigue offline, muestra el log del gateway
        // (servido ~60 s por el servidor de diagnóstico) para ver el fallo.
        if (!_isRunning && attempts >= 10) {
          await _showGatewayLog();
        }
      }
    });
  }

  /// Muestra el log del gateway en un diálogo cuando el arranque falló. Lee del
  /// servidor de diagnóstico temporal (:8645). Si no responde, lo indica.
  Future<void> _showGatewayLog() async {
    final log = await _termux.fetchGatewayLog();
    if (!mounted) return;
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final hasLog = log != null && log.trim().isNotEmpty;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          str.licGatewayLogTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            hasLog ? log : str.licGatewayLogUnavail,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        actions: [
          if (hasLog)
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: log));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(str.licLogCopied,
                        style: const TextStyle(fontSize: 12)),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Text(str.licCopy),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(str.licClose),
          ),
        ],
      ),
    );
  }

  Future<void> _stopAgent() async {
    setState(() => _acting = true);
    await _termux.stopAgent();
    _actingTimer?.cancel();
    _actingTimer = Timer(const Duration(seconds: 5), () async {
      await _refresh();
      if (mounted) setState(() => _acting = false);
    });
  }

  // ── Logs ──────────────────────────────────────────────────────────────────

  Future<void> _fetchLogs() async {
    setState(() => _fetchingLogs = true);
    final logs = await _termux.readAgentLogs();
    if (mounted) {
      setState(() {
        _logsContent = logs;
        _fetchingLogs = false;
      });
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _uptimeLabel() {
    final since = _runningSince;
    if (since == null) return '';
    final d = DateTime.now().difference(since);
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }
  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(widget.connection.label),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
        children: [
          _buildStatusSection(colors),
          const SizedBox(height: 16),
          _buildControlsSection(colors),
          const SizedBox(height: 16),
          _buildModelSummary(colors),
          const SizedBox(height: 16),
          _buildBridgeSection(colors),
          const SizedBox(height: 16),
          _buildLogsSection(colors),
          const SizedBox(height: 16),
          _buildSystemInfoSection(colors),
        ],
      ),
    );
  }

  // ── A) Estado ─────────────────────────────────────────────────────────────

  Widget _buildStatusSection(HermesThemeColors colors) {
    final str = Strings.of(context);
    final dotColor = _acting
        ? colors.accent
        : _isRunning
            ? colors.success
            : colors.error;

    return AccentCard(
      accent: _isRunning ? colors.success : colors.error,
      accentWidth: 2.5,
      background: colors.surfaceVariant.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _acting
                        ? str.licUpdating
                        : _isRunning
                            ? str.licRunning
                            : str.licStopped,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (_isRunning && _runningSince != null)
                    Text(
                      str.licUptime(_uptimeLabel()),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (_acting)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colors.accent,
                ),
              )
            else
              HermesPill(
                color: _isRunning ? colors.success : colors.error,
                label: _isRunning ? 'online' : 'offline',
              ),
          ],
        ),
      ),
    );
  }

  // ── B) Controles ──────────────────────────────────────────────────────────

  Widget _buildControlsSection(HermesThemeColors colors) {
    final str = Strings.of(context);
    // Hay una instalación/reparación EN CURSO (dejada en 2º plano al pulsar
    // «atrás»): la prioridad es PODER VOLVER a ella, no arrancar/reparar de nuevo.
    if (_installRunning) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HermesSectionHeader(str.licControlsSection),
          HermesPrimaryButton(
            label: str.licResumeRepair,
            icon: Icons.downloading_rounded,
            onTap: _acting ? null : _openRepairProgress,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, top: 6),
            child: Text(
              str.licResumeRepairHint,
              style: TextStyle(fontSize: 11, color: colors.textDisabled),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(str.licControlsSection),
        if (_isRunning)
          _buildStopButton(colors)
        else
          HermesPrimaryButton(
            label: str.licStartAgent,
            icon: Icons.play_arrow_rounded,
            onTap: _acting ? null : _startAgent,
          ),
        const SizedBox(height: 10),
        // Reparación: reconstruye el venv de Python (dependencias con ABI rota,
        // p.ej. cryptography → el gateway no arranca) SIN perder configuración.
        // Alternativa a desinstalar+reinstalar.
        TextButton.icon(
          icon: Icon(Icons.healing_rounded, size: 16, color: colors.accent),
          label: Text(
            str.licRepairAgent,
            style: TextStyle(color: colors.accent, fontSize: 12.5),
          ),
          onPressed: _acting ? null : _repairAgent,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
          child: Text(
            str.licRepairHint,
            style: TextStyle(fontSize: 11, color: colors.textDisabled),
          ),
        ),
        // Desinstalar: faltaba un acceso desde el control local (solo existía en
        // onboarding/home), así que un agente ya instalado no tenía forma de
        // desinstalarse desde aquí. Estilo destructivo sutil.
        TextButton.icon(
          icon: Icon(
            Icons.delete_outline_rounded,
            size: 16,
            color: colors.error,
          ),
          label: Text(
            str.lasUninstall,
            style: TextStyle(color: colors.error, fontSize: 12.5),
          ),
          onPressed: _acting
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        LocalUninstallScreen(connManager: widget.connManager),
                  ),
                ),
        ),
      ],
    );
  }

  /// Vuelve a la pantalla de progreso de una instalación/reparación en curso
  /// (se reanuda sola al reabrirse). Al volver, refresca el estado.
  Future<void> _openRepairProgress() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            LocalInstallScreen(connManager: widget.connManager, repair: true),
      ),
    );
    if (mounted) _refresh();
  }

  /// Abre el flujo de REPARACIÓN (reconstruye el venv conservando datos). Tras
  /// volver, refresca el estado por si el agente ya arranca.
  Future<void> _repairAgent() async {
    final str = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(str.licRepairConfirmTitle),
        content: Text(str.licRepairConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(str.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(str.licRepairAgent),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            LocalInstallScreen(connManager: widget.connManager, repair: true),
      ),
    );
    if (mounted) _refresh();
  }

  Widget _buildStopButton(HermesThemeColors colors) {
    final str = Strings.of(context);
    final enabled = !_acting;
    return GestureDetector(
      onTap: enabled ? _stopAgent : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: enabled
              ? colors.error.withValues(alpha: 0.10)
              : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? colors.error.withValues(alpha: 0.45)
                : colors.divider,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.stop_rounded,
              size: 18,
              color: enabled ? colors.error : colors.textDisabled,
            ),
            const SizedBox(width: 9),
            Text(
              str.licStopAgent,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: enabled ? colors.error : colors.textDisabled,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── C0) Mobile Bridge (estado + reparación) ──────────────────────────────

  Widget _buildBridgeSection(HermesThemeColors colors) {
    final str = Strings.of(context);
    final (IconData icon, Color dot, String title, String subtitle) =
        switch (_bridgeUi) {
      _BridgeUi.checking => (
          Icons.sync,
          colors.textSecondary,
          str.licBridgeChecking,
          '',
        ),
      _BridgeUi.connected => (
          Icons.link,
          colors.success,
          str.licBridgeConnected,
          str.licBridgeConnectedHint,
        ),
      _BridgeUi.unlinked => (
          Icons.link_off,
          colors.warning,
          str.licBridgeUnlinked,
          str.licBridgeUnlinkedHint,
        ),
      _BridgeUi.notDetected => (
          Icons.power_off,
          colors.textSecondary,
          str.licBridgeNotDetected,
          str.licBridgeNotDetectedHint,
        ),
    };

    final needsAction =
        _bridgeUi == _BridgeUi.unlinked || _bridgeUi == _BridgeUi.notDetected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(str.licBridgeSection),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: dot),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_bridgeBusy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: str.statusRefresh,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(4),
                      color: colors.accentHover,
                      onPressed: _probeBridge,
                    ),
                ],
              ),
              // Diagnóstico en pantalla: cuando el agente va pero el bridge no,
              // muestra la URL sondeada y la CAUSA real (rechazado/timeout/HTTP…)
              // más el último mensaje de la acción, para no depender de logcat.
              if (_bridgeUi != _BridgeUi.connected && _bridgeState != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Diagnostics',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: colors.textSecondary,
                          )),
                      const SizedBox(height: 6),
                      _diagRow('URL', _bridgeState!.url.isEmpty
                          ? '(sin URL)'
                          : _bridgeState!.url, colors),
                      _diagRow('Token',
                          _bridgeState!.hasToken ? 'sí' : 'no', colors),
                      if (_bridgeState!.errorDetail.isNotEmpty)
                        _diagRow('Causa', _bridgeState!.errorDetail, colors),
                      if (_bridgeMsg != null && _bridgeMsg!.isNotEmpty)
                        _diagRow('Último', _bridgeMsg!, colors),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _bridgeBusy ? null : _showBridgeLog,
                          icon: Icon(Icons.article_outlined,
                              size: 16, color: colors.accent),
                          label: Text('Ver log del bridge',
                              style: TextStyle(color: colors.accent)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (needsAction) ...[
                const SizedBox(height: 14),
                HermesPrimaryButton(
                  label: _bridgeUi == _BridgeUi.notDetected
                      ? str.licBridgeInstall
                      : str.licBridgeRepair,
                  icon: Icons.restart_alt,
                  onTap: _bridgeBusy ? null : _repairBridge,
                ),
                if (_bridgeUi == _BridgeUi.unlinked) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _bridgeBusy ? null : _retryLink,
                      icon: Icon(Icons.cable, size: 16, color: colors.accentHover),
                      label: Text(
                        str.licBridgeRetry,
                        style: TextStyle(color: colors.accentHover),
                      ),
                    ),
                  ),
                ],
              ],
              if (_bridgeMsg != null) ...[
                const SizedBox(height: 6),
                Text(
                  _bridgeMsg!,
                  style: TextStyle(fontSize: 12, color: colors.error),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── C) Modelo (resumen) ───────────────────────────────────────────────────
  // Camino principal: resumen del modelo activo + "Cambiar modelo" → pantalla
  // dedicada de Modelos. El formulario completo (proveedor/API key/OAuth/Ollama)
  // queda plegado tras "Configuración avanzada" para no abrumar aquí.

  Widget _buildModelSummary(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(str.licModelSection),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ModelsScreen(connection: widget.connection),
            ),
          ),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.memory, size: 18, color: colors.accentHover),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        str.licManageModels,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        str.licChangeModel,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.accentHover,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: colors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── D) Logs ───────────────────────────────────────────────────────────────

  Widget _buildLogsSection(HermesThemeColors colors) {
    final str = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(str.licSystemLogsSection),
        AccentCard(
          background: colors.surfaceVariant.withValues(alpha: 0.3),
          child: InkWell(
            onTap: () {
              setState(() => _logsExpanded = !_logsExpanded);
              if (_logsExpanded && _logsContent == null) _fetchLogs();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _logsExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _logsExpanded ? str.licHideLogs : str.licShowLogs,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      if (_logsExpanded)
                        GestureDetector(
                          onTap: _fetchingLogs ? null : _fetchLogs,
                          child: Row(
                            children: [
                              Icon(Icons.refresh,
                                  size: 14, color: colors.accent),
                              const SizedBox(width: 4),
                              Text(
                                str.licRefreshLogs,
                                style: TextStyle(
                                    fontSize: 11, color: colors.accent),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (_logsExpanded) ...[
                    const SizedBox(height: 10),
                    if (_fetchingLogs)
                      TuiLoader(label: str.licReadingLogs)
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colors.background,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          _logsContent ?? str.licLogsNotAvailable,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            height: 1.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── E) Información del sistema ─────────────────────────────────────────────

  Widget _buildSystemInfoSection(HermesThemeColors colors) {
    final str = Strings.of(context);
    // La API local (chat/sesiones/estado) vive en el dashboard :9119; el gateway
    // :8642 es de mensajería y no se usa, así que no se muestra.
    final dashboard =
        '${AgentRuntimeConsts.localHost}:${AgentRuntimeConsts.localDashboardPort}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(str.licSysInfoSection),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: colors.divider.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              _infoRow(colors, str.licApiLocal, dashboard),
              _infoRow(colors, str.licAgentVersion, '-'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoRow(HermesThemeColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style:
                  TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      Strings.of(context).licCopied(value),
                      style: const TextStyle(fontSize: 13),
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
