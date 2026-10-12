// Editor de instancia: Gateway y Dashboard/Admin como superficies separadas,
// con auth propia cada una y diagnóstico de conexión integrado.
//
// Sustituye al antiguo diálogo de alta/edición. El tipo de instancia
// (vps/homelab/…) queda como detalle secundario: lo que manda es URL + auth.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesSelectRow;
import '../design/hermes_design.dart' as design;
import '../design/modal.dart' show HermesOption, showHermesOptions;
import '../services/connection_diagnostics.dart';
import '../services/connection_manager.dart';
import '../services/connection_setup_activity.dart';
import '../services/dashboard_login_capabilities.dart';
import '../utils/api_error.dart';
import '../services/pairing_link.dart';
import '../theme/app_theme.dart';
import '../utils/transport_privacy.dart';
import '../widgets/api_key_help.dart';
import 'onboarding/manual_setup_page.dart';
import '../companion/models/companion_mood.dart';
import '../widgets/hermes_status_indicator.dart';
import '../widgets/instance_kind_picker.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import 'dashboard_setup_screen.dart';
import 'dashboard_password_screen.dart';
import 'qr_scan_screen.dart';
import '../feedback/feedback_policy.dart';
import '../feedback/screen_help.dart';

enum _DuplicatePairingAction { cancel, openExisting, updateExisting }

class _ConnectionOriginChanged implements Exception {
  const _ConnectionOriginChanged();
}

/// One sentence, in plain words, for what a pairing link sets up: the Gateway
/// and, when the link carries it, the Dashboard access. Names the host only.
String pairingLinkSummary(Strings s, PairingLink link) => link.hasDashboardLogin
    ? s.pairLinkSetsGatewayAndDashboard(link.host)
    : s.pairLinkSetsGateway(link.host);

String _safeDiagnosticCopy(DiagnosticsReport report, Strings s) {
  List<ProbeResult> safe(List<ProbeResult> probes) => probes
      .map(
        (p) => ProbeResult(
          name: p.name,
          status: p.status,
          httpCode: p.httpCode,
          latencyMs: p.latencyMs,
        ),
      )
      .toList();
  return DiagnosticsReport(
    gateway: safe(report.gateway),
    dashboard: safe(report.dashboard),
    matrix: report.matrix,
    suggestions: const [],
    ranAt: report.ranAt,
  ).toCopyText(s);
}

class InstanceEditScreen extends StatefulWidget {
  final ConnectionManager connManager;
  final SavedConnection? initial;

  /// Permite probar el flujo completo con un diagnóstico determinista y sin
  /// abrir red. En producción se omite y la pantalla crea su cliente normal.
  final ConnectionDiagnostics? diagnostics;
  final Future<PairingLink?> Function(BuildContext)? scanCode;
  final bool verifyChatBeforeSave;

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
    this.scanCode,
    this.verifyChatBeforeSave = false,
    super.key,
  });

  @override
  State<InstanceEditScreen> createState() => _InstanceEditScreenState();
}

class _InstanceEditScreenState extends State<InstanceEditScreen> {
  late final VoidCallback _releaseSetup;
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

  // Dashboard
  late final TextEditingController _dashboardUrlCtrl;
  AuthMode _dashAuthMode = AuthMode.cookieSession;
  late final TextEditingController _dashTokenCtrl;
  late final TextEditingController _dashUserCtrl;
  late final TextEditingController _dashPassCtrl;
  bool _dashUserEdited = false;
  bool _hasStoredDashboardAccess = false;
  bool _dashboardLoginVerified = false;

  // Diagnóstico
  ConnectionDiagnostics? _diag;
  List<ProbeResult>? _gatewayResults;
  List<ProbeResult>? _dashboardResults;

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

  // Enlace aplicado (QR, pegado o deep link): la pantalla dice en una frase
  // qué configura. Nunca muestra sus secretos.
  PairingLink? _appliedLink;

  // Modo de auth del Dashboard antes de que un enlace trajera su acceso, por
  // si el usuario apunta el formulario a otro servidor y hay que descartarlo.
  AuthMode? _dashModeBeforeLink;

