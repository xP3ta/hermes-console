import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesInlineNotice,
        HermesModelGroup,
        HermesOption,
        HermesSelectRow,
        HermesStatusText,
        HermesStatusTone,
        HermesToggleRow,
        showHermesDialog,
        showHermesModelPicker,
        showHermesOptions;
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/profile_scope.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/read_only.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart'
    as premium
    show HermesListRow, HermesListSection;
import '../widgets/provider_logo.dart';

import '../models/desktop_model_catalog.dart';
import '../models/fallback_chain.dart';
import '../models/free_tier_status.dart';
import '../models/model_identity.dart';
import '../models/oauth_account.dart';
import '../models/provider_exclusions.dart';
import '../models/provider_key_groups.dart';
import '../services/custom_endpoints_api.dart';
import '../services/local_models_client.dart';
import '../services/model_catalog_cache.dart';
import '../services/model_picker_loader.dart';
import '../services/models_snapshot.dart';
import '../services/free_tier_status.dart';
import '../services/shared_gateway_pool.dart';
import '../services/tui_gateway_client.dart';
import 'chat_screen.dart' show friendlyModelName;
import 'custom_endpoints_section.dart';
import 'local_models_screen.dart';
import 'moa_recipe_screen.dart';
import 'model_visibility_screen.dart';
import 'models_accounts_section.dart';
import 'models_api_keys_section.dart';
import 'models_fallback_section.dart';
import 'models_look.dart';
import 'models_write.dart';
import '../widgets/console_loader.dart';
import '../feedback/feedback_policy.dart';

/// Models and providers of a profile. What it offers is what Desktop's
/// Settings → Model and → Providers offer; the page itself is the app's own:
/// the active model card, the fallback chain, "Models by function", one
/// group per connected provider with its models, then what is connected,
/// what is still to set up, local models and custom endpoints.
class ModelsScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Official Dashboard transport and cached gateway catalog test seams.
  @visibleForTesting
  final DashboardClient? dashboardClientForTesting;
  @visibleForTesting
  final DesktopModelCatalog? Function()? gatewayCatalogForTesting;
  @visibleForTesting
  final HermesDesktopFreeTierGateway? freeTierGatewayForTesting;

  /// HTTP client for the endpoint form's phone-side probe, which only runs
  /// for an instance on this phone ([InstanceKind.localhost]).
  @visibleForTesting
  final http.Client? probeClientForTesting;

  /// Active profile source; defaults to the app's for [connection].
  final ActiveProfileScope? profileScope;

  const ModelsScreen({
    required this.connection,
    this.dashboardClientForTesting,
    this.gatewayCatalogForTesting,
    this.freeTierGatewayForTesting,
    this.probeClientForTesting,
    this.profileScope,
    this.snapshotCache,
    this.snapshotPrewarm,
    this.chatCatalogsForTesting,
    super.key,
  });

  /// The chat model picker's own caches (the app's by default): a provider
  /// removed here must not be offered from them.
  @visibleForTesting
  final ({ModelPickerCache picker, ModelCatalogCache catalog})?
  chatCatalogsForTesting;

  /// Last-read catalog per connection/profile. Defaults to the app-wide cache;
  /// a screen built with a testing client gets its own unless one is passed.
  final ModelsSnapshotCache? snapshotCache;
  final ModelsSnapshotPrewarm? snapshotPrewarm;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

/// Desktop's label of a built-in auxiliary task; null for a plugin task,
/// which the server labels itself.
String? _auxLabel(String key, Strings s) => switch (key) {
  'vision' => s.mdlVision,
  'compression' => s.mdlCompression,
  'skills_hub' => s.mdlSkillsHub,
  'approval' => s.mdlApproval,
  'mcp' => s.mdlMcp,
  'title_generation' => s.mdlTitleGeneration,
  'review' => s.mdlReview,
  'voice_chat' => s.mdlVoiceChat,
  'triage_specifier' => s.mdlTriageSpecifier,
  'kanban_decomposer' => s.mdlKanbanDecomposer,
  'profile_describer' => s.mdlProfileDescriber,
  'curator' => s.mdlCurator,
  _ => null,
};

/// Hermes' reasoning levels in ascending order, after "off".
const _reasoningEfforts = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra',
];

