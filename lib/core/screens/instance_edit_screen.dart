// Editor de instancia: Gateway y Dashboard/Admin como superficies separadas,
// con auth propia cada una y diagnóstico de conexión integrado.
//
// Sustituye al antiguo diálogo de alta/edición. El tipo de instancia
// (vps/homelab/…) queda como detalle secundario: lo que manda es URL + auth.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../services/bridge_client.dart';
import '../services/connection_diagnostics.dart';
import '../services/connection_manager.dart';
import '../services/pairing_link.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../utils/transport_privacy.dart';
import '../widgets/api_key_help.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_spark_mascot.dart';
import '../widgets/hermes_status_indicator.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';
import 'dashboard_setup_screen.dart';
import 'qr_scan_screen.dart';

enum _DuplicatePairingAction { cancel, openExisting, updateExisting }

class InstanceEditScreen extends StatefulWidget {
  final ConnectionManager connManager;
  final SavedConnection? initial;

  /// Permite probar el flujo completo con un diagnóstico determinista y sin
  /// abrir red. En producción se omite y la pantalla crea su cliente normal.
  final ConnectionDiagnostics? diagnostics;

  /// Inyección acotada para probar el emparejado sin abrir sockets. Producción
  /// usa [BridgeClient] y su provisión autenticada normales.
  final BridgeClientFactory? bridgeClientFactory;
  final BridgeProvisioner? bridgeProvisioner;

  /// Si es true (alta nueva desde el chooser "Escanear QR"), abre el escáner
  /// automáticamente al entrar para rellenar el formulario sin pasos extra.
  final bool autoScanQr;

  /// Enlace de emparejado para precargar el formulario al entrar (alta nueva
  /// desde "pegar enlace" / deep link). Se aplica como un escaneo de QR.
  final PairingLink? initialLink;

  /// Si es true, [initialLink] llegó de un deep link `hermes://pair` tocado
  /// fuera de la app (no de un QR escaneado ni de "pegar enlace" dentro de
  /// la app). Activa el banner de aviso de datos precargados desde un
  /// enlace externo.
  final bool fromDeepLink;

  /// Precarga de un ALTA nueva (p.ej. emparejado manual del agente local):
  /// rellena el formulario pero mantiene el modo "nueva instancia" — título
  /// de alta, token obligatorio e id real generado al guardar. No usar
  /// [initial] con un draft de id vacío: eso guardaba conexiones con id ''
  /// en ConnectionManager y Keystore (spec 028 A-005).
  final SavedConnection? prefill;

  const InstanceEditScreen({
    required this.connManager,
    this.initial,
    this.autoScanQr = false,
    this.initialLink,
    this.fromDeepLink = false,
    this.prefill,
    this.diagnostics,
    this.bridgeClientFactory,
    this.bridgeProvisioner,
    super.key,
  });

  @override
  State<InstanceEditScreen> createState() => _InstanceEditScreenState();
}

class _InstanceEditScreenState extends State<InstanceEditScreen> {
  // General
  late final TextEditingController _nameCtrl;
  late final TextEditingController _notesCtrl;
  bool _readOnly = false;
  late InstanceKind _kind;
  bool _kindManuallySet = false;
  LocalChatMode _localChatMode = LocalChatMode.auto;

  // Gateway
  late final TextEditingController _gatewayUrlCtrl;
  late final TextEditingController _gatewayTokenCtrl;

  // Mobile Bridge. El token existente nunca se muestra en el formulario:
  // campo vacío al editar = conservar el secreto del Keystore.
  late final TextEditingController _bridgeUrlCtrl;
  late final TextEditingController _bridgeTokenCtrl;
  Future<void> _bridgeConfigLoad = Future<void>.value();
  String _storedBridgeToken = '';
  bool _bridgeUrlEdited = false;

  // Dashboard
  late final TextEditingController _dashboardUrlCtrl;
  AuthMode _dashAuthMode = AuthMode.cookieSession;
  late final TextEditingController _dashTokenCtrl;
  late final TextEditingController _dashUserCtrl;
  late final TextEditingController _dashPassCtrl;
  bool _dashUserEdited = false;

  // Diagnóstico
  ConnectionDiagnostics? _diag;
  List<ProbeResult>? _gatewayResults;
  List<ProbeResult>? _dashboardResults;
  List<ProbeResult>? _bridgeResults;
  bool _autoDashBusy = false;
  List<String> _suggestions = const [];
  CapabilityMatrix? _detectedMatrix;
  ServerCapabilities? _serverCaps;
  DiagnosticsReport? _lastReport;
  bool _probing = false;
  String? _diagnosticError;
  bool _saving = false;
  String? _error;

  // Aviso de datos precargados desde un deep link `hermes://pair`: visible
  // hasta que el usuario edite la URL del gateway o guarde.
  bool _showDeepLinkBanner = false;

  // Disclosures de "avanzado" (mobile bridge manual + tipo de instancia): en
  // una instancia ya guardada empiezan colapsados porque son configuración
  // excepcional, no de todos los días. En una alta nueva empiezan abiertos
  // porque el flujo de QR/enlace los rellena y el usuario quiere verlos.
  // Se inicializan en initState (no aquí: `widget` aún no está disponible en
  // los inicializadores de campo de un State).
  bool _bridgeAdvancedExpanded = false;
  bool _kindAdvancedExpanded = false;

  // Usuario/contraseña del Dashboard a mano: plegado siempre al entrar (el
  // camino recomendado es "Autoconfigurar dashboard"). Se abre solo cuando
  // algún flujo deja una contraseña nueva en el formulario, para que siga
  // estando VISIBLE como antes.
  bool _dashCredsExpanded = false;

  // Un pairing puede llegar dos veces (initial link + stream de app_links, o un
  // rebuild mientras se resuelve el primer frame). La huella evita repetir los
  // probes durante esta pantalla.
  int? _automatedPairingFingerprint;
  Future<void>? _pairingAutomationFuture;
  bool _externalPairingPromptOpen = false;

  // Privacidad de transporte de la URL del gateway (aviso de cleartext).
  TransportPrivacyClass _gatewayTransport = TransportPrivacyClass.secure;

  bool get _isNew => widget.initial == null;

