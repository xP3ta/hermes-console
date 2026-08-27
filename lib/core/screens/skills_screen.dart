// Skills — Fase 7: Skills + Skill Store
//
// Tabs:
//   installed  — list from GET /api/skills (DashboardClient), local search, detail sheet
//   discover   — search against skills.sh (SkillStoreClient), copy install command
//   audited    — skills.sh filtered view; shows honest empty state (API requires auth)
//   trending   — skills.sh trending view; shows honest empty state (API requires auth)
//
// Gateway management endpoints: none found in DashboardClient. The /api/skills endpoint
// is GET-only. Skill management (install/remove) is done via CLI on the server. The
// detail sheet shows the gateway-managed state and a "copy remove command" button.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../main.dart';
import '../services/bridge_client.dart';
import '../services/bridge_manager.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../services/skill_store_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/read_only.dart';
import 'bridge_config_screen.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/feature_dependency_notice.dart';
import 'instance_edit_screen.dart';
import '../../l10n/app_localizations.dart';

@visibleForTesting
String resolveSkillsRouteProfile({
  required String? profileOverride,
  required String activeProfile,
}) {
  final override = profileOverride?.trim() ?? '';
  return override.isNotEmpty ? override : activeProfile.trim();
}

@visibleForTesting
String? skillsInitialLoadProfile({
  required bool dependenciesResolved,
  required String? profileOverride,
  required String activeProfile,
}) {
  if (!dependenciesResolved) return null;
  return resolveSkillsRouteProfile(
    profileOverride: profileOverride,
    activeProfile: activeProfile,
  );
}

@visibleForTesting
bool skillsProfileMutationsBlocked(String profile) {
  final value = profile.trim();
  return value.isNotEmpty && value != 'default';
}

class SkillsScreen extends StatefulWidget {
  final SavedConnection connection;
  final String? profileOverride;
  const SkillsScreen({
    required this.connection,
    this.profileOverride,
    super.key,
  });

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final DashboardClient _dashClient;
  late final SkillStoreClient _storeClient;

  // ── installed tab ───────────────────────────────────────────────────────
  List<Map<String, dynamic>> _installed = [];
  bool _loadingInstalled = true;
  String? _installedError;
  DashboardDependencyFailure _installedDependencyFailure =
      DashboardDependencyFailure.other;

  /// Perfil de agente activo (vacío = por defecto). Escala GET /api/skills.
  String _profile = '';
  bool _profileResolved = false;

  /// Fuente que alimentó la lista: Dashboard (con flag enabled) o Gateway
  /// (/v1/skills, fallback sin estado enabled).
  String _skillsSource = '/api/skills';
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // ── discover tab ────────────────────────────────────────────────────────
  final TextEditingController _discoverController = TextEditingController();
  List<StoreSkill> _discoverResults = [];
  bool _searching = false;
  String? _discoverError;
  bool _discoverSearched = false;

  // ── bridge (gestión nativa: toggle / quitar / instalar) ──────────────────
  BridgeManager? _mgr;
  BridgeState _bridge = BridgeState.unknown;
  bool _bridgeProbed = false;
  bool _popularLoaded = false;
  String? _busySkill; // nombre de la skill con una acción en curso

  /// Hubo un activar/desactivar que edita config.yaml en el servidor; el agente
  /// necesita recargar/reiniciar para que surta efecto. Muestra un aviso.
  bool _pendingReload = false;

  BridgeManager get _bridgeMgr =>
      _mgr ??= context.findAncestorStateOfType<HermesAppState>()!.bridgeManager;

