// Modelos locales (Ollama) para la instancia local de Hermes.
//
// Vive en el apartado Modelos (además del panel de control). Muestra:
//   - Modelos ya descargados (/api/tags vía el provider local)
//   - Catálogo curado filtrado por la RAM del dispositivo, con descarga real
//     (streaming /api/pull → barra de progreso con %)
//   - "Usar": fija el modelo en config.yaml (provider ollama) para que el agente
//     lo use; avisa de reiniciar el agente.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../data/litert_catalog.dart';
import '../services/agent_runtime/agent_runtime.dart';
import '../services/agent_runtime/local_termux_agent_provider.dart';
import '../services/agent_runtime/provider_catalog.dart';
import '../services/bridge_client.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../services/litert_engine.dart';
import '../services/platform/android_apps.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/read_only.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import 'litert_store_screen.dart';

class OllamaModelsScreen extends StatefulWidget {
  /// Conexión local: se usa para fijar el modelo activo vía la API del dashboard
  /// (`model/set`), que es la vía fiable (no RUN_COMMAND).
  final SavedConnection connection;
  const OllamaModelsScreen({required this.connection, super.key});

  @override
  State<OllamaModelsScreen> createState() => _OllamaModelsScreenState();
}

class _OllamaModelsScreenState extends State<OllamaModelsScreen> {
  static const AppBridge _bridge = AndroidApps();
  late final LocalTermuxAgentProvider _termux;

  DeviceInfo _deviceInfo = DeviceInfo.unknown;
  List<String> _downloaded = [];
  bool _loading = true;
  bool _diagRunning = false; // diagnóstico local en curso
  bool _benchRunning = false; // benchmark GPU (llama.cpp) en curso
  bool _gpuProbeRunning = false; // sonda de alcance de GPU (OpenCL/Vulkan)
  String? _selectedTag; // modelo recién aplicado (para marcar "en uso")
  String? _pinningTag; // modelo cuyo «Usar» está en curso (spinner + bloqueo)

  // Motor local mostrado: CPU (Ollama :11434) o GPU (OlliteRT :8000). El motor
  // ACTIVO se deriva de la verdad (base_url en config.yaml, vía el bridge); este
  // campo es además qué panel se muestra y por defecto arranca en el activo.
  _LocalEngine _engine = _LocalEngine.cpu;
  // Último sondeo de OlliteRT (estado del servidor :8000 + modelos servidos).
  OlliteRtSnapshot? _olliteRt;
  bool _olliteRtProbing = false; // sondeo de OlliteRT en curso

  // Estado del daemon Ollama. En móvil real corre on-device (Termux); si no
  // está instalado, las descargas fallan con "connection refused" (socket). Por
  // eso distinguimos «no instalado» de «no arrancado» y ofrecemos instalarlo.
  _OllamaStage _stage = _OllamaStage.checking;
  // Mensaje de progreso del estado actual (descarga/arranque), para no dejar al
  // usuario ante un spinner ciego durante la instalación de Ollama.
  String? _ollamaMsg;
  // ¿El último error vino de instalar (true) o de arrancar el daemon (false)?
  // Decide qué log mostrar y qué acción reintenta el botón en estado [error].
  bool _errorFromInstall = false;