  @override
  void initState() {
    super.initState();
    _diag = widget.diagnostics;
    final init = widget.initial;
    _nameCtrl = TextEditingController(text: init?.label ?? '');
    _notesCtrl = TextEditingController(text: init?.notes ?? '');
    _readOnly = init?.readOnly ?? false;
    _kind = init?.kind ?? InstanceKind.vps;
    _kindManuallySet = init != null;
    _localChatMode = init?.localChatMode ?? LocalChatMode.auto;
    // Alta nueva: los disclosures de "avanzado" empiezan abiertos (el flujo de
    // QR/enlace los rellena). Instancia ya guardada: empiezan colapsados.
    _bridgeAdvancedExpanded = init == null;
    _kindAdvancedExpanded = init == null;
    _gatewayUrlCtrl = TextEditingController(
      text: init == null ? '' : init.gatewayUrl,
    );
    _gatewayTransport = TransportPrivacy.classify(_gatewayUrlCtrl.text);
    _gatewayTokenCtrl = TextEditingController();
    _bridgeUrlCtrl = TextEditingController();
    _bridgeTokenCtrl = TextEditingController();
    _dashboardUrlCtrl = TextEditingController(text: init?.dashboardUrl ?? '');
    // Solo Basic Auth (usuario/contraseña): los otros modos (token automático
    // del Dashboard / token de sesión manual) ya no funcionan en Hermes, así que
    // no se ofrecen. Se fuerza basicAuth siempre.
    _dashAuthMode = AuthMode.basicAuth;
    _dashTokenCtrl = TextEditingController();
    _dashUserCtrl = TextEditingController();
    _dashPassCtrl = TextEditingController();
    if (init != null) {
      _detectedMatrix = widget.connManager.loadCapabilities(init.id);
      _bridgeConfigLoad = _loadBridgeConfig(init.id);
      // Los secretos existentes no se muestran; campo vacío = no cambiar.
      widget.connManager
          .getDashboardSecrets(init.id)
          .then((s) {
            if (!mounted) return;
            if ((s.username?.isNotEmpty ?? false) &&
                _dashUserCtrl.text.isEmpty) {
              _dashUserCtrl.text = s.username!;
            }
          })
          .catchError((Object error) {
            debugPrint(
              '[instance-edit] dashboard secrets unavailable (${error.runtimeType})',
            );
          });
    }
    // Alta precargada (draft sin identidad): rellena el formulario pero el
    // guardado sigue siendo un alta (id UUID nuevo, token obligatorio).
    final pre = widget.prefill;
    if (init == null && pre != null) {
      _nameCtrl.text = pre.label;
      if (pre.notes.isNotEmpty) _notesCtrl.text = pre.notes;
      _gatewayUrlCtrl.text = pre.gatewayUrl;
      _gatewayTransport = TransportPrivacy.classify(_gatewayUrlCtrl.text);
      if (pre.dashboardUrl != null) _dashboardUrlCtrl.text = pre.dashboardUrl!;
      _kind = pre.kind;
      _kindManuallySet = true;
      _localChatMode = pre.localChatMode;
      _readOnly = pre.readOnly;
    }
    // Alta desde el chooser "Escanear QR": abre el escáner al entrar.
    if (widget.autoScanQr && widget.initial == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scanQr();
      });
    }
    // Alta desde "pegar enlace" / deep link: precarga el formulario.
    if (widget.initialLink != null) {
      _showDeepLinkBanner = widget.fromDeepLink;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final link = widget.initialLink!;
        unawaited(_applyInitialLink(link));
      });
    }
  }

  Future<void> _applyInitialLink(PairingLink link) async {
    final applied = await _applyLink(
      link,
      notify: true,
      automate: widget.initial == null && !widget.fromDeepLink,
    );
    if (applied && widget.fromDeepLink && mounted) {
      await _confirmExternalPairingAutomation(link);
    }
  }

  Future<void> _loadBridgeConfig(String connectionId) async {
    try {
      final config = await widget.connManager.getBridgeConfig(connectionId);
      if (!mounted) return;
      setState(() {
        _storedBridgeToken = config.token;
        if (!_bridgeUrlEdited) _bridgeUrlCtrl.text = config.url;
      });
    } catch (error) {
      // Un Keystore temporalmente inaccesible no debe romper el editor. El
      // guardado seguirá fallando de forma visible si el problema persiste.
      debugPrint(
        '[instance-edit] bridge config unavailable (${error.runtimeType})',
      );
    }
  }

  @override
  void dispose() {
    _diag?.close();
    for (final c in [
      _nameCtrl,
      _notesCtrl,
      _gatewayUrlCtrl,
      _gatewayTokenCtrl,
      _bridgeUrlCtrl,
      _bridgeTokenCtrl,
      _dashboardUrlCtrl,
      _dashTokenCtrl,
      _dashUserCtrl,
      _dashPassCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Abre el escáner de QR de emparejado y precarga el formulario con los datos
  /// (host+puerto+token) para que el usuario solo revise y guarde.
  Future<void> _scanQr() async {
    final link = await Navigator.of(context).push<PairingLink>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (link == null || !mounted) return;
    await _applyLink(link, notify: true);
  }

  /// Precarga el formulario desde un enlace de emparejado (QR, pegar o deep
  /// link). Reutilizado por _scanQr y por initialLink.
  Future<bool> _applyLink(
    PairingLink link, {
    bool notify = false,
    bool automate = true,
  }) async {
    final duplicate = widget.connManager.findConnectionByEndpoint(
      host: link.host,
      port: link.port,
      useHttps: link.useHttps,
      excludingId: widget.initial?.id,
    );
    if (duplicate != null && mounted) {
      final action = await _showDuplicatePairingDialog(duplicate);
      if (!mounted || action == _DuplicatePairingAction.cancel) return false;
      if (action == _DuplicatePairingAction.openExisting) {
        await widget.connManager.setActiveConnection(duplicate.id);
        if (!mounted) return false;
        unawaited(
          Navigator.of(context).pushReplacement<bool, bool>(
            MaterialPageRoute<bool>(
              builder: (_) => InstanceEditScreen(
                connManager: widget.connManager,
                initial: duplicate,
              ),
            ),
            result: false,
          ),
        );
        return false;
      }
      unawaited(
        Navigator.of(context).pushReplacement<bool, bool>(
          MaterialPageRoute<bool>(
            builder: (_) => InstanceEditScreen(
              connManager: widget.connManager,
              initial: duplicate,
              initialLink: link,
              fromDeepLink: widget.fromDeepLink,
            ),
          ),
          result: false,
        ),
      );
      return false;
    }

    final draft = link.toDraftConnection();
    setState(() {
      if (_nameCtrl.text.trim().isEmpty) _nameCtrl.text = draft.label;
      _gatewayUrlCtrl.text = draft.gatewayUrl;
      _gatewayTransport = TransportPrivacy.classify(draft.gatewayUrl);
      _gatewayTokenCtrl.text = link.token;
      // Los instaladores oficiales incluyen la URL y el token efectivos del
      // Bridge. Los QR antiguos siguen funcionando: comparten API_SERVER_KEY y
      // dejan que la app derive host:9131.
      final bridgeToken = link.bridgeToken?.trim().isNotEmpty == true
          ? link.bridgeToken!.trim()
          : link.token;
      _bridgeTokenCtrl.text = bridgeToken;
      _storedBridgeToken = bridgeToken;
      _bridgeUrlCtrl.text = link.bridgeUrl?.trim() ?? '';
      _bridgeUrlEdited = true;
      if (link.dashboardUrl != null) {
        _dashboardUrlCtrl.text = link.dashboardUrl!;
      }
      _kind = InstanceKind.vps;
      _kindManuallySet = true;
      // Un QR/enlace acaba de rellenar el bridge: aunque sea una instancia ya
      // guardada, el usuario quiere ver lo que se cargó, no un disclosure
      // colapsado ocultándolo.
      _bridgeAdvancedExpanded = true;
    });
    if (notify && mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).instConnLoaded)),
        kind: HermesNoticeKind.success,
      );
      // Auto-test al precargar (QR/pegar/deep link): el usuario ve enseguida si
      // conecta y, si no, la guía por causa (ConnectionDiagnostics), en vez de
      // descubrir el fallo más tarde. No altera el flujo de guardado.
      if (automate) _startPairingAutomation(link);
    }
    return true;
  }

  Future<_DuplicatePairingAction> _showDuplicatePairingDialog(
    SavedConnection existing,
  ) async {
    final action = await showDialog<_DuplicatePairingAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final s = Strings.of(ctx);
        return AlertDialog(
          title: Text(s.ieDuplicateTitle),
          content: Text(
            s.ieDuplicateBody(
              existing.label,
              '${existing.host}:${existing.port}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _DuplicatePairingAction.cancel),
              child: Text(s.commonCancel),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _DuplicatePairingAction.updateExisting),
              child: Text(s.ieDuplicateUpdate),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, _DuplicatePairingAction.openExisting),
              child: Text(s.ieDuplicateOpen),
            ),
          ],
        );
      },
    );
    return action ?? _DuplicatePairingAction.cancel;
  }

  int _pairingFingerprint(PairingLink link) => Object.hash(
    link.host,
    link.port,
    link.token,
    link.useHttps,
    link.dashboardUrl,
    link.bridgeUrl,
    link.bridgeToken,
  );

  /// Secuencia automática común a QR, pegado y deep link ya consentido.
  /// Mantenerla en un único método evita que las tres entradas diverjan.
  void _startPairingAutomation(PairingLink link) {
    final fingerprint = _pairingFingerprint(link);
    if (_automatedPairingFingerprint == fingerprint) return;
    _automatedPairingFingerprint = fingerprint;

    final automation = () async {
      if (!mounted) return;
      await _runProbe(
        gateway: true,
        dashboard: _dashboardUrlCtrl.text.trim().isNotEmpty,
        bridge: true,
      );
    }();
    _pairingAutomationFuture = automation;
    unawaited(automation);
  }

  /// Los esquemas personalizados de Android no verifican qué app originó el
  /// enlace. Rellenamos primero para que el usuario vea el host, pero no hacemos
  /// requests ni cambiamos credenciales hasta un único consentimiento compacto.
  Future<void> _confirmExternalPairingAutomation(PairingLink link) async {
    if (!mounted || _externalPairingPromptOpen) return;
    _externalPairingPromptOpen = true;
    final automate = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final s = Strings.of(ctx);
        return AlertDialog(
          title: Text(s.ieExternalPairingTitle),
          content: Text(s.ieExternalPairingBody(link.host)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.ieExternalPairingReview),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: Text(s.ieExternalPairingContinue),
            ),
          ],
        );
      },
    );
    _externalPairingPromptOpen = false;
    if (automate == true && mounted) _startPairingAutomation(link);
  }

  /// Botón manual "Autoconfigurar dashboard" (spec 028 A-006).
  ///
  /// Al EDITAR una instancia YA existente, generar una contraseña nueva ROTA la
  /// del servidor y puede romper las sesiones guardadas en otros dispositivos o
  /// navegadores, así que se pide confirmación explícita antes de proceder. En
  /// un alta nueva (sin instancia guardada aún) no hay otro dispositivo que
  /// romper: procede directo, sin diálogo.
  Future<void> _confirmAndAutoConfigureDashboard() async {
    if (!mounted) return;
    if (widget.initial != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Strings.of(ctx).ieDashSetupTitle),
          content: Text(Strings.of(ctx).ieDashSetupBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(Strings.of(ctx).ieNotNow),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(Strings.of(ctx).ieGeneratePassword),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    // Confirmado (o alta nueva): feedback normal (spinner y errores).
    await _autoConfigureDashboard();
  }

  /// Configura el login del Dashboard vía bridge (sin SSH): deriva la URL del
  /// bridge + token (de la instancia existente o del formulario), abre la
  /// pantalla de alta y, al volver, precarga usuario/contraseña en modo
  /// Basic Auth para que al guardar la app entre por cookie automáticamente.
  Future<void> _setupDashboardViaBridge() async {
    await _bridgeConfigLoad;
    if (!mounted) return;
    final bridgeUrl = _effectiveBridgeUrlFromForm();
    final gatewayToken = _gatewayTokenCtrl.text.trim().isNotEmpty
        ? _gatewayTokenCtrl.text.trim()
        : (widget.initial?.apiKey ?? '');
    final bridgeToken = _effectiveBridgeTokenFromForm;
    if (bridgeUrl == null ||
        bridgeUrl.isEmpty ||
        (gatewayToken.isEmpty && bridgeToken.isEmpty)) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).ieGatewayCredentialsRequired),
        ),
        kind: HermesNoticeKind.warning,
      );
      return;
    }
    final result = await Navigator.of(context).push<DashboardCredsResult>(
      MaterialPageRoute(
        builder: (_) => DashboardSetupScreen(
          bridgeUrl: bridgeUrl,
          gatewayKey: gatewayToken,
          bridgeToken: bridgeToken,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _rememberBridgeToken(result.bridgeToken);
    if (!mounted) return;
    setState(() {
      _dashAuthMode = AuthMode.basicAuth;
      _dashUserCtrl.text = result.username;
      _dashPassCtrl.text = result.password;
      // Solo presentación: los campos viven detrás de un disclosure, así que
      // se abre para que la contraseña recién fijada siga a la vista.
      _dashCredsExpanded = true;
    });
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).ieDashboardConfiguredSave)),
    );
  }

  /// Autoconfigura el login del Dashboard vía bridge SIN teclear nada:
  /// provisiona el token del bridge, lee el usuario y FIJA una contraseña nueva
  /// y fuerte, y la deja cargada en el formulario (Basic Auth) para que se
  /// guarde con la instancia. Machaca la contraseña anterior del Dashboard,
  /// por lo que en instancias ya existentes solo debe llamarse tras
  /// confirmación explícita del usuario (botón manual vía
  /// _confirmAndAutoConfigureDashboard, spec 028 A-006); en el alta inicial por
  /// enlace/QR se llama con [silent] sin diálogo. Queda VISIBLE en el campo por
  /// si se quiere usar en el navegador. Con [silent] no muestra errores ni
  /// spinner.
  /// Devuelve true si lo dejó configurado.
  Future<bool> _autoConfigureDashboard({bool silent = false}) async {
    await _bridgeConfigLoad;
    if (!mounted) return false;
    final bridgeUrl = _effectiveBridgeUrlFromForm();
    final gatewayToken = _gatewayTokenCtrl.text.trim().isNotEmpty
        ? _gatewayTokenCtrl.text.trim()
        : (widget.initial?.apiKey ?? '');
    if (bridgeUrl == null ||
        bridgeUrl.isEmpty ||
        (gatewayToken.isEmpty && _effectiveBridgeTokenFromForm.isEmpty)) {
      if (!silent && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).ieNeedGatewayFirst)),
          kind: HermesNoticeKind.warning,
        );
      }
      return false;
    }
    if (!silent && mounted) setState(() => _autoDashBusy = true);
    try {
      final bToken = await _resolveBridgeToken(bridgeUrl, gatewayToken);
      if (bToken == null || bToken.isEmpty) {
        if (!silent && mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).ieBridgeNoToken)),
            kind: HermesNoticeKind.warning,
          );
        }
        return false;
      }
      final client = _createBridgeClient(bridgeUrl, bToken);
      try {
        final creds = await client.getDashboardCredentials();
        final existingUser = (creds['username'] ?? '').toString().trim();
        final user = existingUser.isNotEmpty ? existingUser : 'admin';
        final pass = _generateDashboardPassword();
        final res = await client.setDashboardCredentials(
          username: user,
          password: pass,
        );
        if (res['ok'] != true) {
          if (!silent && mounted) {
            HermesNotice.of(context).showSnackBar(
              SnackBar(content: Text(Strings.of(context).ieDashPassFailed)),
              kind: HermesNoticeKind.error,
            );
          }
          return false;
        }
        final finalUser = (res['username'] ?? user).toString();
        // The remote rotation has already happened. Persist even if the
        // editor was closed while that request was in flight.
        final existingId = widget.initial?.id;
        if (existingId != null) {
          await widget.connManager.setDashboardSecrets(
            existingId,
            username: finalUser,
            password: pass,
          );
        }
        if (!mounted) return false;
        setState(() {
          _dashAuthMode = AuthMode.basicAuth;
          _dashUserCtrl.text = finalUser;
          _dashPassCtrl.text = pass;
          // Solo presentación (no toca el flujo): abre el disclosure de
          // credenciales para que la contraseña generada siga VISIBLE en el
          // campo, como cuando los campos estaban al nivel superior.
          _dashCredsExpanded = true;
          if (_dashboardUrlCtrl.text.trim().isEmpty) {
            final pub = (creds['public_url'] ?? '').toString().trim();
            final uri = Uri.tryParse(_gatewayUrlCtrl.text.trim());
            final host = uri?.host ?? '';
            final scheme = (uri?.scheme.isEmpty ?? true) ? 'http' : uri!.scheme;
            _dashboardUrlCtrl.text = pub.isNotEmpty
                ? pub
                : (host.isEmpty ? '' : '$scheme://$host:9119');
          }
        });
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).ieDashConfigured(finalUser)),
          ),
        );
        return true;
      } finally {
        client.close();
      }
    } catch (e) {
      if (!silent && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).ieDashConfigError(e.toString())),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      return false;
    } finally {
      if (!silent && mounted) setState(() => _autoDashBusy = false);
    }
  }

  /// Contraseña fuerte sin caracteres ambiguos (0/O, 1/l/I) para el Dashboard.
  String _generateDashboardPassword() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    final rnd = Random.secure();
    return List.generate(20, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<String?> _resolveBridgeToken(
    String bridgeUrl,
    String gatewayToken,
  ) async {
    final existing = _effectiveBridgeTokenFromForm;
    if (existing.isNotEmpty) {
      final client = _createBridgeClient(bridgeUrl, existing);
      try {
        final capabilities = await client.detect();
        if (capabilities.online && capabilities.authValid) return existing;
      } finally {
        client.close();
      }
    }
    if (gatewayToken.trim().isEmpty) return null;
    final provisioned =
        await (widget.bridgeProvisioner?.call(bridgeUrl, gatewayToken.trim()) ??
            BridgeClient.provision(bridgeUrl, gatewayToken.trim()));
    if (provisioned == null || provisioned.isEmpty) return null;
    await _rememberBridgeToken(provisioned);
    return provisioned;
  }

  BridgeClient _createBridgeClient(String baseUrl, String token) =>
      widget.bridgeClientFactory?.call(baseUrl: baseUrl, token: token) ??
      BridgeClient(baseUrl: baseUrl, token: token);

  Future<void> _rememberBridgeToken(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) return;
    _storedBridgeToken = normalized;
    if (mounted) _bridgeTokenCtrl.text = normalized;
    final id = widget.initial?.id;
    if (id != null) {
      await widget.connManager.setBridgeConfig(id, token: normalized);
    }
  }

  String? _effectiveBridgeUrlFromForm() {
    final override = _bridgeUrlCtrl.text.trim();
    if (override.isNotEmpty) return override;
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    if (normalized.host.isEmpty) return null;
    return SavedConnection(
      id: widget.initial?.id ?? 'bridge-draft',
      label: '',
      host: normalized.host,
      port: normalized.port,
      apiKey: '',
      useHttps: normalized.useHttps,
      onDeviceLoopback:
          widget.initial?.onDeviceLoopback ??
          widget.prefill?.onDeviceLoopback ??
          false,
    ).derivedBridgeUrl;
  }

  String get _effectiveBridgeTokenFromForm {
    final entered = _bridgeTokenCtrl.text.trim();
    return entered.isNotEmpty ? entered : _storedBridgeToken;
  }

  // ── Construcción del modelo desde el formulario ───────────────────────

  /// Conexión efímera con el estado actual del formulario (para probar
  /// sin guardar). Usa los secretos del Keystore cuando el campo está vacío.
  Future<(SavedConnection, DashboardSecrets)> _draftConnection() async {
    final id = widget.initial?.id ?? const Uuid().v4();
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    var apiKey = _gatewayTokenCtrl.text.trim();
    if (apiKey.isEmpty && widget.initial != null) {
      apiKey =
          widget.connManager
              .getConnections()
              .where((connection) => connection.id == id)
              .firstOrNull
              ?.apiKey ??
          '';
    }
    final stored = widget.initial == null
        ? const DashboardSecrets()
        : await widget.connManager.getDashboardSecrets(id);
    if (!mounted) throw StateError('Instance editor closed');
    final secrets = DashboardSecrets(
      sessionToken: _dashTokenCtrl.text.trim().isNotEmpty
          ? _dashTokenCtrl.text.trim()
          : stored.sessionToken,
      username: _dashUserCtrl.text.trim().isNotEmpty
          ? _dashUserCtrl.text.trim()
          : stored.username,
      password: _dashPassCtrl.text.isNotEmpty
          ? _dashPassCtrl.text
          : stored.password,
    );
    final dashUrl = _dashboardUrlCtrl.text.trim();
    final conn = SavedConnection(
      id: id,
      label: _nameCtrl.text.trim().isEmpty
          ? normalized.host
          : _nameCtrl.text.trim(),
      host: normalized.host,
      port: normalized.port,
      apiKey: apiKey,
      useHttps: normalized.useHttps,
      readOnly: _readOnly,
      dashboardUrl: dashUrl.isEmpty ? null : dashUrl,
      dashboardAuthMode: _dashAuthMode,
      notes: _notesCtrl.text.trim(),
      lastHealthCheckMs: widget.initial?.lastHealthCheckMs,
      // El flag on-device también puede venir de una precarga de alta (agente
      // local): sin él, 127.0.0.1 se reescribiría a 10.0.2.2 en emulador.
      onDeviceLoopback:
          widget.initial?.onDeviceLoopback ??
          widget.prefill?.onDeviceLoopback ??
          false,
      localChatMode: _localChatMode,
      kind: _kindManuallySet ? _kind : inferInstanceKind(normalized.host),
    );
    return (conn, secrets);
  }

  // ── Diagnóstico ───────────────────────────────────────────────────────

  /// Convierte las excepciones de probar/guardar en un mensaje legible en
  /// español (sin volcar "SocketException: … (OS Error: …)" al banner). El
  /// detalle técnico queda en el log de debug y en "copiar diagnóstico".
  String _friendlyError(Object e) {
    debugPrint('[instance-edit] error (${e.runtimeType})');
    final str = Strings.of(context);
    if (e is TimeoutException) {
      return str.ieErrTimeout;
    }
    if (e is SocketException) {
      final os = e.osError?.message.toLowerCase() ?? '';
      if (os.contains('refused')) {
        return str.ieErrRefused;
      }
      if (os.contains('unreachable') || os.contains('network')) {
        return str.ieErrUnreachable;
      }
      return str.ieErrHostNotFound;
    }
    if (e is HandshakeException || e is TlsException) {
      return str.ieErrTls;
    }
    if (e is FormatException) {
      return str.ieErrBadUrl;
    }
    // Errores HTTP con cuerpo JSON, u otros: extrae el detalle útil.
    return humanizeApiError(e);
  }

  _DiagnosticsSnapshot get _diagnosticsSnapshot => _DiagnosticsSnapshot(
    gateway: _gatewayResults,
    dashboard: _dashboardResults,
    bridge: _bridgeResults,
    suggestions: _suggestions,
    matrix: _detectedMatrix,
    serverCapabilities: _serverCaps,
    report: _lastReport,
    error: _diagnosticError,
  );

  Future<_DiagnosticsSnapshot> _runProbe({
    bool gateway = false,
    bool dashboard = false,
    bool bridge = false,
  }) async {
    if (_gatewayUrlCtrl.text.trim().isEmpty) {
      setState(
        () => _diagnosticError = Strings.of(context).ieGatewayUrlBeforeTest,
      );
      return _diagnosticsSnapshot;
    }
    await _bridgeConfigLoad;
    if (!mounted) return _diagnosticsSnapshot;
    // Capturado antes de los await para localizar las sugerencias del
    // diagnóstico sin usar el contexto tras un gap asíncrono.
    final s = Strings.of(context);
    setState(() {
      _probing = true;
      _diagnosticError = null;
    });
    try {
      final (conn, secrets) = await _draftConnection();
      final storedSecrets = widget.initial == null
          ? null
          : await widget.connManager.getDashboardSecrets(widget.initial!.id);
      final credentialsOverridden =
          _gatewayTokenCtrl.text.trim().isNotEmpty ||
          _dashTokenCtrl.text.trim().isNotEmpty ||
          _dashPassCtrl.text.isNotEmpty ||
          (_dashUserCtrl.text.trim().isNotEmpty &&
              _dashUserCtrl.text.trim() != (storedSecrets?.username ?? ''));
      _diag ??= ConnectionDiagnostics();

      // "Todo" (las tres): usa run() que además calcula matriz y sugerencias
      // a partir del conjunto completo.
      if (gateway && dashboard && bridge) {
        final report = await _diag!.run(
          s,
          conn,
          secrets,
          bridgeUrl: _effectiveBridgeUrlFromForm(),
          bridgeToken: _effectiveBridgeTokenFromForm,
        );
        if (!mounted) return _diagnosticsSnapshot;
        // El diagnóstico es un dato de solo lectura y debe sobrevivir aunque el
        // usuario salga sin pulsar Guardar. La función comprueba que URL/auth y
        // credenciales siguen siendo las de la conexión viva; nunca persiste
        // los demás campos del formulario.
        try {
          await persistVerifiedCapabilityMatrix(
            manager: widget.connManager,
            probedConnection: conn,
            matrix: report.matrix,
            credentialsOverridden: credentialsOverridden,
          );
        } catch (e) {
          debugPrint(
            '[instance-edit] no se pudo persistir la matriz verificada: $e',
          );
        }
        if (!mounted) return _diagnosticsSnapshot;
        setState(() {
          _gatewayResults = report.gateway;
          _dashboardResults = report.dashboard;
          _bridgeResults = report.bridge;
          _suggestions = report.suggestions;
          _detectedMatrix = report.matrix;
          _serverCaps = report.serverCapabilities;
          _lastReport = report;
        });
        return _diagnosticsSnapshot;
      }

      // Comprobaciones parciales: cada parte por separado, de forma
      // independiente, sin que una desactive a las otras.
      List<ProbeResult>? gwResults;
      ServerCapabilities? gwCaps;
      List<ProbeResult>? dashResults;
      List<ProbeResult>? bridgeResults;
      if (gateway) {
        final (results, _, serverCaps) = await _diag!.probeGateway(conn);
        gwResults = results;
        gwCaps = serverCaps;
      }
      if (dashboard) {
        dashResults = await _diag!.probeDashboard(conn, secrets);
      }
      if (bridge) {
        bridgeResults = await _diag!.probeBridge(
          conn,
          bridgeUrl: _effectiveBridgeUrlFromForm(),
          bridgeToken: _effectiveBridgeTokenFromForm,
        );
      }
      if (!mounted) return _diagnosticsSnapshot;
      setState(() {
        if (gwResults != null) {
          _gatewayResults = gwResults;
          _serverCaps = gwCaps;
        }
        if (dashResults != null) _dashboardResults = dashResults;
        if (bridgeResults != null) _bridgeResults = bridgeResults;
        if (gateway || dashboard) {
          _suggestions = _diag!.buildSuggestions(
            s,
            conn,
            gwResults ?? const [],
            dashResults ?? const [],
          );
        }
      });
    } catch (e) {
      // Mensaje legible; el detalle técnico va al log y a "copiar diagnóstico"
      // (spec 028 A-007).
      if (mounted) setState(() => _diagnosticError = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _probing = false);
    }
    return _diagnosticsSnapshot;
  }

  /// Estado de ánimo de la mascota según el diagnóstico actual.
  HermesSparkMood _diagMood() => _diagnosticsSnapshot.mood(probing: _probing);

  /// Indicador NEUTRO del diagnóstico de conexión (sin mascota). El icono no
  /// depende solo del color: TalkBack recibe un estado localizado y explícito.
  Widget _diagIndicator() {
    final mood = _diagMood();
    final s = Strings.of(context);
    final label = switch (mood) {
      HermesSparkMood.connecting ||
      HermesSparkMood.thinking => s.ieDiagA11yChecking,
      HermesSparkMood.success => s.ieDiagA11ySuccess,
      HermesSparkMood.error => s.ieDiagA11yError,
      HermesSparkMood.offline => s.ieDiagA11yOffline,
      HermesSparkMood.idle ||
      HermesSparkMood.waiting ||
      HermesSparkMood.jump => s.ieDiagA11yUnchecked,
    };
    return Semantics(
      label: label,
      image: true,
      child: ExcludeSemantics(
        child: HermesStatusIndicator(mood: mood, size: 20),
      ),
    );
  }

  // ── Guardar ───────────────────────────────────────────────────────────

  String _diagnosticsSummary(Strings s) {
    if (_probing) return s.ieConnectionCheckRunning;
    if (!_diagnosticsSnapshot.hasAnyResults) {
      return _detectedMatrix?.checkedAtMs == null
          ? s.ieConnectionCheckSubtitle
          : s.ieConnectionCheckSaved;
    }
    if (!_diagnosticsSnapshot.hasAllSurfaces) {
      return s.ieConnectionCheckPartialSummary;
    }
    return switch (_diagMood()) {
      HermesSparkMood.success => s.ieConnectionCheckReadySummary,
      HermesSparkMood.offline => s.ieConnectionCheckOfflineSummary,
      HermesSparkMood.error => s.ieConnectionCheckIssuesSummary,
      _ => s.ieConnectionCheckSubtitle,
    };
  }

  Future<void> _openDiagnostics() async {
    await _bridgeConfigLoad;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _InstanceDiagnosticsScreen(
          initial: _diagnosticsSnapshot,
          onRun: (scope) => switch (scope) {
            _DiagnosticScope.all => _runProbe(
              gateway: true,
              dashboard: true,
              bridge: true,
            ),
            _DiagnosticScope.gateway => _runProbe(gateway: true),
            _DiagnosticScope.dashboard => _runProbe(dashboard: true),
            _DiagnosticScope.bridge => _runProbe(bridge: true),
          },
        ),
      ),
    );
    // La ruta actualiza el estado del editor mediante onRun. Al volver,
    // refresca la fila compacta aunque la última prueba haya sido parcial.
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    if (normalized.host.isEmpty) {
      setState(() => _error = Strings.of(context).ieGatewayUrlRequired);
      return;
    }
    if (_isNew && _gatewayTokenCtrl.text.trim().isEmpty) {
      setState(() => _error = Strings.of(context).ieGatewayTokenRequired);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Esperar las sondas evita persistir mientras la pantalla todavía procesa
      // el mismo enlace de pairing.
      await _pairingAutomationFuture;
      if (!mounted) return;
      await _bridgeConfigLoad;
      if (!mounted) return;
      final (conn, _) = await _draftConnection();
      if (!mounted) return;
      // Capture the intended edits before the first persistence await. Blank
      // secrets mean preserve the CURRENT stored value, not the initial model.
      final gatewayKey = _gatewayTokenCtrl.text.trim();
      final dashboardToken = _dashTokenCtrl.text.trim();
      final dashboardUser = _dashUserCtrl.text.trim();
      final dashboardPassword = _dashPassCtrl.text;
      final bridgeUrl = _bridgeUrlCtrl.text;
      final bridgeToken = _bridgeTokenCtrl.text;
      final withCheck = _detectedMatrix?.checkedAtMs == null
          ? conn
          : SavedConnection(
              id: conn.id,
              label: conn.label,
              host: conn.host,
              port: conn.port,
              apiKey: conn.apiKey,
              useHttps: conn.useHttps,
              readOnly: conn.readOnly,
              dashboardUrl: conn.dashboardUrl,
              dashboardAuthMode: conn.dashboardAuthMode,
              notes: conn.notes,
              lastHealthCheckMs: _detectedMatrix!.checkedAtMs,
              onDeviceLoopback: conn.onDeviceLoopback,
              localChatMode: conn.localChatMode,
              kind: conn.kind,
            );
      await widget.connManager.upsertConnection(
        withCheck.copyWith(apiKey: gatewayKey),
      );
      await widget.connManager.setDashboardSecrets(
        conn.id,
        sessionToken: dashboardToken.isNotEmpty ? dashboardToken : null,
        username:
            (_isNew || _dashUserEdited || dashboardPassword.isNotEmpty) &&
                dashboardUser.isNotEmpty
            ? dashboardUser
            : null,
        password: dashboardPassword.isNotEmpty ? dashboardPassword : null,
      );
      await widget.connManager.setBridgeConfig(
        conn.id,
        url: _isNew || _bridgeUrlEdited ? bridgeUrl : null,
        token: bridgeToken,
      );
      final matrix = _detectedMatrix;
      if (matrix != null && matrix.checkedAtMs != null) {
        await widget.connManager.saveCapabilities(conn.id, matrix);
      }
      // Una instancia recién dada de alta pasa a ser la ACTIVA: quien acaba de
      // emparejar quiere usarla ya (el home y Ajustes escuchan el notifier y
      // se refrescan solos; spec 028 U-32).
      if (_isNew) await widget.connManager.setActiveConnection(conn.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  /// Ritmo vertical ÚNICO de las cabeceras de sección: mucho hueco arriba y
  /// poco abajo, para que cada cabecera se lea pegada a su grupo y separada
  /// del bloque anterior. Con el hueco por defecto (18/8) las secciones se
  /// distinguían menos que los propios controles y todo parecía una única
  /// lista continua.
  static const EdgeInsets _sectionPadding = EdgeInsets.fromLTRB(4, 26, 4, 9);

  /// Decoración plana (sin caja propia) para un campo que vive dentro de un
  /// [HermesGroup]: la jerarquía visual la da el grupo (superficie + divisor
  /// entre filas), no cada campo por separado. Mismo controller/callbacks que
  /// antes: es un cambio puramente de presentación.
  ///
  /// La tipografía es explícita para que el campo tenga jerarquía real:
  /// etiqueta pequeña y tenue arriba, valor grande y legible debajo. Antes
  /// etiqueta, valor y ayuda pesaban casi lo mismo y el formulario se leía
  /// como un muro de controles idénticos.
  InputDecoration _rowDecoration(
    BuildContext context, {
    required String label,
    String? hint,
    String? helper,
    int? helperMaxLines,
  }) {
    final colors = Theme.of(context).hermes;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: helperMaxLines ?? 2,
      isDense: true,
      filled: false,
      contentPadding: const EdgeInsets.only(top: 4, bottom: 8),
      labelStyle: TextStyle(fontSize: 14.5, color: colors.textSecondary),
      floatingLabelStyle: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: colors.textSecondary,
      ),
      hintStyle: TextStyle(fontSize: 14, color: colors.textDisabled),
      helperStyle: TextStyle(
        fontSize: 11.5,
        height: 1.35,
        color: colors.textDisabled,
      ),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.55)),
      ),
    );
  }

  /// Estilo único del VALOR de cualquier campo del formulario.
  TextStyle _valueStyle() => TextStyle(
    fontSize: 15,
    height: 1.25,
    fontWeight: FontWeight.w500,
    color: Theme.of(context).hermes.textPrimary,
  );

  /// Campo de texto del formulario: misma tipografía y mismo ritmo en todas
  /// las secciones y también dentro de los disclosures, en vez de una mezcla
  /// de campos planos (arriba) y campos con caja del tema (en "avanzado").
  Widget _field({
    Key? key,
    required TextEditingController controller,
    required String label,
    String? hint,
    String? helper,
    bool obscure = false,
    bool autocorrect = true,
    TextInputType? keyboardType,
    int? maxLines = 1,
    int? minLines,
    ValueChanged<String>? onChanged,
  }) => TextField(
    key: key,
    controller: controller,
    obscureText: obscure,
    autocorrect: autocorrect,
    enableSuggestions: !obscure,
    keyboardType: keyboardType,
    maxLines: obscure ? 1 : maxLines,
    minLines: minLines,
    style: _valueStyle(),
    decoration: _rowDecoration(
      context,
      label: label,
      hint: hint,
      helper: helper,
    ),
    onChanged: onChanged,
  );

  /// Fila de campo dentro de un [HermesGroup]. El hueco vertical iguala la
  /// altura de una fila-campo con la de una fila de switch/navegación: antes
  /// los campos medían ~40 dp y el switch ~72 dp DENTRO DEL MISMO grupo, y esa
  /// mezcla es la que hacía que todo pareciera apelotonado.
  Widget _fieldRow(Widget field) =>
      Padding(padding: const EdgeInsets.fromLTRB(16, 7, 16, 7), child: field);

  /// Nota al pie de una sección. UN solo estilo para toda la ayuda de nivel
  /// superior (antes convivían 11, 11,5 y 12 px con huecos de 4, 6, 8 y 10).
  Widget _footnote(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 9, 6, 0),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.45,
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
  );

  /// Nota dentro de un disclosure: un peso por debajo de [_footnote] para que
  /// el contenido anidado no compita con el nivel de sección.
  Widget _nestedNote(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 11.5,
      height: 1.4,
      color: Theme.of(context).hermes.textDisabled,
    ),
  );

  /// Reclasifica el transporte e infiere el tipo al teclear la URL del
  /// gateway. Extraído del `onChanged` inline para que la lista de secciones
  /// se lea de un vistazo (era el bloque más largo del `build`).
  void _onGatewayUrlChanged(String v) {
    final transport = TransportPrivacy.classify(v);
    InstanceKind? inferred;
    if (!_kindManuallySet) {
      final n = SavedConnection.normalizeHostAndPort(v.trim(), 8642);
      final candidate = inferInstanceKind(n.host);
      if (candidate != _kind) inferred = candidate;
    }
    if (transport != _gatewayTransport ||
        inferred != null ||
        _showDeepLinkBanner) {
      setState(() {
        _gatewayTransport = transport;
        if (inferred != null) _kind = inferred;
        // El usuario ya tocó la URL: deja de avisar de precarga.
        _showDeepLinkBanner = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    // Estado del disclosure de credenciales visible ya plegado: si hay usuario
    // conocido se anuncia en el subtítulo, así que no hace falta abrirlo para
    // saber si el Dashboard está configurado.
    final dashUser = _dashUserCtrl.text.trim();
    return Scaffold(
      appBar: HermesAppBar(
        // Título estándar del tema (color/peso/espaciado/tamaño coherentes con
        // el resto): sin estilo inline que lo descuadre frente a otras pantallas.
        title: Text(_isNew ? s.ieNewInstanceTitle : s.homeEditInstance),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        children: [
          if (_error != null) ...[
            const SizedBox(height: 6),
            HermesInfoBanner(
              _error!,
              icon: Icons.error_outline,
              tone: colors.error,
            ),
          ],
          if (_showDeepLinkBanner) ...[
            const SizedBox(height: 6),
            HermesInfoBanner(
              s.ieExternalLinkBanner,
              icon: Icons.link,
              tone: colors.warning,
            ),
          ],
          if (widget.initial == null) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: _scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(s.qrScanTitle),
            ),
            _footnote(s.instQrFasterHint),
          ],

          // ── Identidad: nombre, nota, solo-lectura ──────────────────────
          HermesSectionHeader(s.ieSectionGeneral, padding: _sectionPadding),
          HermesGroup(
            children: [
              _fieldRow(_field(controller: _nameCtrl, label: s.ieName)),
              _fieldRow(
                _field(
                  controller: _notesCtrl,
                  label: s.ieNote,
                  hint: s.ieNoteHint,
                  maxLines: 2,
                  minLines: 1,
                ),
              ),
              // `Material(type: transparency)`: ver nota en
              // dock_settings_screen.dart sobre `HermesGroup` +
              // `HermesSwitchTile` (el fondo del grupo, sin un `Material` de
              // por medio, deja el ripple del switch invisible en depuración).
              Material(
                type: MaterialType.transparency,
                child: HermesSwitchTile(
                  dense: true,
                  title: s.ieReadOnly,
                  subtitle: s.ieReadOnlySub,
                  value: _readOnly,
                  onChanged: (v) => setState(() => _readOnly = v),
                ),
              ),
            ],
          ),

          // ── Conexión: gateway URL + token ───────────────────────────────
          HermesSectionHeader(s.ieSectionGateway, padding: _sectionPadding),
          HermesGroup(
            children: [
              _fieldRow(
                _field(
                  key: const ValueKey('instance-gateway-url'),
                  controller: _gatewayUrlCtrl,
                  label: s.ieGatewayUrl,
                  hint: s.ieGatewayUrlHint,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  onChanged: _onGatewayUrlChanged,
                ),
              ),
              _fieldRow(
                _field(
                  key: const ValueKey('instance-gateway-token'),
                  controller: _gatewayTokenCtrl,
                  label: _isNew ? s.ieGatewayToken : s.ieGatewayTokenEmpty,
                  obscure: true,
                  autocorrect: false,
                ),
              ),
            ],
          ),
          const ApiKeyHelpLink(),
          if (_gatewayUrlCtrl.text.trim().isNotEmpty)
            _TransportPrivacyNote(transport: _gatewayTransport),

          // ── Dashboard / admin ───────────────────────────────────────────
          HermesSectionHeader(s.ieSectionDashboard, padding: _sectionPadding),
          HermesGroup(
            children: [
              _fieldRow(
                _field(
                  controller: _dashboardUrlCtrl,
                  label: s.ieDashboardUrl,
                  hint:
                      widget.initial?.effectiveDashboardUrl ??
                      s.ieDashboardUrlHint,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                ),
              ),
              // Camino recomendado: un toque, sin teclear nada. Provisiona el
              // bridge, fija una contraseña nueva y la deja cargada (visible).
              // Era un FilledButton a media pantalla que competía con
              // "guardar instancia" por el papel de acción principal; como
              // fila de acento dentro del grupo sigue siendo lo primero que se
              // ve del Dashboard sin robarle el foco al guardado.
              _GroupActionRow(
                icon: Icons.auto_fix_high_outlined,
                title: s.ieAutoconfigDash,
                busy: _autoDashBusy,
                onTap: _autoDashBusy ? null : _confirmAndAutoConfigureDashboard,
              ),
              // Usuario/contraseña a mano es el camino de excepción: quien usa
              // la autoconfiguración no necesita verlos, y se abren solos
              // cuando hay algo que mirar (contraseña recién generada).
              _AdvancedDisclosure(
                icon: Icons.password_outlined,
                title: '${s.commonUser} · ${s.commonPassword}',
                subtitle: dashUser.isEmpty ? null : dashUser,
                expanded: _dashCredsExpanded,
                onToggle: () =>
                    setState(() => _dashCredsExpanded = !_dashCredsExpanded),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(
                      controller: _dashUserCtrl,
                      onChanged: (_) => _dashUserEdited = true,
                      label: s.commonUser,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      controller: _dashPassCtrl,
                      label: _isNew ? s.commonPassword : s.iePasswordEmpty,
                      obscure: true,
                    ),
                    const SizedBox(height: 12),
                    // La ayuda vive junto a lo que explica: responde "no sé el
                    // usuario/contraseña", que es justo lo que hace el botón de
                    // abajo. Antes era un párrafo suelto a media pantalla.
                    _nestedNote(s.instDashPwHint),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _setupDashboardViaBridge,
                        icon: const Icon(Icons.key_outlined, size: 18),
                        label: Text(s.instDashPwBridge),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // El Dashboard/Admin necesita su propia protección (VPN, firewall o
          // auth) porque no lleva la del Gateway. Antes era un banner ámbar
          // permanente (se veía como una alerta activa aunque no hubiera
          // ningún problema real); ahora es una nota discreta junto al campo,
          // reservando el ámbar para avisos que sí requieren atención.
          _footnote(s.ieDashboardProtected),

          // ── Avanzado: bridge manual + tipo de instancia ─────────────────
          // Los dos disclosures viven en UN grupo (antes eran dos cajas
          // sueltas separadas por aire, y cada una parecía una sección nueva).
          HermesSectionHeader(s.ieAdvancedSection, padding: _sectionPadding),
          HermesGroup(
            children: [
              _AdvancedDisclosure(
                icon: Icons.hub_outlined,
                title: s.ieSectionBridge,
                subtitle: s.ieBridgeAdvancedSubtitle,
                expanded: _bridgeAdvancedExpanded,
                onToggle: () => setState(
                  () => _bridgeAdvancedExpanded = !_bridgeAdvancedExpanded,
                ),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _nestedNote(s.ieBridgeQrHint),
                    const SizedBox(height: 12),
                    _field(
                      key: const ValueKey('instance-bridge-token'),
                      controller: _bridgeTokenCtrl,
                      label: _isNew ? s.bridgeToken : s.ieBridgeTokenEmpty,
                      hint: s.bridgeTokenHint,
                      obscure: true,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      key: const ValueKey('instance-bridge-url'),
                      controller: _bridgeUrlCtrl,
                      label: s.bridgeUrlAdvanced,
                      hint:
                          _effectiveBridgeUrlFromForm() ??
                          'http://100.x.x.x:9131',
                      helper: s.ieBridgeUrlEmptyHint,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      onChanged: (_) => setState(() => _bridgeUrlEdited = true),
                    ),
                    const SizedBox(height: 10),
                    _nestedNote(s.bridgeTokenNote),
                  ],
                ),
              ),
              _AdvancedDisclosure(
                icon: Icons.category_outlined,
                title: s.ieSectionType,
                subtitle: _kind.label,
                expanded: _kindAdvancedExpanded,
                onToggle: () => setState(
                  () => _kindAdvancedExpanded = !_kindAdvancedExpanded,
                ),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: InstanceKind.values.map((k) {
                        final sel = k == _kind;
                        return ChoiceChip(
                          label: Text(
                            k.label,
                            style: TextStyle(
                              fontSize: 11,
                              color: sel
                                  ? colors.onAccent
                                  : colors.textSecondary,
                            ),
                          ),
                          selected: sel,
                          selectedColor: colors.accent,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() {
                            _kind = k;
                            _kindManuallySet = true;
                          }),
                        );
                      }).toList(),
                    ),
                    // El modo de chat local solo existe para instancias
                    // localhost: vive junto al tipo, no suelto en "identidad",
                    // donde aparecía y desaparecía sin relación con el resto.
                    if (_kind == InstanceKind.localhost) ...[
                      const SizedBox(height: 6),
                      DropdownButtonFormField<LocalChatMode>(
                        initialValue: _localChatMode,
                        style: Theme.of(context).dropdownMenuTheme.textStyle,
                        decoration: _rowDecoration(
                          context,
                          label: s.ieLocalChatMode,
                        ),
                        items: LocalChatMode.values
                            .map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text(switch (m) {
                                  LocalChatMode.auto => s.ieLocalModeAuto,
                                  LocalChatMode.simple => s.ieLocalModeSimple,
                                  LocalChatMode.agent => s.ieLocalModeAgent,
                                }, style: const TextStyle(fontSize: 14)),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _localChatMode = v);
                        },
                      ),
                      if (_localChatMode != LocalChatMode.agent) ...[
                        const SizedBox(height: 6),
                        _nestedNote(
                          _localChatMode == LocalChatMode.auto
                              ? s.instChatSimpleAuto
                              : s.instChatSimpleNoTools,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),

          // ── Diagnóstico: una sola fila, el detalle vive en su propia
          // pantalla (_InstanceDiagnosticsScreen) ─────────────────────────
          HermesSectionHeader(
            s.ieConnectionCheckTitle,
            padding: _sectionPadding,
          ),
          HermesGroup(
            children: [
              _DiagnosticsEntry(
                title: s.ieConnectionCheckAction,
                subtitle: _diagnosticsSummary(s),
                indicator: _diagIndicator(),
                onTap: _probing ? null : _openDiagnostics,
              ),
            ],
          ),
          // Única acción principal de la pantalla.
          const SizedBox(height: 28),
          HermesPrimaryButton(
            key: const ValueKey('instance-save'),
            label: _saving ? s.ieSaving : s.ieSaveInstance,
            icon: Icons.save_outlined,
            onTap: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

/// Fila-disclosure para configuración excepcional: colapsada muestra solo
/// icono + título + subtítulo opcional + chevron; expandida revela [content]
/// justo debajo, sin abrir una pantalla nueva. El estado (expandido/no) vive
/// en el padre para que sobreviva a rebuilds del formulario.
///
/// NO se envuelve en [HermesGroup]: es UNA fila más del grupo que la contiene,
/// así varios disclosures comparten superficie y divisores en vez de dibujar
/// una caja por cada uno (antes "avanzado" eran dos cajas sueltas separadas
/// por aire y cada una se leía como una sección nueva).
class _AdvancedDisclosure extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget content;

  const _AdvancedDisclosure({
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.content,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final sub = subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          label: sub == null ? title : '$title, $sub',
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 19, color: colors.textSecondary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Mismo peso y tamaño que cualquier otra fila de la
                          // pantalla (navegación, acción, diagnóstico): antes
                          // el título del disclosure medía 13,5 y se confundía
                          // con una cabecera de sección (13).
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          if (sub != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: colors.textDisabled,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: content,
          ),
      ],
    );
  }
}

/// Fila de ACCIÓN dentro de un [HermesGroup]: el título va en acento para
/// distinguirla de las filas de datos sin necesidad de un botón relleno que
/// compita con la acción principal de la pantalla ("guardar instancia").
class _GroupActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool busy;
  final VoidCallback? onTap;

  const _GroupActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onTap != null;
    final tone = enabled ? colors.accentHover : colors.textDisabled;
    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 19,
                  height: 19,
                  child: busy
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : Icon(icon, size: 19, color: tone),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: tone,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _DiagnosticScope { all, gateway, dashboard, bridge }

typedef _DiagnosticsRunner =
    Future<_DiagnosticsSnapshot> Function(_DiagnosticScope scope);

enum _DiagnosticSurfaceState { unchecked, ready, attention, offline }

_DiagnosticSurfaceState _surfaceState(List<ProbeResult>? results) {
  final checked = (results ?? const <ProbeResult>[])
      .where((result) => result.status != ProbeStatus.skipped)
      .toList();
  if (checked.isEmpty) return _DiagnosticSurfaceState.unchecked;
  const offline = {
    ProbeStatus.refused,
    ProbeStatus.timeout,
    ProbeStatus.dnsError,
    ProbeStatus.tlsError,
    ProbeStatus.error,
  };
  // La primera sonda de cada superficie es su liveness (health/status). Si esa
  // falla, el servicio está fuera; un endpoint posterior que falle significa
  // que el servicio responde pero necesita revisión.
  if (offline.contains(checked.first.status)) {
    return _DiagnosticSurfaceState.offline;
  }
  if (checked.every((result) => result.status == ProbeStatus.ok)) {
    return _DiagnosticSurfaceState.ready;
  }
  return _DiagnosticSurfaceState.attention;
}

class _DiagnosticsSnapshot {
  final List<ProbeResult>? gateway;
  final List<ProbeResult>? dashboard;
  final List<ProbeResult>? bridge;
  final List<String> suggestions;
  final CapabilityMatrix? matrix;
  final ServerCapabilities? serverCapabilities;
  final DiagnosticsReport? report;
  final String? error;

  const _DiagnosticsSnapshot({
    required this.gateway,
    required this.dashboard,
    required this.bridge,
    required this.suggestions,
    required this.matrix,
    required this.serverCapabilities,
    required this.report,
    required this.error,
  });

  bool get hasAnyResults =>
      gateway != null || dashboard != null || bridge != null;

  bool get hasAllSurfaces =>
      gateway != null && dashboard != null && bridge != null;

  List<_DiagnosticSurfaceState> get surfaceStates => [
    _surfaceState(gateway),
    _surfaceState(dashboard),
    _surfaceState(bridge),
  ];

  HermesSparkMood mood({bool probing = false}) {
    if (probing) return HermesSparkMood.connecting;
    final states = surfaceStates;
    if (states.every((state) => state == _DiagnosticSurfaceState.unchecked)) {
      return HermesSparkMood.idle;
    }
    if (states.any((state) => state == _DiagnosticSurfaceState.offline)) {
      return HermesSparkMood.offline;
    }
    if (states.any((state) => state == _DiagnosticSurfaceState.attention)) {
      return HermesSparkMood.error;
    }
    if (states.every((state) => state == _DiagnosticSurfaceState.ready)) {
      return HermesSparkMood.success;
    }
    return HermesSparkMood.waiting;
  }
}

/// En el editor solo queda esta fila: guardar una instancia ya no queda
/// enterrado bajo endpoints, badges y cuatro botones técnicos. El detalle vive
/// en una pantalla propia, pero el estado sigue siendo visible de un vistazo.
class _DiagnosticsEntry extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget indicator;
  final VoidCallback? onTap;

  const _DiagnosticsEntry({
    required this.title,
    required this.subtitle,
    required this.indicator,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              indicator,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstanceDiagnosticsScreen extends StatefulWidget {
  final _DiagnosticsSnapshot initial;
  final _DiagnosticsRunner onRun;

  const _InstanceDiagnosticsScreen({
    required this.initial,
    required this.onRun,
  });

  @override
  State<_InstanceDiagnosticsScreen> createState() =>
      _InstanceDiagnosticsScreenState();
}

class _InstanceDiagnosticsScreenState
    extends State<_InstanceDiagnosticsScreen> {
  late _DiagnosticsSnapshot _snapshot;
  bool _running = false;
  _DiagnosticScope _scope = _DiagnosticScope.all;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initial;
    // Entrar en "Comprobar conexión" es la acción explícita. Si solo hay
    // una matriz guardada o una prueba parcial del onboarding, completa las tres
    // superficies automáticamente; un informe completo de esta misma edición se
    // conserva hasta que el usuario pulse "volver a comprobar".
    if (!_snapshot.hasAnyResults && _snapshot.matrix?.checkedAtMs == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(_DiagnosticScope.all);
      });
    }
  }

  Future<_DiagnosticsSnapshot> _run(_DiagnosticScope scope) async {
    if (_running) return _snapshot;
    setState(() {
      _running = true;
      _scope = scope;
    });
    final next = await widget.onRun(scope);
    if (!mounted) return next;
    setState(() {
      _snapshot = next;
      _running = false;
    });
    return _snapshot;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.ieConnectionCheckTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _DiagnosticsOverviewCard(
            snapshot: _snapshot,
            running: _running,
            scope: _scope,
          ),
          const SizedBox(height: 12),
          HermesPrimaryButton(
            key: const ValueKey('diagnostics-run-all'),
            label: _running
                ? s.ieConnectionCheckRunning
                : (_snapshot.hasAnyResults
                      ? s.ieConnectionCheckAgain
                      : s.ieConnectionCheckNow),
            icon: _running
                ? Icons.sync_rounded
                : Icons.health_and_safety_outlined,
            onTap: _running ? null : () => _run(_DiagnosticScope.all),
          ),
          HermesSectionHeader(s.ieConnectionServices),
          HermesGroup(
            children: [
              _DiagnosticServiceRow(
                title: s.ieSecGateway,
                icon: Icons.dns_outlined,
                results: _snapshot.gateway,
              ),
              _DiagnosticServiceRow(
                title: s.ieSecDashboard,
                icon: Icons.admin_panel_settings_outlined,
                results: _snapshot.dashboard,
              ),
              _DiagnosticServiceRow(
                title: 'Mobile Bridge',
                icon: Icons.hub_outlined,
                results: _snapshot.bridge,
              ),
            ],
          ),
          if (_snapshot.error != null) ...[
            const SizedBox(height: 12),
            HermesInfoBanner(
              _snapshot.error!,
              icon: Icons.error_outline,
              tone: colors.error,
            ),
          ],
          if (_snapshot.suggestions.isNotEmpty) ...[
            HermesSectionHeader(s.ieConnectionRecommendations),
            for (final suggestion in _snapshot.suggestions)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: HermesInfoBanner(
                  suggestion,
                  icon: Icons.lightbulb_outline,
                  tone: colors.warning,
                ),
              ),
          ],
          HermesSectionHeader(s.ieAdvancedSection),
          HermesGroup(
            children: [
              _TechnicalDiagnosticsDisclosure(
                snapshot: _snapshot,
                running: _running,
                onRun: _run,
              ),
            ],
          ),
          const SizedBox(height: 12),
          HermesInfoBanner(s.ieNetworkNote, icon: Icons.vpn_lock_outlined),
        ],
      ),
    );
  }
}

class _DiagnosticsOverviewCard extends StatelessWidget {
  final _DiagnosticsSnapshot snapshot;
  final bool running;
  final _DiagnosticScope scope;

  const _DiagnosticsOverviewCard({
    required this.snapshot,
    required this.running,
    required this.scope,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final mood = snapshot.mood(probing: running);
    final savedOnly =
        !running &&
        !snapshot.hasAnyResults &&
        snapshot.matrix?.checkedAtMs != null;
    final (title, body, tone) = switch (mood) {
      HermesSparkMood.connecting || HermesSparkMood.thinking => (
        s.ieConnectionCheckingTitle,
        scope == _DiagnosticScope.all
            ? s.ieConnectionCheckRunning
            : s.ieConnectionCheckingService(_scopeLabel(scope)),
        colors.accent,
      ),
      HermesSparkMood.success => (
        s.ieConnectionReadyTitle,
        s.ieConnectionCheckReadySummary,
        colors.success,
      ),
      HermesSparkMood.offline => (
        s.ieConnectionOfflineTitle,
        s.ieConnectionCheckOfflineSummary,
        colors.error,
      ),
      HermesSparkMood.error => (
        s.ieConnectionIssuesTitle,
        s.ieConnectionCheckIssuesSummary,
        colors.warning,
      ),
      HermesSparkMood.waiting || HermesSparkMood.jump => (
        s.ieConnectionPartialTitle,
        s.ieConnectionCheckPartialSummary,
        colors.warning,
      ),
      HermesSparkMood.idle => (
        savedOnly ? s.ieConnectionSavedTitle : s.ieConnectionUncheckedTitle,
        savedOnly ? s.ieConnectionSavedSummary : s.ieConnectionCheckSubtitle,
        colors.textSecondary,
      ),
    };
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: switch (mood) {
                HermesSparkMood.connecting ||
                HermesSparkMood.thinking => s.ieDiagA11yChecking,
                HermesSparkMood.success => s.ieDiagA11ySuccess,
                HermesSparkMood.error => s.ieDiagA11yError,
                HermesSparkMood.offline => s.ieDiagA11yOffline,
                _ => s.ieDiagA11yUnchecked,
              },
              image: true,
              child: ExcludeSemantics(
                child: HermesStatusIndicator(mood: mood, size: 34),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: tone,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    body,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _scopeLabel(_DiagnosticScope scope) => switch (scope) {
    _DiagnosticScope.gateway => 'Gateway',
    _DiagnosticScope.dashboard => 'Dashboard',
    _DiagnosticScope.bridge => 'Mobile Bridge',
    _DiagnosticScope.all => '',
  };
}

class _DiagnosticServiceRow extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<ProbeResult>? results;

  const _DiagnosticServiceRow({
    required this.title,
    required this.icon,
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final state = _surfaceState(results);
    final checked = (results ?? const <ProbeResult>[])
        .where((result) => result.status != ProbeStatus.skipped)
        .toList();
    final passed = checked
        .where((result) => result.status == ProbeStatus.ok)
        .length;
    final (status, tone) = switch (state) {
      _DiagnosticSurfaceState.ready => (s.ieServiceReady, colors.success),
      _DiagnosticSurfaceState.attention => (
        s.ieServiceAttention,
        colors.warning,
      ),
      _DiagnosticSurfaceState.offline => (s.ieServiceOffline, colors.error),
      _DiagnosticSurfaceState.unchecked => (
        s.diagStatusSkipped,
        colors.textDisabled,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  checked.isEmpty
                      ? s.ieServiceUncheckedNote
                      : s.ieServiceChecks(passed, checked.length),
                  style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          HermesBadge(status, color: tone, dot: false),
        ],
      ),
    );
  }
}

class _TechnicalDiagnosticsDisclosure extends StatelessWidget {
  final _DiagnosticsSnapshot snapshot;
  final bool running;
  final _DiagnosticsRunner onRun;

  const _TechnicalDiagnosticsDisclosure({
    required this.snapshot,
    required this.running,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ExpansionTile(
      key: const ValueKey('diagnostics-technical'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: colors.textSecondary,
      collapsedIconColor: colors.textDisabled,
      title: Text(
        s.ieTechnicalDetails,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
      ),
      subtitle: Text(
        s.ieTechnicalDetailsSubtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('diagnostics-run-gateway'),
                label: 'Gateway',
                icon: Icons.dns_outlined,
                onTap: running ? null : () => onRun(_DiagnosticScope.gateway),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('diagnostics-run-dashboard'),
                label: 'Dashboard',
                icon: Icons.admin_panel_settings_outlined,
                onTap: running ? null : () => onRun(_DiagnosticScope.dashboard),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('diagnostics-run-bridge'),
                label: 'Bridge',
                icon: Icons.hub_outlined,
                onTap: running ? null : () => onRun(_DiagnosticScope.bridge),
              ),
            ),
          ],
        ),
        if (snapshot.gateway != null) ...[
          const SizedBox(height: 12),
          _ProbeResultCard(title: s.ieSecGateway, results: snapshot.gateway!),
        ],
        if (snapshot.dashboard != null) ...[
          const SizedBox(height: 10),
          _ProbeResultCard(
            title: s.ieSecDashboard,
            results: snapshot.dashboard!,
          ),
        ],
        if (snapshot.bridge != null) ...[
          const SizedBox(height: 10),
          _ProbeResultCard(title: 'Mobile Bridge', results: snapshot.bridge!),
        ],
        if (snapshot.serverCapabilities != null) ...[
          const SizedBox(height: 10),
          _ServerCapsCard(caps: snapshot.serverCapabilities!),
        ],
        if (snapshot.matrix?.checkedAtMs != null) ...[
          const SizedBox(height: 10),
          _CapabilitySummaryCard(matrix: snapshot.matrix!),
        ],
        if (snapshot.report != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.history, size: 12, color: colors.textDisabled),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.ieDiagLastCheck(
                    TimeOfDay.fromDateTime(
                      snapshot.report!.ranAt,
                    ).format(context),
                  ),
                  style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
                ),
              ),
              HermesSecondaryButton(
                label: s.ieDiagCopyBtn,
                icon: Icons.copy_outlined,
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(text: snapshot.report!.toCopyText(s)),
                  );
                  HermesNotice.of(context).showSnackBar(
                    SnackBar(content: Text(s.ieDiagCopied)),
                    kind: HermesNoticeKind.success,
                  );
                },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Aviso sobre la URL del gateway según su privacidad de transporte
/// ([TransportPrivacy]): silencioso si es https/wss, nota suave si es
/// cleartext en red privada, banner persistente si es cleartext hacia un
/// host público (no bloquea guardar: self-hosted manda, solo avisa claro).
class _TransportPrivacyNote extends StatelessWidget {
  final TransportPrivacyClass transport;

  const _TransportPrivacyNote({required this.transport});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    switch (transport) {
      case TransportPrivacyClass.secure:
        return const SizedBox.shrink();
      // Un http:// dentro de Tailscale/LAN es el caso NORMAL de esta app: era
      // una tarjeta elevada con borde en medio del formulario (una caja más
      // compitiendo, y con pinta de alerta activa). Como nota al pie informa
      // igual sin romper la sección; el ámbar se reserva para el caso público,
      // que sí requiere actuar.
      case TransportPrivacyClass.privateCleartext:
        return Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_open_outlined,
                size: 14,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  Strings.of(context).commonCleartextPrivate,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );
      case TransportPrivacyClass.publicCleartext:
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: HermesInfoBanner(
            Strings.of(context).commonCleartextPublic,
            icon: Icons.warning_amber_outlined,
            tone: colors.warning,
          ),
        );
    }
  }
}

