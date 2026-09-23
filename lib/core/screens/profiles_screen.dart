// Perfiles de agente (NOUS Profile Builder, jun-2026).
//
// Cada perfil es un home aislado del agente (~/.hermes/profiles/<name>/) con su
// propio modelo, SOUL, skills, env y cron. El roster y la creación prefieren
// los RPC profile-scoped `profiles.*` que usa Hermes Desktop. La Dashboard API
// queda como compatibilidad para instalaciones antiguas y para operaciones
// administrativas que Hermes aún no publica por RPC.
//
// - Lista con estado real (modelo·proveedor, nº skills, gateway activo).
// - "Usar como activo": reescala Modelos y Skills a ese perfil.
// - Crear: asistente por pasos con todo preconfigurado (clona del base).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/agent_profile.dart';
import '../models/dock_config.dart';
import '../services/connection_manager.dart';
import '../services/dock_preferences_store.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/mission_profile_avatar.dart';
import 'lock_screen.dart';
import 'profile_editor_screen.dart';

/// Validación del nombre de perfil (debe coincidir con el servidor).
final _profileNameRe = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

class ProfilesScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final String? initialDeleteProfile;
  const ProfilesScreen({
    required this.connection,
    required this.connManager,
    this.initialDeleteProfile,
    super.key,
  });

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  late final DashboardClient _client;
  late final TuiGatewayClient _gateway;
  // Mismo caché que usa Mission Control para las mismas caras de bot: cada
  // perfil ya trae su propia identidad visual (foto subida o "Blobatar"
  // procedural), así que la lista no necesita un icono genérico propio.
  late final MissionProfileAvatarCache _avatarCache;
  List<AgentProfile> _profiles = [];
  bool _loading = true;
  bool _initialDeleteShown = false;
  String? _error;

  String get _activeProfile =>
      widget.connManager.activeProfileFor(widget.connection.id);

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _gateway = TuiGatewayClient(widget.connection, dashboard: _client);
    _avatarCache = MissionProfileAvatarCache(loader: _gateway.profileAvatar);
    // _load() lee Strings.of(context) (Localizations), que NO puede invocarse
    // durante initState: lanzaría dependOnInheritedWidgetOfExactType y, al estar
    // fuera del try, dejaría _loading=true para siempre (spinner eterno). Se
    // difiere al primer frame, cuando el contexto ya tiene Localizations.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    unawaited(_gateway.close());
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    final str = Strings.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<AgentProfile> list;
      try {
        list = await _gateway.listProfiles();
      } catch (_) {
        // Safe read-only fallback for Gateways that predate profiles.list.
        list = await _client.getProfiles();
      }
      if (!mounted) return;
      setState(() {
        _profiles = list;
        _loading = false;
      });
      if (!_initialDeleteShown && widget.initialDeleteProfile != null) {
        _initialDeleteShown = true;
        final profile = list.where((p) => p.name == widget.initialDeleteProfile).firstOrNull;
        if (profile != null && !profile.isDefault && profile.name != 'default') {
          await _delete(profile);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _humanError(str, e);
        _loading = false;
      });
    }
  }

  String _humanError(Strings str, Object e) {
    final s = e.toString();
    if (s.contains('401')) return str.prfLoadErrorToken;
    if (s.contains('404')) return str.prfLoadErrorVersion;
    return str.prfLoadError(humanizeApiError(e));
  }

  void _snack(String msg, {bool ok = true}) {
    if (!mounted) return;
    HermesNotice.of(context).show(
      message: msg,
      kind: ok ? HermesNoticeKind.success : HermesNoticeKind.error,
    );
  }

  // ── Acciones ──────────────────────────────────────────────────────────

  Future<void> _useAsActive(AgentProfile p) async {
    await widget.connManager.setActiveProfile(widget.connection.id, p.name);
    if (!mounted) return;
    final str = Strings.of(context);
    setState(() {});
    _snack(p.isDefault ? str.prfActivatedDefault : str.prfActivated(p.name));
  }

  /// Edición de la identidad visible del bot (nombre visible, cara, sprite),
  /// la misma pantalla que abre Mission Control. El renombrado del profile
  /// (cambia el nombre real en el servidor) sigue aparte en [_rename].
  Future<void> _editProfile(AgentProfile p) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            ProfileEditorScreen(connection: widget.connection, profile: p),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _rename(AgentProfile p) async {
    final str = Strings.of(context);
    final newName = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _NameEntryScreen(
          title: str.prfRenameDialogTitle,
          initial: p.name,
          taken: _profiles.map((e) => e.name).where((n) => n != p.name).toSet(),
        ),
      ),
    );
    if (newName == null || newName == p.name || !mounted) return;
    try {
      final wasActive = _activeProfile == p.name;
      await _client.renameProfile(p.name, newName);
      if (wasActive) {
        await widget.connManager.setActiveProfile(
          widget.connection.id,
          newName,
        );
      }
      _snack(str.prfRenamedTo(newName));
      await _load();
    } catch (e) {
      _snack(str.prfRenameError(humanizeApiError(e)), ok: false);
    }
  }

  Future<void> _delete(AgentProfile p) async {
    if (widget.connection.readOnly || p.isDefault || p.name == 'default') return;
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    // Acción destructiva en el servidor: App Lock si está activo.
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock != null && lock.enabled) {
      final ok = await LockScreen.verify(
        context,
        lock,
        reason: str.prfDeleteVerifyReason,
      );
      if (!ok || !mounted) return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final s = Strings.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(s.prfDeleteTitle),
          content: Text(
            s.prfDeleteContent(p.name),
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.prfCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                s.prfDeleteConfirm,
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        );
      },
    );
    if (confirm != true || !mounted) return;
    try {
      if (_activeProfile == p.name) {
        await widget.connManager.setActiveProfile(widget.connection.id, '');
      }
      await _client.deleteProfile(p.name);
      _snack(str.prfDeleted(p.name));
      await _load();
    } catch (e) {
      _snack(str.prfDeleteError(humanizeApiError(e)), ok: false);
    }
  }

  Future<void> _openBuilder() async {
    final str = Strings.of(context);
    final created = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ProfileBuilderScreen(
          connection: widget.connection,
          existing: _profiles.map((e) => e.name).toSet(),
        ),
      ),
    );
    if (created == null || !mounted) return;
    // Marcar el recién creado como activo y refrescar.
    await widget.connManager.setActiveProfile(widget.connection.id, created);
    _snack(str.prfCreatedActive(created));
    await _load();
  }

  // ── UI ────────────────────────────────────────────────────────────────

  Widget _wrapWithDock(Widget body) => GeneralDockShell(
    connection: widget.connection,
    connManager: widget.connManager,
    onCreate: _openBuilder,
    body: body,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(str.prfScreenTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: str.prfReload,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      // El dock ya expone "Crear" (ver `onCreate` en `_wrapWithDock`); este
      // FAB solo reaparece cuando el interruptor global "Usar dock flotante"
      // está apagado, para que crear un perfil nunca dependa únicamente del
      // dock (mismo patrón que Cron/Tareas — bug ya confirmado antes).
      floatingActionButton: ListenableBuilder(
        listenable: DockPreferencesController.instance.listenable,
        builder: (context, _) {
          final dock = DockPreferencesController.instance.value;
          if (dock.useDock &&
              dock
                  .profile(DockProfileId.general)
                  .visibleItemIds
                  .contains(DockItemId.create)) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.extended(
            onPressed: _openBuilder,
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
            // El tema global fuerza CircleBorder a los FAB (correcto para los
            // redondos), pero eso recortaba este FAB EXTENDIDO a un círculo
            // dejando sólo el «+». StadiumBorder lo restaura a píldora con
            // icono + etiqueta.
            shape: const StadiumBorder(),
            icon: const Icon(Icons.add),
            label: Text(str.prfNewProfile),
          );
        },
      ),
      body: _wrapWithDock(
        _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _ErrorState(message: _error!, onRetry: _load)
            : RefreshIndicator(
                color: colors.accent,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    for (final p in _profiles)
                      _ProfileCard(
                        profile: p,
                        active:
                            _activeProfile == p.name ||
                            (_activeProfile.isEmpty && p.isDefault),
                        avatarCache: _avatarCache,
                        onUse: () => _useAsActive(p),
                        onEdit: widget.connection.readOnly
                            ? null
                            : () => _editProfile(p),
                        onRename: () => _rename(p),
                        onDelete: p.isDefault ? null : () => _delete(p),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ProfileTonalGroup extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  final Widget child;

  const _ProfileTonalGroup({
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return HermesListSection(
      margin: EdgeInsets.zero,
      showDividers: false,
      children: [Padding(padding: padding, child: child)],
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final AgentProfile profile;
  final bool active;
  final MissionProfileAvatarCache avatarCache;
  final VoidCallback onUse;
  final VoidCallback? onEdit;
  final VoidCallback onRename;
  final VoidCallback? onDelete;

  const _ProfileCard({
    required this.profile,
    required this.active,
    required this.avatarCache,
    required this.onUse,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final details = <String>[
      if (active) str.prfInUse,
      if (profile.isDefault) 'default',
      if (profile.gatewayRunning) 'gateway',
      if (profile.description.isNotEmpty) profile.description,
      if (profile.model.isNotEmpty) profile.model,
      if (profile.provider.isNotEmpty) profile.provider,
      str.prfSkillCount(profile.skillCount),
      if (profile.isDistribution) profile.distributionName!,
    ];

    return HermesListSection(
      margin: const EdgeInsets.only(bottom: 10),
      showDividers: false,
      children: [
        HermesListRow(
          // Antes un icono genérico (account_tree_outlined) para todos los
          // perfiles; ahora la cara/avatar real que cada uno tiene
          // configurado, igual que en Bots — mismo caché, mismo widget.
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              MissionProfileAvatar(
                profileName: profile.name,
                hasAvatar: profile.hasAvatar,
                cache: avatarCache,
                size: 34,
                shape: profile.botShape,
                colorHex: profile.botColorHex,
                imageKind: profile.botImageKind,
              ),
              if (active)
                PositionedDirectional(
                  bottom: -2,
                  end: -2,
                  child: Container(
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_circle,
                      size: 14,
                      color: colors.accentHover,
                    ),
                  ),
                ),
            ],
          ),
          title: profile.name,
          subtitle: details.join(' · '),
          selected: active,
          onTap: active ? null : onUse,
          semanticHint: active ? str.prfInUse : str.prfUseAsActive,
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('profile-edit-bot'),
                icon: Icon(
                  Icons.tune,
                  size: 18,
                  color: onEdit == null
                      ? colors.textDisabled
                      : colors.textSecondary,
                ),
                tooltip: str.prfEditBotTooltip,
                onPressed: onEdit,
              ),
              IconButton(
                icon: Icon(
                  Icons.drive_file_rename_outline,
                  size: 18,
                  color: colors.textSecondary,
                ),
                tooltip: str.prfRenameTooltip,
                onPressed: onRename,
              ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: onDelete == null ? colors.textDisabled : colors.error,
                ),
                tooltip: onDelete == null
                    ? str.prfDeleteDisabledTooltip
                    : str.prfDeleteTooltip,
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: colors.textDisabled,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            HermesSecondaryButton(
              label: Strings.of(context).prfRetry,
              icon: Icons.refresh,
              onTap: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Entrada de nombre (ruta, no diálogo: evita _dependents.isEmpty) ──────────

class _NameEntryScreen extends StatefulWidget {
  final String title;
  final String initial;
  final Set<String> taken;
  const _NameEntryScreen({
    required this.title,
    required this.initial,
    required this.taken,
  });

  @override
  State<_NameEntryScreen> createState() => _NameEntryScreenState();
}

class _NameEntryScreenState extends State<_NameEntryScreen> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  void _releaseFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.hasFocus) f.unfocus();
  }

  String? _validate(String v, Strings str) {
    final s = v.trim();
    if (s.isEmpty) return str.prfNameRequired;
    if (!_profileNameRe.hasMatch(s)) return str.prfNamePatternError;
    if (widget.taken.contains(s)) return str.prfNameTaken;
    return null;
  }

  void _save() {
    final str = Strings.of(context);
    final s = _ctrl.text.trim();
    final err = _validate(s, str);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    _releaseFocus();
    Navigator.of(context).pop(s);
  }

  @override
  void deactivate() {
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _releaseFocus();
            Navigator.pop(context);
          },
        ),
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            HermesField(
              controller: _ctrl,
              autofocus: true,
              label: str.prfNameLabel,
              hint: str.prfNameHint,
              errorText: _error,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_-]')),
              ],
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            Text(
              str.prfNameFormatHint,
              style: TextStyle(fontSize: 12, color: colors.textDisabled),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: Text(str.prfSave)),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Profile Builder — asistente por pasos
// ════════════════════════════════════════════════════════════════════════════

/// Preset de identidad para el primer paso (SOUL inicial sugerido).
class _IdentityPreset {
  final String label;
  final String emoji;
  final String soul;
  const _IdentityPreset(this.label, this.emoji, this.soul);
}

List<_IdentityPreset> _identityPresets(Strings s) => [
  _IdentityPreset(s.prfPresetInherit, '↗', ''),
  _IdentityPreset(s.prfPresetTechnical, '🛠', '''# Identidad

Soy un asistente técnico especializado en programación, infraestructura y
administración de sistemas. Respondo de forma concisa y directa, con código
funcional cuando corresponde.

## Estilo
- Respuestas cortas y precisas; expansión solo si se pide
- Código funcional sobre explicaciones largas
- Señalo problemas sin rodeos
'''),
  _IdentityPreset(s.prfPresetHomelab, '🖥', '''# Identidad

Soy el operador de esta instancia homelab. Gestiono servicios, automatizo
tareas repetitivas y mantengo la infraestructura personal segura y eficiente.

## Comportamiento
- Aviso proactivamente de cambios con impacto en servicios activos
- Rollback plan disponible antes de cambios disruptivos
'''),
  _IdentityPreset(s.prfPresetMinimal, '◦', '''# Identidad

Responde con la menor cantidad de palabras que transmita la información
completa. Sin preámbulos, sin despedidas, sin confirmaciones innecesarias.
'''),
];

class ProfileBuilderScreen extends StatefulWidget {
  final SavedConnection connection;
  final Set<String> existing;
  const ProfileBuilderScreen({
    required this.connection,
    required this.existing,
    super.key,
  });

  @override
  State<ProfileBuilderScreen> createState() => _ProfileBuilderScreenState();
}

class _ProfileBuilderScreenState extends State<ProfileBuilderScreen> {
  late final DashboardClient _client;
  late final TuiGatewayClient _gateway;
  final _pageCtrl = PageController();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _soulCtrl = TextEditingController();

  int _step = 0;
  static const _kSteps = 4;

  int _presetIndex = 0; // 0 = heredar
  bool _cloneFromBase = true;
  String _cloneSource = 'default';

  // Modelo elegido (vacío = heredar).
  String _modelProvider = '';
  String _modelId = '';

  bool _creating = false;
  String _progressMsg = '';

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _gateway = TuiGatewayClient(widget.connection, dashboard: _client);
  }

  @override
  void dispose() {
    unawaited(_gateway.close());
    _client.close();
    _pageCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _soulCtrl.dispose();
    super.dispose();
  }

  String? _nameError() {
    final s = _nameCtrl.text.trim();
    if (s.isEmpty) return null; // no marcar error hasta intentar avanzar
    final str = Strings.of(context);
    if (!_profileNameRe.hasMatch(s)) return str.prfNameInvalid;
    if (widget.existing.contains(s)) return str.prfNameExists;
    return null;
  }

  bool get _nameValid {
    final s = _nameCtrl.text.trim();
    return _profileNameRe.hasMatch(s) && !widget.existing.contains(s);
  }

  void _releaseFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.hasFocus) f.unfocus();
  }

  void _next() {
    _releaseFocus();
    if (_step == 0 && !_nameValid) {
      setState(() {}); // refresca para mostrar error
      return;
    }
    if (_step < _kSteps - 1) {
      setState(() => _step++);
      _pageCtrl.animateToPage(
        _step,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _back() {
    _releaseFocus();
    if (_step > 0) {
      setState(() => _step--);
      _pageCtrl.animateToPage(
        _step,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _pickModel() async {
    _releaseFocus();
    final picked =
        await showHermesFloatingSurface<({String provider, String model})>(
          context: context,
          surfaceKey: const ValueKey('profile-model-picker-surface'),
          maxWidth: 560,
          maxHeightFactor: 0.88,
          builder: (_) =>
              _ModelPickerSheet(client: _client, source: _cloneSource),
        );
    if (picked == null || !mounted) return;
    setState(() {
      _modelProvider = picked.provider;
      _modelId = picked.model;
    });
  }

  // ── Creación ──────────────────────────────────────────────────────────

  Future<void> _create() async {
    _releaseFocus();
    final name = _nameCtrl.text.trim();
    final wantsModel = _modelProvider.isNotEmpty && _modelId.isNotEmpty;

    final str = Strings.of(context);
    setState(() {
      _creating = true;
      _progressMsg = str.prfCreatingMsg;
    });
    try {
      final soul = _soulCtrl.text.trim();
      var nativeProfilesAvailable = false;
      try {
        await _gateway.listProfiles();
        nativeProfilesAvailable = true;
      } catch (_) {
        // Read-only capability probe. A failure here happens before any
        // mutation, so an old Gateway may safely use Dashboard compatibility.
      }

      var createdNatively = false;
      if (nativeProfilesAvailable) {
        try {
          await _gateway.createProfileNative(
            name: name,
            cloneFrom: _cloneFromBase ? _cloneSource : null,
            description: _descCtrl.text.trim(),
            soul: soul,
            model: wantsModel ? _modelId : '',
            provider: wantsModel ? _modelProvider : '',
          );
          createdNatively = true;
        } on TuiGatewayRpcError catch (error) {
          if (error.code != -32601) rethrow;
        }
      }

      if (!createdNatively) {
        await _client.createProfile(
          name: name,
          cloneFrom: _cloneFromBase ? _cloneSource : null,
          description: _descCtrl.text.trim(),
        );
        if (soul.isNotEmpty) {
          setState(() => _progressMsg = str.prfWritingSoulMsg);
          try {
            await _client.setProfileSoul(name, _soulCtrl.text);
          } catch (error) {
            _warn(str.prfSoulWarning('$error'));
          }
        }
        // Legacy model/set can mutate the running default Gateway. Leave the
        // inherited model intact instead of reproducing the Codex/Fable drift.
        if (wantsModel) {
          _warn(
            str.prfModelWarning(
              'profiles.create is unavailable on this Hermes Gateway',
            ),
          );
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(name); // éxito → la lista lo marca activo
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _progressMsg = '';
      });
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).prfCreateError(humanizeApiError(e)),
          ),
        ),
        kind: HermesNoticeKind.error,
      );
    }
  }

  void _warn(String msg) {
    if (mounted) {
      HermesNotice.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        leading: IconButton(
          icon: Icon(_step == 0 ? Icons.close : Icons.arrow_back),
          onPressed: _creating ? null : _back,
        ),
        title: Text(
          Strings.of(context).prfBuilderTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: colors.accentHover,
          ),
        ),
      ),
      body: Column(
        children: [
          _StepProgress(step: _step, total: _kSteps, colors: colors),
          Expanded(
            child: PageView(
              controller: _pageCtrl,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _stepIdentity(colors),
                _stepModel(colors),
                _stepBase(colors),
                _stepSummary(colors),
              ],
            ),
          ),
          _BottomBar(
            step: _step,
            total: _kSteps,
            creating: _creating,
            progressMsg: _progressMsg,
            canNext: _step != 0 || _nameValid,
            onBack: _creating ? null : _back,
            onNext: _step < _kSteps - 1 ? _next : null,
            onCreate: _step == _kSteps - 1 && !_creating ? _create : null,
          ),
        ],
      ),
    );
  }

  // Paso 1 — Identidad
  Widget _stepIdentity(HermesThemeColors colors) {
    final str = Strings.of(context);
    final presets = _identityPresets(str);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _StepTitle(str.prfStep1Title, str.prfStep1Subtitle, colors),
        const SizedBox(height: 16),
        HermesField(
          controller: _nameCtrl,
          label: str.prfNameLabelRequired,
          hint: str.prfNameHint,
          errorText: _nameError(),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_-]')),
          ],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        HermesField(
          controller: _descCtrl,
          label: str.prfDescLabel,
          hint: str.prfDescHint,
        ),
        const SizedBox(height: 20),
        Text(
          str.prfSoulTitle,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          str.prfSoulSubtitle,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int i = 0; i < presets.length; i++)
              _PresetChip(
                preset: presets[i],
                selected: _presetIndex == i,
                colors: colors,
                onTap: () => setState(() {
                  _presetIndex = i;
                  _soulCtrl.text = presets[i].soul;
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        HermesField(
          controller: _soulCtrl,
          label: str.prfSoulLabel,
          hint: str.prfSoulHint,
          maxLines: 8,
          minLines: 4,
        ),
      ],
    );
  }

  // Paso 2 — Modelo
  Widget _stepModel(HermesThemeColors colors) {
    final hasModel = _modelProvider.isNotEmpty && _modelId.isNotEmpty;
    final str = Strings.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _StepTitle(str.prfStep2Title, str.prfStep2Subtitle, colors),
        const SizedBox(height: 16),
        _ProfileTonalGroup(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 18,
                color: hasModel ? colors.textSecondary : colors.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      str.prfInheritBase,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      _cloneFromBase
                          ? str.prfInheritFromClone(_cloneSource)
                          : str.prfInheritDefault,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!hasModel)
                Icon(Icons.check_circle, color: colors.accent, size: 18),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (hasModel)
          _ProfileTonalGroup(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.memory_outlined, size: 18, color: colors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _modelId,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      Text(
                        _modelProvider,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  tooltip: str.prfRemoveModelTooltip,
                  onPressed: () => setState(() {
                    _modelProvider = '';
                    _modelId = '';
                  }),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        HermesSecondaryButton(
          label: hasModel ? str.prfChangeModel : str.prfChooseModel,
          icon: Icons.tune,
          onTap: _pickModel,
        ),
      ],
    );
  }

  // Paso 3 — Base
  Widget _stepBase(HermesThemeColors colors) {
    final str = Strings.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _StepTitle(str.prfStep3Title, str.prfStep3Subtitle, colors),
        const SizedBox(height: 16),
        HermesSwitchTile(
          value: _cloneFromBase,
          onChanged: (v) => setState(() => _cloneFromBase = v),
          contentPadding: EdgeInsets.zero,
          title: str.prfCloneToggle,
          subtitle: str.prfCloneToggleDesc,
        ),
        if (_cloneFromBase) ...[
          const SizedBox(height: 8),
          Text(
            str.prfCloneFrom,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in {'default', ...widget.existing})
                ChoiceChip(
                  label: Text(n, style: const TextStyle(fontSize: 12)),
                  selected: _cloneSource == n,
                  selectedColor: colors.accent.withValues(alpha: 0.2),
                  onSelected: (_) => setState(() => _cloneSource = n),
                ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 8),
          HermesInfoBanner(str.prfNoCloneInfo, icon: Icons.info_outline),
        ],
      ],
    );
  }

  // Paso 4 — Resumen
  Widget _stepSummary(HermesThemeColors colors) {
    final soul = _soulCtrl.text.trim();
    final str = Strings.of(context);
    final presets = _identityPresets(str);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _StepTitle(str.prfStep4Title, str.prfStep4Subtitle, colors),
        const SizedBox(height: 16),
        _SummaryRow(
          str.prfSummaryName,
          _nameCtrl.text.trim(),
          colors,
          mono: true,
        ),
        if (_descCtrl.text.trim().isNotEmpty)
          _SummaryRow(str.prfSummaryDesc, _descCtrl.text.trim(), colors),
        _SummaryRow(
          str.prfSummaryModel,
          (_modelProvider.isNotEmpty && _modelId.isNotEmpty)
              ? '$_modelId · $_modelProvider'
              : str.prfSummaryInheritModel,
          colors,
        ),
        _SummaryRow(
          str.prfSummaryBase,
          _cloneFromBase
              ? str.prfSummaryCloneFrom(_cloneSource)
              : str.prfSummaryCleanBase,
          colors,
        ),
        _SummaryRow(
          str.prfSummarySoul,
          soul.isEmpty
              ? str.prfSummarySoulEmpty
              : str.prfSummarySoulContent(
                  soul.length,
                  presets[_presetIndex].label,
                ),
          colors,
        ),
        const SizedBox(height: 16),
        if (_modelProvider.isNotEmpty && _modelId.isNotEmpty)
          HermesInfoBanner(
            str.prfSummaryWithModel,
            icon: Icons.warning_amber_rounded,
          )
        else
          HermesInfoBanner(str.prfSummaryNoModel, icon: Icons.shield_outlined),
      ],
    );
  }
}