  /// El bridge permite gestionar skills (instalar/quitar/activar).
  bool get _bridgeSkills =>
      _bridge.connected && !_bridge.caps.readOnly && _bridge.caps.skillsInstall;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _dashClient = DashboardClient.lazy(widget.connection);
    _storeClient = SkillStoreClient();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final conn = context.findAncestorStateOfType<HermesAppState>()?.connManager;
    final activeProfile = conn?.activeProfileFor(widget.connection.id) ?? '';
    final p = skillsInitialLoadProfile(
      dependenciesResolved: true,
      profileOverride: widget.profileOverride,
      activeProfile: activeProfile,
    )!;
    if (!_profileResolved || p != _profile) {
      _profileResolved = true;
      _profile = p;
      _loadInstalled();
    }
    if (!_bridgeProbed) {
      _bridgeProbed = true;
      _probeBridge();
    }
  }

  Future<void> _probeBridge() async {
    var st = await _bridgeMgr.probe(widget.connection.id);
    if (st.status == BridgeStatus.needsToken) {
      if (await _bridgeMgr.tryProvision(widget.connection.id)) {
        st = await _bridgeMgr.probe(widget.connection.id);
      }
    }
    if (!mounted) return;
    setState(() => _bridge = st);
    // Con bridge listo, precarga skills recomendadas para que descubrir no
    // esté vacío (skills.sh no tiene API pública; usamos el CLI del servidor).
    if (_bridgeSkills && !_discoverSearched && !_popularLoaded) {
      _loadPopular();
    }
  }

  Future<void> _configureDependencies() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: app.connManager,
          initial: widget.connection,
        ),
      ),
    );
    if (mounted) {
      await _loadInstalled();
      await _probeBridge();
    }
  }

  /// Carga skills populares de skills.sh como "recomendadas" (sin búsqueda).
  Future<void> _loadPopular() async {
    _popularLoaded = true;
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) return;
    setState(() => _searching = true);
    try {
      final raw = await client.findSkills('agent'); // alto nº de instalaciones
      if (!mounted || _discoverSearched) return; // el usuario ya buscó
      setState(() {
        _discoverResults = raw.map(_storeSkillFromBridge).toList();
        _searching = false;
      });
    } catch (e) {
      debugPrint(
        '[skills] excepción silenciada (se avisa al usuario y se sigue): $e',
      );
      if (mounted) setState(() => _searching = false);
    } finally {
      client.close();
    }
  }

  StoreSkill _storeSkillFromBridge(Map<String, dynamic> m) => StoreSkill(
    id: m['source']?.toString() ?? '',
    slug: m['name']?.toString() ?? '',
    name: m['name']?.toString() ?? '',
    source: m['source']?.toString() ?? '',
    installs: _parseInstalls(m['installs']?.toString() ?? ''),
    sourceType: (m['trust']?.toString().isNotEmpty ?? false)
        ? m['trust'].toString()
        : 'skills.sh',
    installUrl: m['source']?.toString() ?? '',
    url: m['url']?.toString() ?? '',
    description: m['description']?.toString() ?? '',
  );

  Future<bool> _lock(String reason) async {
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null || !lock.enabled) return true;
    return LockScreen.verify(context, lock, reason: reason);
  }

  Future<void> _configureBridge() async {
    final derived = _bridgeMgr.derivedUrlFor(widget.connection.id) ?? '';
    final result = await Navigator.of(context).push<BridgeConfigResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BridgeConfigScreen(
          initialUrl: _bridge.url.isNotEmpty ? _bridge.url : derived,
          derivedUrl: derived,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final override = result.url.trim() == derived ? '' : result.url.trim();
    await _bridgeMgr.save(
      widget.connection.id,
      token: result.token,
      urlOverride: override,
    );
    await _probeBridge();
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  /// Activa/desactiva una skill (edita skills.disabled en el servidor).
  /// El editor de skills (bridge) actúa sobre el home por defecto. Con un
  /// perfil no-default activo, bloqueamos la edición para no tocar el perfil
  /// equivocado (la lista sí se muestra escalada al perfil).
  bool _blockedByProfile() {
    if (!skillsProfileMutationsBlocked(_profile)) return false;
    if (mounted) {
      final str = Strings.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(str.sklProfileBlockMsg(_profile))));
    }
    return true;
  }

  Future<void> _toggleSkillGate(
    Map<String, dynamic> skill,
    bool enabled,
  ) async {
    final name = skill['name'] as String? ?? '';
    final str = Strings.of(context);
    // Política de aprobación: en YOLO no pregunta; en Preguntar confirma; en
    // Solo-lectura bloquea. Activar/desactivar es reversible → riesgo bajo.
    if (!await confirmMutatingAction(
      context,
      instanceId: widget.connection.id,
      readOnlyInstance: widget.connection.readOnly,
      risk: CommandRisk.low,
      title: enabled ? str.sklActivate : str.sklDeactivate,
      detail: name,
    )) {
      return;
    }
    if (mounted) await _toggleSkill(skill, enabled);
  }

  Future<void> _toggleSkill(Map<String, dynamic> skill, bool enabled) async {
    if (_blockedByProfile()) return;
    final name = skill['name'] as String? ?? '';
    if (name.isEmpty || !_bridgeSkills) return;
    final str = Strings.of(context);
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) return;
    setState(() => _busySkill = name);
    // Importante: NO refetcheamos /api/skills tras el toggle. El bridge edita
    // skills.disabled en config.yaml, pero el agente en marcha sigue con la
    // config cargada; un refetch inmediato revertiría el interruptor y daría
    // sensación de "no hace nada". Mantenemos el estado optimista y avisamos de
    // que hay que reiniciar el agente para aplicarlo.
    var needsResync = false;
    try {
      final res = await client.setSkillEnabled(name, enabled);
      if (res['ok'] == true) {
        if (mounted) {
          setState(() {
            skill['enabled'] = enabled;
            _pendingReload = true;
          });
        }
        _snack(enabled ? str.sklActivated(name) : str.sklDeactivated(name));
      } else {
        needsResync = true;
        _snack(str.sklToggleFailed(name));
      }
    } on BridgeException catch (e) {
      needsResync = true;
      _snack(str.sklBridgeError(e.message));
    } catch (e) {
      needsResync = true;
      _snack(str.sklError(e.toString()));
    } finally {
      client.close();
      if (mounted) setState(() => _busySkill = null);
      if (needsResync) _loadInstalled();
    }
  }

  /// Quita una skill del servidor (con confirmación + App Lock).
  Future<void> _removeSkillNative(Map<String, dynamic> skill) async {
    if (_blockedByProfile()) return;
    final name = skill['name'] as String? ?? '';
    if (name.isEmpty) return;
    final str = Strings.of(context);
    // Política de aprobación: Solo-lectura bloquea; YOLO salta la confirmación;
    // Preguntar/Conservador muestran el diálogo + App Lock.
    final gate = approvalGate(
      context,
      instanceId: widget.connection.id,
      readOnlyInstance: widget.connection.readOnly,
      risk: CommandRisk.medium,
      patternKey: 'skill_remove',
    );
    if (gate == ActionGate.blocked) {
      showReadOnlyNotice(context);
      return;
    }
    if (gate == ActionGate.ask) {
      final colors = Theme.of(context).hermes;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(str.sklRemoveTitle),
          content: Text(str.sklRemoveConfirm(name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(str.sklCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                str.sklRemove,
                style: TextStyle(color: colors.onAccent),
              ),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (!await _lock('remove skill $name') || !mounted) return;
    }
    // El borrado real solo existe vía el agente local (bridge): el Dashboard
    // expone /api/skills como GET-only y /api/skills/{name} responde 404 (ver
    // docs/API_AUDIT.md). El intento previo contra /api/skills/{id} siempre
    // fallaba con 404 y caía al bridge mostrando un "rc 0" opaco.
    if (!_bridgeSkills) {
      _snack(str.sklRemoveNeedsBridge);
      return;
    }
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) {
      _snack(str.sklNoBridgeConnection);
      return;
    }
    setState(() => _busySkill = name);
    try {
      final res = await client.removeSkill(name);
      if (res['ok'] == true) {
        // Las skills builtin no se desinstalan: se archivan y deshabilitan.
        _snack(
          res['mode'] == 'builtin_archived'
              ? str.sklBuiltinArchived(name)
              : str.sklRemoved(name),
        );
        await _loadInstalled();
      } else {
        // Mostrar el motivo real del agente (rc + última línea del log) en vez
        // de un "rc 0" sin contexto que no explica por qué falló.
        final rc = res['rc'];
        final detail = _bridgeLogTail(res['log']);
        _snack(
          '${str.sklRemoveFailed(name, '$rc')}'
          '${detail.isEmpty ? '' : ': $detail'}',
        );
      }
    } on BridgeException catch (e) {
      _snack(str.sklBridgeError(e.message));
    } catch (e) {
      _snack(str.sklError(e.toString()));
    } finally {
      client.close();
      if (mounted) setState(() => _busySkill = null);
    }
  }

  /// Última línea no vacía del log que devuelve el bridge (el motivo real del
  /// fallo), recortada para el snackbar.
  String _bridgeLogTail(Object? log) {
    final text = (log ?? '').toString().trim();
    if (text.isEmpty) return '';
    final line = text
        .split('\n')
        .map((l) => l.trim())
        .lastWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.length > 160 ? '${line.substring(0, 160)}…' : line;
  }

  /// Instala una skill de la tienda (owner/repo) con dry-run + App Lock.
  Future<void> _installFromStore(StoreSkill s) async {
    if (_blockedByProfile()) return;
    final source = s.bridgeSource;
    if (source == null || !BridgeClient.isValidSkillSource(source)) {
      _snack(Strings.of(context).sklNoInstallSource);
      return;
    }
    if (!_bridgeSkills) return;
    // Política de aprobación: instalar ejecuta código en el servidor → riesgo
    // alto. Solo-lectura bloquea; YOLO instala directo; Preguntar muestra el
    // comando (dry-run) + App Lock.
    final gate = approvalGate(
      context,
      instanceId: widget.connection.id,
      readOnlyInstance: widget.connection.readOnly,
      risk: CommandRisk.high,
      patternKey: 'skill_install',
    );
    if (gate == ActionGate.blocked) {
      showReadOnlyNotice(context);
      return;
    }
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) return;
    setState(() => _busySkill = source);
    try {
      if (gate == ActionGate.ask) {
        final dry = await client.installSkill(source, dryRun: true);
        if (!mounted) return;
        final cmd = (dry['would_run'] ?? '').toString();
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(str.sklInstallTitle(s.name)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.description.isNotEmpty)
                  Text(
                    s.description,
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.warning.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colors.warning.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    str.sklInstallWarning(cmd),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(str.sklCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(str.sklInstall),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        if (!await _lock('install skill ${s.name}') || !mounted) return;
      }
      final res = await client.installSkill(source);
      if (res['ok'] == true) {
        _snack(str.sklInstalled(s.name));
      } else {
        // Mostrar el motivo real del agente (última línea del log), igual que en
        // _removeSkillNative, en vez de un "rc" sin contexto.
        final detail = _bridgeLogTail(res['log']);
        _snack(
          '${str.sklInstallFailed('${res['rc']}')}'
          '${detail.isEmpty ? '' : ': $detail'}',
        );
      }
    } on BridgeException catch (e) {
      _snack(str.sklBridgeError(e.message));
    } catch (e) {
      _snack(str.sklError(e.toString()));
    } finally {
      client.close();
      if (mounted) setState(() => _busySkill = null);
      _loadInstalled();
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _dashClient.close();
    _storeClient.close();
    _searchController.dispose();
    _discoverController.dispose();
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────

  Future<void> _loadInstalled() async {
    setState(() {
      _loadingInstalled = true;
      _installedError = null;
      _installedDependencyFailure = DashboardDependencyFailure.other;
    });
    try {
      final raw = await _dashClient.getSkills(profile: _profile);
      if (!mounted) return;
      setState(() {
        _installed = raw;
        _skillsSource = '/api/skills';
        _loadingInstalled = false;
      });
    } catch (dashboardError) {
      // Fallback: el Gateway (Bearer) también lista skills en /v1/skills
      // (name/description/category, sin flag enabled). Útil cuando el
      // Dashboard 9119 no está accesible pero el Gateway 8642 sí.
      try {
        final client = ApiClient(
          baseUrl: widget.connection.baseUrl,
          apiKey: widget.connection.apiKey,
        );
        final raw = await client.getGatewaySkills();
        client.close();
        if (!mounted) return;
        setState(() {
          _installed = raw;
          _skillsSource = '/v1/skills (gateway)';
          _loadingInstalled = false;
        });
      } catch (e) {
        debugPrint(
          '[skills] excepción silenciada (se avisa al usuario y se sigue): $e',
        );
        if (!mounted) return;
        setState(() {
          _installedError = localizedApiError(
            Strings.of(context),
            dashboardError,
          );
          _installedDependencyFailure = classifyDashboardDependencyFailure(
            dashboardError,
          );
          _loadingInstalled = false;
        });
      }
    }
  }

  Future<void> _runDiscover() async {
    final q = _discoverController.text.trim();
    if (q.length < 2) return;
    setState(() {
      _searching = true;
      _discoverError = null;
      _discoverSearched = true;
    });
    // Con bridge: busca en skills.sh proxyando el CLI del servidor (la API de
    // skills.sh no es pública). Sin bridge: estado "solo web" honesto.
    if (_bridgeSkills) {
      final client = await _bridgeMgr.clientFor(widget.connection.id);
      if (client == null) {
        if (mounted) setState(() => _searching = false);
        return;
      }
      try {
        final raw = await client.findSkills(q);
        if (!mounted) return;
        setState(() {
          _discoverResults = raw.map(_storeSkillFromBridge).toList();
          _discoverError = null;
          _searching = false;
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _discoverError = e.toString();
            _searching = false;
          });
        }
      } finally {
        client.close();
      }
      return;
    }
    final result = await _storeClient.search(q);
    if (!mounted) return;
    setState(() {
      _discoverResults = result.skills;
      _discoverError = result.error;
      _searching = false;
    });
  }

  static int _parseInstalls(String s) {
    final m = RegExp(r'([\d.]+)\s*([KM]?)', caseSensitive: false).firstMatch(s);
    if (m == null) return 0;
    final n = double.tryParse(m.group(1) ?? '') ?? 0;
    final unit = (m.group(2) ?? '').toUpperCase();
    return (n *
            (unit == 'M'
                ? 1000000
                : unit == 'K'
                ? 1000
                : 1))
        .round();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  int get _enabledCount => _installed.where((s) => s['enabled'] == true).length;

  List<Map<String, dynamic>> get _filteredInstalled {
    if (_searchQuery.isEmpty) return _installed;
    final q = _searchQuery.toLowerCase();
    return _installed.where((s) {
      final name = (s['name'] as String? ?? '').toLowerCase();
      final desc = (s['description'] as String? ?? '').toLowerCase();
      final cat = (s['category'] as String? ?? '').toLowerCase();
      return name.contains(q) || desc.contains(q) || cat.contains(q);
    }).toList();
  }

  Set<String> get _installedNames =>
      _installed.map((s) => (s['name'] as String? ?? '').toLowerCase()).toSet();

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              Icons.check,
              size: 14,
              color: Theme.of(context).hermes.success,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openSkillsSearch(String q) async {
    final encoded = Uri.encodeQueryComponent(q.trim());
    final uri = Uri.parse(
      q.trim().isEmpty ? 'https://skills.sh' : 'https://skills.sh?q=$encoded',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showInstalledDetail(
    BuildContext ctx,
    Map<String, dynamic> skill,
    HermesThemeColors colors,
  ) {
    final name = skill['name'] as String? ?? '';
    final enabled = skill['enabled'] as bool? ?? false;
    final description = skill['description'] as String? ?? '';
    final category = skill['category'] as String? ?? '';
    final removeCmd = 'npx skills remove $name';
    final str = Strings.of(ctx);

    showHermesFloatingSurface<void>(
      context: ctx,
      surfaceKey: const ValueKey('installed-skill-detail-surface'),
      maxWidth: 560,
      maxHeightFactor: 0.88,
      builder: (sheetCtx) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  _StatusChip(enabled: enabled, colors: colors),
                ],
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  description,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ],
              if (category.isNotEmpty) ...[
                const SizedBox(height: 12),
                _MetaChip(label: category, colors: colors),
              ],
              const SizedBox(height: 20),
              // Nota de gestión: nativa (bridge) o CLI (fallback).
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colors.divider.withValues(alpha: 0.55),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _bridgeSkills
                              ? Icons.cloud_done_outlined
                              : Icons.terminal,
                          size: 13,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _bridgeSkills ? str.sklModeNative : str.sklModeCli,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _bridgeSkills
                          ? str.sklDetailHintBridge
                          : str.sklDetailHintNoBridge,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: colors.textDisabled,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(
                        Icons.download_outlined,
                        size: 14,
                        color: colors.textSecondary,
                      ),
                      label: Text(
                        'cmd install',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: colors.divider.withValues(alpha: 0.55),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        final cmd = 'npx skills add $name';
                        _copyToClipboard(cmd, 'copied: $cmd');
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 14,
                        color: colors.error.withValues(alpha: 0.8),
                      ),
                      label: Text(
                        'cmd remove',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.error.withValues(alpha: 0.8),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: colors.error.withValues(alpha: 0.3),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _copyToClipboard(removeCmd, 'copied: $removeCmd');
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: true,
        title: Column(
          children: [
            const Text('skills'),
            if (_profile.isNotEmpty)
              Text(
                str.sklActiveProfile(_profile),
                style: TextStyle(fontSize: 10.5, color: colors.accent),
              ),
            if (_installed.isNotEmpty)
              Text(
                // Fuente de datos explícita. El conteo de activas solo es
                // fiable con /api/skills (el Gateway no informa enabled).
                _skillsSource == '/api/skills'
                    ? str.sklStatsApi(_enabledCount, _installed.length)
                    : str.sklStatsSource(_installed.length, _skillsSource),
                style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
              ),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          labelStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: 12),
          labelColor: colors.accent,
          unselectedLabelColor: colors.textSecondary,
          indicatorColor: colors.accent,
          indicatorWeight: 2,
          tabs: [
            Tab(text: str.sklTabInstalled),
            Tab(text: str.sklTabDiscover),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Tooltip(
              message: _bridgeSkills
                  ? str.sklBridgeActiveTooltip
                  : _bridge.running
                  ? str.sklBridgeDetectedTooltip
                  : str.sklBridgeUnavailableTooltip,
              child: IconButton(
                icon: Icon(
                  _bridgeSkills
                      ? Icons.cloud_done_outlined
                      : _bridge.running
                      ? Icons.cloud_queue
                      : Icons.cloud_off_outlined,
                  color: _bridgeSkills
                      ? colors.success
                      : _bridge.running
                      ? colors.accent
                      : colors.textSecondary,
                ),
                onPressed: _configureBridge,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh installed',
            onPressed: _loadingInstalled ? null : _loadInstalled,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _InstalledTab(
            skills: _filteredInstalled,
            allSkills: _installed,
            loading: _loadingInstalled,
            error: _installedError,
            dashboardCredentialsRequired:
                _installedDependencyFailure ==
                DashboardDependencyFailure.credentials,
            searchController: _searchController,
            onRefresh: _loadInstalled,
            onConfigureDependencies: _configureDependencies,
            onTap: (skill) => _showInstalledDetail(context, skill, colors),
            bridgeManaged: _bridgeSkills,
            canRemove: _bridgeSkills,
            bridgeRunning: _bridge.running,
            onConfigureBridge: _configureBridge,
            pendingReload: _pendingReload,
            busySkill: _busySkill,
            onToggle: _toggleSkillGate,
            onRemove: _removeSkillNative,
            colors: colors,
          ),
          _DiscoverTab(
            controller: _discoverController,
            results: _discoverResults,
            searching: _searching,
            error: _discoverError,
            searched: _discoverSearched,
            installedNames: _installedNames,
            storeAvailable: _storeClient.isAvailable || _bridgeSkills,
            onSearch: _runDiscover,
            onOpenBrowser: () => _openSkillsSearch(_discoverController.text),
            onCopyInstall: (skill) => _copyToClipboard(
              skill.installCommand,
              'copied: ${skill.installCommand}',
            ),
            bridgeCanInstall: _bridgeSkills,
            busySkill: _busySkill,
            onInstall: _installFromStore,
            colors: colors,
          ),
        ],
      ),
    );
  }
}

// ── Tab: installed ────────────────────────────────────────────────────────────

class _InstalledTab extends StatelessWidget {
  final List<Map<String, dynamic>> skills;
  final List<Map<String, dynamic>> allSkills;
  final bool loading;
  final String? error;
  final bool dashboardCredentialsRequired;
  final TextEditingController searchController;
  final VoidCallback onRefresh;
  final Future<void> Function() onConfigureDependencies;
  final void Function(Map<String, dynamic>) onTap;
  final bool bridgeManaged;
  final bool canRemove;
  final bool bridgeRunning;
  final VoidCallback onConfigureBridge;
  final bool pendingReload;
  final String? busySkill;
  final void Function(Map<String, dynamic>, bool) onToggle;
  final void Function(Map<String, dynamic>) onRemove;
  final HermesThemeColors colors;

  const _InstalledTab({
    required this.skills,
    required this.allSkills,
    required this.loading,
    required this.error,
    required this.dashboardCredentialsRequired,
    required this.searchController,
    required this.onRefresh,
    required this.onConfigureDependencies,
    required this.onTap,
    required this.bridgeManaged,
    required this.canRemove,
    required this.bridgeRunning,
    required this.onConfigureBridge,
    required this.pendingReload,
    required this.busySkill,
    required this.onToggle,
    required this.onRemove,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: TuiLoader());
    if (error != null) {
      final s = Strings.of(context);
      return Padding(
        padding: const EdgeInsets.all(20),
        child: FeatureDependencyNotice(
          noticeId: dashboardCredentialsRequired
              ? 'skills-dashboard'
              : 'skills-load',
          kind: dashboardCredentialsRequired
              ? FeatureDependencyKind.dashboard
              : FeatureDependencyKind.gateway,
          title: dashboardCredentialsRequired
              ? s.dependencyDashboardTitle
              : s.dependencyLoadFailedTitle,
          message: dashboardCredentialsRequired
              ? s.dependencyDashboardBody
              : s.dependencyLoadFailedBody(error!),
          primaryActionLabel: dashboardCredentialsRequired
              ? s.dependencyConfigure
              : null,
          onPrimaryAction: dashboardCredentialsRequired
              ? onConfigureDependencies
              : null,
          retryLabel: s.dependencyRetry,
          onRetry: () async => onRefresh(),
          dismissible: false,
        ),
      );
    }
    if (allSkills.isEmpty) {
      return _EmptyState(
        icon: Icons.extension_off,
        title: 'no skills found',
        subtitle: 'no skills are installed on this gateway',
        colors: colors,
      );
    }

    return Column(
      children: [
        if (!bridgeManaged)
          _BridgeNeededBanner(
            running: bridgeRunning,
            onConfigure: onConfigureBridge,
            colors: colors,
          ),
        if (pendingReload) _PendingReloadBanner(colors: colors),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: searchController,
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'search installed skills…',
              prefixIcon: Icon(
                Icons.search,
                size: 18,
                color: colors.textSecondary,
              ),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(
                        Icons.clear,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                      onPressed: () => searchController.clear(),
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                vertical: 10,
                horizontal: 12,
              ),
            ),
          ),
        ),
        Expanded(
          child: skills.isEmpty
              ? _EmptyState(
                  icon: Icons.search_off,
                  title: 'no match',
                  subtitle: 'no skills match your search',
                  colors: colors,
                )
              : RefreshIndicator(
                  onRefresh: () async => onRefresh(),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: skills.length,
                    itemBuilder: (_, i) => _InstalledTile(
                      skill: skills[i],
                      colors: colors,
                      onTap: () => onTap(skills[i]),
                      bridgeManaged: bridgeManaged,
                      canRemove: canRemove,
                      busy: busySkill == (skills[i]['name'] as String? ?? ''),
                      onToggle: (v) => onToggle(skills[i], v),
                      onRemove: () => onRemove(skills[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _InstalledTile extends StatelessWidget {
  final Map<String, dynamic> skill;
  final HermesThemeColors colors;
  final VoidCallback onTap;
  final bool bridgeManaged;
  final bool canRemove;
  final bool busy;
  final void Function(bool) onToggle;
  final VoidCallback onRemove;

  const _InstalledTile({
    required this.skill,
    required this.colors,
    required this.onTap,
    this.bridgeManaged = false,
    this.canRemove = false,
    this.busy = false,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final name = skill['name'] as String? ?? '';
    final enabled = skill['enabled'] as bool? ?? false;
    final description = skill['description'] as String? ?? '';
    final category = skill['category'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      // Minimalista: panel suave sin borde (estilo Claude).
      color: colors.surfaceVariant.withValues(alpha: 0.35),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  enabled ? Icons.check_circle : Icons.block,
                  color: enabled ? colors.success : colors.textDisabled,
                  size: 15,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 13,
                        color: enabled
                            ? colors.textPrimary
                            : colors.textSecondary,
                        fontWeight: enabled
                            ? FontWeight.w500
                            : FontWeight.normal,
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    if (category != null && category.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _MetaChip(label: category, colors: colors),
                    ],
                  ],
                ),
              ),
              // Gestión nativa: toggle si hay bridge; borrar si Dashboard o bridge.
              if (bridgeManaged || canRemove) ...[
                if (busy)
                  const SizedBox(
                    width: 36,
                    height: 36,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else ...[
                  if (bridgeManaged)
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(value: enabled, onChanged: onToggle),
                    ),
                  if (canRemove)
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: colors.error.withValues(alpha: 0.85),
                      ),
                      tooltip: Strings.of(context).sklRemoveTitle,
                      onPressed: onRemove,
                    ),
                ],
              ] else
                Icon(Icons.chevron_right, size: 16, color: colors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tab: discover ─────────────────────────────────────────────────────────────

class _DiscoverTab extends StatelessWidget {
  final TextEditingController controller;
  final List<StoreSkill> results;
  final bool searching;
  final String? error;
  final bool searched;
  final Set<String> installedNames;
  final bool storeAvailable;
  final VoidCallback onSearch;
  final VoidCallback onOpenBrowser;
  final void Function(StoreSkill) onCopyInstall;
  final bool bridgeCanInstall;
  final String? busySkill;
  final void Function(StoreSkill) onInstall;
  final HermesThemeColors colors;

  const _DiscoverTab({
    required this.controller,
    required this.results,
    required this.searching,
    required this.error,
    required this.searched,
    required this.installedNames,
    required this.storeAvailable,
    required this.onSearch,
    required this.onOpenBrowser,
    required this.onCopyInstall,
    required this.bridgeCanInstall,
    required this.busySkill,
    required this.onInstall,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'search skills.sh…',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 12,
                    ),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => onSearch(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: searching ? null : onSearch,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  minimumSize: Size.zero,
                ),
                child: searching
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.onAccent,
                        ),
                      )
                    : const Text('search', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.open_in_browser, color: colors.textSecondary),
                tooltip: Strings.of(context).sklOpenSkillsSh,
                onPressed: onOpenBrowser,
              ),
            ],
          ),
        ),
        if (!storeAvailable && !searched)
          _ApiUnavailableBanner(onOpenBrowser: onOpenBrowser, colors: colors),
        Expanded(child: _discoverBody(context)),
      ],
    );
  }

  Widget _discoverBody(BuildContext context) {
    if (searching) {
      return const Center(child: TuiLoader());
    }
    // Resultados (búsqueda del usuario o recomendadas por defecto).
    if (results.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!searched)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.local_fire_department_outlined,
                    size: 13,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    Strings.of(context).sklRecommended,
                    style: TextStyle(fontSize: 11, color: colors.textDisabled),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: results.length,
              itemBuilder: (_, i) => _StoreSkillCard(
                skill: results[i],
                isInstalled:
                    installedNames.contains(results[i].name.toLowerCase()) ||
                    installedNames.contains(results[i].slug.toLowerCase()),
                onCopyInstall: () => onCopyInstall(results[i]),
                bridgeCanInstall: bridgeCanInstall,
                busy: busySkill == results[i].bridgeSource,
                onInstall: () => onInstall(results[i]),
                colors: colors,
              ),
            ),
          ),
        ],
      );
    }
    if (!searched) {
      if (storeAvailable) {
        final str = Strings.of(context);
        return _EmptyState(
          icon: Icons.travel_explore,
          title: str.sklDiscoverTitle,
          // Aquí ya no se está cargando (el spinner se muestra arriba mientras
          // searching). Si no hubo recomendadas, invita a buscar por nombre.
          subtitle: bridgeCanInstall
              ? str.sklSearchHintBridge
              : str.sklSearchHintCli,
          colors: colors,
        );
      }
      // skills.sh no tiene API pública: modo catálogo web + comando CLI.
      return _SkillsCliCatalogPanel(
        colors: colors,
        onOpenBrowser: onOpenBrowser,
      );
    }
    if (error != null) {
      if (error!.contains('autenticación') ||
          error!.contains('authentication') ||
          error!.contains('not available')) {
        return _StoreUnavailableState(
          query: controller.text,
          onOpenBrowser: onOpenBrowser,
          colors: colors,
        );
      }
      return _EmptyState(
        icon: Icons.error_outline,
        title: 'error',
        subtitle: error!,
        colors: colors,
      );
    }
    final str = Strings.of(context);
    return _EmptyState(
      icon: Icons.search_off,
      title: str.sklNoResultsTitle,
      subtitle: str.sklNoResultsFor(controller.text),
      colors: colors,
      action: OutlinedButton.icon(
        icon: const Icon(Icons.open_in_browser, size: 14),
        label: Text(str.sklSearchOnline, style: const TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
        onPressed: onOpenBrowser,
      ),
    );
  }
}