// ── Cards de resultados ─────────────────────────────────────────────────

class _ProbeResultCard extends StatelessWidget {
  final String title;
  final List<ProbeResult> results;

  const _ProbeResultCard({required this.title, required this.results});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return HermesCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.8,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          for (final r in results)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.localizedName(s),
                      style: TextStyle(fontSize: 12, color: colors.textPrimary),
                    ),
                  ),
                  if (r.latencyMs != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '${r.latencyMs}ms',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.textDisabled,
                        ),
                      ),
                    ),
                  HermesBadge(
                    r.status.localizedLabel(s),
                    color: _statusColor(r.status, colors),
                    dot: false,
                  ),
                ],
              ),
            ),
          // Detalles de los fallos, debajo de la lista.
          for (final r in results.where(
            (r) => !r.status.isOk && r.detail.isNotEmpty,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${r.localizedName(s)}: ${r.localizedDetail(s)}',
                style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
              ),
            ),
        ],
      ),
    );
  }

  static Color _statusColor(ProbeStatus s, HermesThemeColors c) => switch (s) {
    ProbeStatus.ok => c.success,
    ProbeStatus.notFound || ProbeStatus.methodNotAllowed => c.textSecondary,
    ProbeStatus.skipped => c.textDisabled,
    ProbeStatus.authInvalid || ProbeStatus.authRequired => c.warning,
    _ => c.error,
  };
}

