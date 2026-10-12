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
  final bool botRoutines;

  const CronRepository(this.client, {this.profile = '', this.botRoutines = false});

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
    // Record where each job was read from. The server's per-job `profile`
    // wins; without it a named read came from that profile and an unscoped
    // read from the server's default store. An aggregated read (`all`)
    // without it records nothing, so actions fall back to the bot owner or
    // refuse.
    final listed = switch (selectedProfile) {
      'all' => null,
      '' => 'default',
      final named => named,
    };
    return data
        .whereType<Map>()
        .map(
          (value) => CronJob.fromJson(
            value.cast<String, dynamic>(),
          ).withSourceProfile(listed),
        )
        .where((job) => job.id.isNotEmpty)
        .toList(growable: false);
  }

  /// `?profile=` (or `&profile=`) for an action on [job]: the profile that
  /// owns it, never this repository's screen profile. The default profile
  /// sends no query, the same as every other default-profile call.
  static String _ownerQuery(CronJob job, {bool hasQuery = false}) {
    final owner = ownerProfileOf(job);
    if (owner == 'default') return '';
    return '${hasQuery ? '&' : '?'}profile=${Uri.encodeQueryComponent(owner)}';
  }

  /// Profile that owns [job]; throws [CronJobOwnerUnknownException] when it
  /// cannot be told, so nothing is sent to a guessed profile.
  static String ownerProfileOf(CronJob job) {
    final owner = job.targetProfile;
    if (owner == null) throw CronJobOwnerUnknownException(job.id);
    return owner;
  }

  /// Runs an action on [job] in its owner profile. A 404 there means the
  /// job is not in that profile: typed, never a success.
  static Future<CronJob> _onOwner(
    CronJob job,
    Future<Map<String, dynamic>> Function(String query) send, {
    bool hasQuery = false,
  }) async {
    final query = _ownerQuery(job, hasQuery: hasQuery);
    final owner = ownerProfileOf(job);
    try {
      return CronJob.fromJson(await send(query)).withSourceProfile(owner);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404) throw CronJobNotFoundException(owner);
      rethrow;
    }
  }

  static bool _isUnsupportedAllProfiles(int statusCode) =>
      statusCode == 400 ||
      statusCode == 404 ||
      statusCode == 405 ||
      statusCode == 422 ||
      statusCode == 501;

  /// [profile] is the job's owner when known (see [CronJob.targetProfile]);
  /// otherwise this repository's profile is used.
  Future<CronJob?> getJob(String id, {String? profile}) async {
    final owner = profile?.trim() ?? '';
    final query = owner.isEmpty
        ? _query()
        : owner == 'default'
        ? ''
        : '?profile=${Uri.encodeQueryComponent(owner)}';
    try {
      final job = CronJob.fromJson(
        await client.apiGet('cron/jobs/${Uri.encodeComponent(id)}$query'),
      ).withSourceProfile(
        owner.isNotEmpty
            ? owner
            : (this.profile.isEmpty ? 'default' : this.profile),
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
        if (botRoutines) 'name': botRoutineName(profile, name, prompt)
        else if (name.isNotEmpty) 'name': name,
        'deliver': deliver.isEmpty ? 'local' : deliver,
        if (model.isNotEmpty) 'model': model,
        if (model.isNotEmpty && provider.isNotEmpty) 'provider': provider,
      },
    );
    // Created in this repository's profile.
    return CronJob.fromJson(
      data,
    ).withSourceProfile(profile.isEmpty ? 'default' : profile);
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
    final owner = ownerProfileOf(job);
    final updates = <String, dynamic>{
      'name': botRoutines ? botRoutineName(owner, name, prompt) : name,
      'schedule': schedule,
      'deliver': deliver,
      if (!job.isScriptOnly || prompt.isNotEmpty) 'prompt': prompt,
      if (!job.isScriptOnly) 'model': model.isEmpty ? null : model,
      if (!job.isScriptOnly) 'provider': provider.isEmpty ? null : provider,
    };
    return _onOwner(
      job,
      (query) => client.apiPut(
        'cron/jobs/${Uri.encodeComponent(job.id)}$query',
        body: {'updates': updates},
      ),
    );
  }

  Future<CronJob> pauseOrResume(CronJob job) {
    final action = job.isPaused ? 'resume' : 'pause';
    return _onOwner(
      job,
      (query) => client.apiPost(
        'cron/jobs/${Uri.encodeComponent(job.id)}/$action$query',
      ),
    );
  }

  /// Runs job [id] now (notification "Retry"); same endpoint as [trigger].
  Future<void> triggerById(String id) async {
    await client.apiPost(
      'cron/jobs/${Uri.encodeComponent(id)}/trigger${_query()}',
    );
  }

  Future<CronJob> trigger(CronJob job) => _onOwner(
    job,
    (query) => client.apiPost(
      'cron/jobs/${Uri.encodeComponent(job.id)}/trigger$query',
    ),
  );

  Future<CronJob> instantiateBlueprint(
    AutomationBlueprint blueprint,
    Map<String, String> values,
  ) async {
    final targetProfile = profile.isEmpty ? 'default' : profile;
    final data = await client.apiPost(
      'cron/blueprints/instantiate?profile=${Uri.encodeQueryComponent(targetProfile)}',
      body: {'blueprint': blueprint.key, 'values': values},
    );
    return CronJob.fromJson(data).withSourceProfile(targetProfile);
  }
}

String botRoutineName(String profile, String name, String prompt) {
  final owner = profile.trim().isEmpty ? 'default' : profile.trim();
  final prefix = '[bot:$owner] ';
  if (name.startsWith(prefix)) return name;
  final title = name.trim().isNotEmpty ? name.trim() : prompt.trim().split('\n').first;
  return '$prefix${title.length > 80 ? title.substring(0, 80) : title}';
}