// ── Tab: audited / trending ───────────────────────────────────────────────────

class _StoreSkillCard extends StatelessWidget {
  final StoreSkill skill;
  final bool isInstalled;
  final VoidCallback onCopyInstall;
  final bool bridgeCanInstall;
  final bool busy;
  final VoidCallback onInstall;
  final HermesThemeColors colors;

  const _StoreSkillCard({
    required this.skill,
    required this.isInstalled,
    required this.onCopyInstall,
    this.bridgeCanInstall = false,
    this.busy = false,
    required this.onInstall,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    skill.name.isEmpty ? skill.slug : skill.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (isInstalled)
                  _BadgeChip(
                    label: 'installed',
                    color: colors.success,
                    textColor: colors.background,
                  ),
              ],
            ),
            if (skill.source.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                skill.source,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ],
            if (skill.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                skill.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ],
            if (skill.installs > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.download, size: 12, color: colors.textDisabled),
                  const SizedBox(width: 4),
                  Text(
                    _formatInstalls(skill.installs),
                    style: TextStyle(fontSize: 11, color: colors.textDisabled),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  icon: Icon(Icons.copy, size: 12, color: colors.textSecondary),
                  label: Text(
                    'comando',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(
                      color: colors.divider.withValues(alpha: 0.55),
                    ),
                  ),
                  onPressed: onCopyInstall,
                ),
                if (bridgeCanInstall &&
                    !isInstalled &&
                    skill.bridgeSource != null) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: busy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 14),
                    label: Text(
                      busy ? 'instalando…' : 'instalar',
                      style: const TextStyle(fontSize: 11),
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: busy ? null : onInstall,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatInstalls(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

// ── Reusable small widgets ────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final bool enabled;
  final HermesThemeColors colors;

  const _StatusChip({required this.enabled, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: enabled
            ? colors.success.withValues(alpha: 0.15)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: enabled
              ? colors.success.withValues(alpha: 0.4)
              : colors.divider,
        ),
      ),
      child: Text(
        enabled ? 'enabled' : 'disabled',
        style: TextStyle(
          fontSize: 10,
          color: enabled ? colors.success : colors.textDisabled,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final HermesThemeColors colors;

  const _MetaChip({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: colors.textSecondary),
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _BadgeChip({
    required this.label,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Empty / error states ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final HermesThemeColors colors;
  final Widget? action;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colors,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colors.textDisabled),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(fontSize: 14, color: colors.textSecondary),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colors.textDisabled),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class _StoreUnavailableState extends StatelessWidget {
  final String query;
  final VoidCallback onOpenBrowser;
  final HermesThemeColors colors;

  const _StoreUnavailableState({
    required this.query,
    required this.onOpenBrowser,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore, size: 40, color: colors.textDisabled),
            const SizedBox(height: 14),
            Text(
              Strings.of(context).sklWebOnlyTitle,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              Strings.of(context).sklWebOnlyBody,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colors.textDisabled),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_browser, size: 14),
              label: Text(
                Strings.of(context).sklOpenSkillsSh,
                style: const TextStyle(fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
              ),
              onPressed: onOpenBrowser,
            ),
          ],
        ),
      ),
    );
  }
}

