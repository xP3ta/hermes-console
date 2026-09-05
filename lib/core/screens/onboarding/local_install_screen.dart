// Instalación del agente Hermes local con SEGUIMIENTO EN VIVO.
//
// Premium: lanza el instalador en Termux por RUN_COMMAND (silencioso) usando un
// wrapper que sirve su propio log por localhost (:8643). La app hace polling de
// ese log y pinta una barra por etapas + el paso actual + un mini-terminal real.
// Si Termux no permite apps externas (no hay progreso en ~10 s), salta una
// ventana para activarlo o para lanzarlo en Termux a mano — y el progreso en
// vivo funciona igual (el wrapper sirve el log se lance como se lance).
import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/agent_runtime/agent_runtime.dart';
import '../../services/agent_runtime/local_termux_agent_provider.dart';
import '../../services/agent_runtime/provider_catalog.dart';
import '../../services/bridge_manager.dart';
import '../../services/connection_manager.dart';
import '../../services/notifications/notification_service.dart';
import '../../services/platform/android_apps.dart';
import '../../services/secure_storage.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_spark_mascot.dart';
import '../../widgets/hermes_status_indicator.dart';
import '../../widgets/hermes_ui.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_premium_ui.dart';
import '../../../main.dart';
import '../../../l10n/app_localizations.dart';
import '../external_provider_screen.dart';

/// Una etapa de la instalación + las palabras clave que la detectan en el log.
class _Stage {
  final String label;
  final List<String> keys;
  const _Stage(this.label, this.keys);
}

const List<_Stage> _stages = [
  _Stage('Preparando Termux', [
    '@@stage preparando',
    'python found',
    'checking termux',
  ]),
  _Stage('Descargando instalador', ['@@stage descargando']),
  _Stage('Instalando dependencias', [
    '@@stage instalando',
    'installing git',
    'installing node',
    'pkg install',
    'node.js',
  ]),
  _Stage('Clonando el agente', [
    'cloning into',
    'git clone',
    'receiving objects',
  ]),
  _Stage('Instalando Python', [
    'collecting ',
    'building wheel',
    'building editable',
    'pip install',
    'installing build dependencies',
  ]),
  _Stage('Herramientas (npm)', [
    'npm ',
    'node_modules',
    'added ',
    'browser tools',
  ]),
  _Stage('Configurando', [
    'skip-setup',
    'setup',
    'configuring',
    'hermes_home',
    'venv',
  ]),
  _Stage('¡Listo!', [
    '@@done',
    'hermes_dashboard_ready',
    'installation complete',
    'install complete',
  ]),
];

// Modelo de IA local ejecutable vía ollama en Termux.
class _LocalModel {
  final String tag;
  final String name;
  final double ramGb;
  final String params;
  final String desc;
  const _LocalModel({
    required this.tag,
    required this.name,
    required this.ramGb,
    required this.params,
    required this.desc,
  });
}

// Modelos recomendados para Android, ordenados de menor a mayor exigencia de RAM.
List<_LocalModel> _localModelOptions(Strings s) => [
  _LocalModel(
    tag: 'qwen2.5:0.5b',
    name: 'Qwen 2.5 0.5B',
    ramGb: 0.8,
    params: '0.5B',
    desc: s.lisModelDescLight,
  ),
  _LocalModel(
    tag: 'llama3.2:1b',
    name: 'Llama 3.2 1B',
    ramGb: 1.2,
    params: '1B',
    desc: s.lisModelDescMeta1b,
  ),
  _LocalModel(
    tag: 'phi3:mini',
    name: 'Phi-3 Mini',
    ramGb: 2.2,
    params: '3.8B',
    desc: s.lisModelDescBalance,
  ),
  _LocalModel(
    tag: 'llama3.2:3b',
    name: 'Llama 3.2 3B',
    ramGb: 2.8,
    params: '3B',
    desc: s.lisModelDescMeta3b,
  ),
  _LocalModel(
    tag: 'mistral:7b',
    name: 'Mistral 7B',
    ramGb: 5.0,
    params: '7B',
    desc: s.lisModelDescPowerful,
  ),
  _LocalModel(
    tag: 'llama3.1:8b',
    name: 'Llama 3.1 8B',
    ramGb: 6.0,
    params: '8B',
    desc: s.lisModelDescHighQuality,
  ),
];

// ── Camino B: API en la nube / OAuth ─────────────────────────────────────────
// El catálogo de proveedores vive en `ProviderCatalog` (compartido con
// LocalInstanceControlScreen). El identificador es el que se escribe en
// config.yaml (model.provider); `AgentRuntimeConsts.envVarFor` lo mapea a su
// variable de entorno. Los providers OAuth no usan API key (token vía
// `hermes auth`).

class LocalInstallScreen extends StatefulWidget {
  final ConnectionManager connManager;

  /// Modo REPARACIÓN: en vez de instalar de cero, reconstruye el venv de Python
  /// roto (dependencias con ABI incompatible) conservando config/SOUL/skills.
  /// Mismo flujo y progreso; sólo cambia el comando lanzado y los textos.
  final bool repair;

  const LocalInstallScreen({
    required this.connManager,
    this.repair = false,
    super.key,
  });

  /// Clave en prefs que marca «hay una instalación en curso». Otras pantallas
  /// (p. ej. el setup local) la leen para ofrecer RETOMAR la instalación en vez
  /// de tratar el agente a-medias como instalado/ausente. El instalador reanuda
  /// el seguimiento al reabrirse (initState → resume).
  static const String prefKeyInProgress = 'local_install_in_progress';

  @override
  State<LocalInstallScreen> createState() => _LocalInstallScreenState();
}

