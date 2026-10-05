// Add/edit form for one custom endpoint (Ollama, LM Studio,
// OpenAI-compatible, custom). The saved list, activate and delete live in the
// Models screen (custom_endpoints_section.dart), like Desktop's
// custom-endpoints-settings.tsx. Full route (not a dialog) to avoid the
// _dependents.isEmpty assert with a focused TextField.
//
//  - Remote Hermes: "Test connection" asks Hermes to validate the URL from
//    its server (/api/providers/custom-endpoints/validate, or the older
//    /api/providers/validate). The phone never contacts the endpoint.
//  - Instance on this phone (InstanceKind.localhost): the phone is the
//    server, so it probes {base_url}/models itself (Ollama /api/tags as
//    fallback).
//  - Save stores the endpoint on the active profile; older servers without
//    the saved-endpoints route apply the model with model/set instead.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/bridge_manager.dart';
import '../services/connection_manager.dart';
import '../services/custom_endpoints_api.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../utils/transport_privacy.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';

// ── Provider type ────────────────────────────────────────────────────────────

/// Tipos de proveedor externo que la app puede configurar.
enum ExternalProviderType {
  ollama('Ollama', 'custom', 'http://192.168.x.x:11434/v1'),
  lmStudio('LM Studio', 'custom', 'http://192.168.x.x:1234/v1'),
  openAiCompat('OpenAI-compat.', 'custom', 'https://api.provider.example/v1'),
  custom('Custom', 'custom', 'http://host:port/v1');

  const ExternalProviderType(this.label, this.hermesProvider, this.urlHint);

  /// Label visible en la UI.
  final String label;

  /// Slug de proveedor para `model/set` en Hermes. "custom" es el slug para
  /// cualquier backend OpenAI-compatible (Ollama, LM Studio, etc.).
  final String hermesProvider;

  /// Placeholder de URL para el campo de texto.
  final String urlHint;
}

// ── URL helpers (públicos para tests) ────────────────────────────────────────

/// Normaliza la base_url que el usuario introduce:
/// - Quita espacios y barras finales.
/// - Conserva la ruta OpenAI-compatible completa, incluido `/v1`.
///
/// Hermes Desktop persiste exactamente la URL que se probó. Quitar `/v1`
/// aquí hacía que la prueba móvil y el runtime llamasen a rutas distintas.
String normalizeExternalProviderUrl(String raw) {
  final u = raw.trim().replaceAll(RegExp(r'/+$'), '');
  return u.isEmpty ? u : TransportPrivacy.requireAllowed(u);
}

/// Variantes que se prueban, en orden, sin guardar una URL distinta de la que
/// realmente anunció modelos. Una raíz (`:11434`) conserva compatibilidad con
/// entradas antiguas y después intenta el contrato OpenAI (`:11434/v1`).
List<String> externalProviderBaseUrlCandidates(String raw) {
  final exact = normalizeExternalProviderUrl(raw);
  if (exact.isEmpty || exact.endsWith('/v1')) return [exact];
  return [exact, '$exact/v1'];
}

typedef ExternalProviderProbe = ({String baseUrl, List<String> models});

/// Recorre las variantes compatibles y conserva la URL exacta que respondió.
/// Los fallos de una raíz sin `/v1` no impiden probar su variante OpenAI.
Future<ExternalProviderProbe> probeExternalProviderCandidates(
  String inputBase,
  Future<List<String>> Function(String baseUrl) fetchModels,
) async {
  Object? lastError;
  for (final candidate in externalProviderBaseUrlCandidates(inputBase)) {
    try {
      final models = await fetchModels(candidate);
      if (models.isNotEmpty) return (baseUrl: candidate, models: models);
    } catch (error) {
      lastError = error;
    }
  }
  if (lastError != null) throw lastError;
  return (baseUrl: inputBase, models: const <String>[]);
}

/// Convierte errores de socket/HTTP en mensajes legibles para el usuario.
String humanizeProviderTestError(Strings s, String e) {
  if (e.contains('Connection refused') || e.contains('errno = 111')) {
    return s.extErrRefused;
  }
  if (e.contains('Failed host lookup') ||
      e.contains('getaddrinfo') ||
      e.contains('SocketException')) {
    return s.extErrDns;
  }
  if (e.contains('TimeoutException') || e.contains('timed out')) {
    return s.extErrTimeout;
  }
  if (e.contains('HandshakeException') || e.contains('CERTIFICATE')) {
    return s.extErrTls;
  }
  if (e.contains('HTTP 401') || e.contains('401')) {
    return s.extErrUnauthorized;
  }
  if (e.contains('HTTP 403')) {
    return s.extErrForbidden;
  }
  if (e.contains('HTTP 5')) {
    return s.extErrServer;
  }
  return e.length > 220 ? '${e.substring(0, 220)}…' : e;
}

