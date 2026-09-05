import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'command_risk.dart';

/// Capa ÚNICA de permisos/aprobaciones, compartida por ChatScreen, RunsScreen,
/// ApprovalRequestCard, Activity y (a futuro) las acciones del Mobile Bridge.
/// No debe existir un segundo sistema de aprobaciones en la app.
///
/// Integra con el contrato real del Gateway (`/v1/runs` + `approval.request` /
/// `approval.responded`, choices: once|session|always|deny). El "modo" decide
/// si la app pide permiso, lo auto-resuelve (YOLO) o lo bloquea (solo lectura).

/// Cómo pide permisos el agente.
enum ApprovalMode {
  /// La sesión usa el modo global por defecto (solo válido como override).
  globalDefault,

  /// Auto-aprueba acciones permitidas por la política, sin preguntar.
  yolo,

  /// Pregunta en el chat por cada acción (recomendado).
  interactive,

  /// Pregunta para acciones sensibles; sin auto-approval agresivo.
  conservative,

  /// No se pueden aprobar acciones de escritura; solo denegar.
  readOnly,
}

extension ApprovalModeLabel on ApprovalMode {
  String get label => switch (this) {
    ApprovalMode.globalDefault => 'Config. global',
    ApprovalMode.yolo => 'YOLO',
    ApprovalMode.interactive => 'Preguntar',
    ApprovalMode.conservative => 'Conservador',
    ApprovalMode.readOnly => 'Solo lectura',
  };

  String get storageKey => name;

  static ApprovalMode fromStorage(String? v) =>
      ApprovalMode.values.firstWhere(
        (m) => m.name == v,
        orElse: () => ApprovalMode.interactive,
      );
}

/// Alcance de una resolución de aprobación (mapea 1:1 con el Gateway).
enum ApprovalScope { once, session, always, deny }

extension ApprovalScopeWire on ApprovalScope {
  /// Valor que entiende `POST /v1/runs/{id}/approval {choice}`.
  String get wire => name; // once|session|always|deny
}

/// Riesgo estimado. Reutiliza [CommandRisk] (no hay un segundo enum).
typedef ApprovalRisk = CommandRisk;

/// Qué debe hacer la app ante una `approval.request`.
enum ApprovalDecisionKind {
  /// Mostrar la ApprovalRequestCard y dejar decidir al usuario.
  ask,

  /// Auto-resolver con [ApprovalDecision.scope] (modo YOLO o regla guardada).
  autoApprove,

  /// Bloquear: solo se permite denegar (solo lectura).
  blocked,
}

class ApprovalDecision {
  final ApprovalDecisionKind kind;

  /// Scope con el que auto-resolver cuando [kind] == autoApprove.
  final ApprovalScope? scope;

  /// El paso de aprobación exige una confirmación extra fuerte
  /// (riesgo alto y/o "permitir siempre").
  final bool requiresExtraConfirm;

  /// Motivo legible (para Activity / UI).
  final String reason;

  const ApprovalDecision._(
    this.kind, {
    this.scope,
    this.requiresExtraConfirm = false,
    this.reason = '',
  });

  factory ApprovalDecision.ask({
    bool requiresExtraConfirm = false,
    String reason = '',
  }) => ApprovalDecision._(
    ApprovalDecisionKind.ask,
    requiresExtraConfirm: requiresExtraConfirm,
    reason: reason,
  );

  factory ApprovalDecision.autoApprove(
    ApprovalScope scope, {
    String reason = '',
  }) => ApprovalDecision._(
    ApprovalDecisionKind.autoApprove,
    scope: scope,
    reason: reason,
  );

  factory ApprovalDecision.blocked(String reason) =>
      ApprovalDecision._(ApprovalDecisionKind.blocked, reason: reason);
}

/// Regla de permiso "siempre" guardada localmente (el Gateway no expone
/// listado/gestión de reglas persistidas: se guardan en el móvil, honesto).
class ApprovalRule {
  final String id; // patternKey o hash del comando
  final String description;
  final String? command;
  final String? patternKey;
  final String instanceId;
  final String? sessionId; // null = global a la instancia
  final ApprovalScope scope; // session | always
  final CommandRisk risk;
  final DateTime createdAt;