class _LocalInstallScreenState extends State<LocalInstallScreen>
    with WidgetsBindingObserver {
  static const AppBridge _bridge = AndroidApps();
  static const String _prefKeyInProgress = 'local_install_in_progress';
  late final LocalTermuxAgentProvider _termux;

  /// Se vio progreso al menos una vez (el wrapper ya corre). Evita relanzar.
  bool _progressSeen = false;

  /// Notificación de fin de instalación: una sola vez por ejecución (la
  /// resetea [_retry]). Evita duplicar el aviso si el parser vuelve a entrar.
  bool _finishNotified = false;

  /// Servicio de notificaciones locales, cacheado del árbol mientras está
  /// montado para poder avisar aunque el usuario haya salido de la pantalla.
  NotificationService? _notif;
  NotificationService? get _notifications {
    if (_notif != null) return _notif;
    if (!mounted) return null;
    return _notif = context
        .findAncestorStateOfType<HermesAppState>()
        ?.notifications;
  }

  Timer? _poll;
  Timer? _clock; // refresca el cronómetro mm:ss cada segundo
  DateTime? _startedAt;
  int _stageIndex = 0;
  final List<String> _logTail = [];
  bool _connecting = false;
  bool _agentUp = false;
  bool _failed = false;
  bool _canceled = false; // el usuario abortó la instalación
  bool _canceling = false;
  int? _exitCode;
  int _noProgressTicks = 0;
  bool _fallbackShown = false;
  bool _fallbackDismissed = false; // el usuario eligió «seguir esperando»
  bool _launchedAuto = false;
  bool _foregroundLaunched = false; // se relanzó en primer plano: no duplicar
  // ── Auto-recuperación: si la instalación YA estaba avanzando y el proceso de
  // Termux muere (App Standby / OOM / crash del RunCommandService), el servidor
  // de progreso (:8643) deja de responder. En vez de colgarse y obligar a matar
  // la app, re-lanzamos la instalación automáticamente. El lock del wrapper lo
  // hace seguro: si el viejo sigue vivo, el nuevo sale solo; si murió, retoma.
  int _autoRetries = 0;
  static const int _maxAutoRetries = 3;
  static const int _autoRetryAfterTicks =
      8; // ~12 s de :8643 caído tras progresar

  // ── Bootstrap automático de allow-external-apps (etapa 0) ──────────────────
  // En un Termux recién instalado no existe ~/.termux/termux.properties, así que
  // RUN_COMMAND se rechaza en silencio. Antes de caer al diálogo que rompe el
  // flujo, abrimos Termux en primer plano una vez para activar la propiedad y
  // volver solos; al retomar el foco se reintenta el RUN_COMMAND real.
  Timer? _bootstrapTimer;
  bool _bootstrapTried =
      false; // ya se lanzó el bootstrap foreground (no repetir)
  bool _bootstrapping = false; // esperando a volver de Termux tras el bootstrap

  /// Margen tras lanzar el RUN_COMMAND silencioso antes de decidir que Termux lo
  /// rechazó (no hay señal del log) y disparar el bootstrap automático.
  static const Duration _bootstrapProbe = Duration(seconds: 5);
  bool _installSucceeded = false; // el wrapper terminó con @@EXIT 0
  DateTime? _installDoneAt; // momento del @@EXIT 0 (ventana de gracia)
  bool _installedNotRunning = false; // instalado OK pero el agente no responde
  bool _autoConnecting = false; // el agente levantó solo: conectando sin tap
  bool _starting = false; // el usuario pulsó «Arrancar agente»: sondeando vida
  String? _errorMsg;

  /// Tras un @@EXIT 0, el agente puede tardar en levantar (o no levantar: se
  /// instala con --skip-setup). Le damos esta ventana de gracia sondeando
  /// localhost antes de cerrar en el estado «instalado, sin arrancar».
  static const Duration _postInstallGrace = Duration(seconds: 25);

  /// Tras pulsar «Arrancar agente» damos una ventana más larga: arrancar el
  /// dashboard + gateway (Python en frío) puede tardar más que la gracia normal.
  static const Duration _startGrace = Duration(seconds: 45);
  String? _netWarning; // aviso de red en vivo (Termux no verifica conectividad)

  // Modo simulación (solo debug): reproduce las fases del installer sin Termux
  // real, para verificar el flujo de UI (progreso → error de red → éxito).
  bool _simulating = false;

  // ── Rutas del instalador (ADR-007) ────────────────────────────────────────
  // PRINCIPAL: instalación AUTOMÁTICA guiada (RUN_COMMAND con etapas + log en
  // vivo). Termux es sólo motor de ejecución: no se ofrece ruta manual ni
  // comandos copiables al usuario.
  // ── Detección de log congelado (ruta avanzada) ────────────────────────────
  // Si el log no cambia durante este tiempo mientras la instalación corre, se
  // avisa: probable mirror lento / pkg esperando. No marca fallo (puede
  // recuperarse), pero deja de parecer un cuelgue mudo.
  static const Duration _stallAfter = Duration(seconds: 40);
  String? _lastLogSnapshot;
  DateTime? _lastLogChange;
  String? _stallWarning;

  // Compatibilidad del dispositivo.
  bool _checking = true;
  bool _incompatible = false;
  String _incompatReason = '';
  String? _warning;
  String? _blockReason; // bloqueo transitorio (disco/red): reintentar

  // ── Dual-path post-instalación ────────────────────────────────────────────
  // Cuando la instalación termina con @@EXIT 0 pero el agente no arranca solo
  // (_installedNotRunning=true), el usuario elige entre modelo local (camino A)
  // o API en la nube (camino B). Camino A es el principal.
  DeviceInfo _deviceInfo = DeviceInfo.unknown;
  bool _showPathA = false;
  _LocalModel? _pickedModel;
  // Modelo personalizado de Ollama (tag escrito a mano, ej. llama3.2:1b).
  bool _customModelSelected = false;
  final TextEditingController _customModelCtrl = TextEditingController();
  // 0 = sin empezar, 1 = instalando ollama, 2 = descargando modelo,
  // 3 = configurando hermes, -1 = error
  int _ollamaPhase = 0;
  bool _ollamaCanceled = false;
  String? _ollamaError;
  String _ollamaSubLabel = '';

  // ── Camino B (secundario): API en la nube ─────────────────────────────────
  // Salida de rescate cuando Ollama no es viable. Escribe la config con
  // configureAgent(provider, model, apiKey) y arranca el agente reusando la
  // maquinaria de _startAgent (polling + auto-conexión).
  bool _showPathB = false;
  String _apiProvider = 'openai';
  final TextEditingController _apiModelCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  bool _apiKeyVisible = false;
  bool _apiConfiguring = false;
  bool _apiAuthenticating =
      false; // OAuth: flujo de login en curso (background)
  String? _apiError;
  String? _apiNotice; // mensaje informativo (p.ej. tras lanzar OAuth)
  // OAuth: polling del log (:8644) para extraer la URL de login sin abrir Termux.
  Timer? _apiAuthTimer;
  String? _apiAuthUrl;
  int _apiAuthElapsedSecs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _termux = LocalTermuxAgentProvider(apps: _bridge);
    // Si se abrió con una instalación ya en curso (el usuario salió y volvió),
    // reanudar el polling directamente sin relanzar el script.
    final resuming =
        widget.connManager.prefs.getBool(_prefKeyInProgress) == true;
    if (resuming) {
      _resumePolling();
    } else {
      _init();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Al volver de Termux (p.ej. tras el bootstrap de allow-external-apps), si
    // aún no hubo progreso, reintenta el lanzamiento automático: si ya está
    // permitido, arranca solo sin que el usuario toque nada más.
    if (_progressSeen ||
        _agentUp ||
        _failed ||
        _canceled ||
        _checking ||
        _incompatible ||
        _simulating ||
        _installSucceeded ||
        _installedNotRunning) {
      return;
    }
    // Volvemos del bootstrap foreground: la propiedad ya debería estar activa,
    // así que reintentamos el RUN_COMMAND real (ahora Termux lo aceptará).
    if (_bootstrapping) {
      setState(() {
        _bootstrapping = false;
        _noProgressTicks = 0;
      });
      _launchWorker();
      return;
    }
    if (!_foregroundLaunched) {
      _launchWorker();
    }
  }

  /// Lanza el worker adecuado según el modo: reparación (reconstruye el venv) o
  /// instalación de cero. Ambos comparten flujo, progreso (:8643) y parsing.
  Future<bool> _launchWorker() => widget.repair
      ? _termux.runRepairWithProgress()
      : _termux.runInstallerWithProgress();

  /// Comprueba compatibilidad antes de instalar: el agente necesita una ABI de
  /// 64 bits (arm64-v8a o x86_64) y RAM razonable. Si no, lo dice claramente.
  Future<void> _init() async {
    setState(() {
      _checking = true;
      _blockReason = null;
    });
    final info = await _bridge.deviceInfo();
    if (!mounted) return;
    _deviceInfo = info; // persiste para el filtro de modelos locales
    // 1) ABI de 64 bits — incompatibilidad permanente.
    final str = Strings.of(context);
    if (info.known && !info.is64bit) {
      setState(() {
        _checking = false;
        _incompatible = true;
        _incompatReason = str.lisIncompatCpu(
          info.abis.isEmpty ? 'desconocido' : info.abis.join(', '),
        );
      });
      return;
    }
    // 2) Espacio en disco (~3 GB: clonar + compilar wheels nativos).
    if (info.freeDiskBytes > 0 && info.freeDiskGb < 2.5) {
      setState(() {
        _checking = false;
        _blockReason = str.lisBlockDisk(info.freeDiskGb.toStringAsFixed(1));
      });
      return;
    }
    // 3) Red: ¿se alcanza el instalador? (evita empezar para morir a medias).
    final net = await _termux.installerReachable();
    if (!mounted) return;
    if (!net) {
      setState(() {
        _checking = false;
        _blockReason = str.lisBlockNet;
      });
      return;
    }
    // RAM baja: avisa pero no bloquea.
    if (info.known && info.totalRamGb > 0 && info.totalRamGb < 1.5) {
      _warning = str.lisWarningRam(info.totalRamGb.toStringAsFixed(1));
    }
    setState(() => _checking = false);
    // Ruta PRINCIPAL: instalación AUTOMÁTICA guiada (ADR-007). Lanzamos el
    // wrapper por RUN_COMMAND y mostramos progreso por etapas + log en vivo.
    await _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _clock?.cancel();
    _bootstrapTimer?.cancel();
    _apiAuthTimer?.cancel();
    _apiModelCtrl.dispose();
    _apiKeyCtrl.dispose();
    _customModelCtrl.dispose();
    _termux.dispose();
    super.dispose();
  }

  /// Reanuda el seguimiento de una instalación que ya está corriendo en Termux
  /// (el usuario salió de la app y volvió). No relanza el script.
  void _resumePolling() {
    _progressSeen = true;
    _checking = false;
    _startedAt = DateTime.now();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_agentUp && !_failed) setState(() {});
    });
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
  }

  Future<void> _start() async {
    // Marcar instalación en curso para que si el usuario sale y vuelve, la app
    // sepa que hay que reanudar el seguimiento.
    await widget.connManager.prefs.setBool(_prefKeyInProgress, true);
    // RUN_COMMAND silencioso. Si Termux lo bloquea, el bootstrap intenta
    // activar allow-external-apps y la UI ofrece reintento/cancelación.
    _startedAt = DateTime.now();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_agentUp && !_failed) setState(() {});
    });
    _launchedAuto = await _launchWorker();
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
    // Etapa 0: si en ~5 s el wrapper no da señal de vida (Termux rechazó el
    // RUN_COMMAND por falta de allow-external-apps), lanza el bootstrap
    // automático en lugar de esperar al diálogo que rompe el flujo.
    _bootstrapTimer?.cancel();
    _bootstrapTimer = Timer(_bootstrapProbe, _maybeBootstrap);
  }

  /// Sonda de la etapa 0: si tras [_bootstrapProbe] no hubo ninguna señal del
  /// log (RUN_COMMAND rechazado en silencio), activa `allow-external-apps` sin
  /// intervención abriendo Termux en primer plano una sola vez. Al volver el
  /// foco a la Consola ([didChangeAppLifecycleState]) se reintenta el
  /// RUN_COMMAND real. Si el bootstrap también falla, sigue el camino normal
  /// (el diálogo de reintento queda como último recurso).
  Future<void> _maybeBootstrap() async {
    if (!mounted ||
        _bootstrapTried ||
        _bootstrapping ||
        _progressSeen ||
        _agentUp ||
        _failed ||
        _canceled ||
        _simulating ||
        _installSucceeded ||
        _installedNotRunning ||
        _foregroundLaunched) {
      return;
    }
    // Doble comprobación: puede que el RUN_COMMAND sí funcione y el log ya
    // responda aunque _tick todavía no lo haya parseado. Si hay señal, no hay
    // que tocar nada.
    final log = await _termux.fetchInstallProgress(
      timeout: const Duration(seconds: 2),
    );
    if (!mounted || _progressSeen) return;
    if (log != null) {
      _progressSeen = true;
      return;
    }
    _bootstrapTried = true;
    setState(() => _bootstrapping = true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).lisBootstrapSnack),
          duration: const Duration(seconds: 4),
        ),
      );
    }
    final ok = await _termux.bootstrapExternalApps();
    if (!mounted) return;
    if (!ok) {
      // No se pudo abrir Termux en primer plano (no instalado / intent no
      // resuelto): deja el flujo normal, que acabará ofreciendo reintento.
      setState(() => _bootstrapping = false);
    }
  }

  /// Tiempo transcurrido desde que arrancó la instalación, en mm:ss.
  String get _elapsedLabel {
    final start = _startedAt;
    if (start == null) return '00:00';
    final s = DateTime.now().difference(start).inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _tick() async {
    if (!mounted || _agentUp || _failed || _canceled || _installedNotRunning) {
      return;
    }
    // Tope duro: si supera el tiempo máximo sin terminar, aborta con un error
    // claro y mata el proceso en Termux (no dejarlo colgado para siempre). Solo
    // aplica mientras la instalación sigue en marcha: si el wrapper ya terminó
    // con éxito (@@EXIT 0) no fallamos por tiempo, esperamos a que el agente
    // levante (ver ventana de gracia más abajo).
    final start = _startedAt;
    if (!_installSucceeded &&
        start != null &&
        DateTime.now().difference(start) > AgentRuntimeConsts.installTimeout) {
      _failByTimeout();
      return;
    }
    final log = await _termux.fetchInstallProgress();
    // ¿Ya está vivo el agente? (fin real)
    final up = await _termux.isAgentRunning(
      timeout: const Duration(milliseconds: 1200),
    );
    if (!mounted) return;
    if (up) {
      setState(() {
        _agentUp = true;
        _starting = false;
        _stageIndex = _stages.length - 1;
      });
      // Vivo en :9119 ⇒ existe: persistimos la marca de instalado.
      AgentRuntimeConsts.setAgentInstalled(true);
      _poll?.cancel();
      _clock?.cancel();
      // El agente levantó durante la ventana de gracia (o tras pulsar «Arrancar
      // agente»): conecta solo, sin que el usuario toque nada. Le damos 1 s para
      // que vea brevemente el estado «Agente local listo» antes de entrar.
      if ((_installSucceeded || _starting) && !_autoConnecting) {
        setState(() => _autoConnecting = true);
        Timer(const Duration(seconds: 1), () {
          if (mounted && !_connecting) _connect();
        });
      }
      return;
    }
    // La instalación terminó OK (@@EXIT 0) pero el agente aún no responde. El
    // instalador corre con --skip-setup (instala pero NO arranca el agente), así
    // que puede no levantar solo. Damos una ventana de gracia por si el
    // instalador lo arranca; si se agota, cerramos en un estado de éxito
    // «instalado, sin arrancar» en lugar de colgarnos hasta el tope de 5 min.
    if (_installSucceeded) {
      final doneAt = _installDoneAt;
      final grace = _starting ? _startGrace : _postInstallGrace;
      if (doneAt != null && DateTime.now().difference(doneAt) > grace) {
        _poll?.cancel();
        _clock?.cancel();
        setState(() {
          _installedNotRunning = true;
          _starting = false;
        });
      }
      return;
    }
    if (log == null) {
      _noProgressTicks++;
      // ~10 s sin que el servidor de log responda → Termux bloqueó RUN_COMMAND.
      final elapsed = _startedAt != null
          ? DateTime.now().difference(_startedAt!)
          : Duration.zero;
      // AUTO-RECUPERACIÓN: si la instalación YA había progresado (vimos el
      // servidor antes) y ahora lleva ~12 s caído, el wrapper o Termux murió.
      // Re-lanzamos automáticamente (sin molestar al usuario) en vez de colgar.
      // Sólo aplica al caso «arrancó y murió»; si nunca arrancó (_progressSeen
      // false) es un problema de allow-external-apps → va al fallback guiado.
      if (_progressSeen &&
          !_installSucceeded &&
          !_canceled &&
          _noProgressTicks >= _autoRetryAfterTicks &&
          _autoRetries < _maxAutoRetries) {
        _autoRetries++;
        _noProgressTicks = 0;
        final str = Strings.of(context);
        setState(
          () => _stallWarning = str.lisAutoRecovering(
            _autoRetries,
            _maxAutoRetries,
          ),
        );
        _launchWorker(); // re-dispatch seguro (lock del wrapper)
        return;
      }
      // Agotada la auto-recuperación (o nunca arrancó): fallback guiado manual.
      // Si NUNCA hubo señal del log y el bootstrap de allow-external-apps ya
      // se intentó sin éxito, no hay nada corriendo: esperar ~2 min solo
      // alarga la barra indeterminada — fallback a ~30 s (spec 028 A-004).
      final bootstrapExhausted =
          !_progressSeen && _bootstrapTried && !_bootstrapping;
      final noProgressLimit = bootstrapExhausted
          ? 20
          : (elapsed < const Duration(minutes: 3) ? 80 : 7);
      if (_noProgressTicks >= noProgressLimit &&
          !_fallbackShown &&
          !_fallbackDismissed) {
        _showFallback();
      }
      return;
    }
    _noProgressTicks = 0;
    _progressSeen = true;
    final str = Strings.of(context);
    _detectStall(log, str);
    _parse(log, str);
  }

  /// Ruta avanzada: detecta log CONGELADO (el servidor responde pero el
  /// contenido no cambia). Distinto de "sin servidor" (log==null): aquí el
  /// wrapper corre pero algo —típicamente un mirror lento o `pkg` esperando— no
  /// avanza. No marca fallo (puede recuperarse); avisa de forma accionable.
  void _detectStall(String log, Strings str) {
    final now = DateTime.now();
    if (log != _lastLogSnapshot) {
      _lastLogSnapshot = log;
      _lastLogChange = now;
      if (_stallWarning != null) setState(() => _stallWarning = null);
      return;
    }
    final since = _lastLogChange;
    if (since != null &&
        now.difference(since) > _stallAfter &&
        !_installSucceeded &&
        _stallWarning == null) {
      final isCompiling = _stageIndex >= 4; // Instalando Python o posterior
      setState(() {
        _stallWarning = isCompiling
            ? str.lisStallCompiling
            : str.lisStallWaiting(_stallAfter.inSeconds);
      });
    }
  }

  void _parse(String log, Strings str) {
    final lower = log.toLowerCase();
    var idx = _stageIndex;
    for (var i = _stages.length - 1; i >= 0; i--) {
      if (_stages[i].keys.any(lower.contains)) {
        idx = i > idx ? i : idx;
        break;
      }
    }
    // Error: @@EXIT con código != 0
    int? exit;
    final m = RegExp(r'@@exit\s+(\d+)').firstMatch(lower);
    if (m != null) exit = int.tryParse(m.group(1) ?? '');
    // Aviso de red en vivo: Termux no puede verificar conectividad. No marca
    // fallo todavía (puede recuperarse), pero se lo enseña al usuario.
    final netStall =
        lower.contains('@@netstall') ||
        lower.contains('could not reach') ||
        lower.contains('network may be incomplete') ||
        lower.contains('temporary failure in name resolution');
    final lines = log
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.startsWith('@@'))
        .toList();
    setState(() {
      _stageIndex = idx;
      _logTail
        ..clear()
        ..addAll(lines.length > 14 ? lines.sublist(lines.length - 14) : lines);
      if (netStall && exit == null) {
        _netWarning = str.lisNetWarning;
      }
      if (exit != null && exit == 0) {
        // Instalación completada con éxito. NO marcamos _agentUp aquí: el agente
        // se instala con --skip-setup y puede no estar arrancado todavía. _tick
        // sondea localhost durante la ventana de gracia y decide el estado final
        // (agente vivo → conectar; agente caído → «instalado, sin arrancar»).
        if (!_installSucceeded) {
          _installSucceeded = true;
          _installDoneAt = DateTime.now();
          // Evidencia firme de que el agente existe en este dispositivo: marca
          // persistida para que el setup lo detecte como «instalado» (binario:
          // sólo arrancar, nunca volver a ofrecer instalar).
          AgentRuntimeConsts.setAgentInstalled(true);
          _notifyInstallFinished(ok: true);
        }
        _stageIndex = _stages.length - 1;
      } else if (exit != null && exit != 0) {
        _poll?.cancel();
        _clock?.cancel();
        if (exit == AgentRuntimeConsts.installCanceledCode) {
          _canceled = true;
        } else {
          _failed = true;
          _exitCode = exit;
          _errorMsg = _friendlyError(lower, exit, str);
          _notifyInstallFinished(ok: false, detail: _errorMsg);
        }
      }
    });
  }

  /// Avisa por notificación local del desenlace de la instalación (éxito o
  /// fallo), una sola vez por ejecución. Funciona aunque el usuario haya dejado
  /// la app en segundo plano durante la instalación.
  void _notifyInstallFinished({required bool ok, String? detail}) {
    if (_finishNotified) return;
    _finishNotified = true;
    _notifications?.localInstallFinished(ok: ok, detail: detail);
  }

  /// Traduce el log a una causa entendible (espacio, red, paquetes rotos, etc.).
  String _friendlyError(String lower, int exit, Strings str) {
    // 124 = `timeout` venció una etapa (típicamente la red de Termux colgada).
    if (exit == 124 ||
        lower.contains('@@netstall') ||
        lower.contains('could not reach') ||
        lower.contains('network may be incomplete')) {
      return str.lisErrTimeout;
    }
    if (lower.contains('no space left')) {
      return str.lisErrDisk;
    }
    if (lower.contains('could not resolve host') ||
        lower.contains('network is unreachable') ||
        lower.contains('failed to connect') ||
        lower.contains('temporary failure in name resolution')) {
      return str.lisErrNoConn;
    }
    if (lower.contains('cannot link executable') ||
        lower.contains('libcrypto') ||
        lower.contains('library "lib')) {
      return str.lisErrPackages;
    }
    if (lower.contains('cargo: not found') ||
        lower.contains('no such file or directory: rustc') ||
        lower.contains('rust toolchain')) {
      return str.lisErrRust;
    }
    if (lower.contains('permission denied')) {
      return str.lisErrPermission;
    }
    return str.lisErrFailed(exit);
  }

  Future<void> _showFallback() async {
    _fallbackShown = true;
    if (!mounted) return;
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        icon: Icon(
          Icons.sync_problem_outlined,
          color: colors.warning,
          size: 28,
        ),
        title: Text(
          str.lisFallbackTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        content: Text(
          str.lisFallbackBody,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _fallbackDismissed = true;
                _noProgressTicks = 0;
              });
            },
            child: Text(
              str.lisFallbackWait,
              style: TextStyle(color: colors.textDisabled),
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(str.lisFallbackRetry),
            onPressed: () {
              Navigator.pop(ctx);
              _retry();
            },
          ),
        ],
      ),
    );
  }

  /// Tope duro de tiempo alcanzado: aborta con mensaje claro y mata el proceso
  /// en Termux para no dejarlo colgado consumiendo batería/datos.
  void _failByTimeout() {
    _poll?.cancel();
    _clock?.cancel();
    _termux.cancelInstall();
    if (!mounted) return;
    final errMsg = Strings.of(context).lisErrTimeout;
    setState(() {
      _failed = true;
      _exitCode = 124;
      _errorMsg = errMsg;
    });
    _notifyInstallFinished(ok: false, detail: _errorMsg);
  }

  /// Cancelación manual: el usuario aborta. Mata el proceso en Termux y deja la
  /// pantalla en un estado limpio con opción de reintentar.
  Future<void> _cancel() async {
    setState(() => _canceling = true);
    _poll?.cancel();
    _clock?.cancel();
    _bootstrapTimer?.cancel();
    if (!_simulating) await _termux.cancelInstall();
    await widget.connManager.prefs.remove(_prefKeyInProgress);
    if (!mounted) return;
    setState(() {
      _canceling = false;
      _canceled = true;
    });
  }

  Future<void> _retry() async {
    setState(() {
      _failed = false;
      _canceled = false;
      _exitCode = null;
      _noProgressTicks = 0;
      _fallbackShown = false;
      _fallbackDismissed = false;
      _foregroundLaunched = false;
      _installSucceeded = false;
      _installDoneAt = null;
      _installedNotRunning = false;
      _autoConnecting = false;
      _starting = false;
      _progressSeen = false;
      _finishNotified = false;
      _bootstrapTried = false;
      _bootstrapping = false;
      _netWarning = null;
      _stageIndex = 0;
      _logTail.clear();
      // dual-path reset
      _showPathA = false;
      _pickedModel = null;
      _customModelSelected = false;
      _ollamaPhase = 0;
      _ollamaCanceled = false;
      _ollamaError = null;
      _ollamaSubLabel = '';
      // camino B reset
      _showPathB = false;
      _apiConfiguring = false;
      _apiError = null;
    });
    _poll?.cancel();
    _bootstrapTimer?.cancel();
    await _start();
  }

  /// «Arrancar agente»: lanza el agente instalado en Termux en segundo plano y
  /// Envía el comando de arranque a Termux y entra a la Consola inmediatamente,
  /// sin esperar a que el agente responda. Úsalo cuando el usuario pulsa
  /// «Arrancar agente y entrar» (flujo explícito): la home gestiona el estado
  /// desconectado y hermes levanta en segundo plano.
  Future<void> _launchAndEnter() async {
    _poll?.cancel();
    _clock?.cancel();
    setState(() {
      _starting = true;
      _installedNotRunning = false;
      _netWarning = null;
    });
    if (!_simulating) await _termux.startAgent();
    if (!mounted) return;
    await _connect();
  }

  /// reanuda el sondeo de localhost (como [_retry], pero desde el estado
  /// post-instalación: no reinstala, solo arranca). Cuando el agente responde,
  /// [_tick] conecta solo; si no levanta en [_startGrace], vuelve a
  /// «instalado, sin arrancar» para poder reintentar.
  Future<void> _startAgent() async {
    setState(() {
      _starting = true;
      _installedNotRunning = false;
      _installDoneAt = DateTime.now(); // reabrir la ventana de gracia
      _netWarning = null;
      _stageIndex = _stages.length - 1;
    });
    if (!_simulating) await _termux.startAgent();
    if (!mounted) return;
    _poll?.cancel();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_agentUp && !_failed) setState(() {});
    });
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
  }

  // ── Modo simulación (solo debug) ──────────────────────────────────────────

  /// Menú de escenarios para probar el flujo de UI sin Termux real.
  Future<void> _openSimMenu() async {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final choice = await showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: const ValueKey('local-install-simulation-surface'),
      maxWidth: 520,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 10),
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              str.lisSimTitle,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.check_circle, color: colors.success),
            title: Text(str.lisSimSuccess),
            onTap: () => Navigator.pop(ctx, 'success'),
          ),
          ListTile(
            leading: Icon(Icons.download_done_rounded, color: colors.success),
            title: Text(str.lisSimInstalled),
            onTap: () => Navigator.pop(ctx, 'installed'),
          ),
          ListTile(
            leading: Icon(Icons.wifi_off_rounded, color: colors.error),
            title: Text(str.lisSimNetwork),
            onTap: () => Navigator.pop(ctx, 'network'),
          ),
          ListTile(
            leading: Icon(Icons.broken_image_outlined, color: colors.error),
            title: Text(str.lisSimPackages),
            onTap: () => Navigator.pop(ctx, 'packages'),
          ),
        ],
      ),
    );
    if (choice != null && mounted) _startSimulation(choice);
  }

  /// Reproduce las fases alimentando logs sintéticos al mismo parser que usa el
  /// flujo real, así la UI se ejerce de extremo a extremo sin Termux.
  void _startSimulation(String scenario) {
    _poll?.cancel();
    _clock?.cancel();
    final str = Strings.of(context);
    setState(() {
      _simulating = true;
      _checking = false;
      _incompatible = false;
      _blockReason = null;
      _failed = false;
      _canceled = false;
      _agentUp = false;
      _installSucceeded = false;
      _installDoneAt = null;
      _installedNotRunning = false;
      _autoConnecting = false;
      _starting = false;
      _exitCode = null;
      _errorMsg = null;
      _netWarning = null;
      _stageIndex = 0;
      _logTail.clear();
      _progressSeen = true;
      _launchedAuto = true;
      _startedAt = DateTime.now();
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_agentUp && !_failed) setState(() {});
    });
    final script = _simScript(scenario);
    final buf = StringBuffer();
    var i = 0;
    _poll = Timer.periodic(const Duration(milliseconds: 700), (t) {
      if (!mounted || _canceled) {
        t.cancel();
        return;
      }
      if (i >= script.length) {
        t.cancel();
        _clock?.cancel();
        if (scenario == 'success' && !_failed) {
          setState(() {
            _agentUp = true;
            _stageIndex = _stages.length - 1;
          });
        } else if (scenario == 'installed' && !_failed) {
          // Instalación OK pero el agente no responde (--skip-setup): estado de
          // éxito «instalado, sin arrancar» en vez de colgarse hasta el timeout.
          setState(() {
            _installedNotRunning = true;
            _stageIndex = _stages.length - 1;
          });
        }
        return;
      }
      buf.writeln(script[i]);
      i++;
      _parse(buf.toString(), str); // mismo parser que el flujo real
    });
  }

  /// Guion de log por escenario (incluye marcas @@STAGE/@@EXIT reales).
  List<String> _simScript(String scenario) {
    const common = [
      '@@STAGE Preparando Termux',
      'PATH=/data/data/com.termux/files/usr/bin',
      'pkg found',
      'python found',
      '@@STAGE Descargando instalador',
    ];
    switch (scenario) {
      case 'network':
        return [
          ...common,
          '@@NETSTALL descarga del instalador',
          'curl: (6) Could not resolve host: hermes-agent.nousresearch.com',
          '@@EXIT 6',
          '@@DONE',
        ];
      case 'packages':
        return [
          ...common,
          '@@STAGE Instalando agente',
          'CANNOT LINK EXECUTABLE "python": library "libcrypto.so" not found',
          '@@EXIT 1',
          '@@DONE',
        ];
      case 'installed':
        return [
          ...common,
          '@@STAGE Instalando agente',
          'Cloning into hermes-agent...',
          'receiving objects: 100%',
          'Collecting aiohttp',
          'Building wheel for hermes-agent',
          'added 124 packages in 12s',
          'venv configurado',
          '@@EXIT 0',
          '@@DONE',
        ];
      case 'success':
      default:
        return [
          ...common,
          '@@STAGE Instalando agente',
          'Cloning into hermes-agent...',
          'receiving objects: 100%',
          'Collecting aiohttp',
          'Building wheel for hermes-agent',
          'added 124 packages in 12s',
          'venv configurado',
          '@@DONE',
        ];
    }
  }

  // ── Modelo local vía ollama ──────────────────────────────────────────────

  List<_LocalModel> get _compatibleModels {
    final opts = _localModelOptions(Strings.of(context));
    if (!_deviceInfo.known) return List.from(opts);
    final usableGb = _deviceInfo.totalRamGb * 0.55;
    return opts.where((m) => m.ramGb <= usableGb).toList();
  }

  /// Sondea [check] cada [interval] hasta que devuelva true o expire [timeout].
  Future<bool> _pollUntil(
    Future<bool> Function() check,
    Duration timeout, {
    Duration interval = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || _ollamaCanceled) return false;
      if (await check()) return true;
      if (!mounted || _ollamaCanceled) return false;
      await Future.delayed(interval);
    }
    return false;
  }

  /// Construye un [_LocalModel] a partir del tag escrito en el campo de modelo
  /// personalizado. Devuelve null si está vacío.
  _LocalModel? _customModelFromInput() {
    final tag = _customModelCtrl.text.trim();
    if (tag.isEmpty) return null;
    return _LocalModel(
      tag: tag,
      name: tag,
      ramGb: 0,
      params: 'custom',
      desc: Strings.of(context).lisModelDescCustom,
    );
  }

  /// Actualiza [_ollamaSubLabel] y la notificación de instalación en segundo
  /// plano de forma atómica.
  void _setOllamaSubLabel(String label) {
    if (!mounted) return;
    setState(() => _ollamaSubLabel = label);
    unawaited(_OllamaInstallNotif.update(_notifications, label));
  }

  /// Ejecuta el flujo completo: install ollama → start → pull model →
  /// configure hermes → start agent (usa la maquinaria existente).
  Future<void> _runOllamaSetup() async {
    final s = Strings.of(context);
    // Modelo personalizado: construye un _LocalModel sintético con el tag escrito.
    final model = _customModelSelected ? _customModelFromInput() : _pickedModel;
    if (model == null) return;

    setState(() {
      _ollamaPhase = 1;
      _ollamaError = null;
      _ollamaCanceled = false;
      _ollamaSubLabel = '';
    });
    await _OllamaInstallNotif.start(_notifications);

    try {
      // Fase 1a: descargar e instalar ollama
      _setOllamaSubLabel(s.lisOllamaDownloadEngine);
      try {
        await _termux.installOllama();
      } catch (e) {
        if (mounted && !_ollamaCanceled) {
          setState(() {
            _ollamaPhase = -1;
            _ollamaError = s.lisOllamaDownloadFailed;
            _ollamaSubLabel = '';
          });
        }
        await _OllamaInstallNotif.stop(_notifications);
        return;
      }
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted || _ollamaCanceled) return;

      // Fase 1b: arrancar el servidor y esperar que responda
      _setOllamaSubLabel(s.lisOllamaStartingServer);
      await _termux.startOllama();
      _setOllamaSubLabel(s.lisOllamaWaitingServer);
      final ollamaUp = await _pollUntil(
        () => _termux.isOllamaRunning(),
        const Duration(seconds: 90),
        interval: const Duration(seconds: 4),
      );
      if (!mounted || _ollamaCanceled) return;
      if (!ollamaUp) {
        setState(() {
          _ollamaPhase = -1;
          _ollamaError = s.lisOllamaStartFailed;
          _ollamaSubLabel = '';
        });
        await _OllamaInstallNotif.stop(_notifications);
        return;
      }

      // Fase 2: descargar el modelo
      setState(() => _ollamaPhase = 2);
      _setOllamaSubLabel(
        s.lisOllamaPullingModel(model.name, model.ramGb.toStringAsFixed(1)),
      );
      await _termux.pullOllamaModel(model.tag);
      _setOllamaSubLabel(s.lisOllamaPullInProgress);
      final modelReady = await _pollUntil(
        () => _termux.isOllamaModelAvailable(model.tag),
        const Duration(minutes: 10),
        interval: const Duration(seconds: 5),
      );
      if (!mounted || _ollamaCanceled) return;
      if (!modelReady) {
        setState(() {
          _ollamaPhase = -1;
          _ollamaError = s.lisOllamaModelFailed(model.name);
          _ollamaSubLabel = '';
        });
        await _OllamaInstallNotif.stop(_notifications);
        return;
      }

      // Fase 3: configurar hermes con ollama
      setState(() => _ollamaPhase = 3);
      _setOllamaSubLabel(s.lisOllamaSavingConfig);
      await _termux.configureWithOllama(model.tag);
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || _ollamaCanceled) return;

      // Pasa el testigo a la maquinaria existente de arranque
      _setOllamaSubLabel(s.lisOllamaConnectingAgent);
      await _OllamaInstallNotif.stop(_notifications);
      await _startAgent();
    } catch (e) {
      if (mounted && !_ollamaCanceled) {
        setState(() {
          _ollamaPhase = -1;
          _ollamaError = s.lisInstallUnexpectedError;
          _ollamaSubLabel = '';
        });
      }
      await _OllamaInstallNotif.stop(_notifications);
    }
  }

  /// Camino B: escribe la config con el proveedor de nube elegido y arranca el
  /// agente. Reusa _startAgent (polling + auto-conexión cuando el gateway vive).
  Future<void> _runApiSetup() async {
    final model = _apiModelCtrl.text.trim();
    final key = _apiKeyCtrl.text.trim();
    if (model.isEmpty) {
      setState(() => _apiError = 'Indica un modelo (p.ej. gpt-4o-mini).');
      return;
    }
    if (key.isEmpty) {
      setState(() => _apiError = 'La API key es obligatoria.');
      return;
    }
    setState(() {
      _apiConfiguring = true;
      _apiError = null;
    });
    if (!_simulating) {
      await _termux.configureAgent(
        provider: _apiProvider,
        model: model,
        apiKey: key,
      );
      // Dar un margen a Termux para escribir config.yaml + .env antes de arrancar.
      await Future.delayed(const Duration(seconds: 2));
    }
    if (!mounted) return;
    setState(() => _apiConfiguring = false);
    // startAgent + polling + auto-conexión al gateway (misma maquinaria que A).
    await _startAgent();
  }

  /// Camino B (OAuth): escribe el provider en config.yaml (sin .env) y lanza el
  /// login por navegador (`hermes auth`) EN SEGUNDO PLANO, sin abrir Termux. El
  /// comando sirve su salida por localhost (:8644); aquí sondeamos el log, y en
  /// cuanto aparece la URL `https://…` la ofrecemos como botón. No arranca el
  /// agente: el usuario vuelve y pulsa «Arrancar agente y entrar».
  Future<void> _runApiOAuth() async {
    final s = Strings.of(context);
    final provider = _apiProvider;
    _apiAuthTimer?.cancel();
    setState(() {
      _apiAuthenticating = true;
      _apiAuthUrl = null;
      _apiAuthElapsedSecs = 0;
      _apiError = null;
      _apiNotice = s.lisOauthStarting;
    });
    if (_simulating) {
      setState(() {
        _apiAuthenticating = false;
        _apiNotice = s.lisOauthSimulated;
      });
      return;
    }
    await _termux.configureAgent(
      provider: provider,
      model: _apiModelCtrl.text.trim(),
      apiKey: '',
      isOAuth: true,
    );
    await _termux.runOAuthFlow(provider: provider);
    if (!mounted) return;
    _apiAuthTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      _apiAuthElapsedSecs += 2;
      final log = await _termux.fetchOAuthLog();
      if (!mounted) {
        t.cancel();
        return;
      }
      final url = _extractUrl(log);
      if (url != null && _apiAuthUrl == null) {
        setState(() {
          _apiAuthUrl = url;
          _apiNotice = s.lisOauthOpenUrl;
        });
      }
      final done = log != null && log.contains('@@OAUTH_DONE');
      if (done) {
        t.cancel();
        setState(() {
          _apiAuthenticating = false;
          _apiNotice = _apiAuthUrl == null
              ? s.lisOauthDoneNoUrl
              : s.lisOauthDoneWithUrl;
        });
        return;
      }
      if (_apiAuthUrl == null && _apiAuthElapsedSecs >= 60) {
        t.cancel();
        setState(() {
          _apiAuthenticating = false;
          _apiError = s.lisOauthUrlTimeout;
          _apiNotice = null;
        });
      }
    });
  }

  /// Extrae la primera URL `https://…` de un volcado de log de OAuth.
  String? _extractUrl(String? log) {
    if (log == null) return null;
    final m = RegExp(r'https://[^\s"<>]+').firstMatch(log);
    return m?.group(0);
  }

  /// Abre la URL de autenticación en el navegador del sistema.
  Future<void> _openApiAuthUrl() async {
    final url = _apiAuthUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _cancelOllamaSetup() {
    if (_ollamaPhase >= 1) _termux.stopOllama();
    unawaited(_OllamaInstallNotif.stop(_notifications));
    setState(() {
      _ollamaCanceled = true;
      _ollamaPhase = 0;
      _ollamaSubLabel = '';
      _ollamaError = null;
    });
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    try {
      final conn = await _termux.ensureLocalConnection(widget.connManager);
      await widget.connManager.setActiveConnection(conn.id);
      await widget.connManager.prefs.remove(_prefKeyInProgress);
      // Provisionar el bridge en background: el script lo arranca, pero tarda
      // unos segundos en estar listo. Reintentamos sin bloquear la navegación.
      _provisionBridgeBackground(conn.id);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _autoConnecting = false;
        });
      }
    }
  }

  /// Provisiona el token del bridge en background con reintentos.
  /// Si el bridge no está listo todavía, lo reintenta hasta 3 veces.
  void _provisionBridgeBackground(String connId) {
    Future(() async {
      // El bridge puede tardar 2-4s en arrancar tras el startAgentCommand.
      await Future.delayed(const Duration(seconds: 3));
      final mgr = BridgeManager(SecureStorage(), widget.connManager);
      for (var i = 0; i < 3; i++) {
        try {
          if (await mgr.tryProvision(connId)) return;
        } catch (_) {}
        await Future.delayed(const Duration(seconds: 2));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        // En debug, long-press en el título abre el menú de simulación (Fix E):
        // permite recorrer las fases sin Termux real. En release es un Text normal.
        title: GestureDetector(
          onLongPress: kDebugMode ? _openSimMenu : null,
          child: Text(
            widget.repair ? str.lisRepairTitle : str.lisAppBarTitle,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
              color: colors.accentHover,
            ),
          ),
        ),
        actions: [
          // Copiar/compartir el log completo para pegárselo al agente.
          IconButton(
            icon: Icon(Icons.copy_all_outlined, color: colors.textSecondary),
            tooltip: str.lisCopyLogTooltip,
            onPressed: _copyLog,
          ),
        ],
      ),
      body: SafeArea(
        child: _incompatible
            ? _incompatView(colors, str)
            : _checking
            ? _checkingView(colors, str)
            : _blockReason != null
            ? _blockView(colors, str)
            : _installView(colors, str),
      ),
    );
  }

  /// Copia al portapapeles un volcado de diagnóstico con las últimas líneas del
  /// log del wrapper.
  Future<void> _copyLog() async {
    final b = StringBuffer()
      ..writeln('# Hermes — local installation diagnostics')
      ..writeln('mode: automatic')
      ..writeln('elapsed: $_elapsedLabel');
    if (_logTail.isNotEmpty) {
      b
        ..writeln('\n## Log (wrapper)')
        ..writeln(_logTail.join('\n'));
    }
    if (_errorMsg != null) b.writeln('\n## Error\n$_errorMsg');
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).lisLogCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _checkingView(HermesThemeColors colors, Strings str) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const HermesStatusIndicator(
            mood: HermesSparkMood.connecting,
            size: 56,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            str.lisChecking,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  /// Bloqueo transitorio (sin espacio / sin red): se puede reintentar.
  Widget _blockView(HermesThemeColors colors, Strings str) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HermesStatusIndicator(mood: HermesSparkMood.error, size: 60),
            const SizedBox(height: 18),
            Text(
              str.lisBlockTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _blockReason ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            HermesPrimaryButton(
              label: str.lisRetry,
              icon: Icons.refresh_rounded,
              onTap: _init,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(str.lisBack),
            ),
          ],
        ),
      ),
    );
  }

  Widget _installView(HermesThemeColors colors, Strings str) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        _headerCard(colors, str),
        if (_warning != null) ...[
          const SizedBox(height: 10),
          _warningBanner(colors, _warning!),
        ],
        if (_netWarning != null && !_failed && !_canceled && !_agentUp) ...[
          const SizedBox(height: 10),
          _warningBanner(colors, _netWarning!),
        ],
        if (_stallWarning != null && !_failed && !_canceled && !_agentUp) ...[
          const SizedBox(height: 10),
          _warningBanner(colors, _stallWarning!),
        ],
        const SizedBox(height: 16),
        ..._stageRows(colors, str),
        const SizedBox(height: 16),
        _terminalCard(colors, str),
        const SizedBox(height: 18),
        if (_agentUp)
          HermesPrimaryButton(
            label: (_connecting || _autoConnecting)
                ? str.lisConnecting
                : str.lisConnectEnter,
            icon: Icons.bolt_rounded,
            onTap: (_connecting || _autoConnecting) ? null : _connect,
          )
        else if (_starting) ...[
          HermesPrimaryButton(
            label: str.lisStarting,
            icon: Icons.bolt_rounded,
            onTap: null,
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              str.lisStartingDesc,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colors.textDisabled),
            ),
          ),
        ] else if (_installedNotRunning) ...[
          _successBanner(colors, str),
          const SizedBox(height: 14),
          // El modelo/proveedor NO se elige aquí: se configura después en
          // Ajustes → Modelos (descarga de modelos locales Ollama con progreso,
          // o API/OAuth). Aquí solo se arranca el agente.
          _configureLaterCard(colors, str),
          const SizedBox(height: 16),
          HermesPrimaryButton(
            label: str.lisLaunchEnter,
            icon: Icons.rocket_launch_rounded,
            onTap: _launchAndEnter,
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              str.lisModelLaterHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: colors.textDisabled),
            ),
          ),
        ] else if (_failed || _canceled) ...[
          HermesPrimaryButton(
            label: str.lisRetry,
            icon: Icons.refresh_rounded,
            onTap: _retry,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.copy_all_outlined, size: 16),
              label: Text(str.lisCopyLog),
              onPressed: _copyLog,
            ),
          ),
        ] else ...[
          Center(
            child: Text(
              // Mientras no haya señal del log, el intent solo se DESPACHÓ:
              // no prometer que la instalación continúa (Termux puede haberla
              // rechazado en silencio) — texto honesto de espera (spec 028
              // A-004).
              _bootstrapping
                  ? str.lisBootstrapping
                  : !_progressSeen
                  ? str.lisWaitingTermuxConfirm
                  : _launchedAuto
                  ? str.lisBackgroundOk
                  : str.lisPrepBackground,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.close_rounded, size: 16),
              style: TextButton.styleFrom(foregroundColor: colors.error),
              label: Text(_canceling ? str.lisCanceling : str.lisCancelInstall),
              onPressed: _canceling ? null : _cancel,
            ),
          ),
        ],
      ],
    );
  }

  Widget _headerCard(HermesThemeColors colors, Strings str) {
    final done = _agentUp;
    // «Completo» (barra al 100% y color verde) tanto si el agente ya responde
    // como si la instalación terminó OK aunque el agente no esté arrancado.
    final complete = _agentUp || _installedNotRunning;
    final pct = ((_stageIndex + (complete ? 1 : 0)) / _stages.length).clamp(
      0.0,
      1.0,
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (complete ? colors.success : colors.accent).withValues(
            alpha: 0.35,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HermesStatusIndicator(
                size: 28,
                mood: complete
                    ? HermesSparkMood.success
                    : (_failed || _canceled)
                    ? HermesSparkMood.error
                    : HermesSparkMood.connecting,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  done
                      ? str.lisStatusReady
                      : _installedNotRunning
                      ? str.lisStatusInstalled
                      : _failed
                      ? str.lisStatusFailed
                      : _canceled
                      ? str.lisStatusCanceled
                      : _stageLabel(_stageIndex, str),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (_startedAt != null) ...[
                const SizedBox(width: 8),
                _elapsedChip(colors, done),
              ],
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (complete || _failed || _canceled)
                  ? pct
                  : null, // indeterminado mientras va
              minHeight: 7,
              backgroundColor: colors.surfaceVariant,
              color: _failed
                  ? colors.error
                  : _canceled
                  ? colors.warning
                  : (complete ? colors.success : colors.accent),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            done
                ? str.lisStatusReadyDesc
                : _installedNotRunning
                ? str.lisStatusInstalledDesc
                : _failed
                ? (_errorMsg ?? str.lisStatusFailedCode(_exitCode ?? 0))
                : _canceled
                ? str.lisStatusCanceledDesc
                : str.lisStatusStage(_stageIndex + 1, _stages.length),
            style: TextStyle(
              fontSize: 11.5,
              color: _failed
                  ? colors.error
                  : _canceled
                  ? colors.warning
                  : colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Cronómetro mm:ss del tiempo de instalación. Verde al terminar, rojo si
  /// falló, ámbar mientras corre.
  Widget _elapsedChip(HermesThemeColors colors, bool done) {
    final tint = _failed
        ? colors.error
        : done
        ? colors.success
        : colors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 13, color: tint),
          const SizedBox(width: 4),
          Text(
            _elapsedLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _warningBanner(HermesThemeColors colors, String text) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 15, color: colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// Pantalla clara cuando el móvil no es compatible.
  Widget _incompatView(HermesThemeColors colors, Strings str) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HermesStatusIndicator(mood: HermesSparkMood.error, size: 64),
            const SizedBox(height: 18),
            Text(
              str.lisIncompatTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _incompatReason,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            HermesPrimaryButton(
              label: str.lisIncompatOk,
              icon: Icons.arrow_back_rounded,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }

  String _stageLabel(int idx, Strings str) {
    final labels = <String Function(Strings)>[
      (s) => s.lisStage0,
      (s) => s.lisStage1,
      (s) => s.lisStage2,
      (s) => s.lisStage3,
      (s) => s.lisStage4,
      (s) => s.lisStage5,
      (s) => s.lisStage6,
      (s) => s.lisStage7,
    ];
    return idx >= 0 && idx < labels.length
        ? labels[idx](str)
        : _stages[idx].label;
  }

  List<Widget> _stageRows(HermesThemeColors colors, Strings str) {
    return List.generate(_stages.length, (i) {
      final state = _agentUp || _installedNotRunning || i < _stageIndex
          ? 1 // hecho
          : i == _stageIndex && !_failed && !_canceled
          ? 0 // en curso
          : -1; // pendiente
      final Widget leading;
      if (state == 1) {
        leading = Icon(Icons.check_circle, size: 18, color: colors.success);
      } else if (state == 0) {
        leading = SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.accent,
          ),
        );
      } else {
        leading = Icon(
          Icons.radio_button_unchecked,
          size: 18,
          color: colors.textDisabled,
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _stageLabel(i, str),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: state == -1 ? colors.textDisabled : colors.textPrimary,
                  fontWeight: state == 0 ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _terminalCard(HermesThemeColors colors, Strings str) {
    return Container(
      height: 160,
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
                str.lisTerminalWaiting,
                style: TextStyle(fontSize: 11, color: colors.textDisabled),
              ),
            )
          : ListView(
              reverse: true,
              children: _logTail.reversed
                  .map(
                    (l) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        l,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.3,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
  }

  // ── Widgets del dual-path post-instalación ───────────────────────────────

  Widget _successBanner(HermesThemeColors colors, Strings str) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.success.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 15, color: colors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              str.lisSuccessBannerMsg,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// Devuelve la conexión local activa, si existe.
  SavedConnection? _localConn() {
    try {
      return widget.connManager.getConnections().firstWhere(
        (c) => c.kind == InstanceKind.localhost,
      );
    } catch (_) {
      return null;
    }
  }

  /// Card tras instalar: explica que el modelo se elige en Modelos y ofrece
  /// acceso directo a la pantalla de proveedor externo (Ollama remoto, vLLM…).
  Widget _configureLaterCard(HermesThemeColors colors, Strings str) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory, size: 20, color: colors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      str.lisInstalledTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      str.lisInstalledDesc,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              // En "instalado, sin arrancar" la conexión localhost aún no
              // existe (solo la creaba _connect): se crea al vuelo en vez de
              // no hacer nada al pulsar (spec 028 A-001).
              final conn =
                  _localConn() ??
                  await _termux.ensureLocalConnection(widget.connManager);
              if (!mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ExternalProviderScreen(connection: conn),
                ),
              );
            },
            icon: Icon(
              Icons.swap_horiz_rounded,
              size: 16,
              color: colors.accent,
            ),
            label: Text(
              Strings.of(context).lisExternalProviderCta,
              style: TextStyle(fontSize: 12, color: colors.accent),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: colors.accent.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  // UI de selección de modelo retirada del onboarding; ahora se configura en
  // Ajustes → Modelos. Código muerto a limpiar en una pasada aparte.
  // ignore: unused_element
  Widget _pathACard(HermesThemeColors colors) {
    final compat = _compatibleModels;
    final ramText = _deviceInfo.known
        ? '${_deviceInfo.totalRamGb.toStringAsFixed(1)} GB'
        : 'desconocida';
    final active = _showPathA && _ollamaPhase < 1;
    return GestureDetector(
      onTap: () {
        if (_ollamaPhase >= 1) return; // no colapsar mientras instala
        setState(() => _showPathA = !_showPathA);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colors.accent.withValues(alpha: active ? 0.65 : 0.40),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.computer_outlined,
                color: colors.accent,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sin API key · Privacidad total',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'RAM: $ramText · ${compat.length} modelos compatibles',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _showPathA ? Icons.expand_less : Icons.chevron_right,
              color: colors.accent,
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _localModelSection(HermesThemeColors colors) {
    if (_ollamaPhase == -1) return _ollamaErrorCard(colors);
    if (_ollamaPhase >= 1) return _ollamaProgressCard(colors);
    return _modelPickerCard(colors);
  }

  /// Tarjeta colapsada del Camino B (secundario): usar API de IA en la nube.
  // ignore: unused_element
  Widget _pathBCard(HermesThemeColors colors) {
    return GestureDetector(
      onTap: _apiConfiguring
          ? null
          : () => setState(() => _showPathB = !_showPathB),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colors.divider.withValues(alpha: _showPathB ? 0.75 : 0.45),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.textSecondary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.cloud_outlined,
                color: colors.textSecondary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Usar API de IA (OpenAI, Anthropic, Mistral…)',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Requires your own API key · ideal if the local model will not start',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _showPathB ? Icons.expand_less : Icons.chevron_right,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  /// Formulario del Camino B: proveedor (API key u OAuth) + modelo → configurar
  /// y arrancar. Para OAuth muestra un botón de autenticación en vez de API key.
  // ignore: unused_element
  Widget _pathBForm(HermesThemeColors colors) {
    final opt = ProviderCatalog.byId(_apiProvider);
    final isOAuth = ProviderCatalog.isOAuth(_apiProvider);
    final hint = opt?.modelHint ?? 'nombre del modelo';
    final busy = _apiConfiguring || _apiAuthenticating;

    DropdownMenuItem<String> header(String text) => DropdownMenuItem<String>(
      value: '__hdr_$text',
      enabled: false,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: colors.accent,
        ),
      ),
    );
    DropdownMenuItem<String> item(ProviderOption p) => DropdownMenuItem<String>(
      value: p.id,
      child: Text('${p.label}  ·  ${p.blurb}', overflow: TextOverflow.ellipsis),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _apiProvider,
            isExpanded: true,
            decoration: _pathBInputDecoration(colors, 'Proveedor'),
            dropdownColor: colors.surface,
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
            items: [
              header('API KEY'),
              ...ProviderCatalog.apiKey.map(item),
              header('OAUTH (NAVEGADOR)'),
              ...ProviderCatalog.oauth.map(item),
            ],
            onChanged: busy
                ? null
                : (v) {
                    if (v == null || v.startsWith('__hdr_')) return;
                    setState(() {
                      _apiProvider = v;
                      _apiError = null;
                      _apiNotice = null;
                      _apiKeyCtrl.clear();
                    });
                  },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _apiModelCtrl,
            enabled: !busy,
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
            decoration:
                _pathBInputDecoration(
                  colors,
                  isOAuth ? 'Modelo (opcional)' : 'Modelo',
                ).copyWith(
                  hintText: hint,
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: colors.textDisabled,
                  ),
                ),
          ),
          if (!isOAuth) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _apiKeyCtrl,
              enabled: !busy,
              obscureText: !_apiKeyVisible,
              style: TextStyle(fontSize: 13, color: colors.textPrimary),
              decoration: _pathBInputDecoration(colors, 'API Key').copyWith(
                suffixIcon: IconButton(
                  icon: Icon(
                    _apiKeyVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  onPressed: () =>
                      setState(() => _apiKeyVisible = !_apiKeyVisible),
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              Strings.of(context).lisOauthBrowserNote,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ],
          if (_apiError != null) ...[
            const SizedBox(height: 8),
            Text(
              _apiError!,
              style: TextStyle(fontSize: 11.5, color: colors.error),
            ),
          ],
          if (_apiNotice != null) ...[
            const SizedBox(height: 8),
            Text(
              _apiNotice!,
              style: TextStyle(fontSize: 11.5, color: colors.success),
            ),
          ],
          const SizedBox(height: 14),
          if (isOAuth) ...[
            HermesPrimaryButton(
              label: _apiAuthenticating
                  ? 'autenticando…'
                  : 'Autenticar con ${opt?.label ?? _apiProvider}',
              icon: Icons.lock_open_rounded,
              onTap: busy ? null : _runApiOAuth,
            ),
            if (_apiAuthenticating && _apiAuthUrl == null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                backgroundColor: colors.divider.withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
              ),
            ],
            if (_apiAuthUrl != null) ...[
              const SizedBox(height: 12),
              HermesPrimaryButton(
                label: 'Abrir en navegador →',
                icon: Icons.open_in_new_rounded,
                onTap: _openApiAuthUrl,
              ),
            ],
          ] else
            HermesPrimaryButton(
              label: _apiConfiguring
                  ? 'configurando…'
                  : 'Configurar y arrancar',
              icon: Icons.rocket_launch_rounded,
              onTap: busy ? null : _runApiSetup,
            ),
        ],
      ),
    );
  }

  InputDecoration _pathBInputDecoration(
    HermesThemeColors colors,
    String label,
  ) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c),
    );
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontSize: 12, color: colors.textSecondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      filled: true,
      fillColor: colors.background,
      border: border(colors.divider),
      enabledBorder: border(colors.divider.withValues(alpha: 0.6)),
      focusedBorder: border(colors.accent),
    );
  }

  Widget _modelPickerCard(HermesThemeColors colors) {
    final compat = _compatibleModels;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Elige un modelo compatible',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          if (compat.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'No models are compatible with this device RAM. '
                'You need at least 1 GB of free RAM to run a local model.',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            )
          else
            ...compat.map((m) => _modelOption(colors, m)),
          // Modelo personalizado: el usuario escribe cualquier tag de Ollama.
          _customModelOption(colors),
          if (_customModelSelected) ...[
            const SizedBox(height: 4),
            TextField(
              controller: _customModelCtrl,
              style: TextStyle(fontSize: 13, color: colors.textPrimary),
              onChanged: (_) => setState(() {}),
              decoration: _pathBInputDecoration(
                colors,
                Strings.of(context).lisOllamaTagHint,
              ),
            ),
          ],
          const SizedBox(height: 10),
          HermesPrimaryButton(
            label: _installModelReady
                ? Strings.of(context).lisInstallAndConfigure
                : Strings.of(context).lisSelectModelFirst,
            icon: Icons.rocket_launch_rounded,
            onTap: _installModelReady ? _runOllamaSetup : null,
          ),
        ],
      ),
    );
  }

  /// ¿Hay un modelo listo para instalar (compatible elegido o tag personalizado)?
  bool get _installModelReady => _customModelSelected
      ? _customModelCtrl.text.trim().isNotEmpty
      : _pickedModel != null;

  /// Fila "Modelo personalizado": activa el campo de texto para un tag libre.
  Widget _customModelOption(HermesThemeColors colors) {
    final selected = _customModelSelected;
    return GestureDetector(
      onTap: () => setState(() {
        _customModelSelected = true;
        _pickedModel = null;
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.10)
              : colors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? colors.accent
                : colors.divider.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? colors.accent : colors.textDisabled,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Modelo personalizado',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Strings.of(context).lisOllamaAnyTag,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelOption(HermesThemeColors colors, _LocalModel model) {
    final selected = !_customModelSelected && _pickedModel?.tag == model.tag;
    return GestureDetector(
      onTap: () => setState(() {
        _pickedModel = model;
        _customModelSelected = false;
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.10)
              : colors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? colors.accent
                : colors.divider.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? colors.accent : colors.textDisabled,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          model.params,
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.textDisabled,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${model.desc} · ~${model.ramGb.toStringAsFixed(1)} GB RAM',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ollamaProgressCard(HermesThemeColors colors) {
    final str = Strings.of(context);
    final stepLabels = [
      str.lisOllamaStepInstall,
      str.lisOllamaStepModel,
      str.lisOllamaStepConfigure,
    ];
    final stepIdx = (_ollamaPhase - 1).clamp(0, stepLabels.length - 1);
    final label = (_ollamaPhase == 2 && _pickedModel != null)
        ? str.lisOllamaDownloadingName(_pickedModel!.name)
        : stepLabels[stepIdx];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: colors.surfaceVariant,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _ollamaSubLabel.isNotEmpty
                      ? _ollamaSubLabel
                      : str.lisOllamaStepOf(_ollamaPhase, 3),
                  style: TextStyle(fontSize: 11, color: colors.textDisabled),
                ),
              ),
              TextButton(
                onPressed: _cancelOllamaSetup,
                style: TextButton.styleFrom(
                  foregroundColor: colors.error,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  Strings.of(context).commonCancel,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ollamaErrorCard(HermesThemeColors colors) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 16, color: colors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _ollamaError ?? 'Error desconocido.',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          HermesSecondaryButton(
            label: 'Reintentar',
            icon: Icons.refresh_rounded,
            onTap: () => setState(() {
              _ollamaPhase = 0;
              _ollamaError = null;
              _ollamaCanceled = false;
            }),
          ),
          const SizedBox(height: 6),
          // Salida de rescate: si el modelo local no arranca, usar API en la nube.
          HermesSecondaryButton(
            label: 'Usar API en la nube',
            icon: Icons.cloud_outlined,
            onTap: () => setState(() {
              _ollamaPhase = 0;
              _ollamaError = null;
              _ollamaCanceled = false;
              _showPathA = false;
              _showPathB = true;
            }),
          ),
          const SizedBox(height: 6),
          HermesSecondaryButton(
            label: 'Arrancar sin modelo local',
            icon: Icons.skip_next_rounded,
            onTap: _launchAndEnter,
          ),
        ],
      ),
    );
  }
}

// ── Notificación persistente durante la instalación de Ollama ───────────────
//
// Mantiene al usuario informado cuando la app va a segundo plano mediante una
// notificación local ongoing con ID propio. La instalación corre en Termux, así
// que esta tarjeta no necesita adquirir ni reconfigurar el FGS compartido de
// escucha/Voz/Read Aloud/SSH/SFTP.

class _OllamaInstallNotif {
  static const int _notificationId = 8890;

  static Future<void> start(NotificationService? notifications) =>
      update(notifications, 'Instalando Ollama…');

  static Future<void> update(
    NotificationService? notifications,
    String text,
  ) async {
    await notifications?.operationProgress(
      id: _notificationId,
      title: 'Hermes Console',
      body: text,
    );
  }

  static Future<void> stop(NotificationService? notifications) async =>
      notifications?.cancelOperation(_notificationId);
}