/// Extrae el detalle útil de un 400/422 del Dashboard sin exponer una clave
/// que un servidor remoto pudiera haber incluido en su mensaje de error.
String humanizeExternalProviderError(Object error) {
  var safe = error is DashboardHttpException
      ? humanizeApiError(Exception('HTTP ${error.statusCode}: ${error.body}'))
      : humanizeApiError(error);
  safe = safe.replaceAll(
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{6,}', caseSensitive: false),
    'Bearer [redacted]',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(api[_ -]?key|token|password)\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[redacted]',
  );
  safe = safe.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{6,}\b'), '[redacted]');
  return safe.length > 220 ? '${safe.substring(0, 220)}…' : safe;
}

// ── Screen ───────────────────────────────────────────────────────────────────

class ExternalProviderScreen extends StatefulWidget {
  final SavedConnection connection;
  final String profile;

  /// Dashboard client shared with the caller (the Models screen); not closed
  /// by this form.
  final DashboardClient? dashboard;
  final DashboardClient? dashboardClientForTesting;

  /// URL pre-cargada cuando se abre en modo edición.
  final String? prefillUrl;

  /// Nombre/label pre-cargado cuando se abre en modo edición.
  final String? prefillName;

  /// Shows the edit title instead of "Add endpoint".
  final bool isEditing;

  /// Saved endpoint being edited, from the Models custom endpoints section.
  final CustomEndpoint? endpoint;

  /// HTTP client for the phone-side probe, used only for an instance on this
  /// phone ([InstanceKind.localhost]).
  @visibleForTesting
  final http.Client? probeClientForTesting;

  const ExternalProviderScreen({
    required this.connection,
    this.profile = '',
    this.dashboard,
    this.dashboardClientForTesting,
    this.prefillUrl,
    this.prefillName,
    this.isEditing = false,
    this.endpoint,
    this.probeClientForTesting,
    super.key,
  });

  @override
  State<ExternalProviderScreen> createState() => _ExternalProviderScreenState();
}

class _ExternalProviderScreenState extends State<ExternalProviderScreen> {
  ExternalProviderType _type = ExternalProviderType.ollama;
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  bool _testing = false;
  List<String> _models = [];
  String? _testError;
  bool _setting = false;
  // Modelo activo local (tras el primer "Usar" exitoso, no cerramos la pantalla
  // para que el usuario pueda cambiar entre todos los modelos descubiertos).
  String? _activeModel;
  String? _testedInputBaseUrl;
  String? _resolvedBaseUrl;
  String? _testMessage;
  List<Map<String, dynamic>> _modelDetails = const [];

  late final DashboardClient _dashboard;
  late final bool _ownsDashboard;
  bool? _savedEndpointsSupported;
  CustomEndpoint? _editingEndpoint;
  bool _makeDefault = false;
  bool _changed = false;

  BridgeManager? _bridgeMgr;

  bool get _isLocal => widget.connection.kind == InstanceKind.localhost;

