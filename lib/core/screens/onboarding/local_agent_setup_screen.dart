// Configuración del agente Hermes local en este Android.
//
// Dos caminos honestos:
//   • Runtime local (recomendado): agente Hermes completo, CONTROLABLE desde la
//     Consola (Gateway :8642 / Dashboard :9119 en localhost). Instalación
//     guiada (instalar runtime si falta → lanzar instalador → autodetección →
//     conectar). Fallback de pairing manual (pegar URL/token).
//   • App Hermes Agent (simple): instalar/abrir la app de F-Droid; se usa por su
//     cuenta (no controlable desde la Consola, sin API inter-app).
//
// Nada se instala/ejecuta sin acción del usuario. Sin inventar puertos: el único
// endpoint local usado es el Gateway documentado 127.0.0.1:8642.
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/agent_runtime/agent_runtime.dart';
import '../../services/agent_runtime/local_termux_agent_provider.dart';
import '../../services/connection_manager.dart';
import '../../services/platform/android_apps.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_notice.dart';
import '../../widgets/hermes_ui.dart';
import '../instance_edit_screen.dart';
import 'local_install_screen.dart';
import 'local_uninstall_screen.dart';
import '../../widgets/hermes_app_bar.dart';

class LocalAgentSetupScreen extends StatefulWidget {
  final ConnectionManager connManager;
  const LocalAgentSetupScreen({required this.connManager, super.key});

  @override
  State<LocalAgentSetupScreen> createState() => _LocalAgentSetupScreenState();
}