class _ModelsScreenState extends State<ModelsScreen>
    with ActiveProfileFollower<ModelsScreen> {
  late final DashboardClient _client;
  ModelActiveInfo? _activeInfo;
  List<ModelProvider> _providers = [];

  /// Accounts of the profile (`GET /api/providers/oauth`); null until the
  /// server (or a kept answer) has said.
  List<OAuthAccount>? _accounts;
  List<Map<String, dynamic>> _auxTasks = [];
  String? _auxError;
  FreeTierStatus? _freeTierStatus;
  SharedGatewayLease? _freeTierLease;
  bool _loading = true;

  /// The catalog could not be read and nothing of this profile is on screen.
  String? _error;

  /// What is on screen is the last answer: the refresh behind it failed.
  bool _stale = false;
  bool _setting = false;
  int _catalogGeneration = 0;

  /// Bumped to make the custom endpoints section reload its list.
  int _endpointsReload = 0;

  /// Models (`provider/model`) the user took out of the pickers on this
  /// device ("Edit models"), and the providers older versions of the app let
  /// them hide the same way. A provider is removed on the server now; one
  /// still hidden here is offered back with the providers to set up. The
  /// chat picker reads the same two preferences.
  Set<String> _hidden = {};
  Set<String> _hiddenModels = {};

  /// The providers the profile leaves out of its catalog
  /// (`model_catalog.excluded_providers`), as the server last returned it;
  /// null until it has answered (or a kept snapshot painted it).
  List<String>? _excluded;

  /// Names of the providers the server has listed here, for one that is no
  /// longer in its catalog.
  final Map<String, String> _seenNames = {};
  static const _kHiddenProviders = 'hidden_providers';
  static const _kHiddenModels = 'hidden_models';

  /// Key of the last accounts answer kept on disk, per connection and
  /// profile, so the accounts stay listed when the Dashboard cannot be read.
  String _accountsCacheKey(String profile) =>
      'models_catalog_cache_${jsonEncode([widget.connection.id, profile])}';

  /// Active profile (empty = default). Scopes every call with ?profile=.
  String get _profile => scopedProfileName;

  /// Capability of the Hermes-managed llama.cpp runtime
  /// (`GET /api/local-models/status`): null = checking, otherwise the probe
  /// outcome. 404 ⇒ the server has no local-models routes.
  _LocalModelsProbe? _localProbe;

  /// Desktop's "Run locally" offer: the catalog model the server's hardware
  /// fits while local models are not set up there. Read on open, never
  /// polled; null hides the row.
  LocalCatalogModel? _localSetupFit;
  bool _started = false;

  /// The profile's `fallback_providers`, as the server last returned it;
  /// null until it has answered (or a kept snapshot painted it).
  List<FallbackEntry>? _fallback;
  String? _fallbackError;

  /// The profile's model defaults (`agent.reasoning_effort`,
  /// `agent.service_tier`), from the same config read as the chain.
  Map<String, dynamic>? _agentDefaults;
  int _fallbackGeneration = 0;
  int _writeGeneration = 0;

  late final ModelsSnapshotCache _snapshots =
      widget.snapshotCache ??
      (widget.dashboardClientForTesting == null
          ? ModelsSnapshotCache.shared
          : ModelsSnapshotCache());
  late final ModelsSnapshotPrewarm? _prewarm =
      widget.snapshotPrewarm ??
      (widget.dashboardClientForTesting == null
          ? ModelsSnapshotPrewarm.shared
          : null);

  /// Profile whose server answer (fresh or cached) is on screen.
  String? _shownOwner;

  /// Paints a complete read exactly as the live path would.
  void _applySnapshot(ModelsSnapshot snapshot, String owner) {
    _activeInfo = snapshot.active ?? _mainFromAuxiliary(snapshot.auxiliary);
    _providers = snapshot.providers;
    for (final provider in snapshot.providers) {
      if (provider.name.isNotEmpty) {
        _seenNames[provider.slug.toLowerCase()] = provider.name;
      }
    }
    _accounts = snapshot.accounts ?? _accounts;
    _applyAuxiliary(snapshot.auxiliary, snapshot.auxError);
    _fallback = snapshot.fallback ?? _fallback;
    _agentDefaults = snapshot.agentDefaults ?? _agentDefaults;
    _excluded = snapshot.excluded ?? _excluded;
    if (snapshot.keyGroups case final groups? when _keyGroups == null) {
      _keyGroups = groups;
      _keyGroupsOwner = owner;
    }
    if (snapshot.endpoints case final rows?) {
      _endpoints = rows;
      _endpointsOwner = owner;
    }
  }

  /// The custom endpoints the server last listed for [_endpointsOwner]: what
  /// their section paints first on a reopen.
  List<CustomEndpoint>? _endpoints;
  String? _endpointsOwner;

  /// A kept answer is on screen while the server is asked again.
  bool _revalidating = false;

  @override
  void initState() {
    super.initState();
    _client =
        widget.dashboardClientForTesting ??
        DashboardClient.lazy(widget.connection);
    _loadHidden();
    followActiveProfile(
      widget.profileScope ??
          appActiveProfileScope(context, widget.connection.id),
    );
    // didChangeDependencies starts official profile-scoped reads only.
  }

  Future<void> _loadHidden() async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList(_kHiddenProviders) ?? const [];
    final models = prefs.getStringList(_kHiddenModels) ?? const [];
    if (!mounted) return;
    setState(() {
      _hidden = providers.toSet();
      _hiddenModels = models.toSet();
    });
  }

  void _setHiddenModels(Set<String> models) {
    setState(() => _hiddenModels = models);
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kHiddenModels, models.toList());
    }());
  }

  void _setHiddenProviders(Set<String> providers) {
    setState(() => _hidden = providers);
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kHiddenProviders, providers.toList());
    }());
  }

  /// "Edit models": the models of the providers on the page.
  Future<void> _openVisibility() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ModelVisibilityScreen(
        providers: [
          for (final provider in _listedProviders)
            if (provider.models.isNotEmpty) provider,
        ],
        hiddenModels: _hiddenModels,
        onChanged: _setHiddenModels,
      ),
    ),
  );

  /// Refresh official APIs without probing or provisioning optional services.
  Future<void> _bootstrap() async {
    unawaited(_probeLocalModels());
    await _load();
  }

  LocalModelsClient get _localModels =>
      LocalModelsClient(_client, profile: _profile);

  Future<void> _probeLocalModels() async {
    final ticket = profileReadTicket();
    _LocalModelsProbe probe;
    LocalCatalogModel? fit;
    try {
      final status = await _localModels.status();
      probe = _LocalModelsProbe.available(status.models.length);
      fit = await _readLocalSetupFit(status);
    } on LocalModelsUnavailable {
      probe = const _LocalModelsProbe.unavailable();
    } catch (_) {
      probe = const _LocalModelsProbe.failed();
    }
    if (mounted && ticket.isCurrent) {
      setState(() {
        _localProbe = probe;
        _localSetupFit = fit;
      });
    }
  }

  /// The catalog is only read when the server is not set up yet: a set-up
  /// server never qualifies, so it costs no extra request.
  Future<LocalCatalogModel?> _readLocalSetupFit(
    LocalModelsStatus status,
  ) async {
    if (status.runtimeInstalled && status.models.isNotEmpty) return null;
    try {
      return pickLocalSetupFit(status, await _localModels.catalog());
    } catch (_) {
      return null;
    }
  }

  Future<void> _openLocalModels() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LocalModelsScreen(
          connection: widget.connection,
          profile: _profile,
          client: _localModels,
        ),
      ),
    );
    if (!mounted) return;
    // Activation changes the default model; re-read it and the entry.
    unawaited(_probeLocalModels());
    unawaited(_reload());
  }

  @override
  void onActiveProfileChanged() {
    // A switch re-scopes the whole screen (behind the loader): model,
    // catalog, assignments, accounts, keys and the local models entry.
    _activeInfo = null;
    _providers = [];
    _accounts = null;
    _auxTasks = [];
    _auxError = null;
    _keyGroups = null;
    _keyGroupsOwner = null;
    _endpoints = null;
    _endpointsOwner = null;
    _dropSnapshotIfWriting();
    _setting = false;
    unawaited(_probeLocalModels());
    unawaited(_loadFreeTierStatus());
    _writeGeneration++;
    _fallbackGeneration++;
    _fallback = null;
    _fallbackError = null;
    _agentDefaults = null;
    _excluded = null;
    _shownOwner = null;
    _revalidating = false;
    if (_started) unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _bootstrap();
      unawaited(_loadFreeTierStatus());
    }
  }

  HermesDesktopFreeTierGateway? _freeTierGateway() {
    final testing = widget.freeTierGatewayForTesting;
    if (testing != null) return testing;
    _freeTierLease ??= SharedGatewayPool.instance.acquireIfConnected(
      widget.connection,
    );
    return _freeTierLease?.client;
  }

  Future<void> _loadFreeTierStatus() async {
    final ticket = profileReadTicket();
    final gateway = _freeTierGateway();
    if (gateway == null) {
      if (mounted && ticket.isCurrent) setState(() => _freeTierStatus = null);
      return;
    }
    try {
      final status = await FreeTierStatusReader(
        gateway: gateway,
        profile: ticket.name,
      ).load();
      if (mounted && ticket.isCurrent) {
        setState(() => _freeTierStatus = status);
      }
    } catch (_) {}
  }

  Future<void> _ackFreeTierNotice() async {
    final ticket = profileReadTicket();
    final gateway = _freeTierGateway();
    if (gateway == null) return;
    final status = await FreeTierStatusReader(
      gateway: gateway,
      profile: ticket.name,
    ).acknowledgeAndReload();
    if (mounted && ticket.isCurrent) {
      setState(() => _freeTierStatus = status);
    }
  }

  Future<void> _signInFromFreeTierNotice() async {
    await _ackFreeTierNotice();
    if (!mounted) return;
    await _signIn('Nous', 'nous');
  }

  /// The chain the server returned (a read, or the re-read after a write of
  /// the fallback section) is what the screen and the kept snapshot show.
  void _showFallback(List<FallbackEntry> chain, String owner) {
    _fallbackGeneration++;
    setState(() {
      _fallback = chain;
      _fallbackError = null;
    });
    _snapshots.amend(
      widget.connection,
      owner,
      (snapshot) => snapshot.copyWith(fallback: chain),
    );
  }

  static Map<String, dynamic> _agentDefaultsOf(Map<String, dynamic> config) {
    final agent = config['agent'];
    return {
      if (agent is Map) ...{
        'reasoning_effort': agent['reasoning_effort'],
        'service_tier': agent['service_tier'],
      },
    };
  }

  void _showAgentDefaults(Map<String, dynamic> defaults, String owner) {
    setState(() => _agentDefaults = defaults);
    _snapshots.amend(
      widget.connection,
      owner,
      (snapshot) => snapshot.copyWith(agentDefaults: defaults),
    );
  }

  /// The exclusion list the server returned (a read, or the re-read after it
  /// was changed here) is what the screen and the kept snapshot show.
  void _showExcluded(List<String> excluded, String owner) {
    _fallbackGeneration++;
    setState(() => _excluded = excluded);
    _snapshots.amend(
      widget.connection,
      owner,
      (snapshot) => snapshot.copyWith(excluded: excluded),
    );
  }

  /// One `GET /api/config` for what this screen reads from it: the fallback
  /// chain, the model defaults and the providers left out of the catalog.
  Future<void> _loadConfig() async {
    final ticket = profileReadTicket();
    final generation = ++_fallbackGeneration;
    try {
      final config = await _client.getServerConfig(profile: ticket.name);
      if (!mounted || !ticket.isCurrent || generation != _fallbackGeneration) {
        return;
      }
      _showFallback(fallbackChainOfConfigAnswer(config), ticket.owner);
      _showAgentDefaults(_agentDefaultsOf(config), ticket.owner);
      _showExcluded(excludedProvidersOfConfigAnswer(config), ticket.owner);
    } catch (error) {
      if (!mounted || !ticket.isCurrent || generation != _fallbackGeneration) {
        return;
      }
      setState(
        () => _fallbackError = localizedApiError(Strings.of(context), error),
      );
    }
  }

  @override
  void dispose() {
    _dropSnapshotIfWriting();
    _freeTierLease?.release();
    _client.close();
    super.dispose();
  }

  /// Leaving (or switching profile) while a change is still being written:
  /// its reload will never land here, so the pre-change snapshot must not
  /// answer the next open.
  void _dropSnapshotIfWriting() {
    final owner = _shownOwner;
    if (!_setting || owner == null) return;
    _snapshots.remove(widget.connection, owner);
    _prewarm?.discard(widget.connection, owner);
  }

  Future<void> _saveAccountsCache(
    String profile,
    List<OAuthAccount> accounts,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _accountsCacheKey(profile),
        jsonEncode({
          'accounts': [for (final account in accounts) account.toJson()],
        }),
      );
    } catch (_) {
      // Best effort: only a later failed read depends on it.
    }
  }

  Future<List<OAuthAccount>?> _readAccountsCache(String profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_accountsCacheKey(profile));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['accounts'] is! List) return null;
      return OAuthAccount.listFromJson(decoded['accounts']);
    } catch (_) {
      return null;
    }
  }

  void _applyAuxiliary(Map<String, dynamic>? aux, Object? auxError) {
    _auxError = auxError == null
        ? null
        : localizedApiError(Strings.of(context), auxError);
    if (aux != null) {
      _auxTasks = ((aux['tasks'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
  }

  static ModelActiveInfo? _mainFromAuxiliary(Map<String, dynamic>? aux) {
    final main = aux?['main'];
    if (main is! Map) return null;
    final model = main['model'];
    final provider = main['provider'];
    if (model is! String || model.trim().isEmpty) return null;
    return ModelActiveInfo(
      model: model.trim(),
      provider: provider is String ? provider.trim() : '',
      effectiveContextLength: 0,
    );
  }

  /// Provider keys from `GET /api/env` (Desktop Providers settings), read on
  /// their own so a slow or failed model inventory never hides them. Null
  /// until the server (or a kept answer) has said; empty when the route is
  /// unavailable.
  List<ProviderKeyGroup>? _keyGroups;
  String? _keyGroupsOwner;
  int _keyGroupsGeneration = 0;

  /// The key list the server returned is what the screen and the kept
  /// snapshot show.
  void _showKeyGroups(List<ProviderKeyGroup> groups, String owner) {
    _keyGroupsGeneration++;
    setState(() {
      _keyGroups = groups;
      _keyGroupsOwner = owner;
    });
    _snapshots.amend(
      widget.connection,
      owner,
      (snapshot) => snapshot.copyWith(keyGroups: groups),
    );
  }

  Future<void> _loadProviderKeys() async {
    final generation = ++_keyGroupsGeneration;
    final ticket = profileReadTicket();
    // Another profile's keys are retired at once, not when (or if) the new
    // profile's answer arrives.
    if (_keyGroupsOwner != ticket.owner && _keyGroups != null) {
      setState(() => _keyGroups = null);
    }
    _keyGroupsOwner = ticket.owner;
    List<ProviderKeyGroup> groups;
    try {
      groups = providerKeyGroupsFromEnv(
        await _client.getEnvVars(profile: ticket.name),
      );
    } catch (_) {
      // Keep what is on screen for this profile; there is nothing newer.
      return;
    }
    if (!mounted || !ticket.isCurrent || generation != _keyGroupsGeneration) {
      return;
    }
    _showKeyGroups(groups, ticket.owner);
  }

  /// Re-reads after a change. Neither the last catalog nor a read Home
  /// issued before the change may answer it, and the pre-change snapshot is
  /// dropped so a later open cannot show it as current (Desktop invalidates
  /// its model queries on every mutation). What is on screen stays there
  /// while the server answers.
  Future<void> _reload() {
    final owner = profileReadTicket().owner;
    _snapshots.remove(widget.connection, owner);
    _prewarm?.discard(widget.connection, owner);
    _forChatCatalogs(owner, (picker, catalog, key, profile) {
      // Desktop invalidates the model options its chat picker shares on
      // every change made in settings; the chat's caches are told the same.
      picker.invalidate(key);
      catalog.invalidate(widget.connection.id, profile);
    });
    return _load(fresh: true);
  }

  /// The chat model picker keeps its own copy of the catalog, per connection
  /// and profile, and paints it before (for a minute, instead of) asking the
  /// server. [change] is applied to this profile's copies.
  void _forChatCatalogs(
    String owner,
    void Function(
      ModelPickerCache picker,
      ModelCatalogCache catalog,
      String key,
      String profile,
    )
    change,
  ) {
    final caches =
        widget.chatCatalogsForTesting ??
        switch (context.findAncestorStateOfType<HermesAppState>()) {
          final app? => (
            picker: app.activeChats.modelPickerCache,
            catalog: app.activeChats.modelCatalogCache,
          ),
          null => null,
        };
    if (caches == null) return;
    // A chat names the default profile `default`, or nothing before it is
    // bound to one.
    for (final profile in {owner, if (owner == 'default') ''}) {
      change(
        caches.picker,
        caches.catalog,
        ModelPickerCache.key(widget.connection.id, profile),
        profile,
      );
    }
  }

  Future<void> _load({bool fresh = false}) async {
    unawaited(_loadProviderKeys());
    final generation = ++_catalogGeneration;
    final ticket = profileReadTicket();
    // Like Desktop's query cache: this profile's content stays on screen
    // while the server is asked again, and the first paint for a profile
    // shows its last answer at once. Only a profile with nothing to show
    // waits on the loader.
    final shown = _shownOwner == ticket.owner;
    final seeded = fresh || shown
        ? null
        : _snapshots.read(widget.connection, ticket.owner);
    setState(() {
      _loading = !shown && seeded == null;
      _error = null;
      _stale = false;
      if (seeded != null) {
        _applySnapshot(seeded, ticket.owner);
        _shownOwner = ticket.owner;
      }
      _revalidating = shown || seeded != null;
    });
    unawaited(_markModelsOpened());

    if (!ticket.isCurrent || generation != _catalogGeneration) return;
    unawaited(_loadConfig());
    bool current() =>
        mounted && ticket.isCurrent && generation == _catalogGeneration;
    // A background read Home started for this profile is the fresh answer.
    final warm = !shown && seeded == null && !fresh
        ? _prewarm?.claim(widget.connection, ticket.owner)
        : null;
    if (warm != null) {
      try {
        final snapshot = await warm;
        if (!current()) return;
        _showRead(snapshot, ticket.owner);
        return;
      } catch (_) {
        // Read it again below.
      }
      if (!current()) return;
    }
    try {
      ModelActiveInfo? active;
      List<ModelProvider> providers = [];
      Map<String, dynamic>? aux;
      Object? auxError;
      List<OAuthAccount>? accounts;
      Object? accountsError;
      Object? optionsError;
      // Degrade per call like Desktop's model settings (Promise.allSettled):
      // `/api/model/info` probes the configured provider for its context
      // length and can hang or fail; that must not take the inventory, the
      // auxiliary assignments or the accounts down with it. Only the
      // inventory itself remains required here.
      await Future.wait([
        _client
            .getModelInfo(profile: ticket.name)
            .then<void>((v) => active = v)
            .catchError((Object _) {}),
        _client
            .getModelOptions(profile: ticket.name)
            .then<void>((v) => providers = v)
            .catchError((Object error) {
              optionsError = error;
            }),
        _client
            .getAuxiliaryModels(profile: ticket.name)
            .then<void>((v) {
              if (v['tasks'] is! List) {
                throw const FormatException('Invalid auxiliary response');
              }
              aux = v;
            })
            .catchError((Object error) {
              auxError = error;
            }),
        _client
            .getOAuthProviders(profile: ticket.name)
            .then<void>((v) => accounts = OAuthAccount.listFromJson(v))
            .catchError((Object error) {
              accountsError = error;
            }),
      ]);
      // The previous profile's model never lands on the new one.
      if (!current()) return;
      // The main assignment also lives in the auxiliary config read, so the
      // page still knows the current model when only the live probe failed
      // (Desktop `modelInfo ?? auxiliaryModels?.main`).
      active ??= _mainFromAuxiliary(aux);
      if (optionsError != null) {
        // The inventory failed: the sources that answered (main model,
        // auxiliary assignments, accounts) stay on screen, like Desktop
        // keeps them beside the catalog error.
        setState(() {
          _activeInfo =
              active ?? (shown || seeded != null ? _activeInfo : null);
          _applyAuxiliary(aux, auxError);
          _accounts = accounts ?? _accounts;
        });
        throw optionsError!;
      }
      _showRead(
        ModelsSnapshot(
          active: active,
          providers: providers,
          auxiliary: aux,
          auxError: auxError,
          accounts: accounts,
          accountsError: accountsError,
        ),
        ticket.owner,
      );
    } catch (e) {
      if (!current()) return;
      if (shown || seeded != null) {
        // The refresh failed behind the last answer: keep it on screen and
        // say it could not be refreshed, instead of trading it for an error.
        setState(() {
          _stale = true;
          _revalidating = false;
        });
        return;
      }
      final cached = _accounts == null
          ? await _readAccountsCache(ticket.owner)
          : null;
      if (!mounted || !current()) return;
      final message = localizedApiError(Strings.of(context), e);
      setState(() {
        _accounts ??= cached;
        _error = message;
        _loading = false;
      });
    }
  }

  /// A complete answer of the server for [owner]: on screen, and kept for
  /// the next open together with the sections that answered on their own.
  void _showRead(ModelsSnapshot snapshot, String owner) {
    // Connected in the last answer for this profile and not in this one: the
    // chat picker's own copy must stop listing them now, not when it next
    // asks the server.
    final gone = {
      if (_shownOwner == owner)
        for (final before in _providers)
          if (before.authenticated &&
              !snapshot.providers.any(
                (now) => now.authenticated && now.slug == before.slug,
              ))
            before.slug,
    };
    if (gone.isNotEmpty) {
      _forChatCatalogs(owner, (picker, catalog, key, profile) {
        picker.retireProviders(key, gone);
        catalog.invalidate(widget.connection.id, profile);
      });
    }
    setState(() {
      _applySnapshot(snapshot, owner);
      _shownOwner = owner;
      _loading = false;
      _revalidating = false;
    });
    _snapshots.write(
      widget.connection,
      owner,
      snapshot.copyWith(
        fallback: _fallback,
        agentDefaults: _agentDefaults,
        keyGroups: _keyGroupsOwner == owner ? _keyGroups : null,
        endpoints: _endpointsOwner == owner ? _endpoints : null,
        excluded: _excluded,
      ),
    );
    if (snapshot.accounts case final accounts?) {
      unawaited(_saveAccountsCache(owner, accounts));
    }
  }

  Future<void> _markModelsOpened() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await ModelsSnapshotPrewarm.markOpened(prefs, widget.connection.id);
    } catch (_) {
      // Only the next app start's background read depends on it.
    }
  }

  // ── Catalog on screen ───────────────────────────────────────────────────

  /// Gateway catalog the chat already cached for this connection/profile
  /// (`model.options` with `aliases`). Read-only; never triggers I/O.
  DesktopModelCatalog? _gatewayCatalog() {
    final testing = widget.gatewayCatalogForTesting;
    if (testing != null) return testing();
    final app = context.findAncestorStateOfType<HermesAppState>();
    return app?.activeChats.modelCatalogCache.read(
      widget.connection.id,
      _profile,
    );
  }

  /// Catalog row of the configured default, matched like Desktop
  /// (slug → name → alias, then the cached gateway catalog).
  ModelProvider? _activeProvider(ModelActiveInfo info) =>
      findActiveModelProvider(
        _providers,
        info.provider,
        catalog: _gatewayCatalog(),
      );

  ModelProvider? _providerRow(String provider) {
    final wanted = provider.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    for (final row in _providers) {
      if (row.slug.toLowerCase() == wanted || row.aliases.contains(wanted)) {
        return row;
      }
    }
    return null;
  }

  /// Display name of a provider id, from the catalog on screen.
  String _providerName(String provider) {
    final row = _providerRow(provider);
    return row == null || row.name.isEmpty ? provider : row.name;
  }

  /// The providers of the profile: connected on the server and not taken
  /// out on this device. The page lists them, its pickers and "Edit models"
  /// offer them, and nothing else is offered anywhere.
  List<ModelProvider> get _readyProviders => [
    for (final provider in _providers)
      if (provider.authenticated && !_hidden.contains(provider.slug)) provider,
  ];

  List<String> _shownModels(ModelProvider provider) => [
    for (final model in provider.models)
      if (!_hiddenModels.contains('${provider.slug}/$model')) model,
  ];

  // ── Writes ──────────────────────────────────────────────────────────────

  /// Write authority captured when an action starts. It stays valid only
  /// while the screen still shows the same connection and that connection is
  /// still writable, so a connection turned read-only or swapped while a key
  /// page or a confirmation is open never receives the queued write.
  /// (Rebuilt copies of the same writable connection keep it.)
  bool Function() _credentialWriteLease() {
    final connectionId = widget.connection.id;
    final writable = !widget.connection.readOnly;
    final generation = _connectionAuthorityGeneration;
    return () =>
        mounted &&
        writable &&
        generation == _connectionAuthorityGeneration &&
        widget.connection.id == connectionId &&
        !widget.connection.readOnly;
  }

  /// Bumped whenever the shown connection changes identity or write access,
  /// so a write revoked and later restored (writable → read-only → writable)
  /// stays retired: only a new action started afterwards may write.
  int _connectionAuthorityGeneration = 0;

  @override
  void didUpdateWidget(covariant ModelsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection.id != widget.connection.id ||
        oldWidget.connection.readOnly != widget.connection.readOnly) {
      _connectionAuthorityGeneration++;
    }
  }

  /// Starts a change for the profile on screen. Refused on a read-only
  /// connection; otherwise the profile and the write authority are captured
  /// now, before any confirmation or picker.
  ModelsWrite? _beginWrite() {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return null;
    }
    return _ScreenWrite(this, profileReadTicket(), _credentialWriteLease());
  }

  Future<bool> _runWrite(
    _ScreenWrite write,
    Future<void> Function() body,
  ) async {
    final ticket = write._ticket;
    if (!mounted || !ticket.isCurrent) return false;
    if (!write._authorized()) {
      if (widget.connection.readOnly) showReadOnlyNotice(context);
      return false;
    }
    final generation = ++_writeGeneration;
    bool current() => write.isCurrent && generation == _writeGeneration;
    setState(() => _setting = true);
    try {
      await DashboardClient.guardedWrite(
        () => ticket.isCurrent && write._authorized(),
        body,
      );
      return current();
    } on DashboardWriteRevoked {
      return false;
    } catch (error) {
      if (mounted && current()) {
        final s = Strings.of(context);
        AppFeedback.of(context).notify(
          FeedbackKind.error,
          s.commonError(localizedApiError(s, error)),
        );
      }
      return false;
    } finally {
      // A newer write owns the busy state; a profile switch already reset it.
      if (mounted && ticket.isCurrent && generation == _writeGeneration) {
        setState(() => _setting = false);
      }
    }
  }

  Future<bool> _confirm(
    String title, {
    required String action,
    String? message,
    bool destructive = true,
  }) async {
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: title,
      message: message,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: action,
          value: true,
          style: destructive
              ? HermesDialogActionStyle.destructive
              : HermesDialogActionStyle.primary,
        ),
      ],
    );
    return confirmed == true;
  }

  /// `POST /api/model/set` for one slot. The server may ask for an explicit
  /// acknowledgement of the model first (Desktop `setMainModelAssignment`);
  /// it is asked once and the assignment resent. Nothing is reported as
  /// applied unless the server answered `ok`.
  Future<void> _assign(
    ModelsWrite write, {
    required String provider,
    required String model,
    String scope = 'main',
    String task = '',
  }) async {
    final s = Strings.of(context);
    final baseUrl = _providerRow(provider)?.baseUrl ?? '';
    String? question;
    Future<void> send({required bool acknowledged}) async {
      final answer = await _client.assignModel(
        providerSlug: provider,
        modelId: model,
        scope: scope,
        task: task,
        baseUrl: baseUrl,
        profile: write.profile,
        confirmExpensiveModel: acknowledged,
      );
      if (!acknowledged && answer['confirm_required'] == true) {
        question = (answer['confirm_message'] ?? '').toString().trim();
        return;
      }
      if (answer['ok'] != true) throw StateError(s.mdlApplyModelError);
      await _reload();
    }

    final sent = await write.run(() => send(acknowledged: false));
    final ask = question;
    if (!sent || ask == null || !mounted) return;
    final accepted = await _confirm(
      s.mdlConfirmModelTitle(model),
      message: ask.isEmpty ? null : ask,
      action: s.mdlConfirmModelUse,
      destructive: false,
    );
    if (!accepted || !mounted || !write.isCurrent) return;
    await write.run(() => send(acknowledged: true));
  }

  /// One profile default of the main model (`agent.<key>`), as a sparse
  /// patch like Desktop's `writeAgentDefault`; the row then shows what the
  /// server kept.
  Future<void> _setAgentDefault(String key, String value) async {
    final write = _beginWrite();
    if (write == null) return;
    final s = Strings.of(context);
    final owner = profileReadTicket().owner;
    await write.run(() async {
      final answer = await _client.putServerConfigPatch({
        'agent': {key: value},
      }, profile: write.profile);
      final defaults = _agentDefaultsOf(
        await _client.getServerConfig(profile: write.profile),
      );
      if (write.isCurrent) _showAgentDefaults(defaults, owner);
      if (answer['ok'] != true || defaults[key] != value) {
        throw StateError(s.mdlNotSaved);
      }
    });
  }

  Future<void> _pickReasoning(String current) async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<String>(
      context: context,
      title: s.mdlRowReasoning,
      selected: current,
      options: [
        for (final value in _reasoningEfforts)
          HermesOption(
            key: ValueKey('models-reasoning-$value'),
            value: value,
            label: _effortLabel(value, s),
          ),
      ],
    );
    if (picked == null || picked == current || !mounted) return;
    await _setAgentDefault('reasoning_effort', picked);
  }

  Future<void> _pickSpeed(String current, {required bool fast}) async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<String>(
      context: context,
      title: s.mdlRowSpeed,
      selected: current,
      options: [
        HermesOption(value: 'normal', label: s.mdlSpeedStandard),
        if (fast) HermesOption(value: 'fast', label: s.mdlSpeedFast),
        HermesOption(value: 'ultrafast', label: s.mdlSpeedUltrafast),
      ],
    );
    if (picked == null || picked == current || !mounted) return;
    await _setAgentDefault('service_tier', picked);
  }

  static String _effortLabel(String value, Strings s) => switch (value) {
    'none' => s.mdlReasoningOff,
    'minimal' => s.mdlEffortMinimal,
    'low' => s.mdlEffortLow,
    'medium' => s.mdlEffortMedium,
    'high' => s.mdlEffortHigh,
    'xhigh' => s.mdlEffortXhigh,
    'max' => s.mdlEffortMax,
    'ultra' => s.mdlEffortUltra,
    _ => value,
  };

  /// The shared floating model picker for a provider + model, or automatic.
  Future<({String provider, String model})?> _pickModel({
    required String title,
    bool allowAuto = true,
  }) async {
    final ticket = profileReadTicket();
    final s = Strings.of(context);
    final picked = await showHermesModelPicker(
      context: context,
      surfaceKey: const ValueKey('models-picker-surface'),
      keyPrefix: 'models-picker',
      title: title,
      defaultLabel: allowAuto ? s.mdlAutomatic : null,
      groups: [
        for (final provider in _readyProviders)
          if (_shownModels(provider) case final models when models.isNotEmpty)
            HermesModelGroup(
              slug: provider.slug,
              name: provider.name,
              models: models,
              unavailableModels: provider.unavailableModels,
            ),
      ],
    );
    if (picked == null || !mounted || !ticket.isCurrent) return null;
    if (picked.isDefault) return (provider: 'auto', model: '');
    return (provider: picked.provider, model: picked.model);
  }

  Future<void> _pickAuxModel(String task, String label) async {
    final write = _beginWrite();
    if (write == null) return;
    final picked = await _pickModel(title: label);
    if (picked == null || !mounted || !write.isCurrent) return;
    await _assign(
      write,
      provider: picked.provider,
      model: picked.model,
      scope: 'auxiliary',
      task: task,
    );
  }

  Future<void> _resetAux() async {
    final write = _beginWrite();
    if (write == null) return;
    final s = Strings.of(context);
    if (!await _confirm(s.mdlAuxResetTitle, action: s.mdlAuxResetAll)) return;
    if (!mounted || !write.isCurrent) return;
    await write.run(() async {
      final ok = await _client.resetAuxiliaryModels(profile: write.profile);
      if (!ok) throw StateError(s.mdlApplyModelError);
      await _reload();
    });
  }

  Future<void> _setVoiceReasoning(
    Map<String, dynamic> task,
    String effort,
  ) async {
    if (_setting || widget.connection.readOnly) return;
    final ticket = profileReadTicket();
    // Join the approved base's model-write lease, not a separate busy owner.
    final generation = ++_writeGeneration;
    bool current() =>
        mounted && ticket.isCurrent && generation == _writeGeneration;
    setState(() => _setting = true);
    try {
      final accepted = await _client.setActiveModel(
        providerSlug: (task['provider'] as String?) ?? 'auto',
        modelId: (task['model'] as String?) ?? '',
        scope: 'auxiliary',
        task: 'voice_chat',
        profile: ticket.name,
        updateReasoningEffort: true,
        // null is upstream's explicit inherit; omission preserves the slot.
        reasoningEffort: effort.isEmpty ? null : effort,
      );
      if (!mounted || !current()) return;
      if (!accepted) throw StateError('Auxiliary assignment rejected');
      await _reload();
    } catch (error) {
      if (!mounted || !current()) return;
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        localizedApiError(Strings.of(context), error),
      );
    } finally {
      if (mounted && current()) setState(() => _setting = false);
    }
  }

  // ── Accounts ────────────────────────────────────────────────────────────

  Future<List<OAuthAccount>> _readAccounts(ModelsWrite write) async {
    final accounts = OAuthAccount.listFromJson(
      await _client.getOAuthProviders(profile: write.profile),
    );
    if (write.isCurrent) {
      setState(() => _accounts = accounts);
      final owner = profileReadTicket().owner;
      _snapshots.amend(
        widget.connection,
        owner,
        (snapshot) => snapshot.copyWith(accounts: accounts),
      );
      unawaited(_saveAccountsCache(owner, accounts));
    }
    return accounts;
  }

  /// Device-code sign-in of [id]: starts the flow, opens the verification
  /// page and polls until the provider confirms. "Connected" is only what
  /// the server's account list says afterwards.
  Future<void> _signIn(String name, String id) async {
    final write = _beginWrite();
    if (write == null) return;
    Map<String, dynamic>? start;
    final started = await write.run(() async {
      start = await _client.startOAuth(id, profile: write.profile);
    });
    final data = start;
    if (!started || data == null || !mounted) return;
    final sessionId = providerOAuthStartField(data, const [
      'session_id',
      'session',
      'poll_id',
      'device_code',
      'state',
    ]);
    final url = normalizeProviderOAuthBrowserUrl(
      providerOAuthStartField(data, const [
        'verification_uri_complete',
        'verification_url_complete',
        'auth_url',
        'authorization_url',
        'login_url',
        'verification_url',
        'verification_uri',
        'url',
      ]),
      connection: widget.connection,
      dashboardBaseUrl: _client.baseUrl,
    );
    if (sessionId.isEmpty || url.isEmpty) {
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        Strings.of(context).mdlOAuthNotAvailable(name),
        warning: true,
      );
      return;
    }
    final approved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ProviderOAuthLoginScreen(
          providerName: name,
          providerSlug: id,
          url: url,
          code: providerOAuthStartField(data, const ['user_code', 'code']),
          expiresIn: (data['expires_in'] as num?)?.toInt() ?? 0,
          poll: () => _client.pollOAuth(id, sessionId, profile: write.profile),
        ),
      ),
    );
    if (approved != true || !mounted || !write.isCurrent) return;
    var connected = false;
    final read = await write.run(() async {
      final accounts = await _readAccounts(write);
      connected = accounts.any((a) => a.id == id && a.signedIn);
      await _reload();
    });
    if (!read || !mounted) return;
    unawaited(_loadFreeTierStatus());
    final s = Strings.of(context);
    AppFeedback.of(context).notify(
      connected ? FeedbackKind.routine : FeedbackKind.error,
      connected ? s.mdlProviderConnected(name) : s.mdlAccountNotConnected(name),
    );
  }

  Future<void> _disconnectAccount(OAuthAccount account) async {
    // The account of a connected provider is that provider's connection:
    // signing it out is removing the provider, wherever it is asked from.
    final provider = _providerOfAccount(account);
    if (provider != null) return _removeProvider(provider);
    final write = _beginWrite();
    if (write == null) return;
    final s = Strings.of(context);
    final confirmed = await _confirm(
      s.mdlRemoveNamed(account.name),
      action: s.mdlRemove,
    );
    // A confirmation opened for one profile is never replayed on another.
    if (!confirmed || !mounted || !write.isCurrent) return;
    var removed = false;
    final done = await write.run(() async {
      await _client.disconnectOAuth(account.id, profile: write.profile);
      final accounts = await _readAccounts(write);
      removed = !accounts.any((a) => a.id == account.id && a.signedIn);
      await _reload();
    });
    if (!done || !mounted) return;
    AppFeedback.of(context).notify(
      removed ? FeedbackKind.routine : FeedbackKind.error,
      removed
          ? s.mdlProviderDisconnected(account.name)
          : s.mdlAccountStillConnected(account.name),
    );
  }

  // ── API keys ────────────────────────────────────────────────────────────

  Future<List<ProviderKeyGroup>> _readKeyGroups(ModelsWrite write) async {
    final groups = providerKeyGroupsFromEnv(
      await _client.getEnvVars(profile: write.profile),
    );
    if (write.isCurrent) _showKeyGroups(groups, profileReadTicket().owner);
    return groups;
  }

  /// The key page of a provider. The key belongs to the profile and
  /// connection whose row was tapped: a profile switch or a revoked/replaced
  /// connection while the page is open voids the save instead of writing it
  /// elsewhere.
  Future<void> _enterProviderKey(ProviderKeyGroup group) async {
    final write = _beginWrite();
    if (write == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ProviderKeyScreen(
          providerName: group.name,
          onSave: (key) => _saveProviderKey(write, group, key),
        ),
      ),
    );
    if (saved != true || !mounted || !write.isCurrent) return;
    AppFeedback.of(context).notify(
      FeedbackKind.routine,
      Strings.of(context).mdlProviderKeySaved(group.name),
    );
    // The provider's models come with the key: re-read the catalog behind.
    unawaited(_reload());
  }

  /// Stores [key] for [group] and answers with what the server says: its own
  /// check of the key where it has one, then whether the key is set.
  Future<({ProviderKeyOutcome outcome, String? reason})> _saveProviderKey(
    ModelsWrite write,
    ProviderKeyGroup group,
    String key,
  ) async {
    final s = Strings.of(context);
    String? reason;
    final done = await write.run(() async {
      Map<String, dynamic>? verdict;
      try {
        verdict = await _client.validateProviderKey(
          group.keyEnv,
          key,
          profile: write.profile,
        );
      } on DashboardWriteRevoked {
        rethrow;
      } catch (_) {
        // No verdict (older server, no check for this provider): the key is
        // stored and the row says only that it is set.
      }
      if (verdict != null &&
          verdict['ok'] == false &&
          verdict['reachable'] == true) {
        reason = s.mdlKeyRejected;
        return;
      }
      final accepted = await _client.setEnvVar(
        group.keyEnv,
        key,
        profile: write.profile,
      );
      final groups = await _readKeyGroups(write);
      final stored = groups.any(
        (g) => g.keyEnv == group.keyEnv && g.primarySet,
      );
      if (!accepted || !stored) reason = s.mdlKeyNotSaved;
    });
    if (!write.isCurrent) {
      return (outcome: ProviderKeyOutcome.voided, reason: null);
    }
    if (!done || reason != null) {
      // A failed request is not a stored key either.
      return (
        outcome: ProviderKeyOutcome.refused,
        reason: reason ?? s.mdlKeyNotSaved,
      );
    }
    return (outcome: ProviderKeyOutcome.saved, reason: null);
  }

  Future<void> _removeProviderKey(ProviderKeyGroup group) async {
    // The key of a connected provider is that provider's connection:
    // removing it is removing the provider, wherever it is asked from.
    final provider = _providerOfKey(group);
    if (provider != null) return _removeProvider(provider);
    final write = _beginWrite();
    if (write == null) return;
    final s = Strings.of(context);
    final confirmed = await _confirm(
      s.mdlKeyRemoveTitle(group.name),
      action: s.mdlRemove,
    );
    // A confirmation opened for one profile is never replayed on another.
    if (!confirmed || !mounted || !write.isCurrent) return;
    var removed = false;
    final done = await write.run(() async {
      // Every key variable of the card: any of them keeps it connected.
      for (final variable
          in group.setKeys.isEmpty ? [group.keyEnv] : group.setKeys) {
        await _client.deleteEnvVar(variable, profile: write.profile);
      }
      final groups = await _readKeyGroups(write);
      removed = !groups.any((g) => g.keyEnv == group.keyEnv && g.isSet);
      await _reload();
    });
    if (!done || !mounted) return;
    AppFeedback.of(context).notify(
      removed ? FeedbackKind.routine : FeedbackKind.error,
      removed ? s.mdlProviderDisconnected(group.name) : s.mdlKeyNotRemoved,
    );
  }

  // ── Removing a provider ─────────────────────────────────────────────────

  /// Whether an id written in the profile's config means [provider].
  bool _names(String id, ModelProvider provider) {
    final wanted = id.trim().toLowerCase();
    if (wanted.isEmpty || wanted == 'auto' || wanted == 'main') return false;
    return provider.slug.toLowerCase() == wanted ||
        modelProviderMatches(provider, wanted) ||
        findActiveModelProvider(
              _providers,
              wanted,
              catalog: _gatewayCatalog(),
            )?.slug ==
            provider.slug;
  }

  /// The profile runs on [provider]: its main model, a fallback or a task of
  /// "Models by function" is assigned to it.
  bool _inUse(ModelProvider provider) =>
      provider.isCurrent ||
      _names(_activeInfo?.provider ?? '', provider) ||
      (_fallback ?? const <FallbackEntry>[]).any(
        (entry) => _names('${entry['provider'] ?? ''}', provider),
      ) ||
      _auxTasks.any((task) => _names('${task['provider'] ?? ''}', provider));

  /// A provider in use is not removed: one sentence says what to do first.
  /// (Desktop lets it happen and leaves the profile on a provider that no
  /// longer answers.) True when it was refused.
  bool _refuseInUse(ModelProvider provider, String name) {
    if (!_inUse(provider)) return false;
    AppFeedback.of(context).notify(
      FeedbackKind.error,
      Strings.of(context).mdlProviderInUse(name),
      warning: true,
      noticeKey: const ValueKey('models-provider-in-use'),
    );
    return true;
  }

  /// The provider on the page a key card connects, if any.
  ModelProvider? _providerOfKey(ProviderKeyGroup group) {
    for (final provider in _readyProviders) {
      if (_keyOf(provider)?.keyEnv == group.keyEnv) return provider;
    }
    return null;
  }

  /// The provider on the page an account connects, if any.
  ModelProvider? _providerOfAccount(OAuthAccount account) {
    for (final provider in _readyProviders) {
      if (_accountOf(provider)?.id == account.id) return provider;
    }
    return null;
  }

  /// The saved endpoint behind a row the user wrote, when the server lists
  /// one it can delete (Desktop offers no delete for an address written
  /// straight into the main model either).
  CustomEndpoint? _endpointOf(ModelProvider provider) {
    if (!provider.isUserDefined && provider.baseUrl.isEmpty) return null;
    if (_endpointsOwner != profileReadTicket().owner) return null;
    final slug = provider.slug.toLowerCase();
    for (final endpoint in _endpoints ?? const <CustomEndpoint>[]) {
      if (endpoint.source == 'direct-config') continue;
      final id = endpoint.id.toLowerCase();
      if (id == slug || 'custom:$id' == slug || provider.aliases.contains(id)) {
        return endpoint;
      }
    }
    return null;
  }

  /// Whether "Remove" has anything to act on. The local runtime and Mixture
  /// of Agents are not providers that were connected, and an address written
  /// straight into the config has no entry to delete.
  bool _removable(ModelProvider provider) =>
      provider.excludable || _endpointOf(provider) != null;

  /// Reads the profile's exclusion list, applies [change] to it and stores
  /// that one list; the screen then shows what the server kept. True when
  /// the server holds the list that was asked for.
  Future<bool> _writeExcluded(
    ModelsWrite write,
    String owner,
    List<String> Function(List<String> list) change,
  ) async {
    final before = excludedProvidersOfConfigAnswer(
      await _client.getServerConfig(profile: write.profile),
    );
    final next = change(before);
    Map<String, dynamic>? answer;
    if (!listEquals(next, before)) {
      answer = await _client.putServerConfigPatch(
        excludedProvidersPatch(next),
        profile: write.profile,
      );
    }
    final after = excludedProvidersOfConfigAnswer(
      await _client.getServerConfig(profile: write.profile),
    );
    if (write.isCurrent) _showExcluded(after, owner);
    return (answer == null || answer['ok'] == true) && listEquals(after, next);
  }

  /// "Remove" of a connected provider. What Hermes holds for it is cleared:
  /// its key, its account, or the endpoint the user wrote. If the server
  /// still lists it afterwards, what connects it belongs to another program
  /// there (the GitHub or Claude Code login) and is not Hermes' to delete,
  /// so the provider goes on the profile's exclusion list instead. Either
  /// way one action takes it out of every model list, here and in Desktop.
  Future<void> _removeProvider(ModelProvider provider) async {
    final write = _beginWrite();
    if (write == null) return;
    final s = Strings.of(context);
    final name = provider.name.isEmpty ? provider.slug : provider.name;
    if (_refuseInUse(provider, name)) return;
    final endpoint = _endpointOf(provider);
    final key = endpoint == null ? _keyOf(provider) : null;
    final signedIn = endpoint == null ? _accountOf(provider) : null;
    final account = signedIn != null && signedIn.disconnectable
        ? signedIn
        : null;
    final owner = profileReadTicket().owner;
    final confirmed = await _confirm(
      s.mdlRemoveNamed(name),
      action: s.mdlRemove,
      // Only an endpoint the user wrote is gone for good: a key can be typed
      // again and an excluded provider is offered back on this page.
      message: endpoint == null ? null : s.mdlRemoveEndpointPermanent,
    );
    // A confirmation opened for one profile is never replayed on another.
    if (!confirmed || !mounted || !write.isCurrent) return;
    var removed = false;
    final done = await write.run(() async {
      try {
        if (endpoint != null) {
          await _client.deleteCustomEndpoint(
            endpoint.id,
            profile: write.profile,
          );
          if (mounted) setState(() => _endpointsReload++);
        } else {
          for (final variable in key?.setKeys ?? const <String>[]) {
            await _client.deleteEnvVar(variable, profile: write.profile);
          }
          if (account != null) {
            await _client.disconnectOAuth(account.id, profile: write.profile);
          }
          final cleared = key != null || account != null;
          if (provider.excludable &&
              (!cleared || await _stillConnected(provider, write))) {
            final kept = await _writeExcluded(
              write,
              owner,
              (list) => withProviderExcluded(list, provider.slug),
            );
            if (!kept) throw StateError(s.mdlNotSaved);
          }
        }
      } finally {
        // Whatever was cleared, the page shows what the server holds now.
        if (mounted && write.isCurrent) await _reload();
      }
      removed =
          !_stale &&
          !_providers.any(
            (row) => row.authenticated && row.slug == provider.slug,
          );
    });
    if (!done || !mounted) return;
    AppFeedback.of(context).notify(
      removed ? FeedbackKind.routine : FeedbackKind.error,
      removed ? s.mdlProviderRemoved(name) : s.mdlProviderNotRemoved(name),
    );
  }

  /// The server still lists [provider] as connected.
  Future<bool> _stillConnected(
    ModelProvider provider,
    ModelsWrite write,
  ) async {
    final rows = await _client.getModelOptions(profile: write.profile);
    return rows.any((row) => row.authenticated && row.slug == provider.slug);
  }

  /// Puts back a provider that was taken out: off the profile's exclusion
  /// list or, for one hidden by an older version of the app, off this
  /// device's own list.
  Future<void> _restoreProvider(String slug, {required bool onDevice}) async {
    if (onDevice) {
      _setHiddenProviders({..._hidden}..remove(slug));
      return;
    }
    final write = _beginWrite();
    if (write == null) return;
    final s = Strings.of(context);
    final owner = profileReadTicket().owner;
    var restored = false;
    final done = await write.run(() async {
      try {
        restored = await _writeExcluded(
          write,
          owner,
          (list) => withProviderIncluded(list, slug),
        );
      } finally {
        if (mounted && write.isCurrent) await _reload();
      }
    });
    if (!done || !mounted || restored) return;
    AppFeedback.of(context).notify(FeedbackKind.error, s.mdlNotSaved);
  }

  /// Display name of a provider that is not in the catalog on screen.
  String _nameOfAbsent(String slug) {
    final id = slug.toLowerCase();
    final seen = _seenNames[id];
    if (seen != null) return seen;
    for (final account in _accounts ?? const <OAuthAccount>[]) {
      if (account.id.toLowerCase() == id) return account.name;
    }
    for (final group in _keyGroups ?? const <ProviderKeyGroup>[]) {
      if (group.slug.toLowerCase() == id) return group.name;
    }
    final brand = resolveProviderLogo(provider: slug);
    return brand.id == 'monogram' ? slug : brand.label;
  }

  // ── Page ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        // States which profile this model belongs to.
        title: Text(s.mdlTitle),
        titleBadge: ProfileScopeLabel.badgeFor(
          profile: _profile,
          connectionId: widget.connection.id,
        ),
        actions: [
          if (_setting)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _bootstrap,
              tooltip: s.mdlReload,
            ),
        ],
      ),
      body: RefreshIndicator(
        color: colors.accentHover,
        onRefresh: () {
          setState(() => _endpointsReload++);
          return _load(fresh: true);
        },
        child: ListView(
          clipBehavior: hermesUnderHeader,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: _blocks(s, colors),
        ),
      ),
    );
  }

  /// [_readyProviders] in the order of the page: the current one first.
  List<ModelProvider> get _listedProviders => _readyProviders
    ..sort((a, b) {
      if (a.isCurrent && !b.isCurrent) return -1;
      if (!a.isCurrent && b.isCurrent) return 1;
      return a.name.compareTo(b.name);
    });

  /// The set key of [provider], if the server lists one for it.
  ProviderKeyGroup? _keyOf(ModelProvider provider) {
    final slug = provider.slug.toLowerCase();
    for (final group in _keyGroups ?? const <ProviderKeyGroup>[]) {
      if (!group.isSet) continue;
      if (group.slug.toLowerCase() == slug ||
          (provider.keyEnv.isNotEmpty && provider.keyEnv == group.keyEnv)) {
        return group;
      }
    }
    return null;
  }

  /// The signed-in account of [provider], if the server lists one for it.
  OAuthAccount? _accountOf(ModelProvider provider) {
    final slug = provider.slug.toLowerCase();
    for (final account in _accounts ?? const <OAuthAccount>[]) {
      if (!account.signedIn) continue;
      final id = account.id.toLowerCase();
      if (id == slug || id == '$slug-oauth') return account;
    }
    return null;
  }

  /// The providers that are not connected: accounts with an in-app sign-in,
  /// providers without their key, catalog providers that name the key they
  /// need, and those that were taken out, each with the one action that
  /// connects it (again).
  List<_SetupRow> get _unconfigured {
    final excluded = _excluded ?? const <String>[];
    bool out(String slug) =>
        slug.isNotEmpty && excludesProvider(excluded, slug);
    final rows = <_SetupRow>[
      for (final slug in excluded)
        (
          name: _nameOfAbsent(slug),
          account: null,
          key: null,
          restore: slug,
          onDevice: false,
        ),
      for (final provider in _providers)
        if (provider.authenticated && _hidden.contains(provider.slug))
          (
            name: provider.name.isEmpty ? provider.slug : provider.name,
            account: null,
            key: null,
            restore: provider.slug,
            onDevice: true,
          ),
      for (final account in _accounts ?? const <OAuthAccount>[])
        if (!account.signedIn && account.canSignInHere && !out(account.id))
          (
            name: account.name,
            account: account,
            key: null,
            restore: null,
            onDevice: false,
          ),
      for (final group in _keyGroups ?? const <ProviderKeyGroup>[])
        if (!group.isSet && !out(group.slug))
          (
            name: group.name,
            account: null,
            key: group,
            restore: null,
            onDevice: false,
          ),
    ];
    final keys = {
      for (final row in rows)
        if (row.key != null) row.key!.keyEnv,
    };
    for (final provider in _providers) {
      if (provider.authenticated ||
          provider.keyEnv.isEmpty ||
          out(provider.slug) ||
          !keys.add(provider.keyEnv)) {
        continue;
      }
      rows.add((
        name: provider.name,
        account: null,
        key: ProviderKeyGroup(
          slug: provider.slug,
          name: provider.name,
          keyEnv: provider.keyEnv,
          isSet: false,
        ),
        restore: null,
        onDevice: false,
      ));
    }
    return rows..sort((a, b) => a.name.compareTo(b.name));
  }

  List<Widget> _blocks(Strings s, HermesThemeColors colors) {
    final owner = profileReadTicket().owner;
    final busy = _setting;
    final active = _activeInfo;
    final accounts = _accounts;
    final keyGroups = _keyGroups;
    final fallback = _fallback;
    final listed = _loading ? const <ModelProvider>[] : _listedProviders;
    final unconfigured = _unconfigured;
    return [
      // The last answer is on screen; say it is being refreshed.
      if (_revalidating)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: LinearProgressIndicator(
            key: ValueKey('mdl-revalidating'),
            minHeight: 2,
          ),
        ),
      if (_loading)
        const SizedBox(
          height: 160,
          child: Center(child: ConsoleLoader.large()),
        ),
      if (_error != null || _stale) _buildLoadFailedCard(s, colors),
      if (_freeTierStatus?.shouldShowNotice == true)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: HermesNoticeCard(
            noticeKey: const ValueKey('models-free-tier-notice'),
            message: s.mdlFreeTierNotice(_freeTierStatus!.label),
            action: HermesNoticeAction(
              label: s.mdlFreeTierSignIn,
              onPressed: () => unawaited(_signInFromFreeTierNotice()),
            ),
            showDismiss: true,
            dismissLabel: s.mdlFreeTierDismiss,
            onDismissed: () => unawaited(_ackFreeTierNotice()),
          ),
        ),
      if (_localSetupFit case final fit? when !_loading)
        _buildLocalSetupOffer(s, colors, fit),
      // "ACTIVE MODEL" only when a connected provider is behind it; a server
      // without any gets the "no model" card instead.
      if (!_loading && active != null && _shouldShowActiveCard(active))
        if (_shownOwner != owner || _activeModelUsable(active)) ...[
          _buildActiveCard(s, colors, active),
          ..._buildDefaults(s, active, busy),
        ] else if (!_providers.any((p) => p.authenticated))
          _buildNoActiveModelCard(s, colors),
      // The blocks that keep something open (a group, a problem) carry a
      // key: a notice appearing above them must not close them.
      if (fallback != null)
        Padding(
          key: ValueKey('models-fallback-block-$owner'),
          padding: const EdgeInsets.only(bottom: 8),
          child: ModelsFallbackSection(
            // Keyed by profile: a problem shown for one profile's chain
            // never stays on screen for another's.
            key: ValueKey('models-fallbacks-$owner'),
            dashboard: _client,
            chain: fallback,
            enabled: !busy,
            beginWrite: _beginWrite,
            pickModel: (title) => _pickModel(title: title, allowAuto: false),
            providerName: _providerName,
            onChain: (chain) => _showFallback(chain, owner),
          ),
        )
      else if (_fallbackError != null)
        _problem(
          '${s.mdlSectionFallbacks}: $_fallbackError',
          key: const ValueKey('models-fallback-error'),
        ),
      if (_auxError != null)
        _problem(
          '${s.mdlAuxSection}: $_auxError',
          key: const ValueKey('models-aux-error'),
        ),
      if (_auxTasks.isNotEmpty)
        Column(
          key: ValueKey('models-aux-block-$owner'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildAuxSection(s, colors, busy),
        ),
      if (listed.isNotEmpty) ...[
        ModelsSectionLabel(s.mdlMainProviders),
        premium.HermesListSection(
          key: ValueKey('models-providers-$owner'),
          margin: const EdgeInsets.only(bottom: 8),
          children: [
            for (final provider in listed)
              _buildProviderTile(s, colors, provider, busy),
            premium.HermesListRow(
              key: const ValueKey('models-edit-models'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              icon: Icons.visibility_outlined,
              title: s.mdlEditModels,
              trailing: Icon(
                Icons.chevron_right,
                size: 18,
                color: colors.textDisabled,
              ),
              onTap: _openVisibility,
            ),
          ],
        ),
      ],
      if (accounts != null)
        ModelsAccountsSection(
          accounts: accounts,
          enabled: !busy,
          onSignIn: (account) => _signIn(account.name, account.id),
          onDisconnect: _disconnectAccount,
        ),
      if (keyGroups != null)
        ModelsApiKeysSection(
          groups: keyGroups,
          enabled: !busy,
          onEnter: _enterProviderKey,
          onRemove: _removeProviderKey,
        ),
      if (unconfigured.isNotEmpty)
        KeyedSubtree(
          key: ValueKey('models-unconfigured-block-$owner'),
          child: _buildUnconfiguredSection(s, colors, unconfigured, busy),
        ),
      _buildLocalModelsEntry(s, colors),
      CustomEndpointsSection(
        key: const ValueKey('models-endpoints'),
        connection: widget.connection,
        dashboard: _client,
        profile: _profile,
        profileScope:
            widget.profileScope ??
            appActiveProfileScope(context, widget.connection.id),
        // A missing inventory cannot vouch for the endpoints route.
        requireSupported: _shownOwner != owner,
        reloadToken: _endpointsReload,
        seed: _endpointsOwner == owner ? _endpoints : null,
        onLoaded: (rows) {
          _endpoints = rows;
          _endpointsOwner = owner;
          _snapshots.amend(
            widget.connection,
            owner,
            (snapshot) => snapshot.copyWith(endpoints: rows),
          );
        },
        onChanged: () {
          if (mounted) _reload();
        },
        inUse: (endpoint) {
          for (final provider in _providers) {
            if (_endpointOf(provider)?.id == endpoint.id) {
              return _inUse(provider);
            }
          }
          return endpoint.isCurrent;
        },
        probeClientForTesting: widget.probeClientForTesting,
      ),
    ];
  }

  Widget _problem(String sentence, {Key? key}) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: HermesStatusText(
      key: key,
      label: sentence,
      tone: HermesStatusTone.error,
      maxLines: 3,
    ),
  );

  /// The catalog could not be read (or refreshed): one sentence and Retry.
  Widget _buildLoadFailedCard(Strings s, HermesThemeColors colors) => Card(
    key: const ValueKey('models-load-failed'),
    margin: const EdgeInsets.only(bottom: 8),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: colors.warning.withValues(alpha: 0.45), width: 1),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: colors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.mdlLoadError,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: _loading ? null : _bootstrap,
            child: Text(
              s.mdlRetry,
              style: TextStyle(fontSize: 12, color: colors.accentHover),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildLocalSetupOffer(
    Strings s,
    HermesThemeColors colors,
    LocalCatalogModel fit,
  ) => ModelsTonalGroup(
    margin: const EdgeInsets.only(bottom: 12),
    child: premium.HermesListRow(
      key: const ValueKey('lm-setup-offer'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      icon: Icons.memory_rounded,
      iconColor: colors.accentHover,
      title: s.lmSetupOfferTitle,
      subtitle: s.lmSetupOfferText(fit.displayName, fit.sizeLabel),
      trailing: Text(
        s.lmSetupOfferAction,
        style: TextStyle(
          color: colors.accentHover,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: _openLocalModels,
    ),
  );

  Widget _buildLocalModelsEntry(Strings s, HermesThemeColors colors) {
    final probe = _localProbe;
    final unavailable = probe?.kind == _LocalModelsProbeKind.unavailable;
    final subtitle = switch (probe?.kind) {
      null => s.lm1215EntryChecking,
      _LocalModelsProbeKind.unavailable => s.lm1215Unavailable,
      _LocalModelsProbeKind.failed => s.lm1215EntryError,
      _LocalModelsProbeKind.available =>
        probe!.count > 0
            ? s.lm1215EntrySummary(probe.count)
            : s.lm1215EntryEmpty,
    };
    return ModelsTonalGroup(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      child: premium.HermesListRow(
        key: const ValueKey('lm1215-entry'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        icon: Icons.developer_board_rounded,
        iconColor: unavailable ? null : colors.accentHover,
        title: s.lm1215EntryTitle,
        subtitle: subtitle,
        enabled: probe != null && !unavailable,
        trailing: Icon(
          Icons.chevron_right,
          size: 18,
          color: colors.textDisabled,
        ),
        onTap: probe == null || unavailable ? null : _openLocalModels,
      ),
    );
  }

  /// On an instance on this phone the card is only shown for a local model:
  /// a freshly installed agent reports a cloud default before any is set up.
  bool _shouldShowActiveCard(ModelActiveInfo info) {
    if (widget.connection.kind != InstanceKind.localhost) return true;
    return isLocalModelProviderId(info.provider);
  }

  /// A connected provider is behind the default the server reports (by id,
  /// alias, or because it lists the model).
  bool _activeModelUsable(ModelActiveInfo info) {
    final provider = info.provider.trim().toLowerCase();
    final model = info.model.trim().toLowerCase();
    for (final p in _providers) {
      if (!p.authenticated) continue;
      if (provider.isNotEmpty &&
          (p.slug.toLowerCase() == provider ||
              modelProviderMatches(p, provider))) {
        return true;
      }
      if (model.isNotEmpty && p.models.any((m) => m.toLowerCase() == model)) {
        return true;
      }
    }
    return false;
  }

  Widget _buildNoActiveModelCard(Strings s, HermesThemeColors colors) =>
      ModelsTonalGroup(
        key: const ValueKey('models-no-provider'),
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.do_not_disturb_on_outlined,
                size: 20,
                color: colors.textDisabled,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.mdlNoActiveModelTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.mdlNoProviderYet,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
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

  Widget _buildActiveCard(
    Strings s,
    HermesThemeColors colors,
    ModelActiveInfo info,
  ) {
    final friendly = friendlyModelName(info.model);
    final row = _activeProvider(info);
    final providerLabel = row != null && row.name.isNotEmpty
        ? row.name
        : info.provider;
    final ctx = info.effectiveContextLength;
    final ctxLabel = ctx > 1000
        ? s.mdlCtxKTokens((ctx / 1024).round().toString())
        : s.mdlCtxTokens(ctx.toString());
    final small = Theme.of(context).textTheme.bodySmall;
    return ModelsTonalGroup(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.accent, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  s.mdlActiveLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.textTertiary,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: colors.accent, width: 0.8),
                  ),
                  child: Text(
                    s.mdlActiveBadge,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: colors.accent,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ProviderLogo(
                  key: const ValueKey('provider-logo-active-model'),
                  provider: info.provider,
                  providerName: row?.name,
                  model: info.model,
                  size: 20,
                  selected: true,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    friendly,
                    key: const ValueKey('lm1215-active-model'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.accentHover,
                    ),
                  ),
                ),
              ],
            ),
            if (friendly != info.model) ...[
              const SizedBox(height: 2),
              Text(
                info.model,
                style: small?.copyWith(
                  color: colors.textTertiary,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (providerLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                providerLabel,
                key: const ValueKey('lm1215-active-provider'),
                style: small?.copyWith(color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: 8),
            if (ctx > 0)
              Text(
                ctxLabel,
                style: small?.copyWith(color: colors.textTertiary),
              ),
            if (_shownOwner != null &&
                (row == null || !row.models.contains(info.model)))
              Text(
                s.mdlModelNotInCatalog(info.model),
                key: const ValueKey('models-catalog-missing-default'),
                style: small?.copyWith(color: colors.textSecondary),
              ),
            Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 13,
                  color: colors.textDisabled,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    s.lm1215DefaultForNewChats,
                    style: small?.copyWith(color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The profile defaults of the main model (Desktop: reasoning defaults on,
  /// fast and ultrafast off when the model does not report them).
  List<Widget> _buildDefaults(Strings s, ModelActiveInfo active, bool busy) {
    final defaults = _agentDefaults;
    if (defaults == null) return const [];
    final capabilities = _activeProvider(active)?.capabilities[active.model];
    final reasoning = capabilities?.reasoning ?? true;
    final fast = capabilities?.fast ?? false;
    final ultrafast = capabilities?.ultrafast ?? false;
    if (!reasoning && !fast && !ultrafast) return const [];
    final rawEffort = '${defaults['reasoning_effort'] ?? ''}'
        .trim()
        .toLowerCase();
    final effort = rawEffort == 'false' || rawEffort == 'disabled'
        ? 'none'
        : rawEffort.isEmpty
        ? 'medium'
        : rawEffort;
    final rawTier = '${defaults['service_tier'] ?? ''}'.trim().toLowerCase();
    final speed = rawTier == 'ultrafast'
        ? 'ultrafast'
        : const {'fast', 'priority', 'on'}.contains(rawTier)
        ? 'fast'
        : 'normal';
    return [
      ModelsTonalGroup(
        margin: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            if (reasoning)
              HermesSelectRow(
                key: const ValueKey('models-main-reasoning'),
                title: s.mdlRowReasoning,
                value: _effortLabel(effort, s),
                onTap: busy ? null : () => _pickReasoning(effort),
              ),
            if (ultrafast)
              HermesSelectRow(
                key: const ValueKey('models-main-speed'),
                title: s.mdlRowSpeed,
                value: switch (speed) {
                  'fast' => s.mdlSpeedFast,
                  'ultrafast' => s.mdlSpeedUltrafast,
                  _ => s.mdlSpeedStandard,
                },
                onTap: busy ? null : () => _pickSpeed(speed, fast: fast),
              )
            else if (fast)
              HermesToggleRow(
                key: const ValueKey('models-main-fast'),
                title: s.mdlSpeedFast,
                value: speed == 'fast',
                onChanged: busy
                    ? null
                    : (on) => _setAgentDefault(
                        'service_tier',
                        on ? 'fast' : 'normal',
                      ),
              ),
          ],
        ),
      ),
    ];
  }

  /// Auxiliary slots pinned to a provider other than the main one (Desktop
  /// `staleAuxAssignments`): they keep billing that provider after a switch.
  List<Map<String, dynamic>> get _staleAux {
    final main = (_activeInfo?.provider ?? '').toLowerCase();
    if (main.isEmpty) return const [];
    final mainRow = _providerRow(main);
    return [
      for (final task in _auxTasks)
        if ((task['provider'] ?? '').toString().toLowerCase()
            case final provider
            when provider.isNotEmpty &&
                provider != 'auto' &&
                provider != 'main' &&
                provider != main &&
                _providerRow(provider)?.slug != mainRow?.slug &&
                task['local_endpoint'] != true)
          task,
    ];
  }

  /// "Models by function", collapsed by default.
  List<Widget> _buildAuxSection(
    Strings s,
    HermesThemeColors colors,
    bool busy,
  ) {
    final stale = _staleAux;
    final customized = _auxTasks.where((task) {
      final provider = (task['provider'] ?? 'auto').toString();
      return provider.isNotEmpty && provider != 'auto';
    }).length;
    return [
      if (stale.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: HermesInlineNotice(
            key: const ValueKey('models-aux-stale'),
            message: s.mdlStaleAux(
              stale.length,
              _providerName(stale.first['provider'].toString()),
            ),
            icon: Icons.warning_amber_rounded,
            tone: HermesStatusTone.warn,
          ),
        ),
      ModelsTonalGroup(
        margin: const EdgeInsets.only(bottom: 8),
        child: premium.HermesListRow.alignTile(
          child: ExpansionTile(
            key: const ValueKey('models-aux'),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: SizedBox.square(
              dimension: 30,
              child: Icon(Icons.tune, size: 21, color: colors.accent),
            ),
            title: Text(
              s.mdlAuxSection,
              style: premium.HermesListRow.titleStyle(
                Theme.of(context),
                color: colors.textPrimary,
              ),
            ),
            subtitle: Text(
              customized == 0
                  ? s.mdlAuxAllAuto
                  : s.mdlAuxCustomized(customized, _auxTasks.length),
              style: premium.HermesListRow.subtitleStyle(
                Theme.of(context),
                color: colors.textSecondary,
              ),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: [
              if (customized > 0)
                ListTile(
                  key: const ValueKey('models-aux-reset'),
                  dense: true,
                  leading: Icon(
                    Icons.auto_mode,
                    size: 18,
                    color: colors.accent,
                  ),
                  title: Text(
                    s.mdlAuxResetAll,
                    style: TextStyle(fontSize: 12.5, color: colors.accentHover),
                  ),
                  onTap: busy ? null : _resetAux,
                ),
              for (final task in _auxTasks)
                _buildAuxTile(s, colors, task, busy),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildAuxTile(
    Strings s,
    HermesThemeColors colors,
    Map<String, dynamic> task,
    bool busy,
  ) {
    final slot = task['task'] as String? ?? '';
    final provider = task['provider'] as String? ?? 'auto';
    final model = task['model'] as String? ?? '';
    final isAuto = provider == 'auto' || provider.isEmpty;
    final serverLabel = (task['label'] ?? '').toString().trim();
    final label =
        _auxLabel(slot, s) ?? (serverLabel.isEmpty ? slot : serverLabel);
    final effort = (task['reasoning_effort'] as String?) ?? '';
    const efforts = ['', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh'];
    final selectedEffort = efforts.contains(effort) ? effort : '';
    String effortLabel(String value) => value.isEmpty
        ? s.chaControlInherit
        : value == 'none'
        ? s.chaControlOff
        : value;
    return ModelsTonalGroup(
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        children: [
          premium.HermesListRow(
            key: ValueKey('models-aux-$slot'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            icon: Icons.route_outlined,
            title: label,
            // The stored route as it is, like Desktop's route line.
            subtitle: isAuto
                ? s.mdlAutomatic
                : model.isEmpty
                ? provider
                : '$model · $provider',
            trailing: Icon(
              Icons.chevron_right,
              size: 18,
              color: colors.textDisabled,
            ),
            onTap: busy ? null : () => _pickAuxModel(slot, label),
          ),
          if (slot == 'voice_chat')
            HermesSelectRow(
              key: const ValueKey('voice-chat-reasoning'),
              title: s.chaSessionReasoningLabel,
              value: effortLabel(selectedEffort),
              onTap: busy || widget.connection.readOnly
                  ? null
                  : () async {
                      final picked = await showHermesOptions<String>(
                        context: context,
                        title: s.chaSessionReasoningLabel,
                        selected: selectedEffort,
                        options: [
                          for (final value in efforts)
                            HermesOption(
                              value: value,
                              label: effortLabel(value),
                            ),
                        ],
                      );
                      if (picked == null || !mounted) return;
                      unawaited(_setVoiceReasoning(task, picked));
                    },
            ),
        ],
      ),
    );
  }

  Future<void> _selectMain(ModelProvider provider, String model) async {
    final write = _beginWrite();
    if (write == null) return;
    await _assign(write, provider: provider.slug, model: model);
  }

  /// A configured endpoint whose list is empty is asked for its models when
  /// its group is opened (Desktop's refresh-scoped options read).
  Future<void> _refreshEmptyProvider(ModelProvider provider) async {
    if (provider.models.isNotEmpty || provider.baseUrl.isEmpty) return;
    final ticket = profileReadTicket();
    try {
      final rows = await _client.getModelOptions(
        profile: ticket.name,
        refresh: true,
      );
      if (mounted && ticket.isCurrent) setState(() => _providers = rows);
    } catch (_) {
      // The group keeps the models the catalog listed.
    }
  }

  Widget _tileAction(
    HermesThemeColors colors, {
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool destructive = false,
  }) {
    final color = destructive
        ? colors.error.withValues(alpha: 0.85)
        : colors.accentHover;
    return ListTile(
      key: key,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(icon, size: 17, color: destructive ? color : colors.accent),
      title: Text(label, style: TextStyle(fontSize: 12.5, color: color)),
      onTap: onTap,
    );
  }

  /// One connected provider: its models (the main one is chosen here), what
  /// can be done to the key or the account the server lists for it, and
  /// "Remove".
  Widget _buildProviderTile(
    Strings s,
    HermesThemeColors colors,
    ModelProvider provider,
    bool busy,
  ) {
    final models = _shownModels(provider);
    final keyGroup = _keyOf(provider);
    final account = _accountOf(provider);
    final tint = provider.isCurrent
        ? colors.accent.withValues(alpha: 0.05)
        : Colors.transparent;
    return ExpansionTile(
      key: ValueKey('models-provider-${provider.slug}'),
      shape: const Border(),
      collapsedShape: const Border(),
      backgroundColor: tint,
      collapsedBackgroundColor: tint,
      tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      onExpansionChanged: (expanded) {
        if (expanded) unawaited(_refreshEmptyProvider(provider));
      },
      title: Row(
        children: [
          ProviderLogo(
            key: ValueKey('provider-logo-provider-${provider.slug}'),
            provider: provider.slug,
            providerName: provider.name,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              provider.name,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (models.isNotEmpty)
            Text(
              s.mdlModelCount(models.length),
              style: TextStyle(fontSize: 11, color: colors.textTertiary),
            ),
          if (provider.isCurrent) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.check_circle_outline_rounded,
              size: 18,
              color: colors.accentHover,
              semanticLabel: s.mdlActiveBadge,
            ),
          ],
        ],
      ),
      children: [
        if (provider.slug == 'moa')
          ListTile(
            key: const ValueKey('models-moa'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.tune, size: 18, color: colors.accent),
            title: Text(
              s.moaConfigureRecipe,
              style: TextStyle(fontSize: 13, color: colors.accentHover),
            ),
            trailing: Icon(
              Icons.chevron_right,
              size: 18,
              color: colors.textDisabled,
            ),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => MoaRecipeScreen(
                  connection: widget.connection,
                  profile: _profile,
                ),
              ),
            ),
          ),
        for (final modelId in models)
          _buildModelRow(colors, provider, modelId, busy),
        if (account != null && account.canSignInHere)
          _tileAction(
            colors,
            key: ValueKey('models-provider-reconnect-${provider.slug}'),
            icon: Icons.refresh,
            label: s.mdlReconnect,
            onTap: busy ? null : () => _signIn(account.name, account.id),
          ),
        if (keyGroup != null)
          _tileAction(
            colors,
            key: ValueKey('models-provider-key-${provider.slug}'),
            icon: Icons.key_outlined,
            label: s.mdlUpdateKey,
            onTap: busy ? null : () => _enterProviderKey(keyGroup),
          ),
        if (_removable(provider))
          _tileAction(
            colors,
            key: ValueKey('models-provider-remove-${provider.slug}'),
            icon: Icons.link_off,
            label: s.mdlRemoveProvider,
            destructive: true,
            onTap: busy ? null : () => _removeProvider(provider),
          ),
      ],
    );
  }

  Widget _buildModelRow(
    HermesThemeColors colors,
    ModelProvider provider,
    String modelId,
    bool busy,
  ) {
    final active = _activeInfo;
    final isActive =
        active != null &&
        active.model == modelId &&
        _activeProvider(active)?.slug == provider.slug;
    final unavailable = provider.unavailableModels.contains(modelId);
    return premium.HermesListRow(
      key: ValueKey('models-model-${provider.slug}-$modelId'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: ProviderLogo(
        key: ValueKey('provider-logo-model-${provider.slug}-$modelId'),
        provider: provider.slug,
        providerName: provider.name,
        model: modelId,
        size: 20,
        selected: isActive,
      ),
      title: modelId,
      subtitle: unavailable ? Strings.of(context).chaModelUnavailable : null,
      selected: isActive,
      trailing: Icon(
        isActive ? Icons.check_circle : Icons.radio_button_unchecked,
        color: isActive ? colors.accent : colors.textDisabled,
        size: 18,
      ),
      onTap: busy || unavailable ? null : () => _selectMain(provider, modelId),
    );
  }

  /// "Unconfigured providers", collapsed: what can be connected from here.
  Widget _buildUnconfiguredSection(
    Strings s,
    HermesThemeColors colors,
    List<_SetupRow> rows,
    bool busy,
  ) => ModelsTonalGroup(
    margin: const EdgeInsets.only(bottom: 8),
    child: premium.HermesListRow.alignTile(
      child: ExpansionTile(
        key: const ValueKey('models-unconfigured'),
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: SizedBox.square(
          dimension: 30,
          child: Icon(Icons.lock_outline, size: 21, color: colors.textDisabled),
        ),
        title: Text(
          s.mdlUnconfiguredProviders,
          style: premium.HermesListRow.titleStyle(
            Theme.of(context),
            color: colors.textPrimary,
          ),
        ),
        subtitle: Text(
          s.mdlUnconfiguredHint(rows.length),
          style: premium.HermesListRow.subtitleStyle(
            Theme.of(context),
            color: colors.textSecondary,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          for (final row in rows)
            ModelsTonalGroup(
              margin: const EdgeInsets.only(bottom: 8),
              child: premium.HermesListRow(
                icon: Icons.lock_outline,
                iconColor: colors.textDisabled,
                title: row.name,
                trailing: row.restore != null
                    ? TextButton.icon(
                        key: ValueKey('models-restore-${row.restore}'),
                        onPressed: busy
                            ? null
                            : () => _restoreProvider(
                                row.restore!,
                                onDevice: row.onDevice,
                              ),
                        icon: const Icon(Icons.add, size: 15),
                        label: Text(
                          s.mdlAddBackBtn,
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    : row.account != null
                    ? TextButton.icon(
                        key: ValueKey(
                          'models-account-option-${row.account!.id}',
                        ),
                        onPressed: busy
                            ? null
                            : () => _signIn(row.name, row.account!.id),
                        icon: const Icon(Icons.login, size: 15),
                        label: Text(
                          s.mdlLoginBtn,
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    : TextButton.icon(
                        key: ValueKey('models-key-option-${row.key!.keyEnv}'),
                        onPressed: busy
                            ? null
                            : () => _enterProviderKey(row.key!),
                        icon: const Icon(Icons.key_outlined, size: 15),
                        label: Text(
                          s.mdlConfigureBtn,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// One provider that is not connected and the action that connects it: sign
/// in, enter its key, or put it back ([restore], the id it was taken out
/// under; [onDevice] when this device's own list holds it).
typedef _SetupRow = ({
  String name,
  OAuthAccount? account,
  ProviderKeyGroup? key,
  String? restore,
  bool onDevice,
});

class _ScreenWrite implements ModelsWrite {
  _ScreenWrite(this._state, this._ticket, this._authorized);

  final _ModelsScreenState _state;
  final ProfileReadTicket _ticket;
  final bool Function() _authorized;

  @override
  String get profile => _ticket.name;

  @override
  bool get isCurrent => _state.mounted && _ticket.isCurrent && _authorized();

  @override
  Future<bool> run(Future<void> Function() body) =>
      _state._runWrite(this, body);
}

enum _LocalModelsProbeKind { available, unavailable, failed }

class _LocalModelsProbe {
  const _LocalModelsProbe.available(this.count)
    : kind = _LocalModelsProbeKind.available;
  const _LocalModelsProbe.unavailable()
    : kind = _LocalModelsProbeKind.unavailable,
      count = 0;
  const _LocalModelsProbe.failed()
    : kind = _LocalModelsProbeKind.failed,
      count = 0;

  final _LocalModelsProbeKind kind;
  final int count;
}

/// First non-empty value among [keys] of an OAuth `start` response (device
/// code flows name the same field differently per provider).
String providerOAuthStartField(Map<String, dynamic> data, List<String> keys) {
  for (final key in keys) {
    final value = data[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return '';
}

/// The verification URL a phone can open: a loopback `redirect_uri` points at
/// the Dashboard host instead of the phone itself.
String normalizeProviderOAuthBrowserUrl(
  String rawUrl, {
  required SavedConnection connection,
  required String dashboardBaseUrl,
}) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return rawUrl;
  // Agente on-device: el callback OAuth corre en ESTE mismo
  // dispositivo, así que `localhost` en el redirect_uri ya apunta a la máquina
  // correcta. Reescribir host/puerto al del dashboard rompe flujos con puerto
  // fijo registrado — caso OpenAI Codex, cuyo callback escucha en
  // localhost:1455 (único redirect_uri permitido por su client_id): tras
  // reescribirlo a :9119 el código nunca llega al listener → el poll se queda
  // "pending" y la app acaba diciendo "login no completado / no aprobado".
  if (connection.onDeviceLoopback) return rawUrl;
  final dashboard = Uri.tryParse(dashboardBaseUrl);
  if (dashboard == null || dashboard.host.isEmpty) return rawUrl;

  final query = Map<String, String>.from(uri.queryParameters);
  var changed = false;
  for (final key in const ['redirect_uri', 'redirect_url', 'callback_url']) {
    final value = query[key];
    if (value == null || value.isEmpty) continue;
    final redirect = Uri.tryParse(value);
    if (redirect == null) continue;
    final local =
        redirect.host == 'localhost' ||
        redirect.host == '127.0.0.1' ||
        redirect.host == '0.0.0.0';
    if (!local) continue;
    query[key] = redirect
        .replace(
          scheme: dashboard.scheme,
          host: dashboard.host,
          port: dashboard.hasPort ? dashboard.port : null,
        )
        .toString();
    changed = true;
  }

  if (changed && kDebugMode) {
    debugPrint('OAuth URL redirect normalized for ${dashboard.origin}');
  }
  return changed ? uri.replace(queryParameters: query).toString() : rawUrl;
}

/// Device-code sign-in: shows the code, opens the browser and polls until the
/// provider confirms. Pops `true` on success.
class ProviderOAuthLoginScreen extends StatefulWidget {
  final String providerName;
  final String providerSlug;
  final String url;
  final String code;
  final int expiresIn;
  final Future<Map<String, dynamic>> Function() poll;

  const ProviderOAuthLoginScreen({
    super.key,
    required this.providerName,
    required this.providerSlug,
    required this.url,
    required this.code,
    required this.poll,
    this.expiresIn = 0,
  });

  @override
  State<ProviderOAuthLoginScreen> createState() =>
      _ProviderOAuthLoginScreenState();
}

class _ProviderOAuthLoginScreenState extends State<ProviderOAuthLoginScreen> {
  Timer? _timer;
  Timer? _countdown;
  String? _error;
  int _remaining = 0;
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.expiresIn;
    // Copia el código y abre el navegador automáticamente (un toque menos).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.code.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: widget.code));
      }
      await _open();
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    if (_remaining > 0) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _remaining = (_remaining - 1).clamp(0, 1 << 30));
        if (_remaining == 0) {
          _timer?.cancel();
          _countdown?.cancel();
          setState(() => _error = Strings.of(context).mdlCodeExpired);
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final res = await widget.poll();
      final status = (res['status'] ?? 'pending').toString();
      final normalized = status.toLowerCase();
      if (kDebugMode) {
        debugPrint(
          'OAuth poll ${widget.providerSlug}: status=$status keys=${res.keys.toList()}',
        );
      }
      if (!mounted) return;
      if (!_isPendingStatus(normalized)) {
        _timer?.cancel();
        _countdown?.cancel();
        if (_isSuccessStatus(normalized)) {
          Navigator.of(context).pop(true);
        } else {
          setState(() {
            _error =
                (res['error_message'] ??
                        res['message'] ??
                        res['error'] ??
                        res['detail'] ??
                        Strings.of(context).mdlLoginNotCompleted(status))
                    .toString();
          });
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('OAuth poll ${widget.providerSlug} error: $e');
      // Reintenta en el siguiente tick.
    }
  }

  bool _isPendingStatus(String status) => const {
    'pending',
    'slow_down',
    'authorization_pending',
    'waiting',
    'in_progress',
    'started',
  }.contains(status);

  bool _isSuccessStatus(String status) => const {
    'success',
    'completed',
    'complete',
    'ok',
    'authorized',
    // OpenAI Codex termina el flujo loopback con status "approved" (visto en
    // vivo): sin esto la app mostraba "Login no completado (approved)" pese a
    // que el login SÍ había terminado bien.
    'approved',
    'saved',
    'linked',
    'authenticated',
    'connected',
    'done',
  }.contains(status);

  Future<void> _open() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) setState(() => _opened = true);
      } catch (e) {
        debugPrint('[models] excepción silenciada (se ignora sin más): $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final done = _error != null;
    final expiryLabel = _remaining > 0
        ? s.mdlCodeExpiry(
            '${_remaining ~/ 60}:${(_remaining % 60).toString().padLeft(2, '0')}',
          )
        : '';
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(s.mdlOAuthTitle(widget.providerName)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: s.commonClose,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            _opened
                ? s.mdlOAuthBrowserOpened(widget.providerName)
                : s.mdlOAuthOpenBrowser(widget.providerName),
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          if (widget.code.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  s.mdlOAuthCodeLabel,
                  style: TextStyle(fontSize: 11, color: colors.textTertiary),
                ),
                const Spacer(),
                if (expiryLabel.isNotEmpty)
                  Text(
                    expiryLabel,
                    style: TextStyle(fontSize: 11, color: colors.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: widget.code));
                AppFeedback.of(
                  context,
                ).notify(FeedbackKind.routine, s.mdlCodeCopied);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.accent),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.code,
                        style: TextStyle(
                          fontSize: 22,
                          letterSpacing: 3,
                          color: colors.accentHover,
                        ),
                      ),
                    ),
                    Icon(Icons.copy, size: 16, color: colors.textSecondary),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: done ? null : _open,
            icon: const Icon(Icons.open_in_browser),
            label: Text(_opened ? s.mdlReopenBrowser : s.mdlOpenBrowser),
          ),
          const SizedBox(height: 12),
          if (!done)
            OutlinedButton.icon(
              onPressed: _poll,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(s.mdlCheckNow),
            ),
          const SizedBox(height: 24),
          if (!done)
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  s.mdlWaitingAuth,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.error.withValues(alpha: 0.4)),
              ),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
        ],
      ),
    );
  }
}
