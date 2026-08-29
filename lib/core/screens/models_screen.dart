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
import '../services/bridge_manager.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/read_only.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/bridge_update_banner.dart';
import '../widgets/hermes_premium_ui.dart';
import 'external_provider_screen.dart';
import 'moa_recipe_screen.dart';

class ModelsScreen extends StatefulWidget {
  final SavedConnection connection;
  const ModelsScreen({required this.connection, super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

String _auxLabel(String key, Strings s) => switch (key) {
  'vision' => s.mdlVision,
  'web_extract' => s.mdlWebExtract,
  'compression' => s.mdlCompression,
  'skills_hub' => s.mdlSkillsHub,
  'approval' => s.mdlApproval,
  'mcp' => s.mdlMcp,
  'title_generation' => s.mdlTitleGeneration,
  'triage_specifier' => s.mdlTriageSpecifier,
  'kanban_decomposer' => s.mdlKanbanDecomposer,
  'profile_describer' => s.mdlProfileDescriber,
  'curator' => s.mdlCurator,
  _ => key,
};

class _ModelsScreenState extends State<ModelsScreen> {
  late final DashboardClient _client;
  ModelActiveInfo? _activeInfo;
  List<ModelProvider> _providers = [];
  // slug → flow OAuth (device_code/loopback/external/…). Decide si el login es
  // viable in-app o requiere CLI externo.
  Map<String, String> _oauthFlows = {};
  List<Map<String, dynamic>> _auxTasks = [];
  bool _loading = true;
  String? _error;
  // Si la API de gestión del Dashboard no está autenticada (p.ej. el dashboard
  // pide login propio y la cookie caducó), caemos a listar los modelos del
  // gateway vía /v1/models —que funciona con el MISMO token del gateway— para
  // que "se vean los modelos" siempre, sin depender del login del dashboard.
  List<String> _fallbackModels = [];
  bool _setting = false;
  // Modelo por defecto en modo fallback (sin Bridge/Dashboard accesible):
  // no hay servidor al que aplicar el cambio, así que se guarda como default
  // global (clave 'selected_model') — el chat lo usa si esa sesión no fijó su
  // propio modelo. Antes esta lista era de solo lectura y aquí no pasaba nada.
  String? _fallbackSelected;

  // Modelos descubiertos en vivo para proveedores custom (key = provider.slug).
  final Map<String, List<String>> _liveModels = {};
  final Set<String> _liveLoading = {};

  /// Proveedores ocultados por el usuario (solo afecta a la vista de la app; NO
  /// toca el servidor). Es la vía para quitar de la lista lo que no se puede
  /// borrar de verdad (proveedores de fábrica como Mixture of Agents). Clave =
  /// slug del proveedor. Reversible con el botón "ver ocultos".
  Set<String> _hidden = {};

  /// Modelos ocultados por el usuario, clave "slug_proveedor/id_modelo".
  /// Mismo patrón que _hidden pero a nivel modelo: el catálogo viene del
  /// gateway/Dashboard y NO existe endpoint DELETE de modelos (verificado en
  /// docs/API_AUDIT.md), así que "eliminar" = ocultar en la vista, reversible
  /// con "ver ocultos" → Restaurar (spec 028 U-05).
  Set<String> _hiddenModels = {};
  bool _showHidden = false;
  static const _kHiddenProviders = 'hidden_providers';
  static const _kHiddenModels = 'hidden_models';

  // (spec 028 U-02) Con bridge-first, el catálogo de proveedores por configurar
  // llega por una llamada suplementaria al Dashboard que antes fallaba en
  // silencio (catchError mudos) y hacía "desaparecer" la auth nativa. Estos
  // flags señalan el fallo en la UI y si lo mostrado viene del caché local.
  bool _supplementFailed = false; // la llamada viva al Dashboard falló
  // Motivo TÉCNICO del fallo del suplemento, visible en la tarjeta: sin él,
  // el diagnóstico en dispositivo era imposible (release silencia debugPrint
  // y el aviso genérico escondía timeout vs 401 vs endpoint roto) (U-36).
  String? _supplementDetail;
  bool _catalogFromCache = false; // el catálogo mostrado es el último cacheado

  /// Clave del caché del último catálogo bueno del Dashboard, por conexión
  /// (cada instancia tiene su propio catálogo de proveedores).
  String get _kCatalogCache => 'models_catalog_cache_${widget.connection.id}';

  /// Perfil de agente activo (vacío = por defecto). Escala las llamadas de
  /// modelos a ese perfil con ?profile=.
  String _profile = '';

  // Bridge (para fallback: no hay API nativa de model/set para fallback).
  BridgeManager? _mgr;
  BridgeState _bridge = BridgeState.unknown;
  bool _bridgeProbed = false;
  List<Map<String, String>> _fallback = [];

  // Bridge-first: si el bridge responde, el catálogo COMPLETO y editable viene
  // por él (un solo token, sin login del Dashboard). True = la lista/selección
  // van por el bridge; false = vía Dashboard (puede exigir login).
  bool _viaBridge = false;

  BridgeManager get _bridgeMgr =>
      _mgr ??= context.findAncestorStateOfType<HermesAppState>()!.bridgeManager;

  bool get _fallbackAvailable =>
      _bridge.connected && _bridge.caps.writableTargets.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _loadHidden();
    // La carga la dispara didChangeDependencies tras sondear el bridge, para ir
    // bridge-first y evitar el muro de login del Dashboard si el bridge existe.
  }

  Future<void> _loadHidden() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kHiddenProviders) ?? const [];
    final rawModels = prefs.getStringList(_kHiddenModels) ?? const [];
    if (!mounted) return;
    setState(() {
      _hidden = raw.toSet();
      _hiddenModels = rawModels.toSet();
    });
  }

