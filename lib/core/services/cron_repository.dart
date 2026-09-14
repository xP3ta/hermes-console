import '../models/cron_job.dart';
import 'connection_manager.dart';

enum CronProfileScope { active, all }

class CronJobListing {
  final List<CronJob> jobs;
  final CronProfileScope requestedScope;
  final bool usedLegacyActiveFallback;

  const CronJobListing({
    required this.jobs,
    required this.requestedScope,
    this.usedLegacyActiveFallback = false,
  });
}

/// Contrato móvil de Cron, construido sobre los mismos endpoints que Desktop.
class CronRepository {
  final DashboardClient client;
  final String profile;

  const CronRepository(this.client, {this.profile = ''});

  String _query({bool hasQuery = false}) {
    if (profile.isEmpty) return '';
    return '${hasQuery ? '&' : '?'}profile=${Uri.encodeQueryComponent(profile)}';
  }

  Future<List<CronJob>> listJobs() async =>
      (await listJobsForScope(CronProfileScope.active)).jobs;

  /// Amplía la consulta a todos los perfiles sin cambiar [profile], que sigue
  /// siendo el perfil operativo usado por CRUD. Dashboards anteriores a
  /// `profile=all` degradan a la lectura del perfil activo.
  Future<CronJobListing> listJobsForScope(CronProfileScope scope) async {
    if (scope == CronProfileScope.active) {
      return CronJobListing(
        jobs: await _listJobsWithProfile(profile),
        requestedScope: scope,
      );
    }
    try {
      return CronJobListing(
        jobs: await _listJobsWithProfile('all'),
        requestedScope: scope,
      );
    } on DashboardHttpException catch (error) {
      if (!_isUnsupportedAllProfiles(error.statusCode)) rethrow;
      return CronJobListing(
        jobs: await _listJobsWithProfile(profile),
        requestedScope: scope,
        usedLegacyActiveFallback: true,
      );
    }
  }

  Future<List<CronJob>> _listJobsWithProfile(String selectedProfile) async {
    final suffix = selectedProfile.isEmpty
        ? ''
        : '?profile=${Uri.encodeQueryComponent(selectedProfile)}';
    final data = await client.apiGetList('cron/jobs$suffix');
    return data
        .whereType<Map>()
        .map((value) => CronJob.fromJson(value.cast<String, dynamic>()))
        .where((job) => job.id.isNotEmpty)
        .toList(growable: false);
  }

  static bool _isUnsupportedAllProfiles(int statusCode) =>
      statusCode == 400 ||
      statusCode == 404 ||
      statusCode == 405 ||
      statusCode == 422 ||
      statusCode == 501;

  Future<CronJob?> getJob(String id) async {
    try {
      final job = CronJob.fromJson(
        await client.apiGet('cron/jobs/${Uri.encodeComponent(id)}${_query()}'),
      );
      return job.id.isEmpty ? null : job;
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<CronRuns> listRuns(String id, {int limit = 20}) async {
    try {
      final data = await client.apiGet(
        'cron/jobs/${Uri.encodeComponent(id)}/runs?limit=$limit${_query(hasQuery: true)}',
      );
      final raw = data['runs'] ?? data['data'];
      final sessions = (raw as List? ?? const [])
          .map(Session.tryParse)
          .whereType<Session>()
          .toList(growable: false);
      return CronRuns(sessions);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        return const CronRuns([], available: false);
      }
      rethrow;
    }
  }

  Future<List<CronDeliveryTarget>> deliveryTargets() async {
    try {
      final data = await client.apiGet('cron/delivery-targets');
      final targets = (data['targets'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                CronDeliveryTarget.fromJson(value.cast<String, dynamic>()),
          )
          .where((value) => value.id.isNotEmpty)
          .toList(growable: false);
      return targets.isEmpty ? const [CronDeliveryTarget.local] : targets;
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        return const [CronDeliveryTarget.local];
      }
      rethrow;
    }
  }

  Future<List<AutomationBlueprint>> blueprints() async {
    try {
      final data = await client.apiGet('cron/blueprints');
      return (data['blueprints'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                AutomationBlueprint.fromJson(value.cast<String, dynamic>()),
          )
          .where((value) => value.key.isNotEmpty)
          .toList(growable: false);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return const [];
      rethrow;
    }
  }

  Future<List<ModelProvider>> modelOptions() async {
    try {
      return await client.getModelOptions(
        profile: profile.isEmpty ? null : profile,
        explicitOnly: true,
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return const [];
      rethrow;
    }
  }

  Future<CronEditorResources> editorResources() async {
    Future<List<CronDeliveryTarget>> safeTargets() async {
      try {
        return await deliveryTargets();
      } catch (_) {
        return const [CronDeliveryTarget.local];
      }
    }

    Future<List<ModelProvider>> safeModels() async {
      try {
        return await modelOptions();
      } catch (_) {
        return const [];
      }
    }

    Future<List<AutomationBlueprint>> safeBlueprints() async {
      try {
        return await blueprints();
      } catch (_) {
        return const [];
      }
    }

    final results = await Future.wait<Object>([
      safeTargets(),
      safeModels(),
      safeBlueprints(),
    ]);
    return CronEditorResources(
      deliveryTargets: results[0] as List<CronDeliveryTarget>,
      modelProviders: results[1] as List<ModelProvider>,
      blueprints: results[2] as List<AutomationBlueprint>,
    );
  }

  Future<CronJob> create({
    required String name,
    required String prompt,
    required String schedule,
    required String deliver,
    required String model,
    required String provider,
  }) async {
    final data = await client.apiPost(
      'cron/jobs${_query()}',
      body: {
        'prompt': prompt,
        'schedule': schedule,
        if (name.isNotEmpty) 'name': name,
        'deliver': deliver.isEmpty ? 'local' : deliver,
        if (model.isNotEmpty) 'model': model,
        if (model.isNotEmpty && provider.isNotEmpty) 'provider': provider,
      },
    );
    return CronJob.fromJson(data);
  }

  Future<CronJob> update(
    CronJob job, {
    required String name,
    required String prompt,
    required String schedule,
    required String deliver,
    required String model,
    required String provider,
  }) async {
    final updates = <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'deliver': deliver,
      if (!job.isScriptOnly || prompt.isNotEmpty) 'prompt': prompt,
      if (!job.isScriptOnly) 'model': model.isEmpty ? null : model,
      if (!job.isScriptOnly) 'provider': provider.isEmpty ? null : provider,
    };
    final data = await client.apiPut(
      'cron/jobs/${Uri.encodeComponent(job.id)}${_query()}',
      body: {'updates': updates},
    );
    return CronJob.fromJson(data);
  }

  Future<CronJob> pauseOrResume(CronJob job) async {
    final action = job.isPaused ? 'resume' : 'pause';
    final data = await client.apiPost(
      'cron/jobs/${Uri.encodeComponent(job.id)}/$action${_query()}',
    );
    return CronJob.fromJson(data);
  }

  Future<CronJob> trigger(CronJob job) async {
    final data = await client.apiPost(
      'cron/jobs/${Uri.encodeComponent(job.id)}/trigger${_query()}',
    );
    return CronJob.fromJson(data);
  }

  Future<CronJob> instantiateBlueprint(
    AutomationBlueprint blueprint,
    Map<String, String> values,
  ) async {
    final targetProfile = profile.isEmpty ? 'default' : profile;
    final data = await client.apiPost(
      'cron/blueprints/instantiate?profile=${Uri.encodeQueryComponent(targetProfile)}',
      body: {'blueprint': blueprint.key, 'values': values},
    );
    return CronJob.fromJson(data);
  }
}