  // Exceptional connection options are folded for both create and edit.
  bool _advancedExpanded = false;
  bool _dashboardHttpConsent = false;
  late final TextEditingController _gatewayPortCtrl;
  late final TextEditingController _dashboardPortCtrl;

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
    _releaseSetup = ConnectionSetupActivity.instance.hold();
    _diag = widget.diagnostics;
    final init = widget.initial;
    _nameCtrl = TextEditingController(text: init?.label ?? '');
    _notesCtrl = TextEditingController(text: init?.notes ?? '');
    _readOnly = init?.readOnly ?? false;
    _kind = init?.kind ?? InstanceKind.vps;
    _kindManuallySet = init != null;
    _localChatMode = init?.localChatMode ?? LocalChatMode.auto;
    _gatewayPortCtrl = TextEditingController(
      text: (init?.port ?? 8642).toString(),
    );
    _dashboardPortCtrl = TextEditingController(
      text: (init?.dashboardPort ?? 9119).toString(),
    );
    _gatewayUrlCtrl = TextEditingController(
      text: init == null ? '' : init.gatewayUrl,
    );
    _gatewayTransport = TransportPrivacy.classify(_gatewayUrlCtrl.text);
    _gatewayTokenCtrl = TextEditingController();
    _dashboardUrlCtrl = TextEditingController(text: init?.dashboardUrl ?? '');
    // Preserve the explicit stored mode. Editing a secret never infers a
    // provider or copies the Gateway key into Dashboard authority.
    _dashAuthMode = init?.dashboardAuthMode ?? AuthMode.unknown;
    _dashTokenCtrl = TextEditingController();
    _dashUserCtrl = TextEditingController();
    _dashPassCtrl = TextEditingController();
    _gatewayUrlCtrl.addListener(_syncPorts);
    _dashboardUrlCtrl.addListener(_syncPorts);
    for (final controller in [
      _gatewayUrlCtrl,
      _gatewayTokenCtrl,
      _dashboardUrlCtrl,
      _dashTokenCtrl,
      _dashUserCtrl,
      _dashPassCtrl,
    ]) {
      controller.addListener(_dashboardAuthorityChanged);
    }
    if (init != null) {
      _detectedMatrix = widget.connManager.loadCapabilities(init.id);
      // Los secretos existentes no se muestran; campo vacío = no cambiar.
      widget.connManager
          .getDashboardSecrets(init.id)
          .then((s) {
            if (!mounted) return;
            setState(() {
              _hasStoredDashboardAccess =
                  (s.sessionToken?.isNotEmpty ?? false) ||
                  (s.password?.isNotEmpty ?? false);
              if ((s.username?.isNotEmpty ?? false) &&
                  _dashUserCtrl.text.isEmpty) {
                _dashUserCtrl.text = s.username!;
              }
            });
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
      // A draft whose kind is only what its address implies keeps following
      // the address; one that carries a deliberate kind keeps it.
      final automatic = pre.kind == inferInstanceKind(pre.host);
      _kind = automatic ? suggestInstanceKind(pre.host) : pre.kind;
      _kindManuallySet = !automatic;
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

  @override
  void dispose() {
    _diag?.close();
    _releaseSetup();
    for (final c in [
      _nameCtrl,
      _notesCtrl,
      _gatewayUrlCtrl,
      _gatewayTokenCtrl,
      _dashboardUrlCtrl,
      _dashTokenCtrl,
      _dashUserCtrl,
      _dashPassCtrl,
      _gatewayPortCtrl,
      _dashboardPortCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Abre el escáner de QR de emparejado y precarga el formulario con los datos
  /// (host+puerto+token) para que el usuario solo revise y guarde.
  Future<void> _scanQr() async {
    final link = widget.scanCode != null
        ? await widget.scanCode!(context)
        : await Navigator.of(context).push<PairingLink>(
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
      _invalidateDiagnosis();
      if (_nameCtrl.text.trim().isEmpty) _nameCtrl.text = draft.label;
      _gatewayUrlCtrl.text = draft.gatewayUrl;
      _gatewayTransport = TransportPrivacy.classify(draft.gatewayUrl);
      _gatewayTokenCtrl.text = link.token;
      if (link.dashboardUrl != null) {
        _dashboardUrlCtrl.text = link.dashboardUrl!;
      }
      if (_isNew && !_kindManuallySet) {
        _kind = suggestInstanceKind(draft.host);
      }
      _appliedLink = link;
      if (link.hasDashboardLogin) {
        // Existing sign-in carried by the link: the same form fields, and on
        // save the same Keystore slots, as «Acceder al Dashboard». The
        // password stays obscured and its disclosure folded.
        _dashModeBeforeLink ??= _dashAuthMode;
        _dashAuthMode = AuthMode.basicAuth;
        _dashUserCtrl.text = link.dashboardUser!;
        _dashPassCtrl.text = link.dashboardPassword!;
        _dashUserEdited = true;
      }
    });
    if (notify && mounted) {
      AppFeedback.of(
        context,
      ).notify(FeedbackKind.routine, Strings.of(context).instConnLoaded);
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
    final s = Strings.of(context);
    return await design.showHermesDialog<_DuplicatePairingAction>(
          context: context,
          barrierDismissible: false,
          title: s.ieDuplicateTitle,
          message: s.ieDuplicateBody(existing.label, existing.host),
          actions: [
            design.HermesDialogAction(
              label: s.commonCancel,
              value: _DuplicatePairingAction.cancel,
              style: design.HermesDialogActionStyle.cancel,
            ),
            design.HermesDialogAction(
              label: s.ieDuplicateUpdate,
              value: _DuplicatePairingAction.updateExisting,
            ),
            design.HermesDialogAction(
              label: s.ieDuplicateOpen,
              value: _DuplicatePairingAction.openExisting,
            ),
          ],
        ) ??
        _DuplicatePairingAction.cancel;
  }

  int _pairingFingerprint(PairingLink link) => Object.hash(
    link.host,
    link.port,
    link.token,
    link.useHttps,
    link.dashboardUrl,
    link.dashboardUser,
    link.dashboardPassword,
  );

  /// A link's Dashboard sign-in belongs to the server that link names. If the
  /// user points the form at another server it is dropped, unsent and unsaved.
  void _dropLinkDashboardLoginIfRetargeted() {
    final link = _appliedLink;
    if (link == null || !link.hasDashboardLogin) return;
    final gateway = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    final sameGateway =
        gateway.host.toLowerCase() == link.host.toLowerCase() &&
        gateway.port == link.port &&
        gateway.useHttps == link.useHttps;
    final sameDashboard =
        _dashboardUrlCtrl.text.trim() == (link.dashboardUrl ?? '');
    if (sameGateway && sameDashboard) return;
    setState(() {
      if (_dashUserCtrl.text == link.dashboardUser) _dashUserCtrl.clear();
      if (_dashPassCtrl.text == link.dashboardPassword) _dashPassCtrl.clear();
      _dashAuthMode = _dashModeBeforeLink ?? _dashAuthMode;
      _dashModeBeforeLink = null;
      _appliedLink = null;
    });
  }

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
        dashboard:
            _dashboardUrlCtrl.text.trim().isNotEmpty || link.hasDashboardLogin,
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
    final s = Strings.of(context);
    final automate = await design.showHermesDialog<bool>(
      context: context,
      barrierDismissible: false,
      title: s.ieExternalPairingTitle,
      message: pairingLinkSummary(s, link),
      actions: [
        design.HermesDialogAction(
          label: s.ieExternalPairingReview,
          value: false,
          style: design.HermesDialogActionStyle.cancel,
        ),
        design.HermesDialogAction(
          label: s.ieExternalPairingContinue,
          value: true,
        ),
      ],
    );
    _externalPairingPromptOpen = false;
    if (automate == true && mounted) _startPairingAutomation(link);
  }

  int _dashboardAuthorityEpoch = 0;
  void _dashboardAuthorityChanged() {
    _dashboardAuthorityEpoch++;
    _dashboardHttpConsent = false;
    _dashboardLoginVerified = false;
  }

  void _syncPorts() {
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    final chat = normalized.port.toString();
    if (_gatewayPortCtrl.text != chat) {
      _gatewayPortCtrl.text = chat;
    }
    final port = Uri.tryParse(_effectiveDashboardUrl)?.port ?? 9119;
    if (_dashboardPortCtrl.text != port.toString()) {
      _dashboardPortCtrl.text = port.toString();
    }
  }

  Future<void> _setupDashboardLogin() async {
    if (_autoDashBusy || !mounted) return;
    if (_gatewayUrlCtrl.text.trim().isEmpty) {
      setState(() => _error = Strings.of(context).ieGatewayUrlRequired);
      return;
    }
    final epoch = _dashboardAuthorityEpoch;
    final owner = widget.initial?.id;
    final revision = owner == null
        ? null
        : widget.connManager.connectionRevisionFor(owner).value;
    final profileRevision = owner == null
        ? null
        : widget.connManager.activeProfileRevisionFor(owner).value;
    bool current() =>
        mounted &&
        epoch == _dashboardAuthorityEpoch &&
        (owner == null ||
            (widget.connManager.connectionRevisionFor(owner).value ==
                    revision &&
                widget.connManager.activeProfileRevisionFor(owner).value ==
                    profileRevision));
    setState(() => _autoDashBusy = true);
    try {
      final draft = await _draftConnection();
      if (!mounted || !current()) return;
      final result = await Navigator.of(context).push<DashboardCredsResult>(
        MaterialPageRoute(
          builder: (_) => DashboardSetupScreen(
            connection: draft.$1,
            authorityCurrent: current,
          ),
        ),
      );
      if (result == null || !current()) return;
      setState(() {
        _dashAuthMode = result.mode;
        _dashUserCtrl.text = result.username;
        _dashPassCtrl.text = result.password;
        _dashTokenCtrl.text = result.sessionToken;
        _invalidateDiagnosis();
        // This same authority and, on private HTTP, explicit credential
        // consent were verified by the sign-in route before it returned.
        _dashboardHttpConsent = true;
        _dashboardLoginVerified = true;
      });
      // Existing secure-store save owns persistence; no remote rotation or
      // secret write after this editor lease has ended.
    } catch (error) {
      if (mounted && current()) {
        final s = Strings.of(context);
        setState(
          () => _error = error is _ConnectionOriginChanged
              ? s.sOriginChanged
              : s.sSignInFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _autoDashBusy = false);
    }
  }

  // ── Construcción del modelo desde el formulario ───────────────────────

  /// Conexión efímera con el estado actual del formulario (para probar
  /// sin guardar). Usa los secretos del Keystore cuando el campo está vacío.
  late final String _draftId = widget.initial?.id ?? const Uuid().v4();

  Future<(SavedConnection, DashboardSecrets)> _draftConnection() async {
    final id = _draftId;
    final epoch = _dashboardAuthorityEpoch;
    final existing = widget.connManager
        .getConnections()
        .where((connection) => connection.id == id)
        .firstOrNull;
    final revision = widget.connManager.connectionRevisionFor(id).value;
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    for (final controller in [_gatewayPortCtrl, _dashboardPortCtrl]) {
      final port = int.tryParse(controller.text);
      if (port == null || port < 1 || port > 65535) {
        throw const FormatException('Invalid port');
      }
    }
    var apiKey = _gatewayTokenCtrl.text.trim();
    if (apiKey.isEmpty && widget.initial != null) {
      if (existing != null &&
          existing.apiKey.isNotEmpty &&
          (existing.host.toLowerCase() != normalized.host.toLowerCase() ||
              existing.port != normalized.port ||
              existing.useHttps != normalized.useHttps)) {
        // Blank means preserve only within the original authority, never
        // permission to carry a legacy secret to another server.
        throw const _ConnectionOriginChanged();
      }
      apiKey = existing?.apiKey ?? '';
    }
    final stored = widget.initial == null
        ? const DashboardSecrets()
        : await widget.connManager.getDashboardSecrets(id);
    if (!mounted) throw StateError('Instance editor closed');
    if (epoch != _dashboardAuthorityEpoch ||
        revision != widget.connManager.connectionRevisionFor(id).value) {
      throw DashboardAuthException(DashboardAuthFailureCode.loginRequired);
    }
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
      kind: _kindManuallySet ? _kind : suggestInstanceKind(normalized.host),
    );
    if (existing != null &&
        (existing.dashboardHost.toLowerCase() !=
                conn.dashboardHost.toLowerCase() ||
            existing.dashboardPort != conn.dashboardPort ||
            existing.dashboardUseHttps != conn.dashboardUseHttps) &&
        ((stored.sessionToken?.isNotEmpty ?? false) ||
            (stored.username?.isNotEmpty ?? false) ||
            (stored.password?.isNotEmpty ?? false))) {
      // Legacy slots are ID-bound, not origin-bound. Fail closed rather than
      // persist a new endpoint under a slot that still owns old credentials.
      throw const _ConnectionOriginChanged();
    }
    TransportPrivacy.requireAllowed(conn.gatewayUrl);
    TransportPrivacy.requireAllowed(conn.effectiveDashboardUrl);
    return (conn, secrets);
  }

  // ── Diagnóstico ───────────────────────────────────────────────────────

  /// Tell the person the cause and next step, without exception text or
  /// server bodies. The diagnostic route holds the technical probe results.
  String _friendlyError(Object e) {
    debugPrint('[instance-edit] error (${e.runtimeType})');
    final str = Strings.of(context);
    if (e is _ConnectionOriginChanged) {
      return str.sOriginChanged;
    }
    if (e is TimeoutException) {
      return str.o2Unreachable;
    }
    if (e is SocketException) {
      return str.o2Unreachable;
    }
    if (e is HandshakeException || e is TlsException) {
      return str.sCertificate;
    }
    if (e is FormatException) {
      if (e.message == 'Invalid port') {
        return str.sInvalidPort;
      }
      return str.sBadAddress;
    }
    // Only structural causes, never a remote error body.
    if (e is DashboardAuthException || e is DashboardHttpException) {
      return localizedApiError(str, e);
    }
    if (_gatewayTransport == TransportPrivacyClass.publicCleartext ||
        TransportPrivacy.classify(_effectiveDashboardUrl) ==
            TransportPrivacyClass.publicCleartext) {
      return str.commonCleartextPublic;
    }
    return str.sTryAgain;
  }

  _DiagnosticsSnapshot get _diagnosticsSnapshot => _DiagnosticsSnapshot(
    gateway: _gatewayResults,
    dashboard: _dashboardResults,

    suggestions: _suggestions,
    matrix: _detectedMatrix,
    serverCapabilities: _serverCaps,
    report: _lastReport,
    error: _diagnosticError,
  );

  Future<_DiagnosticsSnapshot> _runProbe({
    bool gateway = false,
    bool dashboard = false,
  }) async {
    if (_gatewayUrlCtrl.text.trim().isEmpty) {
      setState(
        () => _diagnosticError = Strings.of(context).ieGatewayUrlBeforeTest,
      );
      return _diagnosticsSnapshot;
    }
    if (!mounted) return _diagnosticsSnapshot;
    // Capturado antes de los await para localizar las sugerencias del
    // diagnóstico sin usar el contexto tras un gap asíncrono.
    final s = Strings.of(context);
    if (_requiresDashboardConsent && !_dashboardHttpConsent) {
      setState(() => _diagnosticError = s.sConsentNeeded);
      return _diagnosticsSnapshot;
    }
    final epoch = _dashboardAuthorityEpoch;
    final owner = widget.initial?.id;
    final revision = owner == null
        ? null
        : widget.connManager.connectionRevisionFor(owner).value;
    final profile = owner == null
        ? null
        : widget.connManager.activeProfileRevisionFor(owner).value;
    bool current() =>
        epoch == _dashboardAuthorityEpoch &&
        (owner == null ||
            (widget.connManager.connectionRevisionFor(owner).value ==
                    revision &&
                widget.connManager.activeProfileRevisionFor(owner).value ==
                    profile));
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

      // Complete diagnostics observes only the configured official surfaces.
      if (gateway && dashboard) {
        final report = await _diag!.run(s, conn, secrets);
        if (!mounted) return _diagnosticsSnapshot;
        if (!current()) {
          setState(() => _diagnosticError = s.sConnectionChanged);
          return _diagnosticsSnapshot;
        }
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
            '[instance-edit] capability storage failed (${e.runtimeType})',
          );
        }
        if (!mounted) return _diagnosticsSnapshot;
        if (!current()) {
          setState(() => _diagnosticError = s.sConnectionChanged);
          return _diagnosticsSnapshot;
        }
        setState(() {
          _gatewayResults = report.gateway;
          _dashboardResults = report.dashboard;

          _suggestions = report.suggestions;
          _detectedMatrix = report.matrix;
          _serverCaps = report.serverCapabilities;
          _lastReport = report;
          if (!report.matrix.dashboardAuthValid.isYes) {
            _dashboardLoginVerified = false;
          }
        });
        return _diagnosticsSnapshot;
      }

      // Comprobaciones parciales: cada parte por separado, de forma
      // independiente, sin que una desactive a las otras.
      List<ProbeResult>? gwResults;
      ServerCapabilities? gwCaps;
      List<ProbeResult>? dashResults;

      if (gateway) {
        final (results, _, serverCaps) = await _diag!.probeGateway(conn);
        gwResults = results;
        gwCaps = serverCaps;
      }
      if (dashboard) {
        dashResults = await _diag!.probeDashboard(conn, secrets);
      }

      if (!mounted) return _diagnosticsSnapshot;
      if (!current()) {
        setState(() => _diagnosticError = s.sConnectionChanged);
        return _diagnosticsSnapshot;
      }
      setState(() {
        if (gwResults != null) {
          _gatewayResults = gwResults;
          _serverCaps = gwCaps;
        }
        if (dashResults != null) _dashboardResults = dashResults;

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

  /// Indicador NEUTRO del diagnóstico de conexión (sin mascota). El icono no
  /// depende solo del color: TalkBack recibe un estado localizado y explícito.
  Widget _diagIndicator() {
    final s = Strings.of(context);
    final label = _statusSentence(s);
    final mood = _probing
        ? CompanionMood.connecting
        : label == s.sReady
        ? CompanionMood.success
        : label == s.sUnchecked
        ? CompanionMood.idle
        : label == s.o2MissingDashboard || label == s.o2ReadOnly
        ? CompanionMood.waiting
        : label == s.o2Unreachable
        ? CompanionMood.offline
        : CompanionMood.error;
    return Semantics(
      label: label,
      image: true,
      child: ExcludeSemantics(
        child: HermesStatusIndicator(mood: mood, size: 20),
      ),
    );
  }

  // ── Guardar ───────────────────────────────────────────────────────────

  Future<void> _openDiagnostics() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _InstanceDiagnosticsScreen(
          initial: _diagnosticsSnapshot,
          onRun: (scope) => switch (scope) {
            _DiagnosticScope.all => _runProbe(gateway: true, dashboard: true),
            _DiagnosticScope.gateway => _runProbe(gateway: true),
            _DiagnosticScope.dashboard => _runProbe(dashboard: true),
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
    if (widget.verifyChatBeforeSave) {
      await _runProbe(gateway: true, dashboard: true);
      if (!mounted) return;
      if (_diagnosticError != null ||
          !(_lastReport?.gateway.any(
                (p) => p.name == 'sessions' && p.status.isOk,
              ) ??
              false)) {
        setState(() => _error = _statusSentence(Strings.of(context)));
        return;
      }
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
      final (conn, _) = await _draftConnection();
      if (!mounted) return;
      // Capture the intended edits before the first persistence await. Blank
      // secrets mean preserve the CURRENT stored value, not the initial model.
      final gatewayKey = _gatewayTokenCtrl.text.trim();
      final dashboardToken = _dashTokenCtrl.text.trim();
      final dashboardUser = _dashUserCtrl.text.trim();
      final dashboardPassword = _dashPassCtrl.text;
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
      final matrix = _detectedMatrix;
      if (matrix != null && matrix.checkedAtMs != null) {
        await widget.connManager.saveCapabilities(conn.id, matrix);
      } else if (_dashboardLoginVerified) {
        await widget.connManager.saveCapabilities(
          conn.id,
          capabilitiesAfterDashboardLogin(
            widget.connManager.loadCapabilities(conn.id),
          ),
        );
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

  // ── Connection screen S ─────────────────────────────────────────────

  void _invalidateDiagnosis() {
    _error = null;
    _gatewayResults = null;
    _dashboardResults = null;
    _lastReport = null;
    _detectedMatrix = null;
    _diagnosticError = null;
  }

  void _onGatewayUrlChanged(String value) {
    _dropLinkDashboardLoginIfRetargeted();
    final normalized = SavedConnection.normalizeHostAndPort(value.trim(), 8642);
    setState(() {
      _gatewayTransport = TransportPrivacy.classify(value);
      if (!_kindManuallySet) _kind = suggestInstanceKind(normalized.host);
      if (_gatewayPortCtrl.text != normalized.port.toString()) {
        _gatewayPortCtrl.text = normalized.port.toString();
      }
    });
  }

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
    ValueChanged<String>? onChanged,
    bool paste = false,
  }) => Padding(
    padding: const EdgeInsets.all(design.HermesSpace.x3),
    child: HermesField(
      fieldKey: key,
      controller: controller,
      label: label,
      hint: hint,
      helperText: helper,
      obscure: obscure,
      autocorrect: autocorrect,
      enableSuggestions: !obscure,
      enableIMEPersonalizedLearning: !obscure,
      keyboardType: keyboardType,
      maxLines: maxLines,
      textInputAction: maxLines == 1
          ? TextInputAction.next
          : TextInputAction.newline,
      suffix: paste
          ? IconButton(
              tooltip: Strings.of(context).sPaste,
              icon: const Icon(Icons.content_paste),
              onPressed: () => _pasteField(controller, onChanged),
            )
          : null,
      onChanged: (value) {
        _invalidateDiagnosis();
        onChanged?.call(value);
        setState(() {});
      },
    ),
  );

  Future<void> _pasteField(
    TextEditingController controller,
    ValueChanged<String>? onChanged,
  ) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || data?.text == null) return;
      setState(() {
        controller.text = data!.text!;
        _invalidateDiagnosis();
        onChanged?.call(controller.text);
      });
    } catch (_) {
      if (mounted) {
        HermesNotice.show(
          context,
          message: Strings.of(context).o2ClipboardFailed,
          kind: HermesNoticeKind.error,
        );
      }
    }
  }

  Future<void> _pastePairing() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final link = PairingLink.tryParse(data?.text ?? '');
      if (link == null) {
        setState(() => _error = Strings.of(context).o2InvalidCode);
      } else {
        await _applyLink(link, notify: true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = Strings.of(context).o2ClipboardFailed);
      }
    }
  }

  Future<void> _changePassword() async {
    final saved = widget.initial;
    if (saved == null ||
        saved.dashboardAuthMode != AuthMode.basicAuth ||
        _readOnly) {
      return;
    }
    final epoch = _dashboardAuthorityEpoch;
    final revision = widget.connManager.connectionRevisionFor(saved.id).value;
    final profile = widget.connManager.activeProfileRevisionFor(saved.id).value;
    bool current() =>
        mounted &&
        epoch == _dashboardAuthorityEpoch &&
        widget.connManager.getConnections().any(
          (c) => c.id == saved.id && !c.readOnly,
        ) &&
        widget.connManager.connectionRevisionFor(saved.id).value == revision &&
        widget.connManager.activeProfileRevisionFor(saved.id).value == profile;
    try {
      final (draft, _) = await _draftConnection();
      if (!mounted || !current()) return;
      if (draft.gatewayUrl != saved.gatewayUrl ||
          draft.effectiveDashboardUrl != saved.effectiveDashboardUrl) {
        setState(() => _error = Strings.of(context).sPasswordSaveConnection);
        return;
      }
      final updated = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => DashboardPasswordScreen(
            connection: saved,
            connManager: widget.connManager,
            authorityCurrent: current,
          ),
        ),
      );
      if (updated != true || !mounted || epoch != _dashboardAuthorityEpoch) {
        return;
      }
      final secrets = await widget.connManager.getDashboardSecrets(saved.id);
      if (!mounted || epoch != _dashboardAuthorityEpoch) return;
      setState(() {
        _dashUserCtrl.text = secrets.username ?? '';
        _dashPassCtrl.clear();
        _dashUserEdited = false;
        _invalidateDiagnosis();
      });
      if (mounted) {
        HermesNotice.show(
          context,
          message: Strings.of(context).sPasswordSaved,
          kind: HermesNoticeKind.success,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = Strings.of(context).sPasswordSaveFailed);
      }
    }
  }

  void _setGatewayPort(String value) {
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) return;
    final old = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    if (old.host.isEmpty) return;
    _gatewayUrlCtrl.text = Uri(
      scheme: old.useHttps ? 'https' : 'http',
      host: old.host,
      port: port,
    ).toString();
    _onGatewayUrlChanged(_gatewayUrlCtrl.text);
  }