class _StepProgress extends StatelessWidget {
  final int step;
  final int total;
  final HermesThemeColors colors;
  const _StepProgress({
    required this.step,
    required this.total,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          for (int i = 0; i < total; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                height: 4,
                decoration: BoxDecoration(
                  color: i <= step ? colors.accent : colors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (i < total - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final HermesThemeColors colors;
  const _StepTitle(this.title, this.subtitle, this.colors);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  final _IdentityPreset preset;
  final bool selected;
  final HermesThemeColors colors;
  final VoidCallback onTap;
  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.15)
              : colors.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(preset.emoji, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 6),
            Text(
              preset.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? colors.accentHover : colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final HermesThemeColors colors;
  final bool mono;
  const _SummaryRow(this.label, this.value, this.colors, {this.mono = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: colors.textDisabled),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13.5,
                fontFamily: mono ? 'monospace' : null,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int step;
  final int total;
  final bool creating;
  final String progressMsg;
  final bool canNext;
  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final VoidCallback? onCreate;

  const _BottomBar({
    required this.step,
    required this.total,
    required this.creating,
    required this.progressMsg,
    required this.canNext,
    required this.onBack,
    required this.onNext,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final isLast = step == total - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: creating
            ? Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    progressMsg,
                    style: TextStyle(color: colors.textSecondary),
                  ),
                ],
              )
            : Row(
                children: [
                  TextButton(
                    onPressed: onBack,
                    child: Text(
                      step == 0 ? str.prfCancel : str.prfBack,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ),
                  const Spacer(),
                  if (isLast)
                    FilledButton.icon(
                      onPressed: onCreate,
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.accent,
                        foregroundColor: colors.onAccent,
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(str.prfCreate),
                    )
                  else
                    FilledButton(
                      onPressed: canNext ? onNext : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.accent,
                        foregroundColor: colors.onAccent,
                      ),
                      child: Text(str.prfNext),
                    ),
                ],
              ),
      ),
    );
  }
}

// ── Selector de modelo (reutiliza getModelOptions del perfil base) ───────────

class _ModelPickerSheet extends StatefulWidget {
  final DashboardClient client;
  final String source;
  const _ModelPickerSheet({required this.client, required this.source});

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  List<ModelProvider> _providers = [];
  bool _loading = true;
  String? _error;
  bool _onlyAuthed = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.client.getModelOptions(profile: widget.source);
      if (!mounted) return;
      setState(() {
        _providers = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Proveedores con modelos disponibles. Solo los autenticados traen modelos;
  /// los demás necesitan clave/login (se configuran en Modelos).
  List<ModelProvider> get _visible {
    final withModels = _providers.where((p) => p.models.isNotEmpty).toList();
    if (_onlyAuthed) return withModels;
    return _providers;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            str.prfModelsLoadError('$_error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        Row(
          children: [
            Text(
              str.prfPickerTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const Spacer(),
            Text(
              str.prfConnectedOnly,
              style: TextStyle(fontSize: 11, color: colors.textDisabled),
            ),
            Switch(
              value: _onlyAuthed,
              onChanged: (v) => setState(() => _onlyAuthed = v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_visible.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              str.prfNoModelsHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
            ),
          )
        else
          for (final prov in _visible) _providerBlock(prov, colors, str),
      ],
    );
  }

  Widget _providerBlock(
    ModelProvider prov,
    HermesThemeColors colors,
    Strings str,
  ) {
    final hasModels = prov.models.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
          child: Row(
            children: [
              Text(
                prov.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colors.accentHover,
                ),
              ),
              const SizedBox(width: 8),
              if (!prov.authenticated)
                Text(
                  str.prfNotConnected,
                  style: TextStyle(fontSize: 10, color: colors.textDisabled),
                ),
            ],
          ),
        ),
        if (!hasModels)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              str.prfConnectInModels,
              style: TextStyle(fontSize: 11.5, color: colors.textDisabled),
            ),
          )
        else
          for (final m in prov.models)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                Icons.memory_outlined,
                size: 16,
                color: colors.textSecondary,
              ),
              title: Text(m, style: const TextStyle(fontSize: 13)),
              onTap: () =>
                  Navigator.pop(context, (provider: prov.slug, model: m)),
            ),
      ],
    );
  }
}