  const ApprovalRule({
    required this.id,
    required this.description,
    required this.instanceId,
    required this.scope,
    required this.risk,
    required this.createdAt,
    this.command,
    this.patternKey,
    this.sessionId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    if (command != null) 'command': command,
    if (patternKey != null) 'pattern_key': patternKey,
    'instance_id': instanceId,
    if (sessionId != null) 'session_id': sessionId,
    'scope': scope.name,
    'risk': risk.name,
    'created_at': createdAt.toIso8601String(),
  };

  factory ApprovalRule.fromJson(Map<String, dynamic> j) => ApprovalRule(
    id: j['id'] ?? '',
    description: j['description'] ?? '',
    command: j['command'] as String?,
    patternKey: j['pattern_key'] as String?,
    instanceId: j['instance_id'] ?? '',
    sessionId: j['session_id'] as String?,
    scope: ApprovalScope.values.firstWhere(
      (s) => s.name == j['scope'],
      orElse: () => ApprovalScope.always,
    ),
    risk: CommandRisk.values.firstWhere(
      (r) => r.name == j['risk'],
      orElse: () => CommandRisk.medium,
    ),
    createdAt:
        DateTime.tryParse(j['created_at'] ?? '') ?? DateTime.now(),
  );
}

/// Servicio de política de aprobaciones. Estado global persistido en
/// SharedPreferences; overrides por sesión en memoria; reglas "always" locales.
class ApprovalPolicyService extends ChangeNotifier {
  static const _kGlobalMode = 'approval_global_mode';
  static const _kConfirmAlways = 'approval_confirm_always';
  static const _kConfirmHighRisk = 'approval_confirm_high_risk';
  static const _kRequireLock = 'approval_require_lock';
  static const _kRememberSession = 'approval_remember_session';
  static const _kAllowAlways = 'approval_allow_always';
  static const _kSessionModes = 'approval_session_modes';
  static const _kRulesPrefix = 'approval_rules_';

  final SharedPreferences _prefs;

  /// Overrides de modo por sesión (sessionId → modo). Se persiste en prefs para
  /// que un YOLO/Conservador elegido en un chat SOBREVIVA a reinicios y a que el
  /// SO mate el proceso — antes era solo en memoria y se reseteaba al global,
  /// dando la sensación de que "no se aplicaba".
  final Map<String, ApprovalMode> _sessionModes = {};

  ApprovalPolicyService(this._prefs) {
    _loadSessionModes();
  }

  void _loadSessionModes() {
    final raw = _prefs.getString(_kSessionModes);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((sessionId, key) {
        final mode = ApprovalModeLabel.fromStorage(key as String?);
        // globalDefault no se almacena como override (equivale a "sin override").
        if (mode != ApprovalMode.globalDefault) {
          _sessionModes[sessionId] = mode;
        }
      });
    } catch (_) {
      // Persistencia corrupta: ignorar, se reconstruye al elegir modos.
    }
  }

  void _persistSessionModes() {
    final map = _sessionModes.map((k, v) => MapEntry(k, v.storageKey));
    _prefs.setString(_kSessionModes, jsonEncode(map));
  }

  // ── Ajustes globales ──────────────────────────────────────────────────

  /// Modo por defecto. NUNCA YOLO de fábrica: el default es interactive.
  ApprovalMode get globalMode =>
      ApprovalModeLabel.fromStorage(_prefs.getString(_kGlobalMode));

  Future<void> setGlobalMode(ApprovalMode mode) async {
    // globalDefault no es un valor global válido (solo override de sesión).
    final m = mode == ApprovalMode.globalDefault
        ? ApprovalMode.interactive
        : mode;
    await _prefs.setString(_kGlobalMode, m.storageKey);
    notifyListeners();
  }

  /// Confirmación extra para "permitir siempre". Default true.
  bool get confirmAlways => _prefs.getBool(_kConfirmAlways) ?? true;
  Future<void> setConfirmAlways(bool v) async {
    await _prefs.setBool(_kConfirmAlways, v);
    notifyListeners();
  }

  /// Confirmación extra para comandos de riesgo alto. Default true.
  bool get confirmHighRisk => _prefs.getBool(_kConfirmHighRisk) ?? true;
  Future<void> setConfirmHighRisk(bool v) async {
    await _prefs.setBool(_kConfirmHighRisk, v);
    notifyListeners();
  }

  /// Exigir App Lock antes de aprobar acciones sensibles. Default true.
  bool get requireLock => _prefs.getBool(_kRequireLock) ?? true;
  Future<void> setRequireLock(bool v) async {
    await _prefs.setBool(_kRequireLock, v);
    notifyListeners();
  }

  /// Recordar permisos por sesión (scope session). Default true.
  bool get rememberSession => _prefs.getBool(_kRememberSession) ?? true;
  Future<void> setRememberSession(bool v) async {
    await _prefs.setBool(_kRememberSession, v);
    notifyListeners();
  }

  /// Permitir reglas permanentes "always". Default true.
  bool get allowAlways => _prefs.getBool(_kAllowAlways) ?? true;
  Future<void> setAllowAlways(bool v) async {
    await _prefs.setBool(_kAllowAlways, v);
    notifyListeners();
  }

  // ── Modo por sesión ───────────────────────────────────────────────────

  /// Modo override de la sesión, o null si usa el global.
  ApprovalMode? sessionMode(String sessionId) => _sessionModes[sessionId];

  void setSessionMode(String sessionId, ApprovalMode? mode) {
    if (mode == null || mode == ApprovalMode.globalDefault) {
      _sessionModes.remove(sessionId);
    } else {
      _sessionModes[sessionId] = mode;
    }
    _persistSessionModes();
    notifyListeners();
  }