  final Map<String, OllamaPullProgress> _pulls = {};
  final Map<String, StreamSubscription<OllamaPullProgress>> _pullSubs = {};
  final Set<String> _deleting = {}; // tags con borrado en curso
  final TextEditingController _customTagCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _termux = LocalTermuxAgentProvider(apps: _bridge);
    _init();
  }

  @override
  void dispose() {
    for (final s in _pullSubs.values) {
      s.cancel();
    }
    _customTagCtrl.dispose();
    _termux.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final info = await _bridge.deviceInfo();
    if (mounted) setState(() => _deviceInfo = info);
    // Si el móvil arrastra un bridge viejo (la causa del 404 y de que "Usar" no
    // surta efecto), reemplázalo en silencio al abrir la pantalla. Solo reinicia
    // si la versión NO coincide con la de este APK, así en uso normal es un no-op.
    if (widget.connection.onDeviceLoopback) {
      unawaited(_ensureFreshBridge());
    }
    await _refresh();
    // Restaura el badge «en uso» desde la verdad (config.yaml), no desde el
    // estado del widget: `_selectedTag` solo vivía en memoria y se perdía al
    // recrear la pantalla (salir de la app / cambiar de ventana) → el modelo
    // parecía «desmarcarse». Lee el modelo activo real por el bridge.
    if (widget.connection.onDeviceLoopback) {
      unawaited(_loadActiveModel());
      unawaited(_probeOlliteRt());
    }
  }

  /// Sondea OlliteRT (el motor GPU) por loopback `127.0.0.1:8000`: ¿está el
  /// servidor arriba y qué modelos sirve? No pasa por el bridge — la propia app
  /// llega a OlliteRT directo (mismo móvil). Silencioso: si no responde, deja un
  /// snapshot `unreachable` que la UI traduce en «instala/abre OlliteRT».
  Future<void> _probeOlliteRt() async {
    if (_olliteRtProbing) return;
    if (mounted) setState(() => _olliteRtProbing = true);
    final client = OlliteRtClient();
    try {
      final snap = await client.snapshot();
      if (mounted) setState(() => _olliteRt = snap);
    } catch (e) {
      if (mounted) {
        setState(() => _olliteRt = OlliteRtSnapshot(
              status: OlliteRtStatus.unreachable,
              error: e.toString(),
            ));
      }
    } finally {
      client.close();
      if (mounted) setState(() => _olliteRtProbing = false);
    }
  }

  /// Lee el modelo activo de config.yaml (vía el bridge) y marca su badge «en
  /// uso». Silencioso: si el bridge no responde, no marca nada.
  Future<void> _loadActiveModel() async {
    try {
      final base = widget.connection.derivedBridgeUrl;
      final token =
          await BridgeClient.provision(base, widget.connection.apiKey.trim());
      if (token == null || token.isEmpty) return;
      final client = BridgeClient(baseUrl: base, token: token);
      try {
        final res = await client.getActiveModel();
        final active = (res['model'] ?? '').toString().trim();
        final baseUrl = (res['base_url'] ?? '').toString().trim();
        if (mounted) {
          setState(() {
            if (active.isNotEmpty) _selectedTag = active;
            // El motor activo es la verdad de config.yaml: si apunta al puerto
            // de OlliteRT (:8000) estamos en GPU; si no, en CPU (Ollama :11434).
            _engine = baseUrl.contains(':$kOlliteRtDefaultPort')
                ? _LocalEngine.gpu
                : _LocalEngine.cpu;
          });
        }
      } finally {
        client.close();
      }
    } catch (_) {
      // sin conexión con el bridge → no marcamos nada
    }
  }

  /// Diagnóstico RÁPIDO del daemon (sin arrancar nada ni esperar 45 s). Es lo
  /// que corre al entrar a la pantalla: sondea el puerto y, si no responde,
  /// comprueba si el binario está instalado para decidir entre «arrancar»,
  /// «instalar» o «reintentar». NUNCA bloquea la pantalla esperando a que el
  /// daemon suba: eso es ahora una acción explícita del usuario ([_startDaemon]).
  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);

    // 1) ¿Responde ya el daemon en :11434? (sonda corta, 3 s)
    if (await _termux.isOllamaRunning()) {
      final models = await _termux.listOllamaModels();
      if (!mounted) return;
      setState(() {
        _stage = _OllamaStage.ready;
        _downloaded = models;
        _ollamaMsg = null;
        _loading = false;
      });
      return;
    }

    // 2) No responde. ¿Está instalado el binario? (sonda del FS de Termux, no
    //    arranca nada → no se cuelga). Decide el estado accionable.
    final installed = await _termux.isOllamaInstalled();
    if (!mounted) return;
    setState(() {
      _downloaded = [];
      _loading = false;
      _ollamaMsg = null;
      _stage = switch (installed) {
        // Instalado pero el daemon no responde: NO esperamos en :11434, avisamos
        // y ofrecemos arrancar/reparar (causa típica: Android congeló Termux).
        true => _OllamaStage.stopped,
        false => _OllamaStage.notInstalled,
        // Termux no respondió la sonda (sin allow-external-apps / cerrado).
        null => _OllamaStage.unknown,
      };
    });
  }

  /// Arranca el daemon Ollama (instalado pero parado) con progreso en vivo, SIN
  /// bloquear toda la pantalla. Si sube, refresca; si no, deja un error
  /// accionable con «Ver log del servidor» (la causa real del fallo de arranque).
  Future<void> _startDaemon() async {
    if (mounted) {
      setState(() {
        _stage = _OllamaStage.starting;
        _ollamaMsg = 'Starting the server on :11434…';
      });
    }
    await _termux.startOllama();
    final ok = await _termux.waitUntilOllamaReady(
        timeout: const Duration(seconds: 30));
    if (!mounted) return;
    if (ok) {
      await _refresh();
      return;
    }
    setState(() {
      _stage = _OllamaStage.error;
      _errorFromInstall = false;
      _ollamaMsg = 'The server did not respond on :11434. Android usually '
          'froze Termux: open Termux, leave it in the foreground and retry. '
          'Tap "View server log" for the exact cause.';
    });
  }

  /// Garantiza que Ollama esté disponible. Si ya responde → listo. Si no,
  /// intenta arrancarlo; si tras arrancar sigue sin responder asumimos que no
  /// está instalado (en móvil real es la causa del "error de socket/puerto") y
  /// dejamos el estado en [notInstalled] para ofrecer la instalación. Cuando
  /// [tryInstall] es true (descarga iniciada por el usuario) sí instala y espera.
  /// Devuelve true solo si el daemon quedó respondiendo.
  Future<bool> _ensureOllama({bool tryInstall = false}) async {
    if (await _termux.isOllamaRunning()) {
      if (mounted) setState(() => _stage = _OllamaStage.ready);
      return true;
    }
    // ¿Está el binario instalado? Si NO, no tiene sentido arrancarlo y esperar
    // 45 s en :11434 (la causa del "buscando en :11434 y nunca carga nada"):
    // vamos directos a "no instalado" (o a instalar si lo pidió el usuario).
    final installed = await _termux.isOllamaInstalled();
    if (installed == false) {
      if (!tryInstall) {
        if (mounted) setState(() => _stage = _OllamaStage.notInstalled);
        return false;
      }
      return _installAndStart();
    }
    if (mounted) setState(() => _stage = _OllamaStage.starting);
    await _termux.startOllama();
    if (await _termux.waitUntilOllamaReady(
        timeout: const Duration(seconds: 45))) {
      if (mounted) setState(() => _stage = _OllamaStage.ready);
      return true;
    }
    // No arrancó: probablemente no está instalado.
    if (!tryInstall) {
      if (mounted) setState(() => _stage = _OllamaStage.notInstalled);
      return false;
    }
    return _installAndStart();
  }

  /// Instala Ollama (`pkg install ollama`) y espera a que arranque. La
  /// instalación corre en Termux en segundo plano (sin stdout), así que se
  /// sondea arrancando el daemon hasta que responda o se agote el tiempo.
  /// Muestra el log de instalación de Ollama (`~/.hermes/ollama-install.out`)
  /// leído desde Termux, para ver el progreso/error real del `pkg install`.
  Future<void> _showOllamaInstallLog() => _showOllamaLog(server: false);

  /// Muestra el log del DAEMON (`~/.ollama/serve.log`): por qué `ollama serve`
  /// no levanta en :11434 (instalado pero parado).
  Future<void> _showOllamaServeLog() => _showOllamaLog(server: true);

  Future<void> _showOllamaLog({required bool server}) async {
    String? log;
    try {
      log = server
          ? await _termux.readOllamaServeLog()
          : await _termux.readOllamaInstallLog();
    } catch (e) {
      log = 'Could not read the log: $e';
    }
    if (!mounted) return;
    final colors = Theme.of(context).hermes;
    final title = server ? 'Ollama server log' : 'Ollama installation log';
    final empty = server
        ? 'No server log yet. Tap "Start" and come back here '
            'if it does not come up.'
        : 'No log yet. Tap "Install" and come back here if it is slow or '
            'fails.';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              log ?? empty,
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
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<bool> _installAndStart() async {
    if (mounted) {
      setState(() {
        _stage = _OllamaStage.installing;
        _ollamaMsg = 'Downloading Ollama… (pkg install, may take a few minutes)';
      });
    }
    await _termux.installOllama();
    // Sondea la PRESENCIA del binario (no el daemon): así sabemos cuándo acabó
    // la descarga y damos feedback real, en vez de un spinner ciego de 3 min.
    final deadline = DateTime.now().add(const Duration(minutes: 6));
    var installed = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      // Si el usuario salió de la pantalla (back), dejamos de sondear: la
      // instalación sigue en Termux en segundo plano y se verá al volver.
      if (!mounted) return false;
      if (await _termux.isOllamaInstalled() == true) {
        installed = true;
        break;
      }
    }
    if (!installed) {
      if (mounted) {
        setState(() {
          _stage = _OllamaStage.error;
          _errorFromInstall = true;
          _ollamaMsg = 'The installation did not finish in time. '
              'Tap "View installation log" to see why.';
        });
      }
      return false;
    }
    if (mounted) {
      setState(() => _ollamaMsg = 'Installed. Starting the server on :11434…');
    }
    await _termux.startOllama();
    if (await _termux.waitUntilOllamaReady(
        timeout: const Duration(seconds: 45))) {
      if (mounted) {
        setState(() {
          _stage = _OllamaStage.ready;
          _ollamaMsg = null;
        });
      }
      return true;
    }
    if (mounted) {
      setState(() {
        _stage = _OllamaStage.error;
        _errorFromInstall = false;
        _ollamaMsg = 'Ollama installed but did not respond on :11434. '
            'Tap "View server log" for the cause.';
      });
    }
    return false;
  }

  bool _isInstalled(String tag) {
    final t = tag.toLowerCase();
    return _downloaded.any((m) => m.toLowerCase() == t);
  }

  Future<void> _download(DownloadableModel m) => _startPull(m.tag, m.name);

  /// Descarga por tag libre: cualquier modelo del registro de Ollama (ej.
  /// `llama3.3`) o de HuggingFace (`hf.co/usuario/repo[:cuantización]`).
  Future<void> _downloadCustomTag() async {
    final tag = _customTagCtrl.text.trim();
    if (tag.isEmpty) return;
    FocusScope.of(context).unfocus();
    _customTagCtrl.clear();
    await _startPull(tag, tag);
  }

  /// Núcleo de descarga (barra de progreso real vía /api/pull). Compartido por
  /// el catálogo y el tag libre.
  Future<void> _startPull(String tag, String name) async {
    if (_pulls.containsKey(tag) || _isInstalled(tag)) return;
    final s = Strings.of(context);
    // Feedback inmediato: evita que el botón parezca inactivo durante el
    // check de isOllamaRunning (timeout 3 s). También cierra la race condition
    // de doble tap porque el guard del inicio ya ve la entry en _pulls.
    if (mounted) {
      setState(() => _pulls[tag] = OllamaPullProgress(
            status: s.ollStageChecking,
            fraction: null,
            done: false,
          ));
    }
    if (!await _termux.isOllamaRunning()) {
      if (!mounted) return;
      // Arranca y, si hace falta, instala Ollama (causa típica del fallo en
      // móvil real: no estaba instalado → connection refused).
      setState(() => _pulls[tag] = OllamaPullProgress(
            status: s.ollStageStarting,
            fraction: null,
            done: false,
          ));
      final ready = await _ensureOllama(tryInstall: true);
      if (!ready) {
        if (!mounted) return;
        setState(() => _pulls.remove(tag));
        _toast(_stage == _OllamaStage.error
            ? s.ollInstallFailed
            : s.ollNoResponse);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _pulls[tag] = OllamaPullProgress(
          status: s.ollStageStarting,
          fraction: null,
          done: false,
        ));
    final sub = _termux.pullOllamaModelStream(tag).listen(
      (p) {
        if (mounted) setState(() => _pulls[tag] = p);
      },
      onError: (Object e) async {
        await _pullSubs.remove(tag)?.cancel();
        if (!mounted) return;
        setState(() => _pulls.remove(tag));
        final msg = e.toString().contains('Connection refused')
            ? s.ollamaNotActive
            : s.ollDownloadFailed(name);
        _toast(msg);
      },
      onDone: () async {
        _pullSubs.remove(tag);
        final models = await _termux.listOllamaModels();
        if (!mounted) return;
        setState(() {
          _downloaded = models;
          _pulls.remove(tag);
        });
      },
    );
    _pullSubs[tag] = sub;
  }

  /// Cancela una descarga en curso: cierra el stream HTTP (lo que aborta el
  /// pull del lado de ollama) y limpia el progreso. El tag vuelve a estar
  /// disponible para «Descargar».
  Future<void> _cancelPull(String tag) async {
    final s = Strings.of(context);
    await _pullSubs.remove(tag)?.cancel();
    if (!mounted) return;
    setState(() => _pulls.remove(tag));
    _toast(s.ollDownloadCancelled(tag));
  }

  /// Borra un modelo descargado (`DELETE /api/delete`), con confirmación según
  /// la política de aprobación (Solo-lectura bloquea; YOLO directo; Preguntar
  /// confirma).
  Future<void> _delete(String tag) async {
    final s = Strings.of(context);
    final gate = approvalGate(
      context,
      instanceId: widget.connection.id,
      readOnlyInstance: widget.connection.readOnly,
      risk: CommandRisk.medium,
      patternKey: 'model_delete',
    );
    if (gate == ActionGate.blocked) {
      showReadOnlyNotice(context);
      return;
    }
    if (gate == ActionGate.ask) {
      final ok = await _confirm(
        s.ollDeleteModelTitle,
        s.ollDeleteModelBody(tag),
        s.ollDelete,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _deleting.add(tag));
    final removed = await _termux.deleteOllamaModel(tag);
    if (!mounted) return;
    if (removed) {
      final models = await _termux.listOllamaModels();
      if (!mounted) return;
      setState(() {
        _downloaded = models;
        _deleting.remove(tag);
        if (_selectedTag == tag) _selectedTag = null;
      });
      _toast(s.ollModelDeleted(tag));
    } else {
      setState(() => _deleting.remove(tag));
      _toast(s.ollDeleteFailed(tag));
    }
  }

  /// Diálogo de confirmación simple (sin TextField → seguro con showDialog).
  Future<bool> _confirm(String title, String message, String confirmLabel) async {
    final colors = Theme.of(context).hermes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Strings.of(context).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel, style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Fija un modelo descargado como modelo activo del agente, vía la API del
  /// dashboard (`model/set`, provider custom + base_url de Ollama). Es la misma
  /// vía que usa la pantalla Modelos para instancias remotas → fiable e
  /// inmediata (sin RUN_COMMAND).
  Future<void> _use(String tag) async {
    final s = Strings.of(context);
    // Política de aprobación: cambiar el modelo activo es reversible → riesgo
    // bajo. YOLO lo aplica directo; Preguntar confirma; Solo-lectura bloquea.
    if (!await confirmMutatingAction(
      context,
      instanceId: widget.connection.id,
      readOnlyInstance: widget.connection.readOnly,
      risk: CommandRisk.low,
      title: s.ollSetActiveTitle,
      detail: tag,
    )) {
      return;
    }
    // Marca este modelo como «aplicando» → spinner en su botón y bloqueo del
    // resto (evita que parezca que «no hace nada» durante los segundos que tarda
    // el saneo del bridge + provisión + escritura de config).
    if (mounted) setState(() => _pinningTag = tag);
    try {
      // Verifica que Ollama esté activo y tenga el modelo cargado antes de
      // fijarlo, para no dejar al agente apuntando a un modelo que no responde.
      if (!await _ensureOllama()) {
        if (mounted) _toast(s.ollNotInstalled);
        return;
      }
      if (!await _termux.isOllamaModelAvailable(tag)) {
        if (mounted) _toast(s.ollModelNotLoaded(tag));
        return;
      }
      // En local el Dashboard (`/api/model/set`, :9119) NO corre on-device, así
      // que esa vía falla en silencio y el modelo "no se aplica". Escribimos el
      // bloque `model:` de config.yaml por el bridge (:9131), que sí está vivo;
      // el chat local (oneshot `hermes -z`) relee config.yaml en cada turno, así
      // que el cambio surte efecto sin reiniciar el agente.
      if (widget.connection.onDeviceLoopback) {
        final base = widget.connection.derivedBridgeUrl;
        // Si el móvil tenía un bridge viejo, `model/set` no persistía (servía
        // código antiguo). Reemplázalo por el de esta app antes de fijar el modelo.
        await _ensureFreshBridge();
        String? token;
        try {
          token =
              await BridgeClient.provision(base, widget.connection.apiKey.trim());
        } catch (e) {
          debugPrint('[ollama] excepción silenciada (fallback: token = null): $e');
          token = null;
        }
        if (token == null || token.isEmpty) {
          if (mounted) _toast(s.ollPinFailed);
          return;
        }
        final client = BridgeClient(baseUrl: base, token: token);
        try {
          await client.setModel(
            provider: 'custom',
            model: tag,
            modelBaseUrl: 'http://127.0.0.1:11434/v1',
            contextLength: 65536,
          );
          if (!mounted) return;
          setState(() => _selectedTag = tag);
          _toast(s.ollModelPinned(tag));
        } catch (e) {
          if (mounted) _toast(s.ollPinFailedErr(e.toString()));
        } finally {
          client.close();
        }
        return;
      }
      final client = DashboardClient.lazy(widget.connection);
      try {
        final ok = await client.setActiveModel(
          providerSlug: 'custom',
          modelId: tag,
          baseUrl: 'http://127.0.0.1:11434/v1',
        );
        if (!mounted) return;
        if (ok) {
          setState(() => _selectedTag = tag);
          _toast(s.ollModelPinned(tag));
        } else {
          _toast(s.ollPinFailed);
        }
      } catch (e) {
        if (mounted) _toast(s.ollPinFailedErr(e.toString()));
      } finally {
        client.close();
      }
    } finally {
      if (mounted) setState(() => _pinningTag = null);
    }
  }

  /// Fija como modelo activo de Hermes uno SERVIDO por OlliteRT (motor GPU).
  /// Igual que [_use] pero apuntando `base_url` a `127.0.0.1:8000/v1` en vez de
  /// a Ollama (:11434). No verifica Ollama (no interviene); confía en el estado
  /// real de `/v1/models` que ya cruzó la UI antes de ofrecer «Usar».
  Future<void> _useOlliteRt(String modelId) async {
    final s = Strings.of(context);
    if (!await confirmMutatingAction(
      context,
      instanceId: widget.connection.id,
      readOnlyInstance: widget.connection.readOnly,
      risk: CommandRisk.low,
      title: s.ollSetActiveTitle,
      detail: modelId,
    )) {
      return;
    }
    if (!widget.connection.onDeviceLoopback) return;
    if (mounted) setState(() => _pinningTag = modelId);
    try {
      final base = widget.connection.derivedBridgeUrl;
      await _ensureFreshBridge();
      String? token;
      try {
        token =
            await BridgeClient.provision(base, widget.connection.apiKey.trim());
      } catch (e) {
        debugPrint('[ollama] excepción silenciada (fallback: token = null): $e');
        token = null;
      }
      if (token == null || token.isEmpty) {
        if (mounted) _toast(s.ollPinFailed);
        return;
      }
      final client = BridgeClient(baseUrl: base, token: token);
      try {
        await client.setModel(
          provider: 'custom',
          model: modelId,
          modelBaseUrl: kOlliteRtV1BaseUrl,
          contextLength: 65536,
        );
        if (!mounted) return;
        setState(() {
          _selectedTag = modelId;
          _engine = _LocalEngine.gpu;
        });
        _toast(s.ollModelPinned(modelId));
      } catch (e) {
        if (mounted) _toast(s.ollPinFailedErr(e.toString()));
      } finally {
        client.close();
      }
    } finally {
      if (mounted) setState(() => _pinningTag = null);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Garantiza que el bridge EN EJECUCIÓN sea la versión que trae ESTE APK. Un
  /// bridge viejo de una instalación anterior puede seguir vivo (pidfile obsoleto
  /// + retiene :9131) sirviendo código antiguo: los endpoints nuevos dan 404 y
  /// `model/set` no persiste — justo el "no me funciona en el móvil". Si la
  /// versión no coincide (o no responde), redepliega el asset y reinicia el
  /// bridge (mata el viejo por pidfile+cmdline+puerto) y espera a que levante la
  /// versión correcta. Devuelve true si al terminar corre la versión esperada.
  Future<bool> _ensureFreshBridge() =>
      _termux.ensureFreshBridge(widget.connection.derivedBridgeUrl);

  /// Ejecuta el diagnóstico de extremo a extremo EN el dispositivo a través del
  /// bridge local (:9131). Convierte el "spinner infinito sin error" en datos
  /// concretos: versión del bridge, modelo en config.yaml, estado de ollama y
  /// sondas de carga cronometradas (64K vs 4K) con un veredicto accionable.
  Future<void> _runDiag() async {
    final base = widget.connection.derivedBridgeUrl;
    setState(() => _diagRunning = true);
    // La sonda de carga puede tardar (la 1ª carga de un modelo con contexto 64K
    // en un móvil modesto va lenta), así que avisamos con un progreso modal.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                'Diagnosing the local agent…\n'
                'If the bridge is out of date I will restart it.\n'
                'This can take up to ~1 min.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
    String summary;
    try {
      // Antes de nada, asegura que corre el bridge de ESTE APK. Si tu móvil tenía
      // uno viejo (causa del 404), esto lo reemplaza por el actual y reintenta.
      final fresh = await _ensureFreshBridge();
      final token =
          await BridgeClient.provision(base, widget.connection.apiKey.trim());
      if (token == null || token.isEmpty) {
        summary = 'Could not connect to the local bridge (:9131).\n'
            '${fresh ? '' : 'Además, no pude actualizar el bridge a la versión '
                'of this app (${AgentRuntimeConsts.expectedBridgeVersion}).\n'}'
            'Is the local agent running? Start it and retry.';
      } else {
        final client = BridgeClient(baseUrl: base, token: token);
        try {
          final res = await client.localDiag();
          final s = (res['summary'] as String?)?.trim() ?? '';
          summary = s.isNotEmpty
              ? s
              : 'The diagnostic returned no summary.\n$res';
        } finally {
          client.close();
        }
      }
    } catch (e) {
      summary = 'Could not run the diagnostic: $e';
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // cierra el progreso
    setState(() => _diagRunning = false);
    await _showDiagDialog(summary);
  }

  /// Lanza el benchmark de GPU (llama.cpp Vulkan vs CPU) en el dispositivo, para
  /// decidir con datos reales si la GPU del móvil acelera el modelo local.
  /// Reutiliza el saneo del bridge ([_ensureFreshBridge]) y el endpoint
  /// `/bridge/diag/llamacpp`. Puede tardar varios minutos.
  Future<void> _runBench() async {
    final base = widget.connection.derivedBridgeUrl;
    setState(() => _benchRunning = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                'Testing the GPU with llama.cpp…\n'
                'I install llama.cpp if missing and measure GPU vs CPU.\n'
                'This can take SEVERAL minutes. Do not close the app.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
    String summary;
    try {
      final fresh = await _ensureFreshBridge();
      final token =
          await BridgeClient.provision(base, widget.connection.apiKey.trim());
      if (token == null || token.isEmpty) {
        summary = 'Could not connect to the local bridge (:9131).\n'
            '${fresh ? '' : 'Además, no pude actualizar el bridge a la versión '
                'of this app (${AgentRuntimeConsts.expectedBridgeVersion}).\n'}'
            'Is the local agent running? Start it and retry.';
      } else {
        final client = BridgeClient(baseUrl: base, token: token);
        try {
          final res = await client.llamacppBench();
          final s = (res['summary'] as String?)?.trim() ?? '';
          summary = s.isNotEmpty ? s : 'The benchmark returned no summary.\n$res';
        } finally {
          client.close();
        }
      }
    } catch (e) {
      summary = 'Could not run the benchmark: $e';
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // cierra el progreso
    setState(() => _benchRunning = false);
    await _showDiagDialog(summary, title: 'GPU benchmark (llama.cpp)');
  }

  /// Sonda de ALCANCE de la GPU: ¿deja Android ver la GPU (OpenCL/Vulkan) a
  /// Termux? Es la pregunta que decide si CUALQUIER motor por GPU es viable en
  /// este móvil, antes de invertir horas en montar uno. El Android moderno suele
  /// bloquear el driver del vendor por namespace del linker.
  Future<void> _runGpuProbe() async {
    final base = widget.connection.derivedBridgeUrl;
    setState(() => _gpuProbeRunning = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                'Probing the system GPU…\n'
                'I install clinfo/vulkan-tools and check whether OpenCL or Vulkan '
                'can see your Mali. This can take a couple of minutes.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
    String summary;
    try {
      final fresh = await _ensureFreshBridge();
      final token =
          await BridgeClient.provision(base, widget.connection.apiKey.trim());
      if (token == null || token.isEmpty) {
        summary = 'Could not connect to the local bridge (:9131).\n'
            '${fresh ? '' : 'Además, no pude actualizar el bridge a la versión '
                'of this app (${AgentRuntimeConsts.expectedBridgeVersion}).\n'}'
            'Is the local agent running? Start it and retry.';
      } else {
        final client = BridgeClient(baseUrl: base, token: token);
        try {
          final res = await client.gpuProbe();
          final s = (res['summary'] as String?)?.trim() ?? '';
          summary = s.isNotEmpty ? s : 'The probe returned no summary.\n$res';
        } finally {
          client.close();
        }
      }
    } catch (e) {
      summary = 'Could not run the GPU probe: $e';
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // cierra el progreso
    setState(() => _gpuProbeRunning = false);
    await _showDiagDialog(summary, title: 'GPU probe (OpenCL/Vulkan)');
  }

  Future<void> _showDiagDialog(String summary,
      {String title = 'Local diagnostic'}) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(
            summary,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: summary));
              _toast('Diagnostic copied');
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(Strings.of(context).ollTitle),
        actions: [
          if (widget.connection.onDeviceLoopback)
            IconButton(
              icon: const Icon(Icons.health_and_safety_outlined),
              tooltip: 'Local diagnostic',
              onPressed: _diagRunning ? null : _runDiag,
            ),
          if (widget.connection.onDeviceLoopback)
            IconButton(
              icon: const Icon(Icons.developer_board_outlined),
              tooltip: 'GPU available? (OpenCL/Vulkan)',
              onPressed: _gpuProbeRunning ? null : _runGpuProbe,
            ),
          if (widget.connection.onDeviceLoopback)
            IconButton(
              icon: const Icon(Icons.speed_outlined),
              tooltip: 'Test GPU (llama.cpp)',
              onPressed: _benchRunning ? null : _runBench,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: Strings.of(context).ollRefresh,
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _loading
          ? Center(child: TuiLoader(label: Strings.of(context).ollSearching))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (widget.connection.onDeviceLoopback) ...[
                  _engineSelector(colors),
                  const SizedBox(height: 16),
                ],
                if (_engine == _LocalEngine.gpu)
                  ..._gpuPanel(colors)
                else
                  ..._cpuPanel(colors),
              ],
            ),
    );
  }

  /// Selector de motor local: **GPU (OlliteRT)** vs **CPU (Ollama)**. Solo en
  /// local. El segmento marcado decide qué panel se ve y por defecto arranca en
  /// el motor ACTIVO (el de config.yaml). El cambio de panel no toca config; el
  /// motor se aplica al pulsar «Usar» en un modelo del panel correspondiente.
  Widget _engineSelector(HermesThemeColors colors) {
    final caption = _engine == _LocalEngine.gpu
        ? 'GPU: OlliteRT runs the model on the phone GPU/NPU (faster).'
        : 'CPU: on-device Ollama. Optimized just-in-case fallback.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<_LocalEngine>(
            segments: const [
              ButtonSegment(
                value: _LocalEngine.gpu,
                icon: Icon(Icons.bolt, size: 16),
                label: Text('GPU · OlliteRT'),
              ),
              ButtonSegment(
                value: _LocalEngine.cpu,
                icon: Icon(Icons.memory, size: 16),
                label: Text('CPU · Ollama'),
              ),
            ],
            selected: {_engine},
            showSelectedIcon: false,
            onSelectionChanged: (sel) {
              setState(() => _engine = sel.first);
              if (sel.first == _LocalEngine.gpu) unawaited(_probeOlliteRt());
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
        ),
      ],
    );
  }

  /// Panel CPU: las secciones de Ollama de siempre (estado + descargados + tag
  /// manual + catálogo). Es el fallback optimizado «por si acaso».
  List<Widget> _cpuPanel(HermesThemeColors colors) => [
        _statusBanner(colors),
        HermesInfoBanner(Strings.of(context).ollIntro, icon: Icons.memory),
        const SizedBox(height: 16),
        _downloadedSection(colors),
        const SizedBox(height: 20),
        _customTagSection(colors),
        const SizedBox(height: 20),
        _catalogSection(colors),
      ];

  /// Panel GPU: estado de OlliteRT + modelos servidos (con «Usar») + acceso a
  /// la tienda de modelos `.litertlm`. Si OlliteRT no responde, guía para
  /// instalarlo/abrirlo.
  List<Widget> _gpuPanel(HermesThemeColors colors) {
    final snap = _olliteRt;
    final running = snap?.isRunning ?? false;
    return [
      _olliteRtStatusCard(colors),
      const SizedBox(height: 16),
      if (running) ...[
        _servedModelsSection(colors),
        const SizedBox(height: 20),
      ],
      _storeButton(colors),
    ];
  }

  /// Tarjeta de estado de OlliteRT: servidor ↑/↓, nº de modelos y acciones
  /// (refrescar / abrir-instalar OlliteRT).
  Widget _olliteRtStatusCard(HermesThemeColors colors) {
    final snap = _olliteRt;
    final running = snap?.isRunning ?? false;
    // Muestra «comprobando» SIEMPRE que haya un sondeo en curso, también en las
    // re-comprobaciones (antes solo con snap==null → «Comprobar» parecía muerto
    // al re-pulsarlo porque ya había snapshot).
    final probing = _olliteRtProbing;
    final (IconData icon, String title, Color color) = probing
        ? (Icons.hourglass_empty, 'Checking OlliteRT…', colors.accent)
        : running
            ? (
                Icons.check_circle_outline,
                'OlliteRT running (:$kOlliteRtDefaultPort)',
                colors.success
              )
            : (
                Icons.bolt_outlined,
                'OlliteRT is not responding',
                colors.warning,
              );
    final modelsLine = running
        ? (snap!.models.isEmpty
            ? 'Server up, no models loaded. Start one in OlliteRT.'
            : '${snap.models.length} model(s) served.')
        : 'Install OlliteRT and start the server for a .litertlm model to '
            'use the GPU. The app reaches it over loopback at 127.0.0.1:$kOlliteRtDefaultPort.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (probing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              else
                Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Text(
              modelsLine,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill(
                colors,
                icon: Icons.refresh,
                label: 'Check',
                color: colors.accent,
                onTap: _probeOlliteRt,
                busy: _olliteRtProbing,
              ),
              _pill(
                colors,
                icon: running ? Icons.open_in_new : Icons.download_outlined,
                label: running ? 'Open OlliteRT' : 'Install OlliteRT (beta)',
                color: colors.accent,
                onTap: _openOlliteRt,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Lista los modelos que OlliteRT reporta en `/v1/models`, cruzados con el
  /// catálogo para nombre bonito, con acción «Usar» y badge «en uso».
  Widget _servedModelsSection(HermesThemeColors colors) {
    final snap = _olliteRt;
    final models = snap?.models ?? const <OlliteRtServedModel>[];
    final s = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Models in OlliteRT',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        for (final m in models) _servedModelTile(colors, m, s),
      ],
    );
  }

  Widget _servedModelTile(
    HermesThemeColors colors,
    OlliteRtServedModel m,
    Strings s,
  ) {
    final catalog = litertModelForServedId(m.id);
    final name = catalog?.name ?? m.id;
    final inUse = _engine == _LocalEngine.gpu && _selectedTag == m.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                if (catalog != null)
                  Text(
                    '${catalog.family} · ${catalog.contextLabel} · ${catalog.sizeGb} GB',
                    style: TextStyle(
                        fontSize: 11, color: colors.textSecondary),
                  )
                else
                  Text(
                    m.id,
                    style: TextStyle(
                        fontSize: 11, color: colors.textSecondary),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (inUse)
            HermesPill(label: s.ollInUse, color: colors.success)
          else
            _pill(
              colors,
              icon: Icons.play_arrow,
              label: s.ollUse,
              color: colors.accent,
              onTap: _pinningTag == null ? () => _useOlliteRt(m.id) : null,
              busy: _pinningTag == m.id,
            ),
        ],
      ),
    );
  }

  /// Botón de acceso a la tienda de modelos `.litertlm`.
  Widget _storeButton(HermesThemeColors colors) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.storefront_outlined, size: 18),
        label: const Text('GPU model store'),
        onPressed: () async {
          final picked = await Navigator.of(context).push<String>(
            MaterialPageRoute<String>(
              builder: (_) => LitertStoreScreen(
                connection: widget.connection,
                deviceInfo: _deviceInfo,
                served: _olliteRt?.models ?? const [],
                activeModelId:
                    _engine == _LocalEngine.gpu ? _selectedTag : null,
              ),
            ),
          );
          if (picked != null && picked.isNotEmpty) {
            await _useOlliteRt(picked);
          }
        },
      ),
    );
  }

  /// Abre OlliteRT por intent (probando sus package ids); si no está instalado,
  /// abre la página de releases en el navegador.
  Future<void> _openOlliteRt() async {
    for (final pkg in kOlliteRtPackageIds) {
      try {
        if (await _bridge.launch(pkg)) return;
      } catch (_) {
        // siguiente sabor
      }
    }
    // No está instalado: Android NO permite que una app instale otra en
    // silencio, así que abrimos la página de releases para que el usuario baje
    // e instale el APK a mano (luego vuelva aquí y pulse «Comprobar»).
    try {
      final ok = await launchUrl(
        Uri.parse(kOlliteRtReleasesUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception('launchUrl=false');
      if (mounted) {
        _toast('Opening the OlliteRT download (only a beta exists for '
            'now). Install the latest one by hand and tap "Check" again.');
      }
    } catch (e) {
      debugPrint('[ollama] excepción silenciada (se avisa al usuario y se sigue): $e');
      if (mounted) {
        _toast('Could not open the OlliteRT download '
            '($kOlliteRtReleasesUrl).');
      }
    }
  }

  /// Banner de estado del daemon Ollama. Para los estados accionables
  /// (no instalado / error) ofrece un botón Instalar/Reintentar.
  Widget _statusBanner(HermesThemeColors colors) {
    final s = Strings.of(context);
    // Estado normal y silencioso cuando ya está listo: no añade ruido.
    if (_stage == _OllamaStage.ready || _stage == _OllamaStage.checking) {
      return const SizedBox.shrink();
    }
    final bool busy =
        _stage == _OllamaStage.installing || _stage == _OllamaStage.starting;
    final (IconData icon, String text, Color color) = switch (_stage) {
      _OllamaStage.starting => (Icons.play_circle_outline, s.ollStageStarting, colors.accent),
      _OllamaStage.installing => (Icons.downloading, s.ollStageInstalling, colors.accent),
      _OllamaStage.stopped => (
          Icons.pause_circle_outline,
          'Ollama is installed but the server is not responding on :11434.',
          colors.warning
        ),
      _OllamaStage.notInstalled => (Icons.info_outline, s.ollNotInstalled, colors.warning),
      _OllamaStage.unknown => (
          Icons.help_outline,
          'Could not check Ollama (Termux did not respond).',
          colors.warning
        ),
      _OllamaStage.error => (Icons.error_outline, s.ollStartError, colors.error),
      _ => (Icons.info_outline, '', colors.textSecondary),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              else
                Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          // Mensaje de progreso en vivo (descarga/arranque/error concreto).
          if (_ollamaMsg != null && _ollamaMsg!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                _ollamaMsg!,
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
              ),
            ),
          ],
          ..._bannerActions(colors, s),
        ],
      ),
    );
  }

  /// Botones del banner según el estado. Cada estado accionable ofrece su par
  /// «Ver log» (el log relevante) + acción primaria (Arrancar/Instalar/Reintentar).
  List<Widget> _bannerActions(HermesThemeColors colors, Strings s) {
    Widget logPill(String label, {required bool server}) => _pill(
          colors,
          icon: Icons.article_outlined,
          label: label,
          color: colors.textSecondary,
          onTap: server ? _showOllamaServeLog : _showOllamaInstallLog,
        );
    Widget primary(IconData icon, String label, Future<void> Function() onTap) =>
        _pill(colors, icon: icon, label: label, color: colors.accent,
            onTap: () => onTap());

    final (String hint, List<Widget> buttons) = switch (_stage) {
      _OllamaStage.stopped => (
          'The server is not started. Tap "Start" to bring it up on :11434.',
          [
            logPill('View server log', server: true),
            primary(Icons.play_arrow_rounded, 'Start', _startDaemon),
          ],
        ),
      _OllamaStage.notInstalled => (
          s.ollNotInstalledHint,
          [
            logPill('View log', server: false),
            primary(Icons.download_rounded, s.ollInstallNow, () async {
              final ok = await _installAndStart();
              if (ok) await _refresh();
            }),
          ],
        ),
      _OllamaStage.unknown => (
          'Open Termux (leave it in the foreground) and retry the diagnostic.',
          [primary(Icons.refresh_rounded, s.ollRetry, _refresh)],
        ),
      _OllamaStage.error => (
          _errorFromInstall ? s.ollNotInstalledHint : '',
          [
            logPill(_errorFromInstall ? 'View log' : 'View server log',
                server: !_errorFromInstall),
            primary(Icons.refresh_rounded, s.ollRetry, () async {
              if (_errorFromInstall) {
                final ok = await _installAndStart();
                if (ok) await _refresh();
              } else {
                await _startDaemon();
              }
            }),
          ],
        ),
      _ => ('', <Widget>[]),
    };

    if (buttons.isEmpty) return const [];
    return [
      if (hint.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(hint, style: TextStyle(fontSize: 11, color: colors.textSecondary)),
      ],
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            buttons[i],
          ],
        ],
      ),
    ];
  }

  Widget _downloadedSection(HermesThemeColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(Strings.of(context).ollSecDownloaded),
        if (_downloaded.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              Strings.of(context).ollNoModels,
              style: TextStyle(fontSize: 12.5, color: colors.textDisabled),
            ),
          )
        else
          ..._downloaded.map((tag) => _downloadedTile(colors, tag)),
      ],
    );
  }

  Widget _downloadedTile(HermesThemeColors colors, String tag) {
    final selected = _selectedTag == tag;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: selected
            ? colors.accent.withValues(alpha: 0.10)
            : colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? colors.accent.withValues(alpha: 0.5)
              : colors.divider.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 15, color: colors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tag,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_deleting.contains(tag))
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: colors.textSecondary),
            )
          else ...[
            if (selected)
              Text(Strings.of(context).ollInUse,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: colors.success,
                  ))
            else
              _pill(colors,
                  icon: Icons.check_rounded,
                  label: Strings.of(context).ollUse,
                  color: colors.accent,
                  onTap: _pinningTag == null ? () => _use(tag) : null,
                  busy: _pinningTag == tag),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              color: colors.error,
              tooltip: Strings.of(context).ollDeleteModelTitle,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: () => _delete(tag),
            ),
          ],
        ],
      ),
    );
  }

  /// Descarga por tag libre + progreso de las descargas que no están en el
  /// catálogo (p.ej. modelos de HuggingFace pegados por el usuario).
  Widget _customTagSection(HermesThemeColors colors) {
    final catalogTags = OllamaModelCatalog.all.map((m) => m.tag).toSet();
    final customPulls = _pulls.keys
        .where((t) => !catalogTags.contains(t) && !_isInstalled(t))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HermesSectionHeader(Strings.of(context).ollSecDownloadByTag),
        Text(
          Strings.of(context).ollCatalogIntro,
          style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customTagCtrl,
                style: TextStyle(fontSize: 13, color: colors.textPrimary),
                onSubmitted: (_) => _downloadCustomTag(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: Strings.of(context).ollTagHint,
                  hintStyle:
                      TextStyle(fontSize: 12, color: colors.textDisabled),
                  filled: true,
                  fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        BorderSide(color: colors.divider.withValues(alpha: 0.55)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        BorderSide(color: colors.divider.withValues(alpha: 0.55)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: colors.accent.withValues(alpha: 0.6)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _pill(colors,
                icon: Icons.download_rounded,
                label: Strings.of(context).ollDownload,
                color: colors.accent,
                onTap: _downloadCustomTag),
          ],
        ),
        // Progreso de descargas por tag libre (no están en el catálogo).
        for (final tag in customPulls) ...[
          const SizedBox(height: 8),
          _customPullTile(colors, tag, _pulls[tag]!),
        ],
      ],
    );
  }

  Widget _customPullTile(
      HermesThemeColors colors, String tag, OllamaPullProgress progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tag,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'monospace',
                      color: colors.textPrimary,
                    )),
              ),
              Text(
                progress.fraction != null
                    ? '${(progress.fraction! * 100).toStringAsFixed(0)} %'
                    : '…',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.accent),
              ),
              const SizedBox(width: 4),
              _cancelButton(colors, tag),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 5,
              color: colors.accent,
              backgroundColor: colors.accent.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: 4),
          Text(progress.status.isEmpty ? Strings.of(context).ollDownloading : progress.status,
              style: TextStyle(fontSize: 10, color: colors.textDisabled)),
        ],
      ),
    );
  }

  /// Botón compacto para cancelar una descarga en curso.
  Widget _cancelButton(HermesThemeColors colors, String tag) {
    return IconButton(
      icon: const Icon(Icons.close_rounded, size: 18),
      color: colors.textSecondary,
      tooltip: Strings.of(context).ollCancelDownload,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: () => _cancelPull(tag),
    );
  }

  Widget _catalogSection(HermesThemeColors colors) {
    final totalRamGb = _deviceInfo.totalRamGb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: HermesSectionHeader(Strings.of(context).ollCatalog)),
            if (_deviceInfo.known)
              Text('RAM: ${totalRamGb.toStringAsFixed(1)} GB',
                  style: TextStyle(fontSize: 10.5, color: colors.textDisabled)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          Strings.of(context).ollMarkedNeedMoreRam,
          style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
        ),
        const SizedBox(height: 8),
        ...OllamaModelCatalog.all
            .map((m) => _catalogTile(colors, m, totalRamGb)),
      ],
    );
  }

  Widget _catalogTile(
      HermesThemeColors colors, DownloadableModel m, double totalRamGb) {
    final installed = _isInstalled(m.tag);
    final progress = _pulls[m.tag];
    final pulling = progress != null;
    final fits = totalRamGb <= 0 || m.ramGb <= totalRamGb;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color:
                              fits ? colors.textPrimary : colors.textSecondary,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      '~${m.sizeGb.toStringAsFixed(1)} GB · '
                      'RAM ${m.ramGb.toStringAsFixed(0)} GB',
                      style:
                          TextStyle(fontSize: 11, color: colors.textSecondary),
                    ),
                    if (!fits && !installed && !pulling) ...[
                      const SizedBox(height: 2),
                      Text(Strings.of(context).ollRequiresMoreRam,
                          style:
                              TextStyle(fontSize: 10, color: colors.warning)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (installed)
                _pill(colors,
                    icon: Icons.check_rounded,
                    label: Strings.of(context).ollUse,
                    color: colors.accent,
                    onTap: _pinningTag == null ? () => _use(m.tag) : null,
                    busy: _pinningTag == m.tag)
              else if (pulling) ...[
                Text(
                  progress.fraction != null
                      ? '${(progress.fraction! * 100).toStringAsFixed(0)} %'
                      : '…',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.accent),
                ),
                const SizedBox(width: 4),
                _cancelButton(colors, m.tag),
              ]
              else
                _pill(colors,
                    icon: Icons.download_rounded,
                    label: Strings.of(context).ollDownload,
                    color: fits ? colors.accent : colors.textSecondary,
                    onTap: () => _download(m)),
            ],
          ),
          if (pulling) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 5,
                color: colors.accent,
                backgroundColor: colors.accent.withValues(alpha: 0.12),
              ),
            ),
            const SizedBox(height: 4),
            Text(progress.status.isEmpty ? Strings.of(context).ollDownloading : progress.status,
                style: TextStyle(fontSize: 10, color: colors.textDisabled)),
          ],
        ],
      ),
    );
  }

  /// Botón compacto reutilizable. Da feedback REAL al pulsar (ripple de
  /// `InkWell`), se ve apagado cuando `onTap` es null o `busy` (para que no
  /// parezca que "no hace nada" al tocarlo) y muestra un spinner en lugar del
  /// icono mientras la acción está en curso (`busy`).
  Widget _pill(
    HermesThemeColors colors, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
    bool busy = false,
  }) {
    final enabled = onTap != null && !busy;
    final effColor = enabled ? color : color.withValues(alpha: 0.45);
    final radius = BorderRadius.circular(7);
    return Material(
      color: color.withValues(alpha: enabled ? 0.14 : 0.05),
      borderRadius: radius,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: effColor.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: effColor),
                )
              else
                Icon(icon, size: 14, color: effColor),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: effColor)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Estado del daemon Ollama on-device, para mostrar feedback accionable.
///
/// - [checking]      sondeo inicial rápido en curso.
/// - [starting]      arrancando el daemon (acción del usuario).
/// - [installing]    instalando el paquete (acción del usuario).
/// - [ready]         responde en :11434.
/// - [stopped]       instalado pero el daemon no responde → ofrecer Arrancar.
/// - [notInstalled]  el binario no está → ofrecer Instalar.
/// - [unknown]       Termux no respondió la sonda → ofrecer Reintentar.
/// - [error]         falló una acción (instalar/arrancar) → ofrecer Reintentar.
enum _OllamaStage {
  checking,
  starting,
  installing,
  ready,
  stopped,
  notInstalled,
  unknown,
  error,
}

/// Motor local de inferencia que la app muestra/activa.
/// - [cpu]  Ollama on-device en `:11434` (camino actual, fallback optimizado).
/// - [gpu]  OlliteRT en `:8000` (app nativa que sí ve la GPU/NPU vía LiteRT-LM).
enum _LocalEngine { cpu, gpu }
