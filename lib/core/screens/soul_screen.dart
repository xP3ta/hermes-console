// SOUL — editor del documento de identidad/persona del agente.
//
// Tira del agente: con conexión, lee y escribe el SOUL del perfil activo vía la
// Dashboard API (GET/PUT /api/profiles/{name}/soul → SOUL.md en ~/.hermes),
// incluido el perfil default. Funciona igual en local y remoto. El borrador
// local (SharedPreferences) se conserva como autosave/respaldo y como fallback
// cuando no hay conexión.
//
// Características:
//   - Editor de texto completo (mono, multiline, dark)
//   - Borrador local persistente en SharedPreferences, clave `soul_draft_<id>`
//   - Autosave con debounce ~1s, indicador "borrador guardado" sutil
//   - 4 plantillas integradas con confirmación previa si hay contenido
//   - Banner discreto sobre el estado local
//   - Botón copiar todo al portapapeles
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/bridge_manager.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import 'bridge_editor_mixin.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';

// ── Repository interface (local-first, API-ready) ─────────────────────────────

/// Contract for SOUL document persistence.
/// [LocalSoulRepository] is the only impl for now; swap in an API-backed
/// implementation once the gateway exposes a SOUL endpoint.
abstract class SoulRepository {
  Future<String?> load(String connectionId);
  Future<void> save(String connectionId, String content);
  Future<void> delete(String connectionId);
}

class LocalSoulRepository implements SoulRepository {
  static const _prefix = 'soul_draft_';
  static const _backupPrefix = 'soul_backup_';

  /// Guarda una copia del contenido anterior antes de reemplazar/añadir una
  /// plantilla, para poder restaurarlo (local, instantáneo).
  Future<void> saveBackup(String connectionId, String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_backupPrefix$connectionId', content);
  }

  Future<String?> loadBackup(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_backupPrefix$connectionId');
  }

  Future<bool> hasBackup(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_backupPrefix$connectionId');
  }

  @override
  Future<String?> load(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$connectionId');
  }

  @override
  Future<void> save(String connectionId, String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$connectionId', content);
  }

  @override
  Future<void> delete(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$connectionId');
  }
}

// ── Built-in templates ────────────────────────────────────────────────────────

class _SoulTemplate {
  final String id;
  final String label;
  final String description;
  final String content;

  const _SoulTemplate({
    required this.id,
    required this.label,
    required this.description,
    required this.content,
  });
}

/// Etiqueta localizada de una plantilla SOUL (el `content` se deja tal cual).
String _soulTplLabel(Strings s, _SoulTemplate t) => switch (t.id) {
  'tech' => s.soulTplTechName,
  'homelab' => s.soulTplHomelabName,
  'minimal' => s.soulTplMinimalName,
  _ => s.soulTplEmptyName,
};

String _soulTplDesc(Strings s, _SoulTemplate t) => switch (t.id) {
  'tech' => s.soulTplTechDesc,
  'homelab' => s.soulTplHomelabDesc,
  'minimal' => s.soulTplMinimalDesc,
  _ => s.soulTplEmptyDesc,
};

const _kTemplates = [
  _SoulTemplate(
    id: 'tech',
    label: 'Technical assistant',
    description: 'Profile for programming and sysadmin tasks.',
    content: '''# Identidad

Soy un asistente técnico especializado en programación, infraestructura y
administración de sistemas. Respondo de forma concisa y directa, con código
funcional cuando corresponde.

## Estilo

- Respuestas cortas y precisas; expansión solo si se pide
- Código funcional sobre explicaciones largas
- Señalo problemas sin rodeos
- Prefiero soluciones estándar a inventar algo propio

## Valores

- Honestidad sobre limitaciones
- Reproducibilidad y documentación mínima necesaria
- Seguridad por defecto (no hardcodear secretos, no permisos excesivos)
''',
  ),
  _SoulTemplate(
    id: 'homelab',
    label: 'Homelab operator',
    description: 'Profile for home infrastructure management.',
    content: '''# Identidad

Soy el operador de esta instancia homelab. Gestiono servicios, automatizo tareas
repetitivas y mantengo la infraestructura personal segura y eficiente.

## Contexto

- Red privada Tailscale, nodo local
- Servicios: Docker, Nginx, backup offsite
- Prioridad: disponibilidad > automatización > coste cero

## Comportamiento

- Aviso proactivamente de cambios con impacto en servicios activos
- Registro de decisiones en el log antes de ejecutar
- Rollback plan siempre disponible antes de cambios disruptivos
''',
  ),
  _SoulTemplate(
    id: 'minimal',
    label: 'Minimalist agent',
    description: 'No extra instructions; just the base model.',
    content: '''# Identidad

Responde con la menor cantidad de palabras que transmita la información completa.
Sin preámbulos, sin despedidas, sin confirmaciones innecesarias.
''',
  ),
  _SoulTemplate(
    id: 'empty',
    label: 'Empty',
    description: 'Blank document to start from scratch.',
    content: '',
  ),
];

