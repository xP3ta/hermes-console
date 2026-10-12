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
import '../services/active_profile_scope.dart';
import '../services/app_lock_sensitive_read_fence.dart';

import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';

import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/profile_scope.dart';
import '../widgets/console_loader.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        showHermesDialog,
        showHermesReviewPage;
import '../feedback/feedback_policy.dart';
import '../feedback/screen_help.dart';

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

  /// Fixed profile (a bot card). Null follows the active profile.
  final String? profileOverride;

  /// Active profile source; defaults to the app's for [connection].
  final ActiveProfileScope? profileScope;
  final DashboardClient? dashboardClientForTesting;

  const SoulScreen({
    this.connection,
    this.profileOverride,
    this.profileScope,
    @visibleForTesting this.dashboardClientForTesting,

    super.key,
  });

  @override
  State<SoulScreen> createState() => _SoulScreenState();
}

class _SoulScreenState extends State<SoulScreen>
    with ActiveProfileFollower<SoulScreen> {
  final LocalSoulRepository _repo = LocalSoulRepository();
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  bool _loading = true;
  bool _saved = false; // transient "draft saved" indicator
  Timer? _savedTimer;
  bool _hasBackup = false; // hay copia previa restaurable

  // Profile whose SOUL is edited (empty = default): via the Dashboard API.
  String get _profile => scopedProfileName;
  DashboardClient? _dashClient;

  /// Draft key of the text now in the editor. The default profile keeps the
  /// historical per-connection key; any other profile gets its own key, so
  /// one profile's draft never shows (or is applied) as another's.
  String _editorScope = '';
  String get _draftScope => _effectiveProfile == 'default'
      ? _connectionId
      : '$_connectionId@$_effectiveProfile';
  bool _profileBusy = false;
  bool _serverSoulTried = false;
  int _operation = 0;
  String? _lastServerContent;

  String get _connectionId => widget.connection?.id ?? 'default';
  // Nombre de perfil efectivo para la Dashboard API: el perfil default expone
  // su SOUL en /api/profiles/default/soul igual que el resto, así que un perfil
  // vacío se trata como 'default'.
  String get _effectiveProfile => _profile.isEmpty ? 'default' : _profile;
  // Con conexión, el SOUL siempre tira del agente (Dashboard API por perfil),
  // incluido default — sin depender del bridge. Sin conexión cae al borrador
  // local.
  bool get _profileScoped => widget.connection != null;

  @override
  void initState() {
    super.initState();
    final connection = widget.connection;
    if (connection != null) {
      final override = widget.profileOverride?.trim() ?? '';
      followActiveProfile(
        widget.profileScope ?? appActiveProfileScope(context, connection.id),
        fixedProfile: override.isEmpty ? null : override,
      );
    }
    _loadDraft();
    _controller.addListener(_onTextChanged);
  }

  @override
  void onActiveProfileChanged() {
    // Keep what was typed for the previous profile under its own key, then
    // load the new profile's draft and SOUL.
    final pending = _debounce?.isActive ?? false;
    _debounce?.cancel();
    if (pending) unawaited(_repo.save(_editorScope, _controller.text));
    _serverSoulTried = false;
    _operation++;
    _lastServerContent = null;
    setState(() {
      _profileBusy = false;
      _loading = true;
      _hasBackup = false;
    });
    unawaited(_loadDraft());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Cliente del Dashboard para CUALQUIER perfil (incluido default): permite
    // leer el SOUL real del servidor sin el bridge, vía /api/profiles/*/soul.
    if (widget.connection != null) {
      _dashClient ??=
          widget.dashboardClientForTesting ??
          DashboardClient.lazy(widget.connection!);
    }
  }

  /// Carga el SOUL real del servidor (Dashboard API) en el editor cuando el
  /// borrador local está vacío, para que el usuario vea su SOUL y no una página
  /// en blanco que parece "borrada". No pisa un borrador con contenido.
  Future<void> _loadServerSoulIfEmpty() async {
    if (_serverSoulTried) return;
    _serverSoulTried = true;
    await _loadProfileSoul(replaceDraft: false);
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) {
      // Final flush owns its captured key/text even after navigation disposes UI.
      unawaited(_repo.save(_editorScope, _controller.text));
    }
    _debounce?.cancel();
    _savedTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _dashClient?.close();
    super.dispose();
  }

  String _officialContent(Map<String, dynamic> response) {
    final content = response['content'];
    if (content is! String || response['exists'] is! bool) {
      throw const FormatException('Invalid SOUL response');
    }
    return content;
  }

  // ── SOUL por perfil (Dashboard API) ─────────────────────────────────────

  /// Carga el SOUL del perfil activo desde `/api/profiles/<name>/soul`.
  Future<void> _loadProfileSoul({bool replaceDraft = true}) async {
    final s = Strings.of(context);
    final client = _dashClient;
    if (client == null) return;
    final ticket = profileReadTicket();
    final disclosure = AppLockSensitiveReadFence.capture();
    final operation = ++_operation;
    final textBefore = _controller.text;
    bool current() =>
        mounted &&
        operation == _operation &&
        ticket.isCurrent &&
        disclosure.isCurrent;
    if (!current()) return;
    setState(() => _profileBusy = true);
    try {
      if (replaceDraft &&
          textBefore.isNotEmpty &&
          textBefore != _lastServerContent) {
        final confirmed = await showHermesDialog<bool>(
          context: context,
          title: s.bfeReloadTitle,
          message: s.bfeReloadBody,
          actions: [
            HermesDialogAction(
              label: s.commonCancel,
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(label: s.commonReload, value: true),
          ],
        );
        if (confirmed != true || !current() || _controller.text != textBefore) {
          return;
        }
      }
      final content = _officialContent(
        await client.getProfileSoul(ticket.owner),
      );
      if (!current()) return;
      _lastServerContent = content;
      // A pending initial read never overwrites a local edit or another owner.
      if (_controller.text == textBefore &&
          (replaceDraft || textBefore.isEmpty)) {
        _setText(content);
        _toast(s.soulProfileLoaded(ticket.owner), FeedbackKind.routine);
      }
    } catch (e) {
      if (current()) _toast(s.soulLoadFailed(localizedApiError(s, e)));
    } finally {
      // Busy belongs to this operation, independent of disclosure authority.
      if (mounted && operation == _operation) {
        setState(() => _profileBusy = false);
      }
    }
  }

  /// Guarda el SOUL en el perfil activo (`PUT /api/profiles/<name>/soul`).
  Future<void> _applyProfileSoul() async {
    final s = Strings.of(context);
    final client = _dashClient;
    if (client == null || _profileBusy) return;
    final ticket = profileReadTicket();
    final disclosure = AppLockSensitiveReadFence.capture();
    final scope = _editorScope;
    final content = _controller.text;
    bool current() =>
        mounted &&
        ticket.isCurrent &&
        disclosure.isCurrent &&
        scope == _editorScope &&
        scope == _draftScope;
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
    if (!current()) return;
    setState(() => _profileBusy = true);
    try {
      // The official route has no dry-run or remote backup capability.
      final before = _officialContent(
        await client.getProfileSoul(ticket.owner),
      );
      if (!mounted || !current()) return;
      if (gate == ActionGate.ask) {
        final diff = before == content
            ? s.bfeNoDiff
            : '--- SOUL.md\n+++ SOUL.md\n${before.split('\n').map((line) => '-$line').join('\n')}\n${content.split('\n').map((line) => '+$line').join('\n')}';
        final confirmed = await showHermesReviewPage(
          context: context,
          pageKey: const ValueKey('soul-diff-page'),
          title: s.soulApplyProfileTitle(ticket.owner),
          text: diff,
          confirmLabel: s.soulApply,
        );
        if (!confirmed || !mounted || !current()) return;
        final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
        if (lock != null && lock.enabled) {
          final ok = await LockScreen.verify(
            context,
            lock,
            reason: s.soulApplyGateTitle(ticket.owner),
          );
          if (!ok || !current()) return;
        }
      }
      // Recheck after approval; never overwrite a server edit made during review.
      final fresh = _officialContent(await client.getProfileSoul(ticket.owner));
      if (!current()) return;
      if (fresh != before || content != _controller.text) {
        throw StateError(
          'SOUL changed during review. Reload and review again.',
        );
      }
      final result = await client.setProfileSoul(ticket.owner, content);
      if (!current()) return;
      if (result['ok'] != true) {
        throw const FormatException('SOUL write not confirmed');
      }
      final saved = _officialContent(await client.getProfileSoul(ticket.owner));
      if (!current()) return;
      if (saved != content) {
        throw const FormatException('SOUL write not verified');
      }
      _toast(s.soulProfileApplied(ticket.owner), FeedbackKind.routine);
    } catch (e) {
      if (current()) _toast(s.soulApplyFailed(localizedApiError(s, e)));
    } finally {
      if (mounted && ticket.isCurrent) setState(() => _profileBusy = false);
    }
  }

  Future<void> _loadDraft() async {
    final ticket = profileReadTicket();
    final disclosure = AppLockSensitiveReadFence.capture();
    final scope = _draftScope;
    final content = await _repo.load(scope);
    final hasBackup = await _repo.hasBackup(scope);
    if (!mounted || !ticket.isCurrent || !disclosure.isCurrent) return;
    _editorScope = scope;
    _controller.text = content ?? '';
    // Move cursor to end
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    setState(() {
      _loading = false;
      _hasBackup = hasBackup;
    });
    // A stored empty draft is an intentional reset, not missing local data.
    // Only a missing draft is initialized from the official server document.
    if (content == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ticket.isCurrent && disclosure.isCurrent) {
          _loadServerSoulIfEmpty();
        }
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
    await _repo.save(_editorScope, _controller.text);
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
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.routine, Strings.of(context).soulCopied);
  }

  Future<void> _showTemplateMenu() async {
    final colors = Theme.of(context).hermes;
    final ticket = profileReadTicket();
    final disclosure = AppLockSensitiveReadFence.capture();
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
          if (!mounted || !ticket.isCurrent || !disclosure.isCurrent) return;
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
    final ticket = profileReadTicket();
    final disclosure = AppLockSensitiveReadFence.capture();
    final scope = _editorScope;
    bool ownerCurrent() =>
        mounted &&
        ticket.isCurrent &&
        disclosure.isCurrent &&
        scope == _editorScope;
    final current = _controller.text;
    final hasContent = current.trim().isNotEmpty;
    if (!hasContent) {
      _setText(template.content);
      await _forceSave();
      return;
    }
    final mode = await _askApplyMode(_soulTplLabel(s, template));
    if (mode == null || !ownerCurrent() || _controller.text != current) return;

    // Keep the local backup under the captured owner, not the successor.
    await _repo.saveBackup(scope, current);
    if (!ownerCurrent() || _controller.text != current) return;
    setState(() => _hasBackup = true);

    if (mode == _SoulApplyMode.append) {
      if (template.content.trim().isEmpty) return; // nada que añadir
      final sep = current.endsWith('\n') ? '\n---\n\n' : '\n\n---\n\n';
      _setText(current + sep + template.content);
    } else {
      _setText(template.content);
    }
    await _forceSave();
    _toast(s.soulPrevSaved, FeedbackKind.routine);
  }

  Future<_SoulApplyMode?> _askApplyMode(String templateLabel) {
    final s = Strings.of(context);
    return showHermesDialog<_SoulApplyMode?>(
      context: context,
      title: s.soulApplyTemplateTitle(templateLabel),
      message: s.soulApplyTemplateBody,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: null,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.soulAppendToEnd,
          value: _SoulApplyMode.append,
        ),
        HermesDialogAction(label: s.soulReplace, value: _SoulApplyMode.replace),
      ],
    );
  }

  Future<void> _restoreBackup() async {
    final s = Strings.of(context);
    final ticket = profileReadTicket();
    final disclosure = AppLockSensitiveReadFence.capture();
    final scope = _editorScope;
    final text = _controller.text;
    bool current() =>
        mounted &&
        ticket.isCurrent &&
        disclosure.isCurrent &&
        scope == _editorScope &&
        text == _controller.text;
    final backup = await _repo.loadBackup(scope);
    if (backup == null || !mounted || !current()) return;
    final ok = await showHermesDialog<bool>(
      context: context,
      title: s.soulRestorePrevTitle,
      message: s.soulRestorePrevBody,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(label: s.soulRestore, value: true),
      ],
    );
    if (ok != true || !current()) return;
    _setText(backup);
    await _forceSave();
    _toast(s.soulRestored, FeedbackKind.routine);
  }

  void _toast(String msg, [FeedbackKind kind = FeedbackKind.error]) {
    if (!mounted) return;
    AppFeedback.notify(context, kind, msg);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;

    return Scaffold(
      appBar: HermesAppBar(
        title: const Text('SOUL'),
        // Whose SOUL this is, when it is not the default profile's; for the
        // local document, the mark that the draft was just saved.
        titleBadge: _profileScoped
            ? ProfileScopeLabel.badgeFor(
                profile: _profile,
                connectionId: widget.connection?.id,
              )
            : _saved
            ? Icon(
                Icons.check_circle_rounded,
                key: const ValueKey('saved'),
                size: 16,
                color: colors.success,
                semanticLabel: Strings.of(context).soulDraftSaved,
              )
            : null,
        actions: [
          // Saving and the templates come first: they are the two that stay
          // in the header's pill; the rest go behind its "more".
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: Strings.of(context).soulSaveDraft,
            onPressed: _forceSave,
          ),
          IconButton(
            icon: const Icon(Icons.auto_fix_high_outlined),
            tooltip: Strings.of(context).soulTemplatesTitle,
            onPressed: _showTemplateMenu,
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
          if (!_profileScoped)
            ScreenHelpButton(
              title: 'SOUL',
              paragraphs: [Strings.of(context).soulLocalDocNote],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: ConsoleLoader.large())
          : Column(
              children: [
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
                          color: colors.textTertiary,
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
              style: TextStyle(fontSize: 12, color: colors.textTertiary),
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