/// Aviso prominente cuando la gestión nativa de skills no está disponible
/// porque el Mobile Bridge no está conectado. Explica el porqué (en vez de
/// dejar los interruptores invisibles) y ofrece configurarlo en un toque.
class _BridgeNeededBanner extends StatelessWidget {
  final bool running;
  final VoidCallback onConfigure;
  final HermesThemeColors colors;

  const _BridgeNeededBanner({
    required this.running,
    required this.onConfigure,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.accent.withValues(alpha: 0.30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.cloud_queue : Icons.cloud_off_outlined,
                  size: 16,
                  color: colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    running
                        ? Strings.of(context).sklBridgeDetectedTitle
                        : Strings.of(context).sklBridgeDisabledTitle,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _BannerLine(
              colors: colors,
              icon: Icons.check_circle_outline,
              tone: colors.success,
              text: Strings.of(context).sklBridgeCanView,
            ),
            const SizedBox(height: 4),
            _BannerLine(
              colors: colors,
              icon: Icons.block,
              tone: colors.textSecondary,
              text: Strings.of(context).sklBridgeNoActions,
            ),
            const SizedBox(height: 8),
            Text(
              running
                  ? Strings.of(context).sklBridgeRunningNote
                  : Strings.of(context).sklBridgeNotRunningNote,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onConfigure,
                icon: Icon(
                  running
                      ? Icons.link_rounded
                      : Icons.settings_ethernet_rounded,
                  size: 15,
                ),
                label: Text(
                  running
                      ? Strings.of(context).sklBridgeConnect
                      : Strings.of(context).sklBridgeConfigure,
                  style: const TextStyle(fontSize: 12),
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Línea de viñeta del banner del bridge: icono coloreado + texto legible.
class _BannerLine extends StatelessWidget {
  final HermesThemeColors colors;
  final IconData icon;
  final Color tone;
  final String text;

  const _BannerLine({
    required this.colors,
    required this.icon,
    required this.tone,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.5),
          child: Icon(icon, size: 13, color: tone),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Aviso de que hay cambios de skills (activar/desactivar) que solo surten
/// efecto tras recargar/reiniciar el agente.
class _PendingReloadBanner extends StatelessWidget {
  final HermesThemeColors colors;

  const _PendingReloadBanner({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.restart_alt_rounded, size: 16, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                Strings.of(context).sklPendingReload,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApiUnavailableBanner extends StatelessWidget {
  final VoidCallback onOpenBrowser;
  final HermesThemeColors colors;

  const _ApiUnavailableBanner({
    required this.onOpenBrowser,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: colors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                Strings.of(context).sklNoApiNote,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onOpenBrowser,
              child: Text(
                Strings.of(context).sklOpen,
                style: TextStyle(fontSize: 11, color: colors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Panel catálogo/CLI de skills.sh ───────────────────────────────────────────
//
// skills.sh no tiene API pública (verificado) y NO requiere ninguna clave.
// Este panel funciona como catálogo: abrir la web, elegir un skill y generar
// el comando `npx skills add owner/repo` para ejecutarlo en el servidor.
// No existe endpoint seguro en el gateway para instalar remotamente, así que
// la única acción es copiar el comando.

class _SkillsCliCatalogPanel extends StatefulWidget {
  final HermesThemeColors colors;
  final VoidCallback onOpenBrowser;

  const _SkillsCliCatalogPanel({
    required this.colors,
    required this.onOpenBrowser,
  });

  @override
  State<_SkillsCliCatalogPanel> createState() => _SkillsCliCatalogPanelState();
}

class _SkillsCliCatalogPanelState extends State<_SkillsCliCatalogPanel> {
  final _repoCtrl = TextEditingController();

  String get _command {
    final repo = _repoCtrl.text.trim();
    return repo.isEmpty
        ? 'npx skills add <owner/repo>'
        : 'npx skills add $repo';
  }

  @override
  void dispose() {
    _repoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final str = Strings.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          str.sklCliCatalogIntro,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_browser, size: 15),
          label: Text(
            str.sklOpenSkillsSh,
            style: const TextStyle(fontSize: 12.5),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: colors.accent.withValues(alpha: 0.4)),
            foregroundColor: colors.accentHover,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: widget.onOpenBrowser,
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _repoCtrl,
          autocorrect: false,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: str.sklRepoLabel,
            hintText: str.sklRepoHint,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '\$ $_command',
                  style: TextStyle(fontSize: 12.5, color: colors.accentHover),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.copy_outlined,
                  size: 17,
                  color: colors.textSecondary,
                ),
                tooltip: str.sklCopyCommand,
                onPressed: _repoCtrl.text.trim().isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: _command));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(str.sklCommandCopied)),
                        );
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          str.sklCliOnlyNote,
          style: TextStyle(
            fontSize: 11,
            height: 1.45,
            color: colors.textDisabled,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.warning.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.warning.withValues(alpha: 0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_outlined,
                size: 14,
                color: colors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  str.sklSecurityWarning,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