  void _setDashboardPort(String value) {
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) return;
    final uri = Uri.tryParse(
      _dashboardUrlCtrl.text.trim().isEmpty
          ? _effectiveDashboardUrl
          : _dashboardUrlCtrl.text.trim(),
    );
    if (uri == null || uri.host.isEmpty) return;
    _dashboardUrlCtrl.text = uri.replace(port: port).toString();
    _dropLinkDashboardLoginIfRetargeted();
  }

  String get _effectiveDashboardUrl {
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    return SavedConnection(
      id: _draftId,
      label: '',
      host: normalized.host,
      port: normalized.port,
      apiKey: '',
      useHttps: normalized.useHttps,
      dashboardUrl: _dashboardUrlCtrl.text.trim().isEmpty
          ? null
          : _dashboardUrlCtrl.text.trim(),
    ).effectiveDashboardUrl;
  }

  bool get _requiresDashboardConsent {
    if (_dashPassCtrl.text.isEmpty && _dashTokenCtrl.text.trim().isEmpty) {
      return false;
    }
    final url = _effectiveDashboardUrl;
    if (TransportPrivacy.classify(url) !=
        TransportPrivacyClass.privateCleartext) {
      return false;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    return host != 'localhost' &&
        !(InternetAddress.tryParse(host)?.isLoopback ?? false);
  }

  void _setEncrypted(bool value) {
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    if (normalized.host.isEmpty) return;
    _gatewayUrlCtrl.text = Uri(
      scheme: value ? 'https' : 'http',
      host: normalized.host,
      port: normalized.port,
    ).toString();
    _onGatewayUrlChanged(_gatewayUrlCtrl.text);
    _invalidateDiagnosis();
  }

  Future<void> _chooseAuth() async {
    final s = Strings.of(context);
    final mode = await showHermesOptions<AuthMode>(
      context: context,
      title: s.ieDashboardAuth,
      selected: _dashAuthMode,
      options: [
        HermesOption(
          value: AuthMode.sessionToken,
          label: s.ieDashboardAuthSession,
        ),
        HermesOption(value: AuthMode.basicAuth, label: s.ieDashboardAuthBasic),
      ],
    );
    if (mode == null || !mounted) return;
    _dashboardAuthorityChanged();
    setState(() {
      _dashAuthMode = mode;
      _invalidateDiagnosis();
    });
  }

  Future<void> _delete() async {
    final connection = widget.initial;
    if (connection == null) return;
    final s = Strings.of(context);
    final confirmed = await design.showHermesDialog<bool>(
      context: context,
      title: s.sRemoveTitle,
      message: s.sRemoveBody(connection.label),
      actions: [
        design.HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: design.HermesDialogActionStyle.cancel,
        ),
        design.HermesDialogAction(
          label: s.sRemove,
          value: true,
          style: design.HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    await widget.connManager.deleteConnection(connection.id);
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  String _statusSentence(Strings s) {
    if (_probing) return s.sChecking;
    if (_diagnosticError != null) return _diagnosticError!;
    final gateway = _gatewayResults;
    if (gateway == null) return s.sUnchecked;
    if (gateway.any(
      (r) =>
          r.status == ProbeStatus.authInvalid ||
          r.status == ProbeStatus.authRequired,
    )) {
      return s.sChatKeyRejected;
    }
    if (gateway.any((r) => r.status == ProbeStatus.tlsError)) {
      return s.sCertificate;
    }
    if (gateway.any(
      (r) =>
          (r.name == 'health' || r.name == 'sessions') &&
          {
            ProbeStatus.timeout,
            ProbeStatus.dnsError,
            ProbeStatus.refused,
            ProbeStatus.error,
          }.contains(r.status),
    )) {
      return s.o2Unreachable;
    }
    if (!gateway.any((r) => r.name == 'sessions' && r.status.isOk)) {
      return s.sWrongChatAddress;
    }
    final dashboard = _dashboardResults;
    if (dashboard?.any((r) => r.status == ProbeStatus.tlsError) == true) {
      return s.sCertificate;
    }
    if (dashboard?.any((r) => r.name == 'status' && !r.status.isOk) == true) {
      return s.sDashboardUnreachable;
    }
    if (dashboard == null ||
        !dashboard.any((r) => r.name == 'auth' && r.status.isOk) ||
        dashboard.any(
          (r) =>
              r.status == ProbeStatus.authInvalid ||
              r.status == ProbeStatus.authRequired,
        )) {
      return s.o2MissingDashboard;
    }
    if (_readOnly ||
        (_detectedMatrix?.chatSupported.isNo == true &&
            _detectedMatrix?.sessionsWrite.isNo == true)) {
      return s.o2ReadOnly;
    }
    return s.sReady;
  }

  /// Cleartext is normal inside a private network (a quiet footnote) and
  /// never allowed over the public internet (a warning, and the save refuses).
  Widget _transportNote(Strings s, HermesThemeColors colors) {
    if (_gatewayUrlCtrl.text.trim().isEmpty) return const SizedBox.shrink();
    switch (_gatewayTransport) {
      case TransportPrivacyClass.secure:
        return const SizedBox.shrink();
      case TransportPrivacyClass.privateCleartext:
        return Padding(
          key: const ValueKey('instance-cleartext-private'),
          padding: const EdgeInsets.fromLTRB(
            design.HermesSpace.x1,
            design.HermesSpace.x2,
            design.HermesSpace.x1,
            0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_open_outlined,
                size: 14,
                color: colors.textSecondary,
              ),
              const SizedBox(width: design.HermesSpace.x2),
              Expanded(
                child: Text(
                  s.commonCleartextPrivate,
                  style: design.HermesType.support.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );
      case TransportPrivacyClass.publicCleartext:
        return Padding(
          padding: const EdgeInsets.only(top: design.HermesSpace.x3),
          child: HermesInfoBanner(
            s.commonCleartextPublic,
            key: const ValueKey('instance-cleartext-public'),
            icon: Icons.warning_amber_outlined,
            tone: colors.warning,
          ),
        );
    }
  }

  Widget _question(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: design.HermesType.title.copyWith(
          color: Theme.of(context).hermes.textPrimary,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final user = _dashUserCtrl.text.trim();
    final normalized = SavedConnection.normalizeHostAndPort(
      _gatewayUrlCtrl.text.trim(),
      8642,
    );
    return design.HermesPage(
      title: _isNew ? s.sNewConnection : widget.initial!.label,
      listKey: const ValueKey('instance-editor-scroll'),
      // The list ends above Save, which sits on the page itself like every
      // other form's: it never covers a row, and it rides above the keyboard.
      wrapBody: (body) => Column(
        children: [
          Expanded(child: design.HermesFadedEnd(child: body)),
          Padding(
            padding: EdgeInsets.fromLTRB(
              design.HermesSpace.pageH,
              design.HermesSpace.x2,
              design.HermesSpace.pageH,
              design.HermesSpace.x4 + MediaQuery.paddingOf(context).bottom,
            ),
            child: HermesPrimaryButton(
              key: const ValueKey('instance-save'),
              label: _saving ? s.ieSaving : s.commonSave,
              icon: Icons.save_outlined,
              onTap: _saving || _probing ? null : _save,
            ),
          ),
        ],
      ),
      children: [
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: HermesInfoBanner(
              _error!,
              icon: Icons.error_outline,
              tone: colors.error,
            ),
          ),
        if (_appliedLink != null)
          HermesInfoBanner(
            pairingLinkSummary(s, _appliedLink!),
            key: const ValueKey('pairing-link-summary'),
            icon: Icons.link,
          ),
        design.HermesListGroup(
          children: [
            design.HermesListRow(
              title: s.sTestConnection,
              key: const ValueKey('instance-test'),
              icon: Icons.wifi_tethering,
              trailing: _diagIndicator(),
              onTap: _probing
                  ? null
                  : () => _runProbe(gateway: true, dashboard: true),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _statusSentence(s),
                  key: const ValueKey('instance-connection-status'),
                  style: design.HermesType.text.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
            design.HermesListRow(
              title: s.sDetails,
              key: const ValueKey('instance-details'),
              icon: Icons.info_outline,
              onTap: _openDiagnostics,
            ),
          ],
        ),
        _question(s.sWhere),
        design.HermesListGroup(
          dividerIndent: 14,
          children: [
            _field(
              key: const ValueKey('instance-name'),
              controller: _nameCtrl,
              label: s.ieName,
            ),
            _field(
              key: const ValueKey('instance-gateway-url'),
              controller: _gatewayUrlCtrl,
              label: s.ieGatewayUrl,
              hint: s.sAddressHint,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onChanged: _onGatewayUrlChanged,
              paste: true,
            ),
          ],
        ),
        _transportNote(s, colors),
        // Still the first block's: where the Hermes is, and what kind of
        // place it is. Same row as the first-run confirmation.
        Padding(
          padding: const EdgeInsets.only(top: design.HermesSpace.x3),
          child: KeyedSubtree(
            key: const ValueKey('instance-icon'),
            child: InstanceKindPicker(
              value: _kind,
              onChanged: (v) => setState(() {
                _kind = v;
                _kindManuallySet = true;
              }),
            ),
          ),
        ),
        _question(s.sAccess),
        design.HermesListGroup(
          dividerIndent: 14,
          children: [
            if (_isNew)
              _field(
                key: const ValueKey('instance-gateway-token'),
                controller: _gatewayTokenCtrl,
                label: s.ieGatewayToken,
                obscure: true,
                autocorrect: false,
                paste: true,
              ),
            design.HermesListRow(
              title: s.o2SignIn,
              key: const ValueKey('instance-dashboard-sign-in'),
              icon: Icons.login,
              subtitle: user.isNotEmpty
                  ? s.sDashboardUser(user)
                  : _hasStoredDashboardAccess
                  ? s.sSavedAccess
                  : s.sSignInNeeded,
              onTap: _autoDashBusy ? null : _setupDashboardLogin,
            ),
            if (!_isNew &&
                widget.initial!.dashboardAuthMode == AuthMode.basicAuth)
              design.HermesListRow(
                title: s.sPasswordTitle,
                icon: Icons.password_outlined,
                key: const ValueKey('instance-change-password'),
                onTap: _readOnly || widget.initial!.readOnly
                    ? null
                    : _changePassword,
              ),
          ],
        ),
        // Outside the group: a tile on a decorated surface hides its ink.
        if (_requiresDashboardConsent)
          CheckboxListTile(
            key: const ValueKey('instance-http-consent'),
            value: _dashboardHttpConsent,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(s.dashboardSetupCredentialConsent),
            onChanged: (v) => setState(() => _dashboardHttpConsent = v == true),
          ),
        _question(s.sOptions),
        design.HermesListGroup(
          children: [
            design.HermesListRow(
              title: s.sScanNewCode,
              icon: Icons.qr_code_scanner,
              key: const ValueKey('instance-scan'),
              onTap: _scanQr,
            ),
            design.HermesListRow(
              title: s.qrPasteLink,
              icon: Icons.content_paste,
              key: const ValueKey('instance-paste-code'),
              onTap: _pastePairing,
            ),
            design.HermesListRow(
              title: s.sAdvanced,
              icon: Icons.tune,
              key: const ValueKey('instance-advanced'),
              trailing: Icon(
                _advancedExpanded ? Icons.expand_less : Icons.expand_more,
              ),
              onTap: () =>
                  setState(() => _advancedExpanded = !_advancedExpanded),
            ),
          ],
        ),
        if (_advancedExpanded) ...[
          const SizedBox(height: design.HermesSpace.x3),
          design.HermesListGroup(
            dividerIndent: 14,
            children: [
              _field(
                key: const ValueKey('instance-chat-port'),
                controller: _gatewayPortCtrl,
                label: s.sChatPort,
                keyboardType: TextInputType.number,
                onChanged: _setGatewayPort,
              ),
              _field(
                key: const ValueKey('instance-dashboard-port'),
                controller: _dashboardPortCtrl,
                label: s.sDashboardPort,
                keyboardType: TextInputType.number,
                onChanged: _setDashboardPort,
              ),
              if (!_isNew)
                _field(
                  key: const ValueKey('instance-gateway-token'),
                  controller: _gatewayTokenCtrl,
                  label: s.ieGatewayTokenEmpty,
                  obscure: true,
                  autocorrect: false,
                  paste: true,
                ),
              design.HermesListRow(
                title: s.sEncrypted,
                subtitle: 'HTTPS',
                onTap: () => _setEncrypted(!normalized.useHttps),
                trailing: Semantics(
                  label: s.sEncrypted,
                  child: Switch(
                    value: normalized.useHttps,
                    onChanged: _setEncrypted,
                  ),
                ),
              ),
              _field(
                key: const ValueKey('instance-dashboard-url'),
                controller: _dashboardUrlCtrl,
                label: s.ieDashboardUrl,
                hint: _effectiveDashboardUrl,
                autocorrect: false,
                keyboardType: TextInputType.url,
                onChanged: (_) => _dropLinkDashboardLoginIfRetargeted(),
                paste: true,
              ),
              HermesSelectRow(
                key: const ValueKey('dashboard-manual-auth-mode'),
                title: s.ieDashboardAuth,
                value: switch (_dashAuthMode) {
                  AuthMode.sessionToken => s.ieDashboardAuthSession,
                  AuthMode.basicAuth => s.ieDashboardAuthBasic,
                  AuthMode.cookieSession => s.ieDashboardAuthAuto,
                  _ => s.sSignInNeeded,
                },
                onTap: _chooseAuth,
              ),
              if (_dashAuthMode == AuthMode.basicAuth ||
                  _dashAuthMode == AuthMode.unknown) ...[
                _field(
                  key: const ValueKey('dashboard-manual-user'),
                  controller: _dashUserCtrl,
                  label: s.commonUser,
                  autocorrect: false,
                  onChanged: (_) {
                    _dashUserEdited = true;
                    if (_dashUserCtrl.text.trim().isNotEmpty) {
                      _dashAuthMode = AuthMode.basicAuth;
                    }
                  },
                ),
                _field(
                  key: const ValueKey('dashboard-manual-password'),
                  controller: _dashPassCtrl,
                  label: _isNew ? s.commonPassword : s.iePasswordEmpty,
                  obscure: true,
                  autocorrect: false,
                  paste: true,
                  onChanged: (_) {
                    if (_dashPassCtrl.text.isNotEmpty) {
                      _dashAuthMode = AuthMode.basicAuth;
                    }
                  },
                ),
              ],
              if (_dashAuthMode == AuthMode.sessionToken)
                _field(
                  key: const ValueKey('dashboard-manual-token'),
                  controller: _dashTokenCtrl,
                  label: s.dashboardSetupSessionToken,
                  obscure: true,
                  autocorrect: false,
                  paste: true,
                ),
              design.HermesListRow(
                title: s.sBrowserSignIn,
                icon: Icons.open_in_browser,
                key: const ValueKey('instance-oauth'),
                onTap: _setupDashboardLogin,
              ),
              design.HermesListRow(
                title: s.ieReadOnly,
                subtitle: s.ieReadOnlySub,
                key: const ValueKey('instance-read-only'),
                onTap: () => setState(() => _readOnly = !_readOnly),
                trailing: Semantics(
                  label: s.ieReadOnly,
                  child: Switch(
                    value: _readOnly,
                    onChanged: (v) => setState(() => _readOnly = v),
                  ),
                ),
              ),
              _field(
                key: const ValueKey('instance-note'),
                controller: _notesCtrl,
                label: s.ieNote,
                maxLines: null,
              ),
              if (_kind == InstanceKind.localhost)
                Padding(
                  padding: const EdgeInsets.all(design.HermesSpace.x3),
                  child: design.HermesSelectField<LocalChatMode>(
                    key: const ValueKey('instance-local-chat-mode'),
                    value: _localChatMode,
                    decoration: InputDecoration(labelText: s.ieLocalChatMode),
                    options: [
                      for (final m in LocalChatMode.values)
                        design.HermesOption(
                          value: m,
                          label: switch (m) {
                            LocalChatMode.auto => s.ieLocalModeAuto,
                            LocalChatMode.simple => s.ieLocalModeSimple,
                            LocalChatMode.agent => s.ieLocalModeAgent,
                          },
                        ),
                    ],
                    onChanged: (v) => setState(() => _localChatMode = v),
                  ),
                ),
            ],
          ),
          const ApiKeyHelpLink(),
          design.HermesListRow(
            title: s.o2SetupByHand,
            icon: Icons.terminal,
            key: const ValueKey('instance-by-hand-help'),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const ManualSetupPage()),
            ),
          ),
          design.HermesListRow(
            title: s.ieDiagCopyBtn,
            icon: Icons.copy_outlined,
            key: const ValueKey('instance-copy-diagnostic'),
            onTap: _lastReport == null
                ? null
                : () {
                    Clipboard.setData(
                      ClipboardData(text: _safeDiagnosticCopy(_lastReport!, s)),
                    );
                    HermesNotice.show(context, message: s.ieDiagCopied);
                  },
          ),
        ],
        if (!_isNew)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: design.HermesListGroup(
              children: [
                design.HermesListRow(
                  title: s.sRemoveTitle,
                  destructive: true,
                  icon: Icons.delete_outline,
                  key: const ValueKey('instance-delete'),
                  onTap: _saving ? null : _delete,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

enum _DiagnosticScope { all, gateway, dashboard }

typedef _DiagnosticsRunner =
    Future<_DiagnosticsSnapshot> Function(_DiagnosticScope scope);

enum _DiagnosticSurfaceState { unchecked, ready, attention, offline }

_DiagnosticSurfaceState _surfaceState(List<ProbeResult>? results) {
  final checked = (results ?? const <ProbeResult>[])
      .where(
        (result) =>
            result.status != ProbeStatus.skipped && !result.absentOptional,
      )
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

  final List<String> suggestions;
  final CapabilityMatrix? matrix;
  final ServerCapabilities? serverCapabilities;
  final DiagnosticsReport? report;
  final String? error;

  const _DiagnosticsSnapshot({
    required this.gateway,
    required this.dashboard,

    required this.suggestions,
    required this.matrix,
    required this.serverCapabilities,
    required this.report,
    required this.error,
  });

  bool get hasAnyResults => gateway != null || dashboard != null;

  bool get hasAllSurfaces => gateway != null && dashboard != null;

  List<_DiagnosticSurfaceState> get surfaceStates => [
    _surfaceState(gateway),
    _surfaceState(dashboard),
  ];

  CompanionMood mood({bool probing = false}) {
    if (probing) return CompanionMood.connecting;
    final states = surfaceStates;
    if (states.every((state) => state == _DiagnosticSurfaceState.unchecked)) {
      return CompanionMood.idle;
    }
    if (states.any((state) => state == _DiagnosticSurfaceState.offline)) {
      return CompanionMood.offline;
    }
    if (states.any((state) => state == _DiagnosticSurfaceState.attention)) {
      return CompanionMood.error;
    }
    if (states.every((state) => state == _DiagnosticSurfaceState.ready)) {
      return CompanionMood.success;
    }
    return CompanionMood.waiting;
  }
}

/// En el editor solo queda esta fila: guardar una instancia ya no queda
/// enterrado bajo endpoints, badges y cuatro botones técnicos. El detalle vive
/// en una pantalla propia, pero el estado sigue siendo visible de un vistazo.

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
      appBar: HermesAppBar(
        title: Text(s.ieConnectionCheckTitle),
        actions: [
          ScreenHelpButton(
            title: s.ieConnectionCheckTitle,
            paragraphs: [s.ieNetworkNote],
          ),
        ],
      ),
      body: ListView(
        clipBehavior: hermesUnderHeader,
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
      CompanionMood.connecting || CompanionMood.thinking => (
        s.ieConnectionCheckingTitle,
        scope == _DiagnosticScope.all
            ? s.ieConnectionCheckRunning
            : s.ieConnectionCheckingService(_scopeLabel(scope)),
        colors.accent,
      ),
      CompanionMood.success => (
        s.ieConnectionReadyTitle,
        s.ieConnectionCheckReadySummary,
        colors.success,
      ),
      CompanionMood.offline => (
        s.ieConnectionOfflineTitle,
        s.ieConnectionCheckOfflineSummary,
        colors.error,
      ),
      CompanionMood.error => (
        s.ieConnectionIssuesTitle,
        s.ieConnectionCheckIssuesSummary,
        colors.warning,
      ),
      CompanionMood.waiting || CompanionMood.jump => (
        s.ieConnectionPartialTitle,
        s.ieConnectionCheckPartialSummary,
        colors.warning,
      ),
      CompanionMood.idle => (
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
                CompanionMood.connecting ||
                CompanionMood.thinking => s.ieDiagA11yChecking,
                CompanionMood.success => s.ieDiagA11ySuccess,
                CompanionMood.error => s.ieDiagA11yError,
                CompanionMood.offline => s.ieDiagA11yOffline,
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
        .where(
          (result) =>
              result.status != ProbeStatus.skipped && !result.absentOptional,
        )
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
        colors.textTertiary,
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
                  style: TextStyle(fontSize: 10.5, color: colors.textTertiary),
                ),
              ),
              HermesSecondaryButton(
                label: s.ieDiagCopyBtn,
                icon: Icons.copy_outlined,
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: _safeDiagnosticCopy(snapshot.report!, s),
                    ),
                  );
                  AppFeedback.of(
                    context,
                  ).notify(FeedbackKind.routine, s.ieDiagCopied);
                },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

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
                          color: colors.textTertiary,
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
            (r) => !r.status.isOk && !r.absentOptional && r.detail.isNotEmpty,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${r.localizedName(s)}: ${r.localizedDetail(s)}',
                style: TextStyle(fontSize: 10.5, color: colors.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  static Color _statusColor(ProbeStatus s, HermesThemeColors c) => switch (s) {
    ProbeStatus.ok => c.success,
    ProbeStatus.notFound || ProbeStatus.methodNotAllowed => c.textSecondary,
    ProbeStatus.skipped => c.textTertiary,
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
                  ? colors.textTertiary
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
            style: TextStyle(fontSize: 9.5, color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}