/// Resumen de lo declarado por GET /v1/capabilities, expandible al detalle.
class _ServerCapsCard extends StatefulWidget {
  final ServerCapabilities caps;

  const _ServerCapsCard({required this.caps});

  @override
  State<_ServerCapsCard> createState() => _ServerCapsCardState();
}

class _ServerCapsCardState extends State<_ServerCapsCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final caps = widget.caps;
    return HermesCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  Strings.of(context).ieDeclaredByCapabilities,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                    color: colors.accentHover,
                  ),
                ),
              ),
              if (caps.model != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    caps.model!,
                    style: TextStyle(fontSize: 10, color: colors.textSecondary),
                  ),
                ),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.expand_more,
                  size: 15,
                  color: colors.textDisabled,
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      caps.summary,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _CapabilitySummaryCard extends StatelessWidget {
  final CapabilityMatrix matrix;

  const _CapabilitySummaryCard({required this.matrix});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    // (label, estado, campo de la matriz para saber si lo declaró el server)
    final entries = <(String, CapState, String)>[
      ('chat', matrix.chatSupported, 'chatSupported'),
      (s.ieCapSessionsRw, matrix.sessionsRead, 'sessionsRead'),
      ('streaming', matrix.streamingSupported, 'streamingSupported'),
      (s.ieCapSkillsRead, matrix.skillsRead, 'skillsRead'),
      ('skills (toggle)', matrix.skillsToggle, 'skillsToggle'),
      ('cron r/w', matrix.cronWrite, 'cronWrite'),
      (s.ieCapMemoryRead, matrix.memoryRead, 'memoryRead'),
      (s.ieCapMemoryWrite, matrix.memoryWrite, 'memoryWrite'),
      (s.ieCapModelsWrite, matrix.modelsWrite, 'modelsWrite'),
      (s.ieCapConfigRead, matrix.configRead, 'configRead'),
      ('logs', matrix.logsRead, 'logsRead'),
      ('toolsets', matrix.toolsetsRead, 'toolsetsRead'),
      ('plugins', matrix.pluginsSupported, 'pluginsSupported'),
    ];
    return HermesCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  Strings.of(context).ieCapabilitiesDetected,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                    color: colors.textSecondary,
                  ),
                ),
              ),
              if (matrix.gatewayVersion != null)
                Text(
                  'hermes ${matrix.gatewayVersion}',
                  style: TextStyle(fontSize: 10, color: colors.accentHover),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: entries.map((e) {
              final (label, state, field) = e;
              final fromServer = matrix.isServerSourced(field);
              final color = state.isYes
                  ? colors.success
                  : state.isNo
                  ? colors.textDisabled
                  : colors.warning;
              return HermesBadge(
                // '·srv' = lo declaró /v1/capabilities; sin marca = probe.
                '$label: ${state.isYes
                    ? s.capYes
                    : state.isNo
                    ? s.capNo
                    : '?'}${fromServer ? ' ·srv' : ''}',
                color: color,
                dot: false,
              );
            }).toList(),
          ),
          const SizedBox(height: 6),
          Text(
            Strings.of(context).ieDiagSrvNote,
            style: TextStyle(fontSize: 9.5, color: colors.textDisabled),
          ),
        ],
      ),
    );
  }
}
