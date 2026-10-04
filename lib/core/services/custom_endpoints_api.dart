import 'connection_manager.dart';

String _profileQuery(String? profile) {
  final value = profile?.trim() ?? '';
  if (value.isEmpty || value == 'default') return '';
  return '?profile=${Uri.encodeQueryComponent(value)}';
}

final class CustomEndpoint {
  final String id;
  final String name;
  final String baseUrl;
  final String model;
  final List<String> models;
  final String apiMode;
  final int? contextLength;
  final bool discoverModels;
  final bool hasApiKey;
  final bool isCurrent;
  final String source;

  const CustomEndpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.models,
    required this.apiMode,
    required this.contextLength,
    required this.discoverModels,
    required this.hasApiKey,
    required this.isCurrent,
    required this.source,
  });

  factory CustomEndpoint.fromJson(Object? value) {
    final json = value is Map ? value.cast<String, dynamic>() : const {};
    final rawModels = json['models'];
    return CustomEndpoint(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['base_url'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      models: rawModels is List
          ? List<String>.unmodifiable(
              rawModels
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty),
            )
          : const [],
      apiMode: (json['api_mode'] ?? '').toString(),
      contextLength: json['context_length'] is int
          ? json['context_length'] as int
          : null,
      discoverModels: json['discover_models'] != false,
      hasApiKey: json['has_api_key'] == true,
      isCurrent: json['is_current'] == true,
      source: (json['source'] ?? '').toString(),
    );
  }
}

final class CustomEndpointCatalog {
  final List<CustomEndpoint> endpoints;

  const CustomEndpointCatalog(this.endpoints);

  factory CustomEndpointCatalog.fromJson(Map<String, dynamic> json) {
    final rows = json['endpoints'];
    return CustomEndpointCatalog(
      rows is List
          ? List<CustomEndpoint>.unmodifiable(rows.map(CustomEndpoint.fromJson))
          : const [],
    );
  }
}

final class CustomEndpointDraft {
  final String id;
  final String name;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String apiMode;
  final int? contextLength;
  final bool discoverModels;
  final bool makeDefault;
  final List<String>? models;
  final List<Map<String, dynamic>>? modelDetails;

  const CustomEndpointDraft({
    this.id = '',
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.apiMode = '',
    this.contextLength,
    this.discoverModels = true,
    this.makeDefault = false,
    this.models,
    this.modelDetails,
  });

  Map<String, dynamic> toJson() {
    final key = apiKey?.trim();
    return {
      'id': id,
      'name': name.trim(),
      'base_url': baseUrl.trim(),
      'model': model.trim(),
      if (key != null && key.isNotEmpty) 'api_key': key,
      'api_mode': apiMode,
      if (contextLength != null) 'context_length': contextLength,
      'discover_models': discoverModels,
      'make_default': makeDefault,
      if (models != null) 'models': models,
      if (modelDetails != null) 'model_details': modelDetails,
    };
  }
}

final class CustomEndpointValidation {
  final bool ok;
  final bool reachable;
  final String message;
  final List<String> models;
  final List<Map<String, dynamic>> modelDetails;
  final String resolvedBaseUrl;

  const CustomEndpointValidation({
    required this.ok,
    required this.reachable,
    required this.message,
    required this.models,
    required this.modelDetails,
    required this.resolvedBaseUrl,
  });

  factory CustomEndpointValidation.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'];
    final rawDetails = json['model_details'];
    return CustomEndpointValidation(
      ok: json['ok'] == true,
      reachable: json['reachable'] == true,
      message: (json['message'] ?? '').toString(),
      models: rawModels is List
          ? List<String>.unmodifiable(
              rawModels
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty),
            )
          : const [],
      modelDetails: rawDetails is List
          ? List<Map<String, dynamic>>.unmodifiable(
              rawDetails.whereType<Map>().map(
                (item) => Map<String, dynamic>.unmodifiable(
                  item.cast<String, dynamic>(),
                ),
              ),
            )
          : const [],
      resolvedBaseUrl: (json['resolved_base_url'] ?? '').toString(),
    );
  }
}

extension CustomEndpointsApi on DashboardClient {
  Future<CustomEndpointCatalog?> listCustomEndpoints({String? profile}) async {
    try {
      final json = await apiGet(
        'providers/custom-endpoints${_profileQuery(profile)}',
      );
      return CustomEndpointCatalog.fromJson(json);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return null;
      rethrow;
    }
  }

  Future<String> saveCustomEndpoint(
    CustomEndpointDraft draft, {
    String? profile,
  }) async {
    final json = await apiPost(
      'providers/custom-endpoints${_profileQuery(profile)}',
      body: draft.toJson(),
    );
    return (json['id'] ?? '').toString();
  }

  Future<CustomEndpointValidation> validateCustomEndpoint(
    CustomEndpointDraft draft,
  ) async => CustomEndpointValidation.fromJson(
    await apiPost('providers/custom-endpoints/validate', body: draft.toJson()),
  );

  Future<void> activateCustomEndpoint(String id, {String? profile}) async {
    await apiPost(
      'providers/custom-endpoints/${Uri.encodeComponent(id)}/activate'
      '${_profileQuery(profile)}',
    );
  }

  Future<void> deleteCustomEndpoint(String id, {String? profile}) async {
    await apiDelete(
      'providers/custom-endpoints/${Uri.encodeComponent(id)}'
      '${_profileQuery(profile)}',
    );
  }
}