  @override
  void initState() {
    super.initState();
    final shared = widget.dashboard ?? widget.dashboardClientForTesting;
    _ownsDashboard = shared == null;
    _dashboard = shared ?? DashboardClient.lazy(widget.connection);
    if (widget.prefillUrl != null && widget.prefillUrl!.isNotEmpty) {
      _urlCtrl.text = widget.prefillUrl!;
    }
    if (widget.prefillName != null && widget.prefillName!.isNotEmpty) {
      _nameCtrl.text = widget.prefillName!;
    }
    final endpoint = widget.endpoint;
    if (endpoint != null) {
      // Opened from a saved row: the server has the saved-endpoints route.
      _savedEndpointsSupported = true;
      _editingEndpoint = endpoint;
      _nameCtrl.text = endpoint.name;
      _urlCtrl.text = endpoint.baseUrl;
      _models = endpoint.models;
      _activeModel = endpoint.model.isEmpty ? null : endpoint.model;
    } else {
      _detectSavedEndpoints();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bridgeMgr ??= context
        .findAncestorStateOfType<HermesAppState>()
        ?.bridgeManager;
  }

  @override
  void dispose() {
    if (_ownsDashboard) _dashboard.close();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  /// Whether this server stores endpoints per profile (Desktop's flow) or
  /// only accepts model/set (older servers).
  Future<void> _detectSavedEndpoints() async {
    try {
      final catalog = await _dashboard.listCustomEndpoints(
        profile: widget.profile,
      );
      if (mounted) setState(() => _savedEndpointsSupported = catalog != null);
    } catch (_) {
      if (mounted) setState(() => _savedEndpointsSupported = false);
    }
  }

  CustomEndpointDraft _endpointDraft({bool makeDefault = false}) =>
      CustomEndpointDraft(
        id: _editingEndpoint?.id ?? '',
        name: _nameCtrl.text,
        baseUrl: _urlCtrl.text,
        model: _activeModel ?? _editingEndpoint?.model ?? '',
        apiKey: _keyCtrl.text,
        apiMode: _editingEndpoint?.apiMode ?? '',
        contextLength: _editingEndpoint?.contextLength,
        discoverModels: _editingEndpoint?.discoverModels ?? true,
        makeDefault: makeDefault,
        models: _models,
        modelDetails: _modelDetails,
      );

  Future<void> _saveEndpoint() async {
    setState(() => _setting = true);
    try {
      await _dashboard.saveCustomEndpoint(
        _endpointDraft(makeDefault: _makeDefault),
        profile: widget.profile,
      );
      _changed = true;
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(humanizeExternalProviderError(error))),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  // ── Test connection ──────────────────────────────────────────────────────

  Future<void> _testConnection() async {
    final s = Strings.of(context);
    final rawUrl = _urlCtrl.text.trim();
    if (rawUrl.isEmpty) {
      setState(() => _testError = s.extUrlRequired);
      return;
    }
    final apiKey = _keyCtrl.text.trim();
    final headers = <String, String>{'Accept': 'application/json'};
    if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';

    setState(() {
      _testing = true;
      _testError = null;
      _testMessage = null;
      _models = [];
    });
    try {
      final inputBase = normalizeExternalProviderUrl(rawUrl);
      if (!_isLocal && _savedEndpointsSupported == true) {
        final validation = await _dashboard.validateCustomEndpoint(
          _endpointDraft(),
          profile: widget.profile,
        );
        if (!mounted) return;
        final resolved = validation.resolvedBaseUrl.trim();
        setState(() {
          if (resolved.isNotEmpty) _urlCtrl.text = resolved;
          _models = validation.models;
          _modelDetails = validation.modelDetails;
          _testedInputBaseUrl = inputBase;
          _resolvedBaseUrl = resolved.isEmpty ? inputBase : resolved;
          _testMessage = validation.message;
          _testError = validation.ok ? null : validation.message;
          _testing = false;
        });
        return;
      }
      final probe = _isLocal
          ? await _probeDirect(inputBase, headers)
          : await _probeFromHermes(inputBase, apiKey);
      if (!mounted) return;
      setState(() {
        _models = probe.models;
        _testedInputBaseUrl = inputBase;
        _resolvedBaseUrl = probe.baseUrl;
        _testError = probe.models.isEmpty ? s.extNoModels : null;
        _testing = false;
      });
    } on _ServerValidationUnavailable {
      if (!mounted) return;
      setState(() {
        _testError = s.extServerValidationUnavailable;
        _testing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testError = humanizeProviderTestError(
          s,
          humanizeExternalProviderError(e),
        );
        _testing = false;
      });
    }
  }

  Future<ExternalProviderProbe> _probeFromHermes(
    String inputBase,
    String apiKey,
  ) async {
    for (final candidate in externalProviderBaseUrlCandidates(inputBase)) {
      try {
        final result = await _dashboard.validateExternalProvider(
          baseUrl: candidate,
          apiKey: apiKey,
        );
        final models = (result['models'] as List? ?? const [])
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList();
        if (models.isNotEmpty) {
          return (baseUrl: candidate, models: models);
        }
        final reachable = result['reachable'] != false;
        final message = (result['message'] ?? '').toString().trim();
        if (!reachable && message.isNotEmpty) throw Exception(message);
      } on DashboardHttpException catch (error) {
        // Older Hermes without /api/providers/validate. The phone must not
        // probe a remote server's endpoint itself: what the phone reaches
        // says nothing about what Hermes reaches.
        if (error.statusCode != 404 && error.statusCode != 405) rethrow;
        throw _ServerValidationUnavailable();
      }
    }
    return (baseUrl: inputBase, models: const <String>[]);
  }

  /// Phone-side probe. Only for an instance on this phone.
  Future<ExternalProviderProbe> _probeDirect(
    String inputBase,
    Map<String, String> headers,
  ) {
    return probeExternalProviderCandidates(
      inputBase,
      (candidate) => _fetchModels(candidate, headers),
    );
  }

  Future<http.Response> _probeGet(Uri url, Map<String, String> headers) {
    final client = widget.probeClientForTesting;
    final request = client != null
        ? client.get(url, headers: headers)
        : http.get(url, headers: headers);
    return request.timeout(const Duration(seconds: 8));
  }

  /// Intenta `{base_url}/models`; si Ollama y falla, prueba `/api/tags` en la
  /// raíz. [base] es también la URL exacta que se persistirá si responde.
  Future<List<String>> _fetchModels(
    String base,
    Map<String, String> headers,
  ) async {
    final res = await _probeGet(Uri.parse('$base/models'), headers);
    if (res.statusCode == 200) {
      final models = _parseOpenAiModels(res.body);
      if (models.isNotEmpty) return models;
    }
    // Fallback Ollama: /api/tags (modelo descargados).
    if (_type == ExternalProviderType.ollama) {
      final root = base.endsWith('/v1')
          ? base.substring(0, base.length - 3)
          : base;
      final r = await _probeGet(Uri.parse('$root/api/tags'), headers);
      if (r.statusCode == 200) return _parseOllamaTags(r.body);
    }
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return const [];
  }

  static List<String> _parseOpenAiModels(String body) {
    try {
      final data = jsonDecode(body);
      if (data is! Map) return const [];
      final list = data['data'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => (m['id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint(
        '[external-provider] excepción silenciada (se devuelve lista vacía): $e',
      );
      return const [];
    }
  }

  static List<String> _parseOllamaTags(String body) {
    try {
      final data = jsonDecode(body);
      if (data is! Map) return const [];
      final list = data['models'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => (m['name'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint(
        '[external-provider] excepción silenciada (se devuelve lista vacía): $e',
      );
      return const [];
    }
  }

  // ── Use model ────────────────────────────────────────────────────────────

  Future<void> _useModel(String modelId) async {
    final s = Strings.of(context);
    setState(() => _setting = true);
    try {
      final inputBase = normalizeExternalProviderUrl(_urlCtrl.text.trim());
      final base = _testedInputBaseUrl == inputBase
          ? (_resolvedBaseUrl ?? inputBase)
          : inputBase;
      final apiKey = _keyCtrl.text.trim();
      if (_isLocal) {
        final client = await _bridgeMgr?.clientFor(widget.connection.id);
        if (client == null) {
          throw Exception(s.extBridgeUnavailable);
        }
        try {
          final r = await client.setModel(
            provider: _type.hermesProvider,
            model: modelId,
            modelBaseUrl: base,
            contextLength: 65536,
          );
          if (r['ok'] != true) {
            throw Exception(
              (r['error'] ?? r['message'] ?? s.extApplyRejected).toString(),
            );
          }
        } finally {
          client.close();
        }
      } else {
        final ok = await _dashboard.setActiveModel(
          providerSlug: _type.hermesProvider,
          modelId: modelId,
          baseUrl: base,
          apiKey: apiKey,
        );
        if (!ok) throw Exception(s.extApplyRejected);
      }
      if (!mounted) return;
      // No cerramos la pantalla: el usuario puede cambiar de modelo sin salir.
      setState(() => _activeModel = modelId);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).extActiveModel(modelId)),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = humanizeExternalProviderError(e);
      final isVenvBroken =
          msg.contains('hermes_cli') ||
          msg.contains('ModuleNotFoundError') ||
          msg.contains('No module named') ||
          msg.contains('ruamel_unavailable');
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isVenvBroken ? s.extVenvUnavailable : s.extApplyError(msg),
          ),
          duration: Duration(seconds: isVenvBroken ? 6 : 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(widget.isEditing ? s.extEditTitle : s.mdlAddEndpoint),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: s.commonClose,
          onPressed: () => Navigator.of(context).pop(_changed),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          HermesInfoBanner(
            _isLocal ? s.extReachabilityInfo : s.extServerReachabilityInfo,
            icon: Icons.info_outline,
          ),
          const SizedBox(height: 20),
          _label(s.extProviderType, colors),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ExternalProviderType.values.map((t) {
              final sel = _type == t;
              return ChoiceChip(
                label: Text(t.label),
                selected: sel,
                selectedColor: colors.accent.withValues(alpha: 0.18),
                side: BorderSide(color: sel ? colors.accent : colors.divider),
                labelStyle: TextStyle(
                  color: sel ? colors.accentHover : colors.textSecondary,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                ),
                onSelected: (_) => setState(() {
                  _type = t;
                  _models = [];
                  _testError = null;
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          HermesField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            label: 'Base URL',
            hint: _type.urlHint,
            helperText: s.extBaseUrlHelp,
            onChanged: (_) => setState(() {
              _models = [];
              _testError = null;
            }),
          ),
          const SizedBox(height: 16),
          if (!_isLocal) ...[
            HermesField(
              controller: _nameCtrl,
              autocorrect: false,
              enableSuggestions: false,
              label: s.extServerName,
              hint: s.extServerNameHint,
            ),
            const SizedBox(height: 16),
          ],
          HermesField(
            controller: _keyCtrl,
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
            label: s.extApiKeyOptional,
            hint: s.extApiKeyHint,
          ),
          const SizedBox(height: 20),
          if (_savedEndpointsSupported == true)
            OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(_testing ? s.commonTesting : s.extTestConnection),
            )
          else
            FilledButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onAccent,
                      ),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(
                _testing
                    ? Strings.of(context).commonTesting
                    : Strings.of(context).extTestConnection,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
              ),
            ),
          if (_testError != null) ...[
            const SizedBox(height: 12),
            _ErrorBanner(_testError!, colors),
          ],
          if (_testError == null &&
              _testMessage != null &&
              _testMessage!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            HermesInfoBanner(_testMessage!, icon: Icons.check_circle_outline),
          ],
          if (_models.isNotEmpty) ...[
            const SizedBox(height: 24),
            _label(s.extAvailableModels, colors),
            const SizedBox(height: 8),
            ..._models.map(
              (m) => _ModelTile(
                modelId: m,
                isActive: _activeModel == m,
                colors: colors,
                setting: _setting,
                onUse: _savedEndpointsSupported == true
                    ? () => setState(() {
                        _activeModel = m;
                        _makeDefault = true;
                      })
                    : () => _useModel(m),
              ),
            ),
          ],
          if (_savedEndpointsSupported == true) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _setting ? null : _saveEndpoint,
              icon: _setting
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onAccent,
                      ),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(
                !_makeDefault ? s.mdlEndpointSave : s.mdlEndpointSaveAndUse,
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static Widget _label(String text, HermesThemeColors colors) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colors.textDisabled,
      letterSpacing: 1.2,
    ),
  );
}

/// The server has no validation route and the instance is remote.
class _ServerValidationUnavailable implements Exception {}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  final HermesThemeColors colors;
  const _ErrorBanner(this.message, this.colors);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: colors.error.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: colors.error.withValues(alpha: 0.35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: colors.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 12.5, color: colors.error),
          ),
        ),
      ],
    ),
  );
}

class _ModelTile extends StatelessWidget {
  final String modelId;
  final bool isActive;
  final HermesThemeColors colors;
  final bool setting;
  final VoidCallback onUse;

  const _ModelTile({
    required this.modelId,
    required this.isActive,
    required this.colors,
    required this.setting,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: isActive ? colors.accent : colors.divider,
        width: isActive ? 1.5 : 1,
      ),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      title: Text(
        modelId,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
          color: isActive ? colors.accentHover : colors.textPrimary,
        ),
      ),
      trailing: setting
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          : isActive
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 16, color: colors.accent),
                const SizedBox(width: 6),
                Text(
                  Strings.of(context).extActive,
                  style: TextStyle(fontSize: 11, color: colors.accent),
                ),
              ],
            )
          : TextButton(
              onPressed: onUse,
              child: Text(
                Strings.of(context).extUse,
                style: TextStyle(fontSize: 12, color: colors.accent),
              ),
            ),
    ),
  );
}
