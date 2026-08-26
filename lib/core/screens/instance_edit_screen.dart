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
      widget.connManager.getDashboardSecrets(init.id).then((s) {
        if (!mounted) return;
        if ((s.username?.isNotEmpty ?? false) && _dashUserCtrl.text.isEmpty) {
          _dashUserCtrl.text = s.username!;
        }
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
    });
    if (notify && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).instConnLoaded)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).ieGatewayCredentialsRequired),
        ),
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
    });
    ScaffoldMessenger.of(context).showSnackBar(
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).ieNeedGatewayFirst)),
        );
      }
      return false;
    }
    if (!silent && mounted) setState(() => _autoDashBusy = true);
    try {
      final bToken = await _resolveBridgeToken(bridgeUrl, gatewayToken);
      if (bToken == null || bToken.isEmpty) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).ieBridgeNoToken)),
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(Strings.of(context).ieDashPassFailed)),
            );
          }
          return false;
        }
        final finalUser = (res['username'] ?? user).toString();
        if (!mounted) return false;
        setState(() {
          _dashAuthMode = AuthMode.basicAuth;
          _dashUserCtrl.text = finalUser;
          _dashPassCtrl.text = pass;
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
        ScaffoldMessenger.of(context).showSnackBar(
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).ieDashConfigError(e.toString())),
          ),
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
      apiKey = widget.initial!.apiKey;
    }
    final stored = widget.initial == null
        ? const DashboardSecrets()
        : await widget.connManager.getDashboardSecrets(id);
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
    debugPrint('[instance-edit] detalle técnico del error: $e');
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
      final (conn, _) = await _draftConnection();
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
      await widget.connManager.upsertConnection(withCheck);
      await widget.connManager.setDashboardSecrets(
        conn.id,
        sessionToken: _dashTokenCtrl.text.trim().isNotEmpty
            ? _dashTokenCtrl.text.trim()
            : null,
        username: _dashUserCtrl.text.trim().isNotEmpty
            ? _dashUserCtrl.text.trim()
            : null,
        password: _dashPassCtrl.text.isNotEmpty ? _dashPassCtrl.text : null,
      );
      await widget.connManager.setBridgeConfig(
        conn.id,
        url: _bridgeUrlCtrl.text,
        token: _bridgeTokenCtrl.text,
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        // Título estándar del tema (color/peso/espaciado/tamaño coherentes con
        // el resto): sin estilo inline que lo descuadre frente a otras pantallas.
        title: Text(_isNew ? s.ieNewInstanceTitle : s.homeEditInstance),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          if (_error != null) ...[
            const SizedBox(height: 8),
            HermesInfoBanner(
              _error!,
              icon: Icons.error_outline,
              tone: colors.error,
            ),
          ],
          if (_showDeepLinkBanner) ...[
            const SizedBox(height: 8),
            HermesInfoBanner(
              s.ieExternalLinkBanner,
              icon: Icons.link,
              tone: colors.warning,
            ),
          ],
          if (widget.initial == null) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(Strings.of(context).qrScanTitle),
            ),
            const SizedBox(height: 4),
            Text(
              Strings.of(context).instQrFasterHint,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
            const SizedBox(height: 8),
          ],
          HermesSectionHeader(s.ieSectionGeneral),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(labelText: Strings.of(context).ieName),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _notesCtrl,
            maxLines: 2,
            minLines: 1,
            decoration: InputDecoration(
              labelText: Strings.of(context).ieNote,
              hintText: Strings.of(context).ieNoteHint,
            ),
          ),
          const SizedBox(height: 4),
          HermesSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: Strings.of(context).ieReadOnly,
            subtitle: Strings.of(context).ieReadOnlySub,
            value: _readOnly,
            onChanged: (v) => setState(() => _readOnly = v),
          ),
          if (_kind == InstanceKind.localhost) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<LocalChatMode>(
              initialValue: _localChatMode,
              style: Theme.of(context).dropdownMenuTheme.textStyle,
              decoration: InputDecoration(
                labelText: Strings.of(context).ieLocalChatMode,
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
            if (_localChatMode != LocalChatMode.agent)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: Text(
                  _localChatMode == LocalChatMode.auto
                      ? Strings.of(context).instChatSimpleAuto
                      : Strings.of(context).instChatSimpleNoTools,
                  style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
                ),
              ),
          ],
          HermesSectionHeader(s.ieSectionGateway),
          TextField(
            key: const ValueKey('instance-gateway-url'),
            controller: _gatewayUrlCtrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: Strings.of(context).ieGatewayUrl,
              hintText: s.ieGatewayUrlHint,
            ),
            onChanged: (v) {
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
            },
          ),
          if (_gatewayUrlCtrl.text.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _TransportPrivacyNote(transport: _gatewayTransport),
          ],
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('instance-gateway-token'),
            controller: _gatewayTokenCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _isNew
                  ? Strings.of(context).ieGatewayToken
                  : Strings.of(context).ieGatewayTokenEmpty,
            ),
          ),
          const SizedBox(height: 4),
          const ApiKeyHelpLink(),
          HermesSectionHeader(s.ieSectionBridge),
          HermesInfoBanner(s.ieBridgeQrHint, icon: Icons.hub_outlined),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('instance-bridge-token'),
            controller: _bridgeTokenCtrl,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: _isNew ? s.bridgeToken : s.ieBridgeTokenEmpty,
              hintText: s.bridgeTokenHint,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('instance-bridge-url'),
            controller: _bridgeUrlCtrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: s.bridgeUrlAdvanced,
              hintText:
                  _effectiveBridgeUrlFromForm() ?? 'http://100.x.x.x:9131',
              helperText: s.ieBridgeUrlEmptyHint,
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() => _bridgeUrlEdited = true),
          ),
          const SizedBox(height: 6),
          Text(
            s.bridgeTokenNote,
            style: TextStyle(fontSize: 11, color: colors.textDisabled),
          ),
          HermesSectionHeader(s.ieSectionDashboard),
          TextField(
            controller: _dashboardUrlCtrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: Strings.of(context).ieDashboardUrl,
              hintText:
                  widget.initial?.effectiveDashboardUrl ?? s.ieDashboardUrlHint,
            ),
          ),
          const SizedBox(height: 10),
          // Camino recomendado: un toque, sin teclear nada. Provisiona el
          // bridge, fija una contraseña nueva y la deja cargada (visible).
          FilledButton.icon(
            onPressed: _autoDashBusy ? null : _confirmAndAutoConfigureDashboard,
            icon: _autoDashBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_outlined),
            label: Text(Strings.of(context).ieAutoconfigDash),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _setupDashboardViaBridge,
            icon: const Icon(Icons.key_outlined),
            label: Text(Strings.of(context).instDashPwBridge),
          ),
          Text(
            Strings.of(context).instDashPwHint,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          // Solo Basic Auth: usuario + contraseña, siempre visibles.
          const SizedBox(height: 10),
          TextField(
            controller: _dashUserCtrl,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: Strings.of(context).commonUser,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _dashPassCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _isNew
                  ? Strings.of(context).commonPassword
                  : Strings.of(context).iePasswordEmpty,
            ),
          ),
          const SizedBox(height: 8),
          HermesInfoBanner(
            Strings.of(context).ieDashboardProtected,
            icon: Icons.shield_outlined,
            tone: colors.warning,
          ),
          HermesSectionHeader(s.ieSectionType),
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
                    color: sel ? colors.onAccent : colors.textSecondary,
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
          HermesSectionHeader(s.ieConnectionCheckTitle),
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
          const SizedBox(height: 20),
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
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
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(s.ieDiagCopied)));
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
      case TransportPrivacyClass.privateCleartext:
        return HermesInfoBanner(
          Strings.of(context).commonCleartextPrivate,
          icon: Icons.lock_open_outlined,
        );
      case TransportPrivacyClass.publicCleartext:
        return HermesInfoBanner(
          Strings.of(context).commonCleartextPublic,
          icon: Icons.warning_amber_outlined,
          tone: colors.warning,
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