  /// Modo efectivo: override de sesión si existe, si no el global.
  ApprovalMode effectiveMode(String? sessionId) {
    if (sessionId != null) {
      final m = _sessionModes[sessionId];
      if (m != null) return m;
    }
    return globalMode;
  }

  // ── Decisión central ──────────────────────────────────────────────────

  /// Decide qué hacer ante una `approval.request`.
  ///
  /// Invariantes de seguridad:
  ///  - Solo lectura (de instancia O de modo) SIEMPRE gana, incluso sobre YOLO.
  ///  - YOLO nunca está activo por defecto (lo garantiza [globalMode]).
  ///  - YOLO es un opt-in explícito (App Lock + diálogo): auto-aprueba TODO,
  ///    como el `--yolo` de la TUI. Solo Lectura sigue ganando sobre él.
  ///  - [confirmHighRisk] rige la doble confirmación del modo Preguntar, NO
  ///    anula un YOLO que el usuario eligió a propósito.
  ApprovalDecision evaluate({
    required ApprovalMode mode,
    required CommandRisk risk,
    required bool readOnlyInstance,
    bool hasSavedAlways = false,
  }) {
    // 1) Solo lectura gana sobre todo.
    if (readOnlyInstance || mode == ApprovalMode.readOnly) {
      return ApprovalDecision.blocked(
        'Read-only: write actions cannot be approved.',
      );
    }

    final highNeedsConfirm = confirmHighRisk && risk == CommandRisk.high;

    switch (mode) {
      case ApprovalMode.yolo:
        // YOLO = YOLO: auto-aprueba todo (incluido riesgo alto). El usuario lo
        // activó deliberadamente tras App Lock + confirmación; respetamos su
        // elección igual que la TUI con `--yolo`. Solo Lectura ya ganó arriba.
        return ApprovalDecision.autoApprove(
          ApprovalScope.once,
          reason: 'Auto-aprobado por YOLO',
        );

      case ApprovalMode.conservative:
        // Conservador: siempre pregunta; ignora reglas "always" guardadas y
        // exige reconfirmación para riesgo alto.
        return ApprovalDecision.ask(
          requiresExtraConfirm: risk == CommandRisk.high,
          reason: 'Modo conservador',
        );

      case ApprovalMode.interactive:
      case ApprovalMode.globalDefault:
        // Una regla "always" guardada auto-aprueba (si está permitido).
        if (hasSavedAlways && allowAlways && !highNeedsConfirm) {
          return ApprovalDecision.autoApprove(
            ApprovalScope.always,
            reason: 'Regla guardada (permitir siempre)',
          );
        }
        // Preguntar SIEMPRE para lo que el servidor decidió que necesita
        // aprobación. No auto-aprobamos por "riesgo bajo": la heurística no
        // puede clasificar con fiabilidad los scripts de execute_code (un
        // `subprocess.run(['rm', …])` no contiene el patrón `rm ` y se colaría
        // como bajo). El control real es del usuario, no de la heurística.
        return ApprovalDecision.ask(
          requiresExtraConfirm: highNeedsConfirm,
          reason: 'Modo interactivo',
        );

      case ApprovalMode.readOnly:
        return ApprovalDecision.blocked('Solo lectura.');
    }
  }

  // ── Reglas "always" guardadas (locales) ───────────────────────────────

  String _rulesKey(String instanceId) => '$_kRulesPrefix$instanceId';

  List<ApprovalRule> rulesFor(String instanceId) {
    final raw = _prefs.getString(_rulesKey(instanceId));
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(ApprovalRule.fromJson)
          .toList();
    } catch (e) {
      debugPrint('[approval-policy] excepción silenciada (se devuelve lista vacía): $e');
      return const [];
    }
  }

  /// ¿Hay una regla guardada que cubra este comando/patrón?
  bool hasSavedAlways(
    String instanceId, {
    String? patternKey,
    String? command,
  }) {
    if (!allowAlways) return false;
    return rulesFor(instanceId).any(
      (r) =>
          (patternKey != null && r.patternKey == patternKey) ||
          (command != null && r.command == command),
    );
  }

  Future<void> saveRule(ApprovalRule rule) async {
    final rules = [...rulesFor(rule.instanceId)]
      ..removeWhere((r) => r.id == rule.id)
      ..add(rule);
    await _prefs.setString(
      _rulesKey(rule.instanceId),
      jsonEncode(rules.map((r) => r.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> revokeRule(String instanceId, String ruleId) async {
    final rules = [...rulesFor(instanceId)]
      ..removeWhere((r) => r.id == ruleId);
    await _prefs.setString(
      _rulesKey(instanceId),
      jsonEncode(rules.map((r) => r.toJson()).toList()),
    );
    notifyListeners();
  }
}