class _LocalAgentSetupScreenState extends State<LocalAgentSetupScreen>
    with WidgetsBindingObserver {
  static const AppBridge _bridge = AndroidApps();
  late final LocalTermuxAgentProvider _termux;

  AgentRuntimeStatus? _termuxStatus;
  bool _termuxInstalled = false;
  bool _busy = false;
  bool _starting = false; // arrancando un agente ya instalado y sondeando vida
  bool _probing = false; // sondeando el FS de Termux (instalado vs ausente)
  bool _installRunning = false; // hay una instalación en curso → ofrecer retomar

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _termux = LocalTermuxAgentProvider(apps: _bridge);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _termux.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Al volver (p.ej. de arrancar el agente en Termux la primera vez) se
    // re-sondea: un agente que arrancó tras abrir esta pantalla se detecta
    // solo, sin obligar a salir y entrar de nuevo.
    if (state == AppLifecycleState.resumed && !_busy) _refresh();
  }

  Future<void> _refresh() async {
    final t = await _termux.status();
    final installed = await _termux.isTermuxInstalled();
    if (!mounted) return;
    // Con Termux presente pero el agente sin responder (estados `installed` o
    // `needsSetup`), la VERDAD la da la sonda del FS de Termux, NO el marcador
    // persistido: éste puede quedar obsoleto si el usuario desinstaló Hermes por
    // fuera de la app (entonces el marcador decía «instalado» → «Arrancar» un
    // agente inexistente que nunca respondía). Sondeamos SIEMPRE en ese caso,
    // mostrando «Comprobando…» para no parpadear, y corregimos el marcador en
    // AMBOS sentidos. Sólo si la sonda es inconcluyente (null: sin
    // allow-external-apps / timeout) conservamos el marcador como mejor pista.
    final needsProbe = (t == AgentRuntimeStatus.installed ||
            t == AgentRuntimeStatus.needsSetup) &&
        !_busy;
    setState(() {
      _termuxStatus = t;
      _termuxInstalled = installed;
      _probing = needsProbe;
      _installRunning = false;
    });
    if (!needsProbe) return;
    // ¿Hay una instalación EN CURSO ahora mismo? Entonces no sondeamos el FS ni
    // ofrecemos arrancar/instalar (el agente está a-medias): mostramos «Ver
    // progreso» para RETOMAR la instalación, que se reanuda sola al reabrirse.
    final installing = await _termux.isInstallRunning();
    if (!mounted) return;
    if (installing) {
      setState(() {
        _installRunning = true;
        _probing = false;
      });
      return;
    }
    final probed = await _termux.probeAgentInstalled();
    if (!mounted) return;
    if (probed == true) {
      await AgentRuntimeConsts.setAgentInstalled(true);
    } else if (probed == false) {
      await AgentRuntimeConsts.setAgentInstalled(false);
    }
    // probed == null → no tocamos el marcador (sonda no concluyente).
    final resolved = await _termux.status();
    if (!mounted) return;
    setState(() {
      _termuxStatus = resolved; // installed → Arrancar / needsSetup → Instalar
      _probing = false;
    });
  }

  Future<void> _connectDetected() async {
    setState(() => _busy = true);
    try {
      await _termux.ensureLocalConnection(widget.connManager);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Arranca un agente ya instalado en Termux y conecta en cuanto responde.
  ///
  /// La app no puede leer el sistema de archivos de Termux, así que no sabe si
  /// Hermes está instalado-pero-parado o no instalado: ambos casos caen en
  /// `needsSetup`. Arrancar es inofensivo — si no estuviera instalado, el
  /// comando falla y :9119 nunca responde, y caemos a ofrecer la instalación.
  Future<void> _startAndConnect() async {
    setState(() {
      _busy = true;
      _starting = true;
    });
    try {
      await _termux.startAgent();
      // El dashboard + gateway (Python en frío) puede tardar; sondeamos hasta 45s.
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      var up = false;
      while (DateTime.now().isBefore(deadline)) {
        if (!mounted) return;
        if (await _termux.isAgentRunning(
          timeout: const Duration(milliseconds: 1500),
        )) {
          up = true;
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!mounted) return;
      if (up) {
        await _termux.ensureLocalConnection(widget.connManager);
        if (mounted) Navigator.pop(context, true);
        return;
      }
      // No respondió: probablemente no está instalado. Ofrecer la instalación.
      await _refresh();
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).lasStartFailed),
          duration: const Duration(seconds: 5),
        ),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _starting = false;
        });
      }
    }
  }

  /// Instala el runtime local; si no hay tienda disponible, lo dice y da el enlace.
  Future<void> _installTermux() async {
    final ok = await _termux.installTermux();
    if (ok || !mounted) return;
    final colors = Theme.of(context).hermes;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final s = Strings.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          icon: Icon(Icons.error_outline, color: colors.warning, size: 26),
          title: Text(
            s.lasNoStoreTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.lasNoStoreBody,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(Strings.of(ctx).lasClose),
            ),
          ],
        );
      },
    );
  }

  /// Abre la instalación con seguimiento en vivo (barra por etapas + log).
  void _openInstaller() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => LocalInstallScreen(connManager: widget.connManager),
          ),
        )
        .then((_) {
          if (mounted) _refresh();
        });
  }

  Future<void> _manualPairing() async {
    final str = Strings.of(context);
    // Draft SIN identidad: se pasa como `prefill` (no `initial`) para que el
    // editor sea un alta de verdad — id UUID real al guardar y token
    // obligatorio; con `initial` se guardaba una conexión con id '' en
    // ConnectionManager y Keystore (spec 028 A-005).
    final draft = SavedConnection(
      id: '',
      label: str.lasConnectionLabel,
      host: AgentRuntimeConsts.localHost,
      // El agente local sirve toda su API (chat/sesiones/estado) en el dashboard
      // :9119; el gateway :8642 es de mensajería y no expone HTTP.
      port: AgentRuntimeConsts.localDashboardPort,
      apiKey: '',
      dashboardUrl:
          'http://${AgentRuntimeConsts.localHost}:${AgentRuntimeConsts.localDashboardPort}',
      kind: InstanceKind.localhost,
      // Servicios en este mismo dispositivo: no reescribir 127.0.0.1→10.0.2.2.
      onDeviceLoopback: true,
    );
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            InstanceEditScreen(connManager: widget.connManager, prefill: draft),
      ),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(
          str.lasScreenTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: colors.accentHover,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: str.lasRecheck,
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            _termuxCard(colors),
            const SizedBox(height: 14),
            Center(
              child: TextButton.icon(
                onPressed: _manualPairing,
                icon: const Icon(Icons.link, size: 16),
                label: Text(str.lasManualPairing),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tarjeta del agente local controlable ─────────────────────────────
  Widget _termuxCard(HermesThemeColors colors) {
    final status = _termuxStatus;
    final str = Strings.of(context);
    return _Card(
      colors: colors,
      icon: Icons.terminal_rounded,
      title: str.lasCardTitle,
      subtitle: str.lasCardSubtitle,
      child: status == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Detección del runtime local, siempre visible.
                _statusLine(
                  colors,
                  _termuxInstalled,
                  _termuxInstalled
                      ? str.lasRuntimeDetected
                      : str.lasRuntimeMissing,
                ),
                const SizedBox(height: 12),
                if (status == AgentRuntimeStatus.ready) ...[
                  // Agente vivo en :9119 → SÓLO conectar.
                  _statusLine(colors, true, str.lasAgentDetected),
                  const SizedBox(height: 12),
                  HermesPrimaryButton(
                    label: _busy ? str.lasConnecting : str.lasConnect,
                    icon: Icons.bolt_rounded,
                    onTap: _busy ? null : _connectDetected,
                  ),
                ] else if (_installRunning) ...[
                  // Hay una instalación en curso (el wrapper sigue vivo). No
                  // sondeamos ni ofrecemos arrancar/instalar: dejamos RETOMAR el
                  // seguimiento (la pantalla de instalación se reanuda sola).
                  Text(
                    str.lasInstalling,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  HermesPrimaryButton(
                    label: str.lasViewProgress,
                    icon: Icons.downloading_rounded,
                    onTap: _busy ? null : _openInstaller,
                  ),
                ] else if (_probing) ...[
                  // Sondeando el FS de Termux (instalado real vs ausente): no
                  // mostramos «Arrancar» NI «Instalar» hasta tener la verdad, para
                  // no mandar a arrancar un agente que el usuario ya desinstaló.
                  Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          str.lasChecking,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (status == AgentRuntimeStatus.installed) ...[
                  // Agente REALMENTE instalado (sonda confirmó el venv) pero
                  // parado → SÓLO arrancar y conectar. No se ofrece instalar.
                  Text(
                    str.lasStartInstalledBody,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  HermesPrimaryButton(
                    label: _starting ? str.lasStarting : str.lasStartConnect,
                    icon: Icons.bolt_rounded,
                    onTap: _busy ? null : _startAndConnect,
                  ),
                  if (_starting) ...[
                    const SizedBox(height: 8),
                    Text(
                      str.lasStartingHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textDisabled,
                      ),
                    ),
                  ],
                ] else if (status == AgentRuntimeStatus.needsSetup) ...[
                  // Termux presente y la sonda confirmó que el agente NO está
                  // instalado (o no pudo sondear) → SÓLO instalar.
                  Text(
                    str.lasInstallAgentBody,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  HermesPrimaryButton(
                    label: str.lasInstallAgent,
                    icon: Icons.download_rounded,
                    onTap: _busy ? null : _openInstaller,
                  ),
                ] else ...[
                  // notInstalled = falta el runtime Termux → instalarlo primero.
                  Text(
                    str.lasNeedRuntimeBody,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  HermesPrimaryButton(
                    label: str.lasInstallRuntime,
                    icon: Icons.download_rounded,
                    onTap: _installTermux,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    str.lasAfterInstall,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textDisabled,
                    ),
                  ),
                ],
                // «Desinstalar» sólo tiene sentido si el agente EXISTE
                // (corriendo o instalado-parado); nunca si no hay nada que quitar
                // ni mientras aún se está comprobando.
                if (!_probing &&
                    !_installRunning &&
                    (status == AgentRuntimeStatus.ready ||
                        status == AgentRuntimeStatus.installed)) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 15,
                        color: colors.error,
                      ),
                      label: Text(
                        str.lasUninstall,
                        style: TextStyle(color: colors.error, fontSize: 12),
                      ),
                      onPressed: () => Navigator.of(context)
                          .push(
                            MaterialPageRoute(
                              builder: (_) => LocalUninstallScreen(
                                connManager: widget.connManager,
                              ),
                            ),
                          )
                          .then((_) {
                            if (mounted) _refresh();
                          }),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _statusLine(HermesThemeColors colors, bool ok, String text) {
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.error_outline,
          size: 16,
          color: ok ? colors.success : colors.warning,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final HermesThemeColors colors;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  const _Card({
    required this.colors,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