/// Cómo se aplica una plantilla cuando ya hay contenido en el borrador.
enum _SoulApplyMode { replace, append }

// ── Screen ────────────────────────────────────────────────────────────────────

class SoulScreen extends StatefulWidget {
  /// Optional connection used to scope the local draft and, when a non-default
  /// agent profile is active, to read/write that profile's SOUL via the
  /// Dashboard API (`/api/profiles/<name>/soul`). Pass null for a generic draft.
  final SavedConnection? connection;

  const SoulScreen({this.connection, super.key});

  @override
  State<SoulScreen> createState() => _SoulScreenState();
}

class _SoulScreenState extends State<SoulScreen>
    with BridgeEditorMixin<SoulScreen> {
  final LocalSoulRepository _repo = LocalSoulRepository();
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  bool _loading = true;
  bool _saved = false; // transient "draft saved" indicator
  Timer? _savedTimer;
  bool _hasBackup = false; // hay copia previa restaurable

  // Perfil activo (no-default ⇒ SOUL por perfil vía Dashboard API).
  String _profile = '';
  DashboardClient? _dashClient;
  bool _profileBusy = false;
  bool _serverSoulTried = false;

  String get _connectionId => widget.connection?.id ?? 'default';
  // Nombre de perfil efectivo para la Dashboard API: el perfil default expone
  // su SOUL en /api/profiles/default/soul igual que el resto, así que un perfil
  // vacío se trata como 'default'.
  String get _effectiveProfile => _profile.isEmpty ? 'default' : _profile;
  // Con conexión, el SOUL siempre tira del agente (Dashboard API por perfil),
  // incluido default — sin depender del bridge. Sin conexión cae al borrador
  // local / bridge.
  bool get _profileScoped => widget.connection != null;

  // ── BridgeEditorMixin ──
  @override
  String get bridgeConnectionId => _connectionId;
  @override
  String get bridgeTarget => 'soul';
  @override
  TextEditingController get bridgeController => _controller;
  @override
  String get bridgeLockReason => Strings.of(context).soulApplyToServer;

  @override
  void initState() {
    super.initState();
    _loadDraft();
    _controller.addListener(_onTextChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    probeBridgeOnce();
    // Perfil activo de esta instancia: si no es default, el SOUL se edita por
    // perfil vía Dashboard API en vez del bridge (que apunta al home default).
    final cm = context.findAncestorStateOfType<HermesAppState>()?.connManager;
    final p = (widget.connection != null && cm != null)
        ? cm.activeProfileFor(widget.connection!.id)
        : '';
    // Cliente del Dashboard para CUALQUIER perfil (incluido default): permite
    // leer el SOUL real del servidor sin el bridge, vía /api/profiles/*/soul.
    if (widget.connection != null) {
      _dashClient ??= DashboardClient.lazy(widget.connection!);
    }
    if (p != _profile) {
      setState(() => _profile = p);
    }
    // El perfil activo se resuelve AQUÍ (después de initState, donde _loadDraft
    // pudo cargar el SOUL del default por timing). Para un perfil NO-default,
    // carga su SOUL real vía Dashboard scoped (una vez), de modo que se vea y
    // edite el SOUL del perfil activo y no el del default. El auto-load del
    // bridge queda desactivado para no-default (ver bridgeAutoLoadEnabled), que
    // apunta siempre al home default.
    if (widget.connection != null &&
        _effectiveProfile != 'default' &&
        !_initialProfileLoadDone) {
      _initialProfileLoadDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadProfileSoul();
      });
    }
  }

  bool _initialProfileLoadDone = false;

  /// Desactiva la auto-carga del bridge cuando el perfil activo NO es default: el
  /// bridge lee/escribe el home default y pisaría (o sobreescribiría) el perfil.
  /// El SOUL por perfil se gestiona vía Dashboard scoped (`_loadProfileSoul` /
  /// `_applyProfileSoul`).
  @override
  bool get bridgeAutoLoadEnabled => _effectiveProfile == 'default';

  /// Carga el SOUL real del servidor (Dashboard API) en el editor cuando el
  /// borrador local está vacío, para que el usuario vea su SOUL y no una página
  /// en blanco que parece "borrada". No pisa un borrador con contenido.
  Future<void> _loadServerSoulIfEmpty() async {
    final s = Strings.of(context);
    if (_serverSoulTried) return;
    _serverSoulTried = true;
    final conn = widget.connection;
    if (conn == null) return;
    final client = _dashClient ??= DashboardClient.lazy(conn);
    try {
      final res = await client.getProfileSoul(_effectiveProfile);
      final content = (res['content'] ?? '').toString();
      if (!mounted || content.isEmpty) return;
      if (_controller.text.trim().isEmpty) {
        _setText(content);
        _toast(s.soulServerLoaded);
      }
    } catch (_) {
      // Sin conexión/sin auth: se queda el borrador local. No es un error grave.
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _savedTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _dashClient?.close();
    super.dispose();
  }

  // ── SOUL por perfil (Dashboard API) ─────────────────────────────────────

  /// Carga el SOUL del perfil activo desde `/api/profiles/<name>/soul`.
  Future<void> _loadProfileSoul() async {
    final s = Strings.of(context);
    final client = _dashClient;
    if (client == null) return;
    setState(() => _profileBusy = true);
    try {
      final res = await client.getProfileSoul(_effectiveProfile);
      final content = (res['content'] ?? '').toString();
      if (!mounted) return;
      _setText(content);
      _toast(s.soulProfileLoaded(_effectiveProfile));
    } catch (e) {
      if (mounted) _toast(s.soulLoadFailed(localizedApiError(s, e)));
    } finally {
      if (mounted) setState(() => _profileBusy = false);
    }
  }

  /// Guarda el SOUL en el perfil activo (`PUT /api/profiles/<name>/soul`).
  Future<void> _applyProfileSoul() async {
    final s = Strings.of(context);
    final client = _dashClient;
    if (client == null) return;
    // Política de aprobación: Solo-lectura bloquea; YOLO aplica directo;
    // Preguntar muestra el diálogo + App Lock. Escribir SOUL → riesgo medio.
    final gate = approvalGate(
      context,
      instanceId: _connectionId,
      readOnlyInstance: widget.connection?.readOnly ?? false,
      risk: CommandRisk.medium,
      patternKey: 'soul_write',
    );
    if (gate == ActionGate.blocked) {
      showReadOnlyNotice(context);
      return;
    }
    if (gate == ActionGate.ask) {
      final colors = Theme.of(context).hermes;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          title: Text(s.soulApplyProfileTitle(_effectiveProfile)),
          content: Text(
            s.soulApplyProfileBody(_effectiveProfile),
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(s.soulApply),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
      final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
      if (lock != null && lock.enabled) {
        final ok = await LockScreen.verify(
          context,
          lock,
          reason: s.soulApplyGateTitle(_effectiveProfile),
        );
        if (!ok || !mounted) return;
      }
    }
    setState(() => _profileBusy = true);
    try {
      await client.setProfileSoul(_effectiveProfile, _controller.text);
      if (mounted) _toast(s.soulProfileApplied(_effectiveProfile));
    } catch (e) {
      if (mounted) _toast(s.soulApplyFailed(localizedApiError(s, e)));
    } finally {
      if (mounted) setState(() => _profileBusy = false);
    }
  }

  Future<void> _loadDraft() async {
    final content = await _repo.load(_connectionId);
    final hasBackup = await _repo.hasBackup(_connectionId);
    if (!mounted) return;
    _controller.text = content ?? '';
    // Move cursor to end
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    setState(() {
      _loading = false;
      _hasBackup = hasBackup;
    });
    // Si el borrador local está vacío, intenta mostrar el SOUL real del
    // servidor (sin bridge, vía Dashboard API). Tras un frame para que
    // didChangeDependencies haya creado el cliente del Dashboard.
    if ((content ?? '').trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadServerSoulIfEmpty();
      });
    }
  }

  void _onTextChanged() {
    // Cancel previous debounce and start a new one
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), _autosave);
    // Hide "saved" indicator while typing
    if (_saved) setState(() => _saved = false);
  }

  Future<void> _autosave() async {
    await _repo.save(_connectionId, _controller.text);
    if (!mounted) return;
    setState(() => _saved = true);
    _savedTimer?.cancel();
    _savedTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  Future<void> _forceSave() async {
    _debounce?.cancel();
    await _autosave();
  }

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    HermesNotice.of(context).show(
      message: Strings.of(context).soulCopied,
      kind: HermesNoticeKind.success,
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _showTemplateMenu() async {
    final colors = Theme.of(context).hermes;
    final hasContent = _controller.text.trim().isNotEmpty;

    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('soul-template-surface'),
      maxWidth: 560,
      builder: (ctx) => _TemplateSheet(
        colors: colors,
        hasContent: hasContent,
        onSelect: (template) async {
          Navigator.pop(ctx);
          await _applyTemplate(template);
        },
      ),
    );
  }

  void _setText(String t) {
    _controller.text = t;
    _controller.selection = TextSelection.collapsed(offset: t.length);
  }

  /// Aplica una plantilla de forma segura: si ya hay contenido, deja elegir
  /// entre **Reemplazar** o **Añadir al final**, y guarda una copia previa
  /// restaurable. Si el borrador está vacío, la inserta sin preguntar.
  Future<void> _applyTemplate(_SoulTemplate template) async {
    final s = Strings.of(context);
    final current = _controller.text;
    final hasContent = current.trim().isNotEmpty;
    if (!hasContent) {
      _setText(template.content);
      await _forceSave();
      return;
    }
    final mode = await _askApplyMode(_soulTplLabel(s, template));
    if (mode == null || !mounted) return; // cancelado

    // Copia de seguridad del contenido anterior antes de tocarlo.
    await _repo.saveBackup(_connectionId, current);
    if (mounted) setState(() => _hasBackup = true);

    if (mode == _SoulApplyMode.append) {
      if (template.content.trim().isEmpty) return; // nada que añadir
      final sep = current.endsWith('\n') ? '\n---\n\n' : '\n\n---\n\n';
      _setText(current + sep + template.content);
    } else {
      _setText(template.content);
    }
    await _forceSave();
    _toast(s.soulPrevSaved);
  }

  Future<_SoulApplyMode?> _askApplyMode(String templateLabel) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return showDialog<_SoulApplyMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          s.soulApplyTemplateTitle(templateLabel),
          style: TextStyle(fontSize: 15, color: colors.textPrimary),
        ),
        content: Text(
          s.soulApplyTemplateBody,
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _SoulApplyMode.append),
            child: Text(
              s.soulAppendToEnd,
              style: TextStyle(color: colors.accent),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _SoulApplyMode.replace),
            child: Text(s.soulReplace),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreBackup() async {
    final s = Strings.of(context);
    final backup = await _repo.loadBackup(_connectionId);
    if (backup == null || !mounted) return;
    final colors = Theme.of(context).hermes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(s.soulRestorePrevTitle),
        content: Text(
          s.soulRestorePrevBody,
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.soulRestore),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _setText(backup);
    await _forceSave();
    _toast(s.soulRestored);
  }

  void _toast(String msg) {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;

    return Scaffold(
      appBar: HermesAppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SOUL'),
            _profileScoped
                ? Text(
                    Strings.of(context).soulProfileLabelFmt(_effectiveProfile),
                    style: TextStyle(fontSize: 11, color: colors.accentHover),
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _saved
                        ? Text(
                            Strings.of(context).soulDraftSaved,
                            key: const ValueKey('saved'),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.success,
                            ),
                          )
                        : Text(
                            Strings.of(context).soulLocalDoc,
                            key: const ValueKey('local'),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textDisabled,
                            ),
                          ),
                  ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              bridgeIcon,
              color: bridge.connected
                  ? colors.success
                  : bridge.running
                  ? colors.accent
                  : colors.textSecondary,
            ),
            tooltip: Strings.of(context).soulConfigBridge,
            onPressed: configureBridge,
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: Strings.of(context).soulCopyAll,
            onPressed: _controller.text.isEmpty ? null : _copyAll,
          ),
          if (_hasBackup)
            IconButton(
              icon: const Icon(Icons.restore),
              tooltip: Strings.of(context).soulRestorePrevTitle,
              onPressed: _restoreBackup,
            ),
          IconButton(
            icon: const Icon(Icons.auto_fix_high_outlined),
            tooltip: Strings.of(context).soulTemplatesTitle,
            onPressed: _showTemplateMenu,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: Strings.of(context).soulSaveDraft,
            onPressed: _forceSave,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Builder(
                    builder: (_) {
                      // Sin bridge conectado: mantener el banner local original.
                      if (bridge.status == BridgeStatus.notConfigured ||
                          bridge.status == BridgeStatus.unreachable) {
                        return _ApiBanner(colors: colors);
                      }
                      final b = bridgeBanner(localFallback: '');
                      return HermesInfoBanner(b.text, icon: b.icon);
                    },
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textPrimary,
                        height: 1.5,
                      ),
                      decoration: InputDecoration(
                        hintText: Strings.of(context).soulEditorHint,
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: colors.textDisabled,
                          height: 1.5,
                        ),
                        filled: true,
                        fillColor: colors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: colors.divider.withValues(alpha: 0.55),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: colors.divider.withValues(alpha: 0.55),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: colors.accent.withValues(alpha: 0.5),
                          ),
                        ),
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                ),
                // Con perfil activo: recargar/aplicar por perfil (Dashboard API).
                if (_profileScoped)
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: SafeArea(
                      top: false,
                      child: Row(
                        children: [
                          HermesSecondaryButton(
                            label: _profileBusy
                                ? Strings.of(context).commonLoading
                                : Strings.of(context).soulReload,
                            icon: Icons.cloud_download_outlined,
                            onTap: _profileBusy ? null : _loadProfileSoul,
                          ),
                          const SizedBox(width: 7),
                          HermesSecondaryButton(
                            label: _profileBusy
                                ? Strings.of(context).soulApplying
                                : Strings.of(context).soulApply,
                            icon: Icons.cloud_upload_outlined,
                            color: colors.accent,
                            onTap: _profileBusy ? null : _applyProfileSoul,
                          ),
                        ],
                      ),
                    ),
                  )
                else if (bridgeCanRead || bridgeCanWrite)
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: SafeArea(
                      top: false,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          children: [
                            if (bridgeCanRead) ...[
                              HermesSecondaryButton(
                                label: bridgeLoading
                                    ? Strings.of(context).commonLoading
                                    : Strings.of(context).soulReload,
                                icon: Icons.cloud_download_outlined,
                                onTap: bridgeLoading
                                    ? null
                                    : () => loadFromServer(),
                              ),
                              const SizedBox(width: 7),
                            ],
                            if (bridgeCanWrite)
                              HermesSecondaryButton(
                                label: bridgeApplying
                                    ? Strings.of(context).soulApplying
                                    : Strings.of(context).soulApply,
                                icon: Icons.cloud_upload_outlined,
                                color: colors.accent,
                                onTap: bridgeApplying ? null : applyToServer,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ── Banner discreto ────────────────────────────────────────────────────────────

class _ApiBanner extends StatefulWidget {
  final HermesThemeColors colors;
  const _ApiBanner({required this.colors});

  @override
  State<_ApiBanner> createState() => _ApiBannerState();
}

class _ApiBannerState extends State<_ApiBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: widget.colors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.colors.divider),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 14,
            color: widget.colors.textDisabled,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              Strings.of(context).soulLocalDocNote,
              style: TextStyle(fontSize: 11, color: widget.colors.textDisabled),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close,
              size: 14,
              color: widget.colors.textDisabled,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: Strings.of(context).commonClose,
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}

// ── Template selection sheet ──────────────────────────────────────────────────

class _TemplateSheet extends StatelessWidget {
  final HermesThemeColors colors;
  final bool hasContent;
  final void Function(_SoulTemplate) onSelect;

  const _TemplateSheet({
    required this.colors,
    required this.hasContent,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Strings.of(context).soulTemplatesTitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          if (hasContent) ...[
            const SizedBox(height: 4),
            Text(
              Strings.of(context).soulPickTemplateReplaces,
              style: TextStyle(fontSize: 12, color: colors.textDisabled),
            ),
          ],
          const SizedBox(height: 12),
          ..._kTemplates.map(
            (t) => _TemplateTile(template: t, colors: colors, onTap: onSelect),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final _SoulTemplate template;
  final HermesThemeColors colors;
  final void Function(_SoulTemplate) onTap;

  const _TemplateTile({
    required this.template,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onTap(template),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _soulTplLabel(Strings.of(context), template),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _soulTplDesc(Strings.of(context), template),
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: colors.textDisabled),
          ],
        ),
      ),
    );
  }
}
