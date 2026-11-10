// Perfiles de agente (NOUS Profile Builder, jun-2026).
//
// Cada perfil es un home aislado del agente (~/.hermes/profiles/<name>/) con su
// propio modelo, SOUL, skills, env y cron. El roster y la creación prefieren
// los RPC profile-scoped `profiles.*` que usa Hermes Desktop. La Dashboard API
// queda como compatibilidad para instalaciones antiguas y para operaciones
// administrativas que Hermes aún no publica por RPC.
//
// - Lista con estado real (modelo·proveedor, nº skills, gateway activo).
// - Cada fila muestra la MISMA identidad visual que el resto de la app
//   (`ProfileFace`: personaje del Estudio > foto > mascota > cara) y al
//   tocarla abre el perfil (`ProfileHubScreen`: modelo, skills,
//   integraciones…). Su menú ⋯ lleva la administración del servidor.
// - "Hacer activo": reescala Modelos y Skills a ese perfil.
// - Crear / clonar: el mismo formulario que «Nuevo bot» en Modo Bot (un bot
//   es un perfil), ver `profile_flows.dart`.
//
// Bots = tus bots (modo bot, estado vivo, chat). Esta pantalla es la
// administración del servidor: crear, clonar, renombrar, borrar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../bots/ui/profile/profile_hub_screen.dart';
import '../design/modal.dart' show HermesAction, showHermesMenu;
import '../models/agent_profile.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
import '../services/connection_manager.dart';
import '../services/new_session_factory.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/mission_profile_avatar.dart' show MissionProfileAvatarCache;
import '../widgets/profile_face.dart';
import 'chat_screen.dart';
import 'profile_editor_screen.dart';
import 'profile_flows.dart';
import '../widgets/console_loader.dart';
import '../feedback/feedback_policy.dart';

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

  /// Stands in for the chat route of «Abrir chat» in tests.
  final Future<void> Function(AgentProfile profile)? chatOpenerOverride;
  const ProfilesScreen({
    required this.connection,
    required this.connManager,
    this.rosterRegistry,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.gatewayProfilesOverride,
    @visibleForTesting this.chatOpenerOverride,
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
    return str.prfLoadError(localizedApiError(str, e));
  }

  void _snack(String msg, {bool ok = true}) {
    if (!mounted) return;
    AppFeedback.notify(
      context,
      ok ? FeedbackKind.routine : FeedbackKind.error,
      msg,
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
        builder: (_) => ProfileEditorScreen(
          connection: widget.connection,
          profile: p,
          onChanged: _load,
        ),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  /// The profile's own page (model, skills, integrations…), the same one
  /// Bots and Inicio open.
  Future<void> _openProfile(AgentProfile p) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileHubScreen(
          key: ValueKey('profile-hub-${p.name}'),
          connection: widget.connection,
          connManager: widget.connManager,
          profile: p.name,
          rosterRegistry: _roster,
          onChat: () => unawaited(_openChat(p)),
          onChanged: () => unawaited(_load()),
          onEdited: () => unawaited(_load()),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// A new chat with [p]: it becomes the active profile first, so the
  /// chat, Models and Skills all follow it.
  Future<void> _openChat(AgentProfile p) async {
    await ActiveProfileScope.of(
      widget.connManager,
      widget.connection.id,
    ).switchTo(p.name);
    if (!mounted) return;
    final override = widget.chatOpenerOverride;
    if (override != null) return override(p);
    final session = Session(
      id: generateSessionId(),
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
      profile: p.name,
      isDefaultProfile: p.isDefault,
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  /// «Clonar»: the create flow with [p] as the source to clone from.
  Future<void> _clone(AgentProfile p) async {
    final str = Strings.of(context);
    final created = await openCreateProfile(
      context,
      connection: widget.connection,
      existing: _profiles.map((e) => e.name).toSet(),
      initialCloneFrom: p.name,
    );
    if (created == null || !mounted) return;
    _roster.profileCreated(widget.connection.id, AgentProfile(name: created));
    await ActiveProfileScope.of(
      widget.connManager,
      widget.connection.id,
    ).switchTo(created);
    _snack(str.prfCreatedActive(created));
    await _load();
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
      _snack(str.prfRenameError(localizedApiError(str, e)), ok: false);
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

  Widget _wrapWithDock(Widget Function(double) buildBody) => GeneralDockShell(
    connection: widget.connection,
    connManager: widget.connManager,
    pet: false,
    onCreate: _openBuilder,
    bodyBuilder: (_, bottomClearance) => buildBody(bottomClearance),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(str.pfuManageProfiles),
        // This screen's own way to add a profile is up here, with the dock
        // on, off or hidden (the dock's "+" is a new chat).
        actions: [
          IconButton(
            key: const ValueKey('profiles-new'),
            icon: const Icon(Icons.add_rounded),
            tooltip: str.prfNewProfile,
            onPressed: widget.connection.readOnly ? null : _openBuilder,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: str.prfReload,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _wrapWithDock(
        // The shared (or cached) roster stays visible while it revalidates.
        (bottomClearance) => _loading && _profiles.isEmpty
            ? Padding(
                padding: EdgeInsets.only(bottom: bottomClearance),
                child: const Center(child: ConsoleLoader.large()),
              )
            : _error != null
            ? Padding(
                padding: EdgeInsets.only(bottom: bottomClearance),
                child: _ErrorState(message: _error!, onRetry: _load),
              )
            : RefreshIndicator(
                color: colors.accent,
                onRefresh: _load,
                child: ListView(
                  // Q9-CRISTAL: the roster passes under the glass header.
                  clipBehavior: hermesUnderHeader,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    24 + bottomClearance,
                  ),
                  children: [
                    for (final p in _profiles)
                      _ProfileCard(
                        profile: p,
                        connectionId: widget.connection.id,
                        active:
                            _activeProfile == p.name ||
                            (_activeProfile.isEmpty && p.isDefault),
                        avatarCache: ProfileFace.cacheFor(
                          widget.connection,
                          rosterTicket: _store.ticket,
                          loader: widget.clientOverride == null
                              ? null
                              : (_) async => null,
                        ),
                        onOpen: () => _openProfile(p),
                        onUse: () => _useAsActive(p),
                        onChat: () => _openChat(p),
                        onEdit: widget.connection.readOnly
                            ? null
                            : () => _editProfile(p),
                        onRename: () => _rename(p),
                        onClone: widget.connection.readOnly
                            ? null
                            : () => _clone(p),
                        onDelete: p.isDefault ? null : () => _delete(p),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// What a profile's "more" menu offers.
enum _ProfileAction { edit, makeActive, chat, rename, clone, delete }

class _ProfileCard extends StatelessWidget {
  final AgentProfile profile;
  final String connectionId;
  final bool active;
  final MissionProfileAvatarCache avatarCache;
  final VoidCallback onOpen;
  final VoidCallback onUse;
  final VoidCallback onChat;
  final VoidCallback? onEdit;
  final VoidCallback onRename;
  final VoidCallback? onClone;
  final VoidCallback? onDelete;

  const _ProfileCard({
    required this.profile,
    required this.connectionId,
    required this.active,
    required this.avatarCache,
    required this.onOpen,
    required this.onUse,
    required this.onChat,
    required this.onEdit,
    required this.onRename,
    required this.onClone,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final title = profile.botListName;
    // State first, then what it runs; the free text goes last, where the
    // ellipsis falls. The server's own name shows when the visible one
    // differs, so the row still says which profile it administers.
    final details = <String>[
      if (active) str.prfInUse,
      if (title != profile.name) profile.name,
      if (profile.gatewayRunning) 'gateway',
      if (profile.model.isNotEmpty) profile.model,
      if (profile.provider.isNotEmpty) profile.provider,
      str.prfSkillCount(profile.skillCount),
      if (profile.isDistribution) profile.distributionName!,
      if (profile.description.isNotEmpty) profile.description,
    ];

    return HermesListSection(
      margin: const EdgeInsets.only(bottom: 10),
      showDividers: false,
      children: [
        HermesListRow(
          key: ValueKey('profile-row-${profile.name}'),
          // The face every list of the app draws for this profile: Studio
          // character, photo, mascot or classic face, one resolver.
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              ProfileFace(
                profileName: profile.name,
                profile: profile,
                avatarCache: avatarCache,
                connectionId: connectionId,
                active: active,
                size: 40,
              ),
              if (active)
                PositionedDirectional(
                  bottom: -2,
                  end: -2,
                  child: Container(
                    key: ValueKey('profile-active-check-${profile.name}'),
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
          title: title,
          titleMaxLines: 1,
          subtitle: details.join(' · '),
          selected: active,
          onTap: onOpen,
          semanticHint: str.pfuOpenHint,
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          // One control at the end of the row, like every other list of
          // Ajustes: what was three buttons is its menu.
          trailing: Builder(
            builder: (anchor) => IconButton(
              key: ValueKey('profile-more-${profile.name}'),
              icon: Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: colors.textSecondary,
              ),
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              onPressed: () => _showMore(anchor, str),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showMore(BuildContext anchor, Strings str) async {
    final action = await showHermesMenu<_ProfileAction>(
      context: anchor,
      surfaceKey: const ValueKey('profile-more-menu'),
      actions: [
        if (onEdit != null)
          HermesAction(
            key: const ValueKey('profile-edit-bot'),
            value: _ProfileAction.edit,
            icon: Icons.tune,
            label: str.prfEditBotTooltip,
          ),
        if (!active)
          HermesAction(
            key: const ValueKey('profile-make-active'),
            value: _ProfileAction.makeActive,
            icon: Icons.check_circle_outline,
            label: str.pfuMakeActive,
          ),
        HermesAction(
          key: const ValueKey('profile-open-chat'),
          value: _ProfileAction.chat,
          icon: Icons.chat_bubble_outline_rounded,
          label: str.pfuOpenChat,
        ),
        HermesAction(
          key: const ValueKey('profile-rename'),
          value: _ProfileAction.rename,
          icon: Icons.drive_file_rename_outline,
          label: str.prfRenameTooltip,
        ),
        if (onClone != null)
          HermesAction(
            key: const ValueKey('profile-clone'),
            value: _ProfileAction.clone,
            icon: Icons.copy_all_outlined,
            label: str.pfuClone,
          ),
        if (onDelete != null)
          HermesAction(
            key: const ValueKey('profile-delete'),
            value: _ProfileAction.delete,
            icon: Icons.delete_outline,
            label: str.prfDeleteTooltip,
            destructive: true,
          ),
      ],
    );
    switch (action) {
      case _ProfileAction.edit:
        onEdit?.call();
      case _ProfileAction.makeActive:
        onUse();
      case _ProfileAction.chat:
        onChat();
      case _ProfileAction.rename:
        onRename();
      case _ProfileAction.clone:
        onClone?.call();
      case _ProfileAction.delete:
        onDelete?.call();
      case null:
        break;
    }
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
          clipBehavior: hermesUnderHeader,
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
              style: TextStyle(fontSize: 12, color: colors.textTertiary),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: Text(str.prfSave)),
          ],
        ),
      ),
    );
  }
}