  Future<void> _setHidden(String slug, bool hidden) async {
    setState(() {
      if (hidden) {
        _hidden.add(slug);
      } else {
        _hidden.remove(slug);
        if (_hidden.isEmpty && _hiddenModels.isEmpty) _showHidden = false;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHiddenProviders, _hidden.toList());
  }

  bool _isModelHidden(String slug, String modelId) =>
      _hiddenModels.contains('$slug/$modelId');

  /// Oculta/restaura un modelo concreto de la vista (clave "slug/modelo").
  /// Solo local: no hay borrado server-side de modelos (spec 028 U-05).
  Future<void> _setModelHidden(String slug, String modelId, bool hidden) async {
    final key = '$slug/$modelId';
    setState(() {
      if (hidden) {
        _hiddenModels.add(key);
      } else {
        _hiddenModels.remove(key);
        if (_hidden.isEmpty && _hiddenModels.isEmpty) _showHidden = false;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHiddenModels, _hiddenModels.toList());
  }

  /// Oculta un modelo con aviso y Deshacer inmediato (spec 028 U-05). El
  /// borrado real de modelos Ollama locales ya existe en su propia pantalla;
  /// aquí solo se limpia la vista.
  void _hideModel(ModelProvider provider, String modelId) {
    _setModelHidden(provider.slug, modelId, true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(Strings.of(context).mdlModelHiddenSnack(modelId)),
        action: SnackBarAction(
          label: Strings.of(context).mdlUndo,
          onPressed: () => _setModelHidden(provider.slug, modelId, false),
        ),
      ),
    );
  }

  /// Nº de elementos ocultos relevantes en esta pantalla: proveedores del
  /// catálogo actual + modelos ocultos de esos proveedores. Alimenta el
  /// contador "N ocultos" siempre visible del appbar (spec 028 U-02/U-05).
  int get _hiddenItemCount {
    final slugs = _providers.map((p) => p.slug).toSet();
    final providers = _providers.where((p) => _hidden.contains(p.slug)).length;
    final models = _hiddenModels
        .where((k) => slugs.contains(k.split('/').first))
        .length;
    return providers + models;
  }

  /// Sondea el bridge (best-effort) y luego carga. Si el bridge responde, la
  /// carga será bridge-first; si no, cae al Dashboard.
  Future<void> _bootstrap() async {
    await _probeBridge();
    await _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final conn = context.findAncestorStateOfType<HermesAppState>()?.connManager;
    final p = conn?.activeProfileFor(widget.connection.id) ?? '';
    if (p != _profile) {
      _profile = p;
      if (_bridgeProbed) _load(); // reescala si cambió el perfil activo
    }
    if (!_bridgeProbed) {
      _bridgeProbed = true;
      _bootstrap();
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
    if (_bridge.connected) _loadFallback();
  }

  Future<void> _loadFallback() async {
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) return;
    try {
      final fb = await client.getFallback();
      if (mounted) setState(() => _fallback = fb);
    } catch (e) {
      debugPrint('[models] excepción silenciada (se ignora sin más): $e');
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  // ── Caché del catálogo del Dashboard (spec 028 U-02) ─────────────────────
  // Guarda el último catálogo bueno (proveedores por configurar + flows OAuth)
  // para que, con bridge-first y Dashboard caído, la sección de login de
  // proveedores nativos no desaparezca: se muestra el caché marcado como
  // "sin conexión al Dashboard" en lugar de una lista vacía en silencio.

  /// Serializa un proveedor con las claves canónicas de ModelProvider.fromJson
  /// (no hay toJson en el modelo; se mantiene aquí para no tocar otros ficheros).
  Map<String, dynamic> _providerToJson(ModelProvider p) => {
    'slug': p.slug,
    'name': p.name,
    // El "activo" no se cachea: al volver la conexión ya no sería fiable.
    'is_current': false,
    'authenticated': p.authenticated,
    'auth_type': p.authType,
    'oauth_provider': p.oauthProviderId,
    'key_env': p.keyEnv,
    'warning': p.warning,
    'models': p.models,
    'base_url': p.baseUrl,
  };

  /// Actualiza el caché fusionando con lo ya guardado: catálogo y flows llegan
  /// por llamadas distintas y pueden fallar por separado.
  Future<void> _saveCatalogCache({
    List<ModelProvider>? unauthProviders,
    Map<String, String>? oauthFlows,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic> data = {};
      final prev = prefs.getString(_kCatalogCache);
      if (prev != null) {
        final decoded = jsonDecode(prev);
        if (decoded is Map) data = decoded.cast<String, dynamic>();
      }
      if (unauthProviders != null) {
        data['providers'] = unauthProviders.map(_providerToJson).toList();
      }
      if (oauthFlows != null) data['oauth_flows'] = oauthFlows;
      await prefs.setString(_kCatalogCache, jsonEncode(data));
    } catch (e) {
      // El caché es best-effort: fallar al guardarlo no debe romper la carga.
      debugPrint('[models] no se pudo guardar el caché del catálogo: $e');
    }
  }

  Future<({List<ModelProvider> providers, Map<String, String> flows})?>
  _readCatalogCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCatalogCache);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final provs = <ModelProvider>[];
      final rawProvs = decoded['providers'];
      if (rawProvs is List) {
        for (final e in rawProvs) {
          if (e is Map) {
            provs.add(ModelProvider.fromJson(e.cast<String, dynamic>()));
          }
        }
      }
      final flows = <String, String>{};
      final rawFlows = decoded['oauth_flows'];
      if (rawFlows is Map) {
        rawFlows.forEach((k, v) => flows[k.toString()] = v.toString());
      }
      return (providers: provs, flows: flows);
    } catch (e) {
      debugPrint('[models] caché del catálogo ilegible (se ignora): $e');
      return null;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      // Se recalculan en cada carga (spec 028 U-02).
      _supplementFailed = false;
      _supplementDetail = null;
      _catalogFromCache = false;
    });
    // Bridge-first: trae el catálogo completo y editable con el MISMO token,
    // sin login del Dashboard. Solo si el bridge no responde caemos al Dashboard.
    if (_bridge.connected && await _bridgeLoadOptions()) return;
    _viaBridge = false;
    try {
      ModelActiveInfo? active;
      List<ModelProvider> providers = [];
      Map<String, dynamic> aux = {};
      Map<String, String> oauthFlows = {};
      await Future.wait([
        _client.getModelInfo(profile: _profile).then((v) => active = v),
        _client.getModelOptions(profile: _profile).then((v) => providers = v),
        // Las asignaciones por función son opcionales (puede no existir el
        // endpoint en versiones viejas): no debe tumbar la pantalla.
        _client
            .getAuxiliaryModels(profile: _profile)
            .then((v) => aux = v)
            .catchError((_) => aux = <String, dynamic>{}),
        // Flows OAuth (device_code/loopback/external): deciden si el login es
        // viable in-app. Best-effort.
        _client
            .getOAuthFlows()
            .then((v) => oauthFlows = v)
            .catchError((_) => oauthFlows = <String, String>{}),
      ]);
      if (!mounted) return;
      setState(() {
        _activeInfo = active;
        _providers = providers;
        _oauthFlows = oauthFlows;
        _auxTasks = ((aux['tasks'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _loading = false;
      });
      // Alimenta el caché también en modo dashboard-only: así el modo
      // bridge-first sin Dashboard tiene catálogo que enseñar (spec 028 U-02).
      unawaited(
        _saveCatalogCache(
          unauthProviders: providers.where((p) => !p.authenticated).toList(),
          oauthFlows: oauthFlows,
        ),
      );
    } catch (e) {
      // La gestión vía Dashboard falló (típico: el dashboard pide login propio y
      // el token del gateway no lo abre, o la cookie caducó). En vez de dejar la
      // pantalla en error, intentamos LISTAR los modelos del gateway con el mismo
      // token —eso siempre funciona— para que al menos se vean.
      List<String> fallback = const [];
      try {
        final api = ApiClient(
          baseUrl: widget.connection.gatewayUrl,
          apiKey: widget.connection.apiKey,
        );
        // /v1/models (lo que anuncia Hermes) + tags Ollama del host (gemma4…),
        // dedup, para que se vean los modelos reales y no solo el alias.
        final results = await Future.wait([
          api.getModels(),
          api.getBackendModels(),
        ]);
        final seen = <String>{};
        fallback = [
          for (final m in [...results[0], ...results[1]])
            if (m.isNotEmpty && seen.add(m)) m,
        ];
      } catch (_) {
        // El gateway tampoco respondió: dejamos el error original.
      }
      String? selected;
      try {
        final prefs = await SharedPreferences.getInstance();
        selected = prefs.getString('selected_model');
      } catch (_) {
        // No crítico: la lista simplemente arranca sin ninguno marcado.
      }
      if (!mounted) return;
      final message = localizedApiError(Strings.of(context), e);
      setState(() {
        _error = message;
        _fallbackModels = fallback;
        _fallbackSelected = selected;
        _loading = false;
      });
    }
  }

  /// Aplica `modelId` como default global (modo fallback, sin Bridge/Dashboard):
  /// no hay a qué servidor mandarlo, así que queda en `SharedPreferences` bajo
  /// la clave 'selected_model'. El chat la usa si esa sesión no fijó su propio
  /// modelo (`_loadPrefs` en chat_screen.dart le da prioridad al override por
  /// sesión, así que esto no pisa una elección hecha dentro de un chat).
  Future<void> _applyFallbackModel(String modelId) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', modelId);
    if (!mounted) return;
    setState(() => _fallbackSelected = modelId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).mdlActiveModelSet(modelId)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Carga el catálogo de modelos POR EL BRIDGE (sin login del Dashboard).
  /// Devuelve true si lo consiguió (estado ya actualizado), false si no.
  Future<bool> _bridgeLoadOptions() async {
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) return false;
    try {
      final data = await client.modelOptions();
      if (data['ok'] != true) return false;
      final raw = data['providers'];
      final maps = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) maps.add(e.cast<String, dynamic>());
        }
      } else if (raw is Map) {
        raw.forEach((k, v) {
          if (v is Map) {
            maps.add({'slug': k.toString(), ...v.cast<String, dynamic>()});
          }
        });
      }
      final providers = maps
          .map(ModelProvider.fromJson)
          // Se conservan las filas SIN modelos cuando no están autenticadas:
          // son el catálogo "por configurar" del bridge ≥1.11.2 (los
          // proveedores configurables aún no tienen modelos). Filtrarlas
          // vaciaba el catálogo completo y forzaba la vuelta al Dashboard
          // (U-38): el aviso "no se pudo cargar" en servidores sin credencial.
          .where((p) => p.models.isNotEmpty || !p.authenticated)
          .toList();
      if (providers.isEmpty) return false;
      if (!mounted) return false;
      setState(() {
        _activeInfo = ModelActiveInfo(
          model: (data['model'] ?? '').toString(),
          provider: (data['provider'] ?? '').toString(),
          effectiveContextLength: 0,
        );
        _providers = providers;
        _oauthFlows = {};
        _auxTasks = [];
        _fallbackModels = [];
        _error = null;
        _viaBridge = true;
        _loading = false;
      });
      // El bridge no expone OAuth ni aux tasks; los pedimos al Dashboard en
      // paralelo sin bloquear (si el Dashboard no está disponible, no pasa nada).
      _loadBridgeSupplement();
      return true;
    } catch (e) {
      debugPrint('[models] excepción silenciada (se asume false): $e');
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> _loadBridgeSupplement() async {
    // (spec 028 U-02) Antes los fallos de estas llamadas se tragaban con
    // catchError((_) {}) y, si el Dashboard no respondía (cookie caducada,
    // :9119 inaccesible, solo-gateway), la sección de proveedores por
    // configurar desaparecía en silencio: "la auth nativa ya no está". Ahora
    // cada llamada registra su resultado; si el catálogo vivo falla se fusiona
    // el último catálogo bueno cacheado y la UI muestra una fila informativa
    // con Reintentar en lugar de callar.
    try {
      var auxOk = true;
      var flowsOk = true;
      var catalogOk = true;
      Object? supplementError;
      Map<String, dynamic> aux = {};
      Map<String, String> oauthFlows = {};
      List<ModelProvider> dashProviders = [];
      // Bridge ≥1.11.2 (picker con include_unconfigured): el catálogo del
      // bridge ya trae TAMBIÉN los proveedores por configurar, así que el
      // Dashboard sobra para el catálogo — el QR-setup funciona completo sin
      // credencial del Dashboard (U-37). Señal: alguna fila no autenticada.
      final bridgeHasFullCatalog =
          _viaBridge && _providers.any((p) => !p.authenticated);
      await Future.wait([
        _client
            .getAuxiliaryModels(profile: _profile)
            .then((v) {
              aux = v;
            })
            .catchError((_) {
              auxOk = false;
            }),
        _client
            .getOAuthFlows()
            .then((v) {
              oauthFlows = v;
            })
            .catchError((_) {
              flowsOk = false;
            }),
        // Con bridges antiguos (solo configurados), el Dashboard completa el
        // catálogo con los no configurados (OAuth / API key desde la app).
        if (!bridgeHasFullCatalog)
          _client
              .getModelOptions(profile: _profile)
              .then((v) {
                dashProviders = v;
              })
              .catchError((e) {
                catalogOk = false;
                supplementError = e;
              }),
      ]);
      if (!mounted) return;

      var fromCache = false;
      if (catalogOk && flowsOk) {
        // Catálogo vivo correcto: refresca el caché para el próximo fallo.
        unawaited(
          _saveCatalogCache(
            unauthProviders: dashProviders
                .where((p) => !p.authenticated)
                .toList(),
            oauthFlows: oauthFlows,
          ),
        );
      } else {
        // Llamada viva fallida: se cubre con el último catálogo bueno cacheado
        // (si existe), marcándolo como "sin conexión al Dashboard".
        final cached = await _readCatalogCache();
        if (!mounted) return;
        if (cached != null) {
          if (!catalogOk && cached.providers.isNotEmpty) {
            dashProviders = cached.providers;
            fromCache = true;
          }
          if (!flowsOk && cached.flows.isNotEmpty) {
            oauthFlows = cached.flows;
            flowsOk = true; // recuperados del caché: se pueden aplicar
          }
        }
        // Si solo falló una parte, cachea la que sí llegó viva.
        if (catalogOk) {
          unawaited(
            _saveCatalogCache(
              unauthProviders: dashProviders
                  .where((p) => !p.authenticated)
                  .toList(),
            ),
          );
        }
      }

      // Proveedores del bridge (autenticados, con modelos) son la fuente principal.
      // Añadimos los no configurados del Dashboard que no estén ya en la lista.
      List<ModelProvider> merged = _providers;
      if (dashProviders.isNotEmpty) {
        final bridgeSlugs = _providers.map((p) => p.slug).toSet();
        final unauthExtra = dashProviders
            .where((p) => !p.authenticated && !bridgeSlugs.contains(p.slug))
            .toList();
        if (unauthExtra.isNotEmpty) {
          merged = [..._providers, ...unauthExtra];
        }
      }
      setState(() {
        // Con fallo y sin caché se conservan los flows actuales en vez de
        // vaciarlos: pisarlos con {} rompía el botón de login OAuth.
        if (flowsOk) _oauthFlows = oauthFlows;
        if (auxOk) {
          _auxTasks = ((aux['tasks'] as List?) ?? const [])
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        }
        _providers = merged;
        _supplementFailed = !catalogOk;
        _supplementDetail = catalogOk ? null : _shortError(supplementError);
        _catalogFromCache = fromCache;
      });
    } catch (e) {
      // Red de seguridad: un fallo inesperado no debe tumbar la pantalla,
      // pero sí dejar constancia visible del problema (spec 028 U-02).
      debugPrint('[models] fallo cargando el suplemento del Dashboard: $e');
      if (mounted) {
        setState(() {
          _supplementFailed = true;
          _supplementDetail = _shortError(e);
        });
      }
    }
  }

  Future<bool?> _confirmMainModelChange(String modelId) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        icon: Icon(
          Icons.warning_amber_rounded,
          color: colors.warning,
          size: 28,
        ),
        title: Text(
          s.mdlAffectsRunningAgent,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        content: Text(
          s.mdlConfirmMainModelBody(_profile, modelId),
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              s.commonCancel,
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: colors.warning),
            child: Text(
              s.mdlChangeAnyway,
              style: TextStyle(color: colors.onAccent),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectModel(
    String providerSlug,
    String modelId, {
    String scope = 'main',
    String task = '',
    String? successLabel,
    String providerBaseUrl = '',
  }) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final l10n = Strings.of(context);
    // Footgun: `model/set` toca el gateway EN EJECUCIÓN (un solo gateway), no
    // solo el perfil seleccionado. Al cambiar el modelo PRINCIPAL con un perfil
    // no-default activo, avisamos de que también cambia el modelo del agente.
    if (scope == 'main' && _profile.isNotEmpty) {
      final ok = await _confirmMainModelChange(modelId);
      if (ok != true) return;
    }
    setState(() => _setting = true);
    // Proveedores CUSTOM (base_url propio, p.ej. un backend llama.cpp propio
    // como "llama-cpp-home"): el bridge solo da el trato "custom" (gate de
    // context_length + reenvío de base_url) a los slugs literales
    // custom/ollama, no a nombres arbitrarios — así que aplicarlos por bridge
    // deja base_url/context_length sin tocar. El Dashboard sí los transporta
    // (mismo patrón que external_provider_screen/ollama_models_screen), así
    // que para estos se prueba el Dashboard primero y solo si no responde se
    // cae al bridge (comportamiento previo).
    if (providerBaseUrl.isNotEmpty && scope == 'main') {
      try {
        final done = await _client.setActiveModel(
          providerSlug: providerSlug,
          modelId: modelId,
          scope: scope,
          task: task,
          profile: _profile,
          baseUrl: providerBaseUrl,
        );
        if (!done) throw Exception('El Dashboard rechazó el cambio');
        await _load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                successLabel ??
                    Strings.of(context).mdlActiveModelSetViaDashboard(modelId),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        if (mounted) setState(() => _setting = false);
        return;
      } catch (_) {
        // Dashboard no disponible para este proveedor custom: sigue con el
        // camino de siempre (bridge si el catálogo vino por él).
      }
    }
    try {
      // Modelo PRINCIPAL vía bridge cuando el catálogo vino por él (sin login del
      // Dashboard). Las asignaciones por función (scope != 'main') siguen por el
      // Dashboard, que es quien las gestiona.
      if (_viaBridge && scope == 'main') {
        final client = await _bridgeMgr.clientFor(widget.connection.id);
        if (client == null) {
          throw Exception(l10n.mdlBridgeUnavailable);
        }
        try {
          final r = await client.setModel(
            provider: providerSlug,
            model: modelId,
          );
          if (r['ok'] != true) {
            throw Exception(
              (r['error'] ?? r['message'] ?? l10n.mdlApplyModelError)
                  .toString(),
            );
          }
        } finally {
          client.close();
        }
      } else {
        await _client.setActiveModel(
          providerSlug: providerSlug,
          modelId: modelId,
          scope: scope,
          task: task,
          profile: _profile,
        );
      }
      await _load();
      if (!mounted) return;
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(successLabel ?? s.mdlActiveModelSet(modelId)),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.mdlErrorChangingModel(localizedApiError(s, e))),
        ),
      );
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  Future<void> _resetAux() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    setState(() => _setting = true);
    try {
      await _client.resetAuxiliaryModels(profile: _profile);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).mdlAuxResetToAuto)),
        );
      }
    } catch (e) {
      if (mounted) {
        final s = Strings.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.commonError(localizedApiError(s, e)))),
        );
      }
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  /// Hoja para elegir el modelo de una función auxiliar (o automático).
  Future<void> _pickModelForTask(String task) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final picked = await _pickModel(
      title: _auxLabel(task, s),
      subtitle: s.mdlPickModelSubtitle,
      allowAuto: true,
    );
    if (picked == null) return;
    await _selectModel(
      picked.provider,
      picked.model,
      scope: 'auxiliary',
      task: task,
      successLabel: picked.provider == 'auto'
          ? '${_auxLabel(task, s)}: ${s.mdlAutomatic.toLowerCase()}'
          : '${_auxLabel(task, s)}: ${picked.model}',
    );
  }

  /// Hoja genérica para elegir provider+model (o automático).
  Future<({String provider, String model})?> _pickModel({
    required String title,
    String? subtitle,
    bool allowAuto = true,
  }) {
    final colors = Theme.of(context).hermes;
    var query = '';
    return showHermesFloatingSurface<({String provider, String model})>(
      context: context,
      surfaceKey: const ValueKey('models-picker-surface'),
      maxWidth: 560,
      maxHeightFactor: 0.88,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final candidates = _providers
              .where(
                (provider) =>
                    provider.authenticated && !_hidden.contains(provider.slug),
              )
              .map(
                (provider) => provider.copyWith(
                  models: provider.models
                      .where((model) => !_isModelHidden(provider.slug, model))
                      .toList(),
                ),
              )
              .toList();
          final visibleProviders = filterModelProviders(candidates, query);
          final hasMatches = visibleProviders.any(
            (provider) => provider.models.isNotEmpty,
          );

          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('models-model-search'),
                textInputAction: TextInputAction.search,
                onChanged: (value) => setSheet(() => query = value),
                decoration: InputDecoration(
                  hintText: Strings.of(ctx).modelSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              if (allowAuto && query.trim().isEmpty) ...[
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.auto_mode,
                    color: colors.accent,
                    size: 20,
                  ),
                  title: Text(
                    Strings.of(ctx).mdlAutomatic,
                    style: TextStyle(color: colors.textPrimary),
                  ),
                  subtitle: Text(
                    Strings.of(ctx).mdlUsesMainModel,
                    style: TextStyle(fontSize: 11, color: colors.textDisabled),
                  ),
                  onTap: () =>
                      Navigator.pop(ctx, (provider: 'auto', model: '')),
                ),
                const Divider(),
              ],
              // El selector respeta lo ocultado por el usuario, igual que la
              // lista principal: proveedores y modelos ocultos no se ofrecen
              // (se restauran desde "ver ocultos") (spec 028 U-05).
              if (!hasMatches)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 22,
                  ),
                  child: Text(
                    Strings.of(ctx).modelSearchEmpty,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              for (final p in visibleProviders)
                ...p.models.map(
                  (m) => ListTile(
                    dense: true,
                    title: Text(
                      m,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      p.name,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: colors.textDisabled,
                      ),
                    ),
                    onTap: () =>
                        Navigator.pop(ctx, (provider: p.slug, model: m)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickFallback() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final picked = await _pickModel(
      title: s.mdlFallbackTitle,
      subtitle: s.mdlFallbackSubtitle,
      allowAuto: false,
    );
    if (picked == null) return;
    await _setFallback([
      {'provider': picked.provider, 'model': picked.model},
    ]);
  }

  /// Configura un proveedor con API key: pide la clave en una RUTA (no diálogo)
  /// y la guarda con PUT /api/env (variable `keyEnv` del proveedor).
  Future<void> _configureProviderKey(ModelProvider provider) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final key = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ProviderKeyScreen(
          providerName: provider.name,
          keyEnv: provider.keyEnv,
        ),
      ),
    );
    if (key == null || key.isEmpty || !mounted) return;
    setState(() => _setting = true);
    try {
      await _client.setEnvVar(provider.keyEnv, key);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).mdlProviderKeySaved(provider.name),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final s = Strings.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.commonError(localizedApiError(s, e)))),
        );
      }
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  /// Desconecta/desconfigura un proveedor ya configurado: borra su API key
  /// (DELETE /api/env) o desconecta su OAuth (DELETE /api/providers/oauth/{id}).
  Future<void> _disconnectProvider(ModelProvider provider) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final colors = Theme.of(context).hermes;
    final isActive = provider.isCurrent;
    final isOAuth = _isOAuthProvider(provider);
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.mdlDisconnectProviderTitle(provider.name)),
        content: Text(
          (provider.keyEnv.isNotEmpty && !isOAuth)
              ? s.mdlDisconnectApiKeyBody(provider.keyEnv) +
                    (isActive ? s.mdlDisconnectActiveWarningModel : '')
              : s.mdlDisconnectOAuthBody(provider.name) +
                    (isActive ? s.mdlDisconnectActiveWarning : ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              s.mdlDisconnect,
              style: TextStyle(color: colors.onAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _setting = true);
    try {
      if (isOAuth) {
        await _client.disconnectOAuth(_oauthProviderId(provider));
      } else {
        await _client.deleteEnvVar(provider.keyEnv);
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).mdlProviderDisconnected(provider.name),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final s = Strings.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.commonError(localizedApiError(s, e)))),
        );
      }
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  /// Slugs OAuth REALES (fallback SOLO si el endpoint no informa `auth_type`,
  /// p.ej. en algún provider ya autenticado). Verificado contra el agente: estos
  /// son los únicos OAuth; el resto (anthropic, minimax, xai, qwen, copilot…) es
  /// `api_key` o AWS y NO debe ofrecer "Autenticar".
  static const _kOAuthSlugs = {
    'nous',
    'openai-codex',
    'codex',
    'xai-oauth',
    'qwen-oauth',
    'minimax-oauth',
    'google-gemini-cli',
  };

  /// ¿El provider usa OAuth? Fuente de verdad: el `auth_type` real del dashboard
  /// (`oauth_device_code`/`oauth_external`/`oauth_minimax`/…). Solo si viene
  /// vacío se recurre a la lista de slugs OAuth conocidos.
  bool _isOAuthProvider(ModelProvider p) {
    final at = p.authType.toLowerCase();
    if (at.isNotEmpty) return at.startsWith('oauth');
    return _kOAuthSlugs.contains(p.slug);
  }

  /// ¿El login OAuth se puede completar DENTRO de la app? Solo los flujos
  /// device_code / loopback / minimax (o pkce). Los `external` (qwen-oauth,
  /// google-gemini-cli) necesitan el CLI del proveedor en el servidor → NO se
  /// ofrece "login" (daría error). Fuente: `/api/providers/oauth` (flow).
  bool _canLoginInApp(ModelProvider p) {
    if (!_isOAuthProvider(p)) return false;
    final flow = (_oauthFlows[p.slug] ?? '').toLowerCase();
    if (flow.isEmpty) {
      // Sin info de flow: permite solo los que sabemos device_code/loopback.
      return const {
        'nous',
        'openai-codex',
        'xai-oauth',
        'minimax-oauth',
      }.contains(p.slug);
    }
    return flow == 'device_code' ||
        flow == 'loopback' ||
        flow == 'minimax' ||
        flow == 'pkce';
  }

  String _oauthProviderId(ModelProvider p) {
    final explicit = p.oauthProviderId.trim();
    if (explicit.isNotEmpty) return explicit;
    if (p.slug == 'nous' || p.slug == 'openai-codex') return p.slug;
    if (p.slug == 'minimax' || p.slug == 'minimax-oauth') {
      return 'minimax-oauth';
    }
    if (p.slug == 'codex' || p.slug == 'openai-codex') return 'codex-oauth';
    if (p.slug == 'qwen') return 'qwen-oauth';
    if (p.slug == 'xai') return 'xai-oauth';
    if (p.slug.endsWith('-oauth')) return p.slug;
    if (p.authType.toLowerCase().contains('oauth')) return '${p.slug}-oauth';
    return p.slug;
  }

  /// ¿El proveedor es un servidor externo configurado por URL (Ollama, LM Studio,
  /// etc.)? Estos no tienen env var ni OAuth — se identifican por la ausencia de
  /// ambos y por el slug/authType "custom" o vacío/none.
  bool _isCustomUrlProvider(ModelProvider p) {
    if (_isOAuthProvider(p) || p.keyEnv.isNotEmpty) return false;
    final at = p.authType.toLowerCase();
    // Proveedores nativos sin auth (bedrock aws_sdk, etc.) tienen authType propio.
    // Los proveedores custom configurados desde la app tienen slug "custom" o
    // authType "none"/"custom"/vacío y normalmente tienen una base_url.
    return at.isEmpty ||
        at == 'none' ||
        at == 'custom' ||
        p.slug == 'custom' ||
        p.baseUrl.isNotEmpty;
  }

  /// ¿El proveedor se puede desconectar (tiene key o es OAuth)?
  bool _canDisconnect(ModelProvider p) =>
      (p.keyEnv.isNotEmpty || _isOAuthProvider(p)) && !_isCustomUrlProvider(p);

  /// Login OAuth (device_code: OpenAI Codex/ChatGPT, Nous, MiniMax). Inicia el
  /// flujo, abre la URL de verificación y sondea hasta completar.
  Future<void> _startOAuthLogin(ModelProvider provider) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    setState(() => _setting = true);
    Map<String, dynamic> start;
    final oauthProviderId = _oauthProviderId(provider);
    try {
      start = await _client.startOAuth(oauthProviderId);
      if (kDebugMode) {
        debugPrint(
          'OAuth start ${provider.slug}/$oauthProviderId: keys=${start.keys.toList()}',
        );
      }
    } catch (e) {
      if (mounted) {
        final s = Strings.of(context);
        setState(() => _setting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.mdlOAuthStartError(localizedApiError(s, e))),
          ),
        );
      }
      return;
    }
    if (mounted) setState(() => _setting = false);
    final sessionId = _firstOAuthString(start, const [
      'session_id',
      'session',
      'poll_id',
      'device_code',
      'state',
    ]);
    final rawUrl = _firstOAuthString(start, const [
      'verification_uri_complete',
      'verification_url_complete',
      'auth_url',
      'authorization_url',
      'login_url',
      'verification_url',
      'verification_uri',
      'url',
    ]);
    final url = _normalizeOAuthBrowserUrl(rawUrl);
    final code = _firstOAuthString(start, const ['user_code', 'code']);
    if (sessionId.isEmpty || url.isEmpty || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).mdlOAuthNotAvailable(provider.name),
            ),
          ),
        );
      }
      return;
    }
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _OAuthLoginScreen(
          providerName: provider.name,
          providerSlug: oauthProviderId,
          url: url,
          code: code,
          expiresIn: (start['expires_in'] as num?)?.toInt() ?? 0,
          poll: () => _client.pollOAuth(oauthProviderId, sessionId),
        ),
      ),
    );
    if (ok == true && mounted) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).mdlProviderConnected(provider.name),
            ),
          ),
        );
      }
    }
  }

  static String _firstOAuthString(
    Map<String, dynamic> data,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  String _normalizeOAuthBrowserUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return rawUrl;
    // Agente on-device (Termux): el callback OAuth corre en ESTE mismo
    // dispositivo, así que `localhost` en el redirect_uri ya apunta a la máquina
    // correcta. Reescribir host/puerto al del dashboard rompe flujos con puerto
    // fijo registrado — caso OpenAI Codex, cuyo callback escucha en
    // localhost:1455 (único redirect_uri permitido por su client_id): tras
    // reescribirlo a :9119 el código nunca llega al listener → el poll se queda
    // "pending" y la app acaba diciendo "login no completado / no aprobado".
    if (widget.connection.onDeviceLoopback) return rawUrl;
    final dashboard = Uri.tryParse(_client.baseUrl);
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

  Future<void> _setFallback(List<Map<String, String>> providers) async {
    final client = await _bridgeMgr.clientFor(widget.connection.id);
    if (client == null) return;
    setState(() => _setting = true);
    try {
      await client.setFallback(providers);
      await _loadFallback();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              providers.isEmpty
                  ? Strings.of(context).mdlFallbackDisabled
                  : Strings.of(
                      context,
                    ).mdlFallbackActive(providers.first['model']!),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final s = Strings.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.commonError(localizedApiError(s, e)))),
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _setting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: _profile.isEmpty
            ? Text(s.mdlTitle)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.mdlTitle),
                  Text(
                    s.mdlProfile(_profile),
                    style: TextStyle(fontSize: 11, color: colors.accent),
                  ),
                ],
              ),
        actions: [
          // Contador "N ocultos" (proveedores + modelos): siempre visible
          // mientras haya algo oculto, para que lo escondido no parezca
          // borrado; lleva al toggle "ver ocultos" (spec 028 U-02/U-05).
          if (_hiddenItemCount > 0)
            Tooltip(
              message: _showHidden
                  ? Strings.of(context).mdlHideHiddenTip
                  : Strings.of(context).mdlShowHiddenTip,
              child: TextButton.icon(
                onPressed: () => setState(() => _showHidden = !_showHidden),
                icon: Icon(
                  _showHidden ? Icons.visibility_off : Icons.visibility,
                  size: 16,
                  color: _showHidden ? colors.accent : colors.textSecondary,
                ),
                label: Text(
                  Strings.of(context).mdlHiddenCount(_hiddenItemCount),
                  style: TextStyle(
                    fontSize: 12,
                    color: _showHidden ? colors.accent : colors.textSecondary,
                  ),
                ),
              ),
            ),
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
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(HermesThemeColors colors) {
    final s = Strings.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    // Fallback: la gestión del Dashboard falló pero el gateway sí listó modelos
    // con el mismo token. Mostramos la lista (solo lectura) para que se vean.
    if (_error != null && _activeInfo == null && _fallbackModels.isNotEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 20, color: colors.warning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.mdlGatewayFallbackTitle,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          s.mdlGatewayFallbackHint,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              s.mdlAvailableModels,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            for (final m in _fallbackModels)
              _ModelTonalGroup(
                margin: const EdgeInsets.only(bottom: 8),
                child: HermesListRow(
                  icon: Icons.memory_rounded,
                  iconColor: colors.accentHover,
                  title: m,
                  selected: m == _fallbackSelected,
                  trailing: m == _fallbackSelected
                      ? Icon(
                          Icons.check_rounded,
                          color: colors.accentHover,
                          semanticLabel: s.mdlActiveLabel,
                        )
                      : null,
                  onTap: () => _applyFallbackModel(m),
                ),
              ),
            const SizedBox(height: 16),
            Center(
              child: TextButton.icon(
                onPressed: _bootstrap,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(s.mdlRetry),
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null && _activeInfo == null) {
      final isOffline =
          _error!.contains('Connection refused') ||
          _error!.contains('SocketException') ||
          _error!.contains('errno = 111') ||
          _error!.contains('Connection reset');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOffline ? Icons.wifi_off_rounded : Icons.error_outline,
                size: 48,
                color: colors.warning,
              ),
              const SizedBox(height: 16),
              Text(
                isOffline ? s.mdlAgentOffline : s.mdlLoadError,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isOffline ? s.mdlAgentOfflineHint : s.mdlCheckConnection,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textSecondary,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _bootstrap,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(s.mdlRetry),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Filtro de ocultos: salvo que se pidan ver, los proveedores que el usuario
    // ocultó no aparecen en ninguna de las dos listas.
    bool visible(ModelProvider p) => _showHidden || !_hidden.contains(p.slug);

    final authProviders =
        _providers.where((p) => p.authenticated && visible(p)).toList()
          ..sort((a, b) {
            if (a.isCurrent && !b.isCurrent) return -1;
            if (!a.isCurrent && b.isCurrent) return 1;
            return a.name.compareTo(b.name);
          });
    final unauthProviders =
        _providers.where((p) => !p.authenticated && visible(p)).toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    return RefreshIndicator(
      color: colors.accentHover,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (widget.connection.kind != InstanceKind.localhost)
            BridgeUpdateBanner(
              bridge: _bridge,
              connection: widget.connection,
              onUpdated: _bootstrap,
            ),
          // El catálogo vivo del Dashboard falló: se avisa en vez de callar
          // (antes la sección de login desaparecía sin rastro) (spec 028 U-02).
          if (_supplementFailed) _buildSupplementErrorCard(colors),
          // (spec 028 punto 2) Solo se afirma "modelo ACTIVO" si de verdad hay
          // un proveedor con credencial detrás. En un servidor recién instalado
          // sin API keys, /api/model/info devuelve el `model.default` del
          // config.yaml (p.ej. claude-opus-4.6 o el preset Mixture of Agents)
          // aunque no sea usable: en ese caso NO se pinta la tarjeta de activo;
          // si además no hay ningún proveedor autenticado se muestra un aviso
          // claro de "sin modelo configurado" en su lugar.
          if (_activeInfo != null && _shouldShowActiveCard(_activeInfo!))
            if (_activeModelUsable(_activeInfo!))
              _buildActiveCard(colors, _activeInfo!)
            else if (!_providers.any((p) => p.authenticated))
              _buildNoActiveModelCard(colors),
          if (_fallbackAvailable) _buildFallbackCard(colors),
          if (_auxTasks.isNotEmpty) _buildAuxSection(colors),
          if (authProviders.isNotEmpty) ...[
            _buildSectionHeader(colors, s.mdlMainProviders),
            HermesListSection(
              margin: const EdgeInsets.only(bottom: 8),
              children: [
                for (final provider in authProviders)
                  _buildProviderTile(colors, provider),
              ],
            ),
          ],
          if (unauthProviders.isNotEmpty)
            _buildUnauthSection(colors, unauthProviders),
          _buildExternalProviderTile(colors),
        ],
      ),
    );
  }

  /// Fila informativa cuando el catálogo vivo del Dashboard no respondió
  /// (spec 028 U-02). Sustituye al antiguo fallo silencioso: explica qué
  /// falta, aclara si lo mostrado es el último catálogo guardado y ofrece
  /// reintentar la carga completa.
  /// Compacta un error para mostrarlo en una línea de tarjeta.
  String? _shortError(Object? e) {
    if (e == null) return null;
    final message = localizedApiError(
      Strings.of(context),
      e,
    ).replaceAll('\n', ' ').trim();
    return message.length > 180 ? '${message.substring(0, 180)}…' : message;
  }

  Widget _buildSupplementErrorCard(HermesThemeColors colors) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: colors.warning.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, size: 18, color: colors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Strings.of(context).mdlCatalogLoadFailed,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _catalogFromCache
                        ? Strings.of(context).mdlCatalogFromCache
                        : Strings.of(context).mdlCatalogNoDashboard,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textSecondary,
                      height: 1.3,
                    ),
                  ),
                  if (_supplementDetail != null) ...[
                    const SizedBox(height: 3),
                    // Motivo técnico crudo (sin l10n a propósito): es el dato
                    // que permite diagnosticar en el dispositivo (U-36).
                    Text(
                      _supplementDetail!,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: colors.warning.withValues(alpha: 0.9),
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            TextButton(
              onPressed: _loading ? null : _bootstrap,
              child: Text(
                Strings.of(context).mdlRetry,
                style: TextStyle(fontSize: 12, color: colors.accentHover),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tile que abre la pantalla de configuración de proveedor externo:
  /// Ollama remoto, LM Studio, OpenAI-compatible, custom.
  Widget _buildExternalProviderTile(HermesThemeColors colors) {
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.accent.withValues(alpha: 0.4), width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context)
            .push<bool>(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) =>
                    ExternalProviderScreen(connection: widget.connection),
              ),
            )
            .then((changed) {
              if (changed == true && mounted) _load();
            }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.4),
                  ),
                ),
                child: Icon(
                  Icons.add_link_rounded,
                  size: 20,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Strings.of(context).mdlExternalProvider,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.accentHover,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Strings.of(context).mdlExternalProviderSubtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }

  /// Para instancias locales sólo mostramos el modelo activo si es un modelo
  /// Ollama real (provider "custom" o "ollama"). El agente Hermes recién
  /// instalado puede reportar claude-sonnet u otro modelo cloud como su default
  /// antes de que el usuario configure Ollama; en ese caso no mostramos nada
  /// para no dar la impresión de que hay un modelo cloud funcionando.
  bool _shouldShowActiveCard(ModelActiveInfo info) {
    if (widget.connection.kind != InstanceKind.localhost) return true;
    final p = info.provider.toLowerCase();
    return p == 'custom' || p == 'ollama';
  }

  /// (spec 028 punto 2) ¿El modelo activo declarado por el servidor es de verdad
  /// usable? En un servidor virgen sin API keys, /api/model/info devuelve el
  /// `model.default` del config.yaml (claude-opus-4.6, el preset Mixture of
  /// Agents…) aunque NO haya ningún proveedor con credencial detrás. Solo se
  /// considera usable si un proveedor AUTENTICADO lo respalda (por slug/nombre o
  /// porque el modelo está en su catálogo). También vía bridge: el atajo
  /// "bridge ⇒ activo real" era FALSO — el bridge también reporta el default
  /// del config (claude-opus-4.6 en un servidor virgen), y desde el 1.11.0
  /// (picker_hints) su catálogo trae los `authenticated` reales, así que
  /// aplica la misma comprobación (U-32).
  bool _activeModelUsable(ModelActiveInfo info) {
    final prov = info.provider.trim().toLowerCase();
    final model = info.model.trim().toLowerCase();
    for (final p in _providers) {
      if (!p.authenticated) continue;
      if (prov.isNotEmpty &&
          (p.slug.toLowerCase() == prov || p.name.toLowerCase() == prov)) {
        return true;
      }
      if (model.isNotEmpty && p.models.any((m) => m.toLowerCase() == model)) {
        return true;
      }
    }
    return false;
  }

  /// (spec 028 punto 2) Sustituye a la tarjeta de "modelo activo" cuando el
  /// servidor declara un modelo por defecto pero NINGÚN proveedor tiene
  /// credencial: deja claro que no hay nada usable todavía en vez de fingir un
  /// modelo listo. El catálogo nativo (abajo) sigue visible para configurarlo.
  Widget _buildNoActiveModelCard(HermesThemeColors colors) {
    final s = Strings.of(context);
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.divider, width: 1),
      ),
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
                    s.mdlNoActiveModelBody,
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
  }

  Widget _buildActiveCard(HermesThemeColors colors, ModelActiveInfo info) {
    final s = Strings.of(context);
    final ctx = info.effectiveContextLength;
    final ctxLabel = ctx > 1000
        ? s.mdlCtxKTokens((ctx / 1024).round().toString())
        : s.mdlCtxTokens(ctx.toString());

    return _ModelTonalGroup(
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
                    color: colors.textDisabled,
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
            Text(
              info.model,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.accentHover,
              ),
            ),
            if (info.provider.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                info.provider,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              ctxLabel,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textDisabled),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackCard(HermesThemeColors colors) {
    final s = Strings.of(context);
    final has = _fallback.isNotEmpty;
    final fb = has ? _fallback.first : null;
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(bottom: 8),
      child: HermesListRow(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        icon: Icons.alt_route,
        iconColor: colors.accentHover,
        title: s.mdlFallbackTitle,
        subtitle: has ? '${fb!['model']} · ${fb['provider']}' : s.mdlNoFallback,
        trailing: has
            ? IconButton(
                icon: Icon(Icons.close, size: 18, color: colors.textDisabled),
                tooltip: s.mdlRemoveFallback,
                onPressed: _setting ? null : () => _setFallback([]),
              )
            : Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
        onTap: _setting ? null : _pickFallback,
      ),
    );
  }

  /// "Modelos por función" colapsado en un desplegable (cerrado por defecto).
  Widget _buildAuxSection(HermesThemeColors colors) {
    final s = Strings.of(context);
    final customized = _auxTasks.where((t) {
      final p = (t['provider'] ?? 'auto').toString();
      return p.isNotEmpty && p != 'auto';
    }).length;
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Icon(Icons.tune, color: colors.accent),
        title: Text(
          s.mdlAuxSection,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        subtitle: Text(
          customized == 0
              ? s.mdlAuxAllAuto
              : s.mdlAuxCustomized(customized, _auxTasks.length),
          style: TextStyle(fontSize: 11, color: colors.textDisabled),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          if (customized > 0)
            ListTile(
              dense: true,
              leading: Icon(Icons.auto_mode, size: 18, color: colors.accent),
              title: Text(
                s.mdlAuxResetAll,
                style: TextStyle(fontSize: 12.5, color: colors.accentHover),
              ),
              onTap: _setting ? null : _resetAux,
            ),
          ..._auxTasks.map((t) => _buildAuxTile(colors, t)),
        ],
      ),
    );
  }

  /// "Proveedores sin configurar" colapsado en un desplegable.
  Widget _buildUnauthSection(
    HermesThemeColors colors,
    List<ModelProvider> providers,
  ) {
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Icon(Icons.lock_outline, color: colors.textDisabled),
        title: Text(
          Strings.of(context).mdlUnconfiguredProviders,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        subtitle: Text(
          // Con el Dashboard caído se enseña el último catálogo bueno,
          // dejándolo claro para no fingir datos en vivo (spec 028 U-02).
          _catalogFromCache
              ? '${Strings.of(context).mdlUnconfiguredHint(providers.length)} · ${Strings.of(context).mdlCatalogOfflineSuffix}'
              : Strings.of(context).mdlUnconfiguredHint(providers.length),
          style: TextStyle(fontSize: 11, color: colors.textDisabled),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: providers.map((p) => _buildUnauthTile(colors, p)).toList(),
      ),
    );
  }

  Widget _buildAuxTile(HermesThemeColors colors, Map<String, dynamic> task) {
    final s = Strings.of(context);
    final slot = task['task'] as String? ?? '';
    final provider = task['provider'] as String? ?? 'auto';
    final model = task['model'] as String? ?? '';
    final isAuto = provider == 'auto' || provider.isEmpty;
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(bottom: 6),
      child: HermesListRow(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        icon: Icons.route_outlined,
        title: _auxLabel(slot, s),
        subtitle: isAuto ? s.mdlAuxAutoMain : '$model · $provider',
        trailing: Icon(
          Icons.chevron_right,
          size: 18,
          color: colors.textDisabled,
        ),
        onTap: _setting ? null : () => _pickModelForTask(slot),
      ),
    );
  }

  Widget _buildSectionHeader(HermesThemeColors colors, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colors.textDisabled,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Future<void> _discoverCustomModels(ModelProvider provider) async {
    final slug = provider.slug;
    if (_liveLoading.contains(slug) || _liveModels.containsKey(slug)) return;
    final base = provider.baseUrl.isNotEmpty
        ? provider.baseUrl
        : _inferUrl(provider.name);
    if (base.isEmpty) return;
    if (!mounted) return;
    setState(() => _liveLoading.add(slug));
    try {
      List<String> models = [];
      // Intenta OpenAI-compatible primero, luego /api/tags (Ollama nativo).
      final r1 = await http
          .get(Uri.parse('$base/v1/models'))
          .timeout(const Duration(seconds: 6));
      if (r1.statusCode == 200) {
        final data = jsonDecode(r1.body);
        if (data is Map) {
          final list = data['data'];
          if (list is List) {
            models = list
                .whereType<Map>()
                .map((m) => (m['id'] ?? '').toString().trim())
                .where((id) => id.isNotEmpty)
                .toList();
          }
        }
      }
      if (models.isEmpty) {
        final r2 = await http
            .get(Uri.parse('$base/api/tags'))
            .timeout(const Duration(seconds: 6));
        if (r2.statusCode == 200) {
          final data = jsonDecode(r2.body);
          if (data is Map) {
            final list = data['models'];
            if (list is List) {
              models = list
                  .whereType<Map>()
                  .map((m) => (m['name'] ?? '').toString().trim())
                  .where((id) => id.isNotEmpty)
                  .toList();
            }
          }
        }
      }
      if (mounted && models.isNotEmpty) {
        setState(() => _liveModels[slug] = models);
      }
    } catch (_) {
      // Fallo silencioso: el tile sigue mostrando los modelos del config.
    } finally {
      if (mounted) setState(() => _liveLoading.remove(slug));
    }
  }

  Widget _buildProviderTile(HermesThemeColors colors, ModelProvider provider) {
    final s = Strings.of(context);
    return Builder(
      builder: (context) {
        final live = _liveModels[provider.slug];
        // Filtro de modelos ocultos (spec 028 U-05): mismo criterio que los
        // proveedores — sin DELETE server-side, "eliminar" = ocultar en la
        // vista; con "ver ocultos" reaparecen atenuados con "Restaurar".
        final displayModels = (live ?? provider.models)
            .where((m) => _showHidden || !_isModelHidden(provider.slug, m))
            .toList();
        final isLoadingLive = _liveLoading.contains(provider.slug);
        return ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          backgroundColor: provider.isCurrent
              ? colors.accent.withValues(alpha: 0.05)
              : Colors.transparent,
          collapsedBackgroundColor: provider.isCurrent
              ? colors.accent.withValues(alpha: 0.05)
              : Colors.transparent,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          onExpansionChanged: _isCustomUrlProvider(provider)
              ? (expanded) {
                  if (expanded) _discoverCustomModels(provider);
                }
              : null,
          title: Row(
            children: [
              Expanded(
                child: Text(
                  provider.name,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (isLoadingLive)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: colors.textDisabled,
                  ),
                )
              else if (displayModels.isNotEmpty)
                Text(
                  s.mdlModelCount(displayModels.length),
                  style: TextStyle(fontSize: 11, color: colors.textDisabled),
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
            // Mixture of Agents (spec 029): además de seleccionar un preset,
            // se puede ver y editar la receta del comité desde una pantalla
            // propia. Solo para el proveedor virtual "moa".
            if (provider.slug == 'moa')
              ListTile(
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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        MoaRecipeScreen(connection: widget.connection),
                  ),
                ),
              ),
            ...displayModels.map((modelId) {
              final isActive =
                  _activeInfo?.model == modelId &&
                  _activeInfo?.provider == provider.slug;
              // Solo puede llegar aquí oculto con "ver ocultos" activo: se
              // muestra atenuado y con "Restaurar" a un toque (spec 028 U-05).
              final hiddenModel = _isModelHidden(provider.slug, modelId);
              return HermesListRow(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                icon: hiddenModel
                    ? Icons.visibility_off_outlined
                    : Icons.memory_outlined,
                title: modelId,
                selected: isActive,
                semanticHint: hiddenModel
                    ? Strings.of(context).mdlRestore
                    : null,
                trailing: hiddenModel
                    ? TextButton(
                        onPressed: () =>
                            _setModelHidden(provider.slug, modelId, false),
                        child: Text(
                          Strings.of(context).mdlRestore,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.accentHover,
                          ),
                        ),
                      )
                    : (isActive
                          ? Icon(
                              Icons.check_circle,
                              color: colors.accent,
                              size: 18,
                            )
                          : Icon(
                              Icons.radio_button_unchecked,
                              color: colors.textDisabled,
                              size: 18,
                            )),
                onTap: _setting || hiddenModel
                    ? null
                    : () => _selectModel(
                        provider.slug,
                        modelId,
                        providerBaseUrl: provider.baseUrl,
                      ),
                // Pulsación larga: ocultar el modelo de la lista, con Deshacer
                // en el snackbar (spec 028 U-05).
                onLongPress: hiddenModel
                    ? null
                    : () => _hideModel(provider, modelId),
              );
            }),
            // Reautenticar cuando el token falla/caduca (= hermes auth add) o
            // actualizar la API key sin desconectar.
            if (_isOAuthProvider(provider))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(Icons.refresh, size: 17, color: colors.accent),
                title: Text(
                  s.mdlReconnect,
                  style: TextStyle(fontSize: 12.5, color: colors.accentHover),
                ),
                subtitle: Text(
                  s.mdlReconnectHint,
                  style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
                ),
                onTap: _setting ? null : () => _startOAuthLogin(provider),
              )
            else if (provider.keyEnv.isNotEmpty)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(
                  Icons.key_outlined,
                  size: 17,
                  color: colors.accent,
                ),
                title: Text(
                  s.mdlUpdateKey,
                  style: TextStyle(fontSize: 12.5, color: colors.accentHover),
                ),
                onTap: _setting ? null : () => _configureProviderKey(provider),
              ),
            if (_canDisconnect(provider))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(
                  Icons.link_off,
                  size: 17,
                  color: colors.error.withValues(alpha: 0.85),
                ),
                title: Text(
                  s.mdlDisconnectProvider,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.error.withValues(alpha: 0.85),
                  ),
                ),
                onTap: _setting ? null : () => _disconnectProvider(provider),
              ),
            // Proveedor externo (URL propia): ofrecer editar / eliminar.
            if (_isCustomUrlProvider(provider)) ...[
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(
                  Icons.edit_outlined,
                  size: 17,
                  color: colors.accent,
                ),
                title: Text(
                  s.mdlEditProvider,
                  style: TextStyle(fontSize: 12.5, color: colors.accentHover),
                ),
                onTap: _setting
                    ? null
                    : () => Navigator.of(context)
                          .push<bool>(
                            MaterialPageRoute(
                              fullscreenDialog: true,
                              builder: (_) => ExternalProviderScreen(
                                connection: widget.connection,
                                prefillUrl: provider.baseUrl.isNotEmpty
                                    ? provider.baseUrl
                                    : _inferUrl(provider.name),
                                prefillName: provider.name,
                                isEditing: true,
                              ),
                            ),
                          )
                          .then((changed) {
                            if (changed == true && mounted) _load();
                          }),
              ),
            ],
            _hideTile(colors, provider),
          ],
        );
      },
    );
  }

  /// Fila para ocultar/mostrar un proveedor de la lista de la app. No toca el
  /// servidor: es la única vía para quitar de la vista los proveedores de
  /// fábrica que no se pueden borrar (p. ej. Mixture of Agents). Reversible.
  Widget _hideTile(HermesThemeColors colors, ModelProvider provider) {
    final hidden = _hidden.contains(provider.slug);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(
        hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        size: 17,
        color: colors.textSecondary,
      ),
      title: Text(
        hidden
            ? Strings.of(context).mdlShowInList
            : Strings.of(context).mdlHideFromList,
        style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
      ),
      // Descubribilidad del gesto por modelo (spec 028 U-05): la fila de
      // ocultar el proveedor es el sitio natural donde buscarlo.
      subtitle: provider.models.isNotEmpty
          ? Text(
              Strings.of(context).mdlLongPressToHide,
              style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
            )
          : null,
      onTap: () => _setHidden(provider.slug, !hidden),
    );
  }

  /// Intenta inferir la URL base del nombre del proveedor (p.ej. "192.168.1.10:11434"
  /// → "http://192.168.1.10:11434"). Fallback a vacío.
  static String _inferUrl(String name) {
    if (name.startsWith('http://') || name.startsWith('https://')) return name;
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+:\d+$').hasMatch(name)) {
      return 'http://$name';
    }
    if (RegExp(r'^[\w.-]+:\d+$').hasMatch(name)) return 'http://$name';
    return '';
  }

  /// (spec 028 punto 5) La gestión de proveedores (pegar API key, iniciar
  /// OAuth) SIEMPRE va por el Dashboard (`_client`). Si el catálogo vivo falló
  /// (bridge-first con Dashboard inaccesible), el catálogo nativo se sigue
  /// mostrando desde caché pero NO se puede configurar: las acciones se
  /// deshabilitan. `_supplementFailed` marca justo ese caso.
  bool get _dashboardConfigDown => _supplementFailed;

  Widget _buildUnauthTile(HermesThemeColors colors, ModelProvider provider) {
    final s = Strings.of(context);
    final canLogin = _canLoginInApp(provider);
    final isOAuth = _isOAuthProvider(provider);
    final hasKey = provider.keyEnv.isNotEmpty;
    // Acción correcta por tipo de auth (verificado contra el agente):
    //  - OAuth in-app (device_code/loopback/minimax) → login.
    //  - api_key con env var → configurar (pegar la clave).
    //  - OAuth externo (qwen-oauth, gemini-cli) → requiere CLI del proveedor en
    //    el servidor; NO login in-app.
    //  - resto (aws_sdk Bedrock, external_process, api_key sin env como
    //    openrouter/custom) → se configura en el servidor. Sin botón "login"
    //    (daría error, p.ej. el 400 de Bedrock).
    final String subtitle;
    if (canLogin) {
      subtitle = provider.warning.isNotEmpty
          ? provider.warning
          : s.mdlLoginOAuth;
    } else if (hasKey) {
      subtitle = provider.warning.isNotEmpty
          ? provider.warning
          : s.mdlNeedsKey(provider.keyEnv);
    } else if (isOAuth) {
      subtitle = provider.warning.isNotEmpty
          ? provider.warning
          : s.mdlOAuthExternal;
    } else {
      subtitle = provider.warning.isNotEmpty
          ? provider.warning
          : s.mdlConfigureOnServer;
    }
    Widget? trailing;
    if (_dashboardConfigDown) {
      // (spec 028 punto 5) El catálogo nativo SIGUE visible aunque el Dashboard
      // no responda (se muestra desde caché), pero configurar/añadir key va por
      // el Dashboard: sin él, la acción se deshabilita con aviso en vez de
      // fingir que funciona y fallar al pulsarla. NO se oculta el proveedor.
      trailing = Tooltip(
        message: s.mdlConfigNeedsDashboard,
        child: Icon(
          Icons.cloud_off_rounded,
          size: 16,
          color: colors.textDisabled,
        ),
      );
    } else if (canLogin) {
      trailing = TextButton.icon(
        onPressed: _setting ? null : () => _startOAuthLogin(provider),
        icon: const Icon(Icons.login, size: 15),
        label: Text(s.mdlLoginBtn, style: const TextStyle(fontSize: 12)),
      );
    } else if (hasKey) {
      trailing = TextButton.icon(
        onPressed: _setting ? null : () => _configureProviderKey(provider),
        icon: const Icon(Icons.key_outlined, size: 15),
        label: Text(s.mdlConfigureBtn, style: const TextStyle(fontSize: 12)),
      );
    } else {
      // Sin acción in-app; lo indica el subtítulo.
      trailing = Icon(
        Icons.terminal_rounded,
        size: 16,
        color: colors.textDisabled,
      );
    }
    return _ModelTonalGroup(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.divider, width: 1),
      ),
      child: HermesListRow(
        icon: Icons.lock_outline,
        iconColor: colors.textDisabled,
        title: provider.name,
        subtitle: _dashboardConfigDown
            ? '$subtitle · ${s.mdlDashboardOfflineSuffix}'
            : subtitle,
        trailing: trailing,
        // Pulsación larga: ocultar/mostrar este proveedor de la lista de la app.
        onLongPress: () {
          final hidden = _hidden.contains(provider.slug);
          _setHidden(provider.slug, !hidden);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(milliseconds: 1400),
              content: Text(
                hidden
                    ? Strings.of(context).mdlProviderVisibleAgain(provider.name)
                    : Strings.of(context).mdlProviderHidden(provider.name),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Pantalla del flujo OAuth device_code, pensada para conectar de un toque:
/// auto-copia el código, auto-abre el navegador y sondea hasta completar.
/// El token NUNCA pasa por la app: el agente lo obtiene y guarda en el servidor;
/// la app solo muestra el código y consulta el estado.
class _ModelTonalGroup extends StatelessWidget {
  final EdgeInsetsGeometry margin;
  final ShapeBorder? shape;
  final Widget child;

  const _ModelTonalGroup({
    this.margin = EdgeInsets.zero,
    this.shape,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final content = shape == null
        ? child
        : ClipPath(
            clipper: ShapeBorderClipper(shape: shape!),
            child: child,
          );
    return HermesListSection(
      margin: margin,
      showDividers: false,
      children: [content],
    );
  }
}

class _OAuthLoginScreen extends StatefulWidget {
  final String providerName;
  final String providerSlug;
  final String url;
  final String code;
  final int expiresIn;
  final Future<Map<String, dynamic>> Function() poll;

  const _OAuthLoginScreen({
    required this.providerName,
    required this.providerSlug,
    required this.url,
    required this.code,
    required this.poll,
    this.expiresIn = 0,
  });

  @override
  State<_OAuthLoginScreen> createState() => _OAuthLoginScreenState();
}

class _OAuthLoginScreenState extends State<_OAuthLoginScreen> {
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
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: ListView(
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
                  style: TextStyle(fontSize: 11, color: colors.textDisabled),
                ),
                const Spacer(),
                if (expiryLabel.isNotEmpty)
                  Text(
                    expiryLabel,
                    style: TextStyle(fontSize: 11, color: colors.textDisabled),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: widget.code));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(s.mdlCodeCopied)));
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
          const SizedBox(height: 16),
          Text(
            s.mdlOAuthSecurityNote,
            style: TextStyle(fontSize: 11, color: colors.textDisabled),
          ),
        ],
      ),
    );
  }
}

/// Entrada de la API key de un proveedor, como RUTA del Navigator (no diálogo,
/// para no disparar el assert `_dependents.isEmpty` con un TextField enfocado).
class _ProviderKeyScreen extends StatefulWidget {
  final String providerName;
  final String keyEnv;
  const _ProviderKeyScreen({required this.providerName, required this.keyEnv});

  @override
  State<_ProviderKeyScreen> createState() => _ProviderKeyScreenState();
}

class _ProviderKeyScreenState extends State<_ProviderKeyScreen> {
  final _ctrl = TextEditingController();

  void _release() {
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.hasFocus) f.unfocus();
  }

  void _save() {
    _release();
    Navigator.of(context).pop(_ctrl.text.trim());
  }

  @override
  void deactivate() {
    _release();
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
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(widget.providerName),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _release();
            Navigator.of(context).pop();
          },
        ),
        actions: [TextButton(onPressed: _save, child: Text(s.mdlSave))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            s.mdlApiKeyTitle,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: colors.accentHover,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.mdlApiKeyHint(widget.keyEnv),
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: widget.keyEnv,
              hintText: s.mdlApiKeyHintText,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(s.mdlSaveKey),
          ),
        ],
      ),
    );
  }
}
