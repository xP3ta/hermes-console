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
// - Crear: el mismo formulario que «Nuevo bot» en Modo Bot (un bot es un
//   perfil), ver `profile_flows.dart`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/agent_profile.dart';
import '../models/dock_config.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
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
import 'profile_editor_screen.dart';
import 'profile_flows.dart';

/// Validación del nombre de perfil (debe coincidir con el servidor).
final _profileNameRe = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

class ProfilesScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;

  /// Roster shared with every other screen; [BotRosterRegistry.shared] by
  /// default.
  final BotRosterRegistry? rosterRegistry;
  final DashboardClient? clientOverride;

  /// Stands in for the Gateway's `profiles.list` in tests.
  final Future<List<AgentProfile>> Function()? gatewayProfilesOverride;
  const ProfilesScreen({
    required this.connection,
    required this.connManager,
    this.rosterRegistry,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.gatewayProfilesOverride,
    super.key,
  });

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  late final DashboardClient _client;
  TuiGatewayClient? _gateway;
  late final BotRosterRegistry _roster;
  late final BotRosterStore _store;
  // Mismo caché que usa Mission Control para las mismas caras de bot: cada
  // perfil ya trae su propia identidad visual (foto subida o "Blobatar"
  // procedural), así que la lista no necesita un icono genérico propio.
  late final MissionProfileAvatarCache _avatarCache;
  List<AgentProfile> get _profiles => _store.profiles;
  bool _loading = true;
  String? _error;

  String get _activeProfile =>
      widget.connManager.activeProfileFor(widget.connection.id);

  @override
  void initState() {
    super.initState();
    _client = widget.clientOverride ?? DashboardClient.lazy(widget.connection);
    final gateway = widget.clientOverride == null
        ? TuiGatewayClient(widget.connection, dashboard: _client)
        : null;
    _gateway = gateway;
    _avatarCache = MissionProfileAvatarCache(
      loader: gateway?.profileAvatar ?? (_) async => null,
    );
    _roster = widget.rosterRegistry ?? BotRosterRegistry.shared;
    _roster.hydrate(widget.connection);
    _store = _roster.store(widget.connection.id)..addListener(_onRoster);
    // _load() lee Strings.of(context) (Localizations), que NO puede invocarse
    // durante initState: lanzaría dependOnInheritedWidgetOfExactType y, al estar
    // fuera del try, dejaría _loading=true para siempre (spinner eterno). Se
    // difiere al primer frame, cuando el contexto ya tiene Localizations.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _onRoster() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_onRoster);
    unawaited(_gateway?.close());
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    final str = Strings.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    final ticket = _roster.beginRead(widget.connection.id);
    try {
      List<AgentProfile> list;
      try {
        final gateway = _gateway;
        final override = widget.gatewayProfilesOverride;
        if (override != null) {
          list = await override();
        } else if (gateway == null) {
          throw StateError('no gateway');
        } else {
          list = await gateway.listProfiles();
        }
      } catch (gatewayError) {
        // Safe read-only fallback for Gateways that predate profiles.list.
        try {
          list = await _client.getProfiles();
        } catch (error) {
          // Neither route exists: this server has no roster to show.
          if (BotRosterRegistry.isUnsupportedRead(gatewayError) &&
              BotRosterRegistry.isUnsupportedRead(error)) {
            _roster.unsupported(widget.connection.id, ticket: ticket);
          }
          rethrow;
        }
      }
      // The shared store keeps whichever roster is newest; this screen
      // renders the store, never a late response of its own.
      _roster.publish(
        widget.connection.id,
        widget.connection.label,
        list,
        ticket: ticket,
      );
      if (!mounted) return;
      setState(() => _loading = false);
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
    await ActiveProfileScope.of(
      widget.connManager,
      widget.connection.id,
    ).switchTo(p.name);
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
      _roster.profileRenamed(widget.connection.id, p.name, newName);
      if (wasActive) {
        await ActiveProfileScope.of(
          widget.connManager,
          widget.connection.id,
        ).switchTo(newName);
      }
      _snack(str.prfRenamedTo(newName));
      await _load();
    } catch (e) {
      _snack(str.prfRenameError(humanizeApiError(e)), ok: false);
    }
  }

  Future<void> _delete(AgentProfile p) async {
    if (p.isDefault) return;
    final deleted = await deleteProfileFlow(
      context,
      connection: widget.connection,
      connManager: widget.connManager,
      profile: p.name,
      rosterRegistry: _roster,
      deleteRemote: widget.clientOverride == null
          ? null
          : (name) => _client.deleteProfile(name),
    );
    if (deleted && mounted) await _load();
  }

  /// Same create flow as Bot Mode's "New bot" (a bot is a profile).
  Future<void> _openBuilder() async {
    final str = Strings.of(context);
    final created = await openCreateProfile(
      context,
      connection: widget.connection,
      existing: _profiles.map((e) => e.name).toSet(),
    );
    if (created == null || !mounted) return;
    _roster.profileCreated(widget.connection.id, AgentProfile(name: created));
    // Marcar el recién creado como activo y refrescar.
    await ActiveProfileScope.of(
      widget.connManager,
      widget.connection.id,
    ).switchTo(created);
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
        // The shared (or cached) roster stays visible while it revalidates.
        _loading && _profiles.isEmpty
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
          tooltip: str.commonClose,
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
